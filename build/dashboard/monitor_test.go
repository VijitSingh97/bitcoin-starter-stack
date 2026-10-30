package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func response(code int, body string) *http.Response {
	return &http.Response{
		StatusCode: code,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     make(http.Header),
	}
}

func configuredMonitor(t *testing.T, handler roundTripFunc) *Monitor {
	t.Helper()
	t.Setenv("TELEGRAM_BOT_TOKEN", "123:secret")
	t.Setenv("TELEGRAM_CHAT_ID", "42")
	t.Setenv("NODE_NAME", "alice")
	t.Setenv("ALERT_NEW_BLOCK", "1")
	t.Setenv("HEALTHCHECKS_URL", "")
	m := NewMonitor("1.2.0", t.TempDir(), t.TempDir())
	m.client = &http.Client{Transport: handler}
	m.diskFreeGB = func(string) (float64, error) { return 1000, nil }
	m.output = io.Discard
	return m
}

func TestMonitorStateTransitionsAndExactMessages(t *testing.T) {
	var messages []string
	m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
		var payload struct {
			ChatID string `json:"chat_id"`
			Text   string `json:"text"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.ChatID != "42" {
			t.Fatalf("chat id = %q", payload.ChatID)
		}
		messages = append(messages, payload.Text)
		return response(http.StatusOK, `{"ok":true}`), nil
	})

	m.tick(t.Context(), map[string]any{"initialblockdownload": true, "blocks": float64(100)}, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), map[string]any{"initialblockdownload": true, "blocks": float64(200)}, nil)
	m.tick(t.Context(), map[string]any{"initialblockdownload": false, "blocks": float64(900000)}, nil)
	m.tick(t.Context(), map[string]any{"initialblockdownload": false, "blocks": float64(900001)}, nil)

	want := []string{
		"[alice] ✅ initial sync complete at height 900000",
		"[alice] 🟧 new block 900001",
	}
	if strings.Join(messages, "\n") != strings.Join(want, "\n") {
		t.Fatalf("messages:\n%s\nwant:\n%s", strings.Join(messages, "\n"), strings.Join(want, "\n"))
	}
}

func TestUnknownStartupAndInitialSyncSuppressAutomaticTelegram(t *testing.T) {
	var telegrams int
	m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
		switch r.URL.Host {
		case "api.github.com":
			return response(http.StatusOK, `{"tag_name":"v1.3.0"}`), nil
		case "api.telegram.org":
			telegrams++
			return response(http.StatusOK, `{"ok":true}`), nil
		default:
			t.Fatalf("unexpected host %q", r.URL.Host)
			return nil, nil
		}
	})
	m.diskFreeGB = func(string) (float64, error) { return 40, nil }

	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.state.ticks = 0
	m.tick(t.Context(), map[string]any{"blocks": float64(1)}, map[string]any{})
	m.state.ticks = 0
	m.tick(t.Context(), map[string]any{"initialblockdownload": true, "blocks": float64(100)}, map[string]any{})

	if telegrams != 0 {
		t.Fatalf("automatic Telegram sends during unknown startup or sync = %d", telegrams)
	}
	if got := m.UpdateNote(); got != "stack v1.3.0 available (running v1.2.0)" {
		t.Fatalf("silent release note = %q", got)
	}
	if m.state.notifiedStack != "" {
		t.Fatalf("silent release was marked notified: %q", m.state.notifiedStack)
	}
}

func TestOperationalAlertsRetryUntilDelivered(t *testing.T) {
	var messages []string
	attempt := 0
	m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
		var payload struct {
			Text string `json:"text"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		messages = append(messages, payload.Text)
		attempt++
		switch attempt {
		case 1:
			return response(http.StatusBadGateway, `{"ok":false}`), nil
		case 3:
			return response(http.StatusOK, `{"ok":false}`), nil
		default:
			return response(http.StatusOK, `{"ok":true}`), nil
		}
	})

	m.tick(t.Context(), map[string]any{"initialblockdownload": false, "blocks": float64(100)}, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), map[string]any{"initialblockdownload": false}, nil)
	m.tick(t.Context(), map[string]any{"initialblockdownload": false}, nil)
	m.tick(t.Context(), map[string]any{"initialblockdownload": false}, nil)

	want := []string{
		"[alice] 🔴 node down — RPC unreachable for 3 minutes",
		"[alice] 🔴 node down — RPC unreachable for 3 minutes",
		"[alice] 🟢 node recovered — RPC is answering again",
		"[alice] 🟢 node recovered — RPC is answering again",
	}
	if strings.Join(messages, "\n") != strings.Join(want, "\n") {
		t.Fatalf("operational retries:\n%s\nwant:\n%s", strings.Join(messages, "\n"), strings.Join(want, "\n"))
	}
	if m.state.downAlerted || m.state.fails != 0 {
		t.Fatalf("recovered state = downAlerted %v, fails %d", m.state.downAlerted, m.state.fails)
	}
}

func TestSyncAndNewBlockAlertsRetryUntilDelivered(t *testing.T) {
	for _, test := range []struct {
		name  string
		ticks []map[string]any
		want  string
	}{
		{
			name: "sync complete",
			ticks: []map[string]any{
				{"initialblockdownload": true, "blocks": float64(100)},
				{"initialblockdownload": false, "blocks": float64(100)},
				{"initialblockdownload": false, "blocks": float64(100)},
				{"initialblockdownload": false, "blocks": float64(100)},
			},
			want: "[alice] ✅ initial sync complete at height 100",
		},
		{
			name: "new block",
			ticks: []map[string]any{
				{"initialblockdownload": false, "blocks": float64(100)},
				{"initialblockdownload": false, "blocks": float64(101)},
				{"initialblockdownload": false, "blocks": float64(101)},
				{"initialblockdownload": false, "blocks": float64(101)},
			},
			want: "[alice] 🟧 new block 101",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			var messages []string
			m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
				var payload struct {
					Text string `json:"text"`
				}
				_ = json.NewDecoder(r.Body).Decode(&payload)
				messages = append(messages, payload.Text)
				if len(messages) == 1 {
					return response(http.StatusBadGateway, `{"ok":false}`), nil
				}
				return response(http.StatusOK, `{"ok":true}`), nil
			})
			for _, info := range test.ticks {
				m.tick(t.Context(), info, nil)
			}
			if len(messages) != 2 || messages[0] != test.want || messages[1] != test.want {
				t.Fatalf("retry messages = %#v, want two %q", messages, test.want)
			}
		})
	}
}

func TestSyncCompleteRetryWaitsForConfirmedCompletedState(t *testing.T) {
	var messages []string
	m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
		var payload struct {
			Text string `json:"text"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		messages = append(messages, payload.Text)
		if len(messages) == 1 {
			return response(http.StatusBadGateway, `{"ok":false}`), nil
		}
		return response(http.StatusOK, `{"ok":true}`), nil
	})
	m.settings.AlertNewBlock = false

	m.tick(t.Context(), map[string]any{"initialblockdownload": true, "blocks": float64(100)}, nil)
	m.tick(t.Context(), map[string]any{"initialblockdownload": false, "blocks": float64(200)}, nil)
	m.tick(t.Context(), map[string]any{"initialblockdownload": true, "blocks": float64(201)}, nil)
	m.tick(t.Context(), map[string]any{"blocks": float64(202)}, nil)
	if len(messages) != 1 {
		t.Fatalf("sync completion retried without a confirmed completed state: %#v", messages)
	}
	m.tick(t.Context(), map[string]any{"initialblockdownload": false, "blocks": float64(203)}, nil)

	want := "[alice] ✅ initial sync complete"
	if len(messages) != 2 || !strings.Contains(messages[0], want) || !strings.Contains(messages[1], want) {
		t.Fatalf("sync completion retries = %#v", messages)
	}
}

func TestDiskAlertRetriesUntilDelivered(t *testing.T) {
	free := 40.0
	var messages []string
	m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
		var payload struct {
			Text string `json:"text"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		messages = append(messages, payload.Text)
		if len(messages) == 1 {
			return response(http.StatusBadGateway, `{"ok":false}`), nil
		}
		return response(http.StatusOK, `{"ok":true}`), nil
	})
	m.diskFreeGB = func(string) (float64, error) { return free, nil }
	info := map[string]any{"initialblockdownload": false}
	m.tick(t.Context(), info, nil)
	m.tick(t.Context(), info, nil)
	m.tick(t.Context(), info, nil)
	free = 100
	m.tick(t.Context(), info, nil)
	free = 40
	m.tick(t.Context(), info, nil)
	if got, want := strings.Join(messages, "\n"), strings.Join([]string{
		"[alice] 💾 disk low: 40 GB free",
		"[alice] 💾 disk low: 40 GB free",
		"[alice] 💾 disk low: 40 GB free",
	}, "\n"); got != want {
		t.Fatalf("disk retry messages:\n%s\nwant:\n%s", got, want)
	}
}

func TestDisabledTelegramDoesNotRetryOperationalAlerts(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	t.Setenv("TELEGRAM_CHAT_ID", "")
	stateDir := t.TempDir()
	m := NewMonitor("dev", t.TempDir(), stateDir)
	m.output = io.Discard
	m.diskFreeGB = func(string) (float64, error) { return 40, nil }
	m.client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("disabled Telegram made an HTTP request")
		return nil, nil
	})}
	info := map[string]any{"initialblockdownload": false}
	m.tick(t.Context(), info, nil)
	m.tick(t.Context(), info, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)

	events, err := os.ReadFile(filepath.Join(stateDir, "events.log"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(events), "disk low") != 1 || strings.Count(string(events), "node down") != 1 {
		t.Fatalf("disabled Telegram repeated operational events: %q", events)
	}
}

func TestHealthchecksRetriesThenThrottlesAndUsesFailEndpoint(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	t.Setenv("HEALTHCHECKS_URL", "https://hc-ping.com/private-uuid/?source=node")
	m := NewMonitor("dev", t.TempDir(), t.TempDir())
	m.diskFreeGB = func(string) (float64, error) { return 1000, nil }
	m.output = io.Discard
	var paths []string
	attempt := 0
	m.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		paths = append(paths, r.URL.RequestURI())
		attempt++
		if attempt < 3 {
			return response(http.StatusBadGateway, ""), nil
		}
		return response(http.StatusOK, ""), nil
	})}

	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	if len(paths) != 0 {
		t.Fatalf("transient failures pinged Healthchecks: %v", paths)
	}
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	m.tick(t.Context(), nil, nil)
	if got, want := strings.Join(paths, ","), "/private-uuid/fail?source=node,/private-uuid/fail?source=node,/private-uuid/fail?source=node"; got != want {
		t.Fatalf("sustained failure paths = %q, want %q", got, want)
	}
	for range 5 {
		m.tick(t.Context(), map[string]any{"initialblockdownload": false}, nil)
	}
	if len(paths) != 4 || paths[3] != "/private-uuid/?source=node" {
		t.Fatalf("paths after cadence = %v", paths)
	}
}

func TestUpdateCheckKeepsBadgeAndDoesNotRepeatAlert(t *testing.T) {
	var telegrams, stackChecks, coreChecks int
	m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
		switch r.URL.Host {
		case "api.github.com":
			if strings.Contains(r.URL.Path, "bitcoin-starter-stack") {
				stackChecks++
				return response(http.StatusOK, `{"tag_name":"v1.3.0"}`), nil
			}
			coreChecks++
			return response(http.StatusOK, `{"tag_name":"v32.0"}`), nil
		case "api.telegram.org":
			telegrams++
			return response(http.StatusOK, `{"ok":true}`), nil
		default:
			t.Fatalf("unexpected host %q", r.URL.Host)
			return nil, nil
		}
	})

	m.checkUpdates(t.Context())
	m.checkUpdates(t.Context())
	want := "stack v1.3.0 available (running v1.2.0)"
	if got := m.UpdateNote(); got != want {
		t.Fatalf("UpdateNote() = %q, want %q", got, want)
	}
	if telegrams != 1 {
		t.Fatalf("telegram sends = %d, want 1", telegrams)
	}
	if stackChecks != 2 || coreChecks != 0 {
		t.Fatalf("release checks = stack %d, Core %d", stackChecks, coreChecks)
	}
	if newer("31.1", "31.1.0") || newer("1.12.0", "1.12.1") || !newer("32.0", "31.1.0") {
		t.Fatal("numeric version ordering changed")
	}
}

func TestUpdateCheckUsesBakedBaselineAndPersistsAlert(t *testing.T) {
	workingDirectory, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	imageDirectory := t.TempDir()
	if err := os.WriteFile(filepath.Join(imageDirectory, "VERSION"), []byte("1.31.1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(imageDirectory); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(workingDirectory) })

	t.Setenv("TELEGRAM_BOT_TOKEN", "123:secret")
	t.Setenv("TELEGRAM_CHAT_ID", "42")
	stateDir := t.TempDir()
	telegrams := 0
	handler := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Host {
		case "api.github.com":
			return response(http.StatusOK, `{"tag_name":"v1.32.0"}`), nil
		case "api.telegram.org":
			telegrams++
			switch telegrams {
			case 1:
				return response(http.StatusBadGateway, `{"ok":false}`), nil
			case 2:
				return response(http.StatusOK, `{"ok":false}`), nil
			default:
				return response(http.StatusOK, `{"ok":true}`), nil
			}
		default:
			t.Fatalf("unexpected host %q", r.URL.Host)
			return nil, nil
		}
	})
	m := NewMonitor("7101c3a", t.TempDir(), stateDir)
	m.client = &http.Client{Transport: handler}
	m.output = io.Discard
	m.checkUpdates(t.Context())
	if got, want := m.UpdateNote(), "stack v1.32.0 available (running v1.31.1)"; got != want {
		t.Fatalf("UpdateNote() = %q, want %q", got, want)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "monitor_state.json")); !os.IsNotExist(err) {
		t.Fatalf("failed delivery persisted monitor state: %v", err)
	}
	m.checkUpdates(t.Context())
	if _, err := os.Stat(filepath.Join(stateDir, "monitor_state.json")); !os.IsNotExist(err) {
		t.Fatalf("rejected Telegram response persisted monitor state: %v", err)
	}
	m.checkUpdates(t.Context())

	persisted, err := os.ReadFile(filepath.Join(stateDir, "monitor_state.json"))
	if err != nil || !strings.Contains(string(persisted), `"notified_stack":"1.32.0"`) {
		t.Fatalf("successful delivery state = %q, %v", persisted, err)
	}
	legacy := []byte(`{"notified_stack":"1.32.0","notified_core":"32.0"}`)
	if err = os.WriteFile(filepath.Join(stateDir, "monitor_state.json"), legacy, 0o600); err != nil {
		t.Fatal(err)
	}
	restarted := NewMonitor("7101c3a", t.TempDir(), stateDir)
	restarted.client = &http.Client{Transport: handler}
	restarted.output = io.Discard
	restarted.checkUpdates(t.Context())
	if telegrams != 3 {
		t.Fatalf("telegram sends across retries and restart = %d, want 3", telegrams)
	}
}

func TestUpdateCheckWaitsForTelegramConfiguration(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	t.Setenv("TELEGRAM_CHAT_ID", "")
	stateDir := t.TempDir()
	release := func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.github.com" {
			t.Fatalf("unexpected request to %q", r.URL.Host)
		}
		return response(http.StatusOK, `{"tag_name":"v1.3.0"}`), nil
	}
	m := NewMonitor("1.2.0", t.TempDir(), stateDir)
	m.client = &http.Client{Transport: roundTripFunc(release)}
	m.output = io.Discard
	m.checkUpdates(t.Context())
	if _, err := os.Stat(filepath.Join(stateDir, "monitor_state.json")); !os.IsNotExist(err) {
		t.Fatalf("disabled Telegram persisted monitor state: %v", err)
	}

	t.Setenv("TELEGRAM_BOT_TOKEN", "123:secret")
	t.Setenv("TELEGRAM_CHAT_ID", "42")
	sent := 0
	restarted := NewMonitor("1.2.0", t.TempDir(), stateDir)
	restarted.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "api.telegram.org" {
			sent++
			return response(http.StatusOK, `{"ok":true}`), nil
		}
		return release(r)
	})}
	restarted.output = io.Discard
	restarted.checkUpdates(t.Context())
	if sent != 1 {
		t.Fatalf("Telegram sends after configuration = %d, want 1", sent)
	}
}

func TestEventLogRotatesAndUsesUTCTimestamp(t *testing.T) {
	stateDir := t.TempDir()
	logPath := filepath.Join(stateDir, "events.log")
	if err := os.WriteFile(logPath, []byte(strings.Repeat("old line\n", 120000)), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	m := NewMonitor("dev", t.TempDir(), stateDir)
	m.output = io.Discard
	m.now = func() time.Time { return time.Date(2026, 10, 27, 1, 2, 3, 0, time.FixedZone("local", -5*3600)) }
	m.sendTelegram(t.Context(), "🔴 node down")
	b, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	if len(lines) != 60001 || lines[len(lines)-1] != "2026-10-27T06:02:03Z 🔴 node down" {
		t.Fatalf("rotated log has %d lines, last %q", len(lines), lines[len(lines)-1])
	}
}

func TestRunSendsOnlineAndStopsWithContext(t *testing.T) {
	seen := make(chan string, 2)
	m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
		var payload struct {
			Text string `json:"text"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		seen <- payload.Text
		return response(http.StatusOK, `{"ok":true}`), nil
	})
	m.tickEvery = time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		m.Run(ctx, func() map[string]any { return map[string]any{"initialblockdownload": false} }, nil)
		close(done)
	}()
	select {
	case got := <-seen:
		if got != "[alice] 🚀 node monitor online" {
			t.Fatalf("online message = %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("online message was not sent")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Run did not stop after cancellation")
	}
}

func TestRunDoesNotSendOnlineDuringInitialSync(t *testing.T) {
	var telegrams atomic.Int32
	m := configuredMonitor(t, func(*http.Request) (*http.Response, error) {
		telegrams.Add(1)
		return response(http.StatusOK, `{"ok":true}`), nil
	})
	m.tickEvery = time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		m.Run(ctx, func() map[string]any { return map[string]any{"initialblockdownload": true} }, nil)
		close(done)
	}()
	time.Sleep(10 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Run did not stop after cancellation")
	}
	if got := telegrams.Load(); got != 0 {
		t.Fatalf("initial sync Telegram sends = %d", got)
	}
}

func TestRunCancellationStopsReleaseCheck(t *testing.T) {
	m := NewMonitor("1.2.0", t.TempDir(), t.TempDir())
	m.diskFreeGB = func(string) (float64, error) { return 1000, nil }
	started := make(chan struct{})
	m.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		close(started)
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		m.Run(ctx,
			func() map[string]any { return map[string]any{"initialblockdownload": false} },
			func() map[string]any { return map[string]any{} },
		)
		close(done)
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("release check did not start")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Run did not cancel an in-flight release check")
	}
}

func TestMonitorRequestsHonorParentCancellation(t *testing.T) {
	tests := []struct {
		name  string
		setup func(*Monitor)
		call  func(context.Context, *Monitor) bool
	}{
		{name: "Telegram", call: func(ctx context.Context, m *Monitor) bool { return m.sendTelegram(ctx, "test") }},
		{
			name: "Healthchecks",
			setup: func(m *Monitor) {
				m.settings.HealthchecksEnabled = true
				m.settings.HealthchecksURL = "https://healthchecks.io/test"
			},
			call: func(ctx context.Context, m *Monitor) bool { return m.pingHealthchecks(ctx, true) },
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			started := make(chan struct{})
			m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
				close(started)
				<-r.Context().Done()
				return nil, r.Context().Err()
			})
			if test.setup != nil {
				test.setup(m)
			}
			ctx, cancel := context.WithCancel(t.Context())
			done := make(chan struct{})
			go func() {
				test.call(ctx, m)
				close(done)
			}()
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("request did not start")
			}
			cancel()
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("request did not stop after parent cancellation")
			}
		})
	}
}

func TestRunSyncsWithoutOnlineAndSendsOneCompletion(t *testing.T) {
	messages := make(chan string, 4)
	m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
		var payload struct {
			Text string `json:"text"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		messages <- payload.Text
		return response(http.StatusOK, `{"ok":true}`), nil
	})
	m.tickEvery = time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var calls atomic.Int32
	done := make(chan struct{})
	go func() {
		m.Run(ctx, func() map[string]any {
			switch calls.Add(1) {
			case 1:
				return map[string]any{"initialblockdownload": true, "blocks": float64(100)}
			case 2:
				return map[string]any{"initialblockdownload": false, "blocks": float64(200)}
			default:
				<-ctx.Done()
				return nil
			}
		}, nil)
		close(done)
	}()

	select {
	case got := <-messages:
		if got != "[alice] ✅ initial sync complete at height 200" {
			t.Fatalf("sync transition message = %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("sync completion message was not sent")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Run did not stop after cancellation")
	}
	select {
	case extra := <-messages:
		t.Fatalf("unexpected extra sync transition message: %q", extra)
	default:
	}
}

func TestTorTransportUsesRemoteDNSForHTTPAndHTTPS(t *testing.T) {
	for _, scheme := range []string{"http", "https"} {
		t.Run(scheme, func(t *testing.T) {
			var backend *httptest.Server
			if scheme == "https" {
				backend = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))
			} else {
				backend = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))
			}
			defer backend.Close()
			proxy, domains := fakeSOCKSProxy(t, backend.Listener.Addr().String(), false)
			client := newTorHTTPClient(proxy)
			if scheme == "https" {
				client.Transport.(*http.Transport).TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
			}
			resp, err := client.Get(scheme + "://remote.example:9443/check")
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusNoContent {
				t.Fatalf("status = %d", resp.StatusCode)
			}
			select {
			case got := <-domains:
				if got != "remote.example" {
					t.Fatalf("SOCKS destination = %q", got)
				}
			case <-time.After(time.Second):
				t.Fatal("SOCKS handshake not observed")
			}
		})
	}
}

func TestTorTransportNeverFallsBackToDirect(t *testing.T) {
	var direct atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { direct.Add(1) }))
	defer origin.Close()
	proxy, _ := fakeSOCKSProxy(t, "", true)
	client := newTorHTTPClient(proxy)
	client.Timeout = time.Second
	if _, err := client.Get(origin.URL); err == nil {
		t.Fatal("request unexpectedly succeeded")
	}
	if direct.Load() != 0 {
		t.Fatal("request fell back to a direct connection")
	}
}

func TestHealthchecksRejectsUnencryptedOrCredentialedURLs(t *testing.T) {
	for _, endpoint := range []string{"http://hc-ping.com/secret", "https://user:secret@hc-ping.com/id", "https:///id"} {
		t.Run(endpoint, func(t *testing.T) {
			m := configuredMonitor(t, func(*http.Request) (*http.Response, error) {
				t.Fatal("invalid URL reached the network")
				return nil, nil
			})
			m.settings.HealthchecksEnabled = true
			m.settings.HealthchecksURL = endpoint
			if m.pingHealthchecks(t.Context(), true) {
				t.Fatal("invalid Healthchecks URL was accepted")
			}
		})
	}
}

func TestTorClientDoesNotFollowRedirects(t *testing.T) {
	client := newTorHTTPClient("127.0.0.1:1")
	var requests int
	client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		requests++
		resp := response(http.StatusFound, "")
		resp.Header.Set("Location", "http://other.example/leaked-secret")
		return resp, nil
	})
	resp, err := client.Get("https://original.example/secret")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if requests != 1 || resp.StatusCode != http.StatusFound {
		t.Fatalf("redirect followed: requests=%d status=%d", requests, resp.StatusCode)
	}
}

func TestSOCKSHandshakeCancellationClosesStalledConnection(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	accepted := make(chan struct{})
	closed := make(chan struct{})
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		close(accepted)
		_, _ = io.Copy(io.Discard, conn)
		close(closed)
	}()

	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, err := socks5DialContext(ln.Addr().String())(ctx, "tcp", "remote.example:443")
		result <- err
	}()
	select {
	case <-accepted:
	case <-time.After(time.Second):
		t.Fatal("proxy did not accept connection")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("dial error = %v, want context canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled SOCKS handshake did not return")
	}
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("canceled SOCKS handshake did not close connection")
	}
}

func TestTransportErrorsRedactSecrets(t *testing.T) {
	var output strings.Builder
	t.Setenv("TELEGRAM_BOT_TOKEN", "123:top-secret")
	t.Setenv("TELEGRAM_CHAT_ID", "42")
	t.Setenv("HEALTHCHECKS_URL", "https://hc-ping.com/private-uuid")
	m := NewMonitor("dev", t.TempDir(), t.TempDir())
	m.output = &output
	m.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, errors.New(r.URL.String())
	})}
	m.sendTelegram(t.Context(), "hello")
	m.pingHealthchecks(t.Context(), true)
	got := output.String()
	if strings.Contains(got, "top-secret") || strings.Contains(got, "private-uuid") {
		t.Fatalf("secret leaked in output: %q", got)
	}
}

func fakeSOCKSProxy(t *testing.T, backend string, reject bool) (string, <-chan string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	domains := make(chan string, 2)
	var wg sync.WaitGroup
	t.Cleanup(func() {
		ln.Close()
		wg.Wait()
	})
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				handleSOCKSConn(conn, backend, reject, domains)
			}()
		}
	}()
	return ln.Addr().String(), domains
}

func handleSOCKSConn(conn net.Conn, backend string, reject bool, domains chan<- string) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	hello := make([]byte, 3)
	if _, err := io.ReadFull(r, hello); err != nil || string(hello) != "\x05\x01\x00" {
		return
	}
	_, _ = conn.Write([]byte{5, 0})
	head := make([]byte, 4)
	if _, err := io.ReadFull(r, head); err != nil || head[0] != 5 || head[1] != 1 {
		return
	}
	var host string
	switch head[3] {
	case 1:
		b := make([]byte, 4)
		_, _ = io.ReadFull(r, b)
		host = net.IP(b).String()
	case 3:
		n, err := r.ReadByte()
		if err != nil {
			return
		}
		b := make([]byte, int(n))
		_, _ = io.ReadFull(r, b)
		host = string(b)
	case 4:
		b := make([]byte, 16)
		_, _ = io.ReadFull(r, b)
		host = net.IP(b).String()
	default:
		return
	}
	port := make([]byte, 2)
	_, _ = io.ReadFull(r, port)
	_ = binary.BigEndian.Uint16(port)
	domains <- host
	if reject {
		_, _ = conn.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	upstream, err := net.Dial("tcp", backend)
	if err != nil {
		_, _ = conn.Write([]byte{5, 1, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer upstream.Close()
	_, _ = conn.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 0})
	go io.Copy(upstream, r)
	_, _ = io.Copy(conn, upstream)
}
