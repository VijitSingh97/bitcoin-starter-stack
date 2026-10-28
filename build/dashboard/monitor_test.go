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
		return response(http.StatusOK, ""), nil
	})

	m.tick(map[string]any{"initialblockdownload": true, "blocks": float64(100)}, nil)
	m.tick(nil, nil)
	m.tick(nil, nil)
	m.tick(nil, nil)
	m.tick(map[string]any{"initialblockdownload": false, "blocks": float64(900000)}, nil)
	m.tick(map[string]any{"initialblockdownload": false, "blocks": float64(900001)}, nil)

	want := []string{
		"[alice] 🔴 node down — RPC unreachable for 3 minutes",
		"[alice] 🟢 node recovered — RPC is answering again",
		"[alice] ✅ initial sync complete at height 900000",
		"[alice] 🟧 new block 900001",
	}
	if strings.Join(messages, "\n") != strings.Join(want, "\n") {
		t.Fatalf("messages:\n%s\nwant:\n%s", strings.Join(messages, "\n"), strings.Join(want, "\n"))
	}
}

func TestHealthchecksRetriesThenThrottlesAndUsesFailEndpoint(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	t.Setenv("HEALTHCHECKS_URL", "https://hc-ping.com/private-uuid/")
	m := NewMonitor("dev", t.TempDir(), t.TempDir())
	m.diskFreeGB = func(string) (float64, error) { return 1000, nil }
	m.output = io.Discard
	var paths []string
	attempt := 0
	m.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		paths = append(paths, r.URL.Path)
		attempt++
		if attempt < 3 {
			return response(http.StatusBadGateway, ""), nil
		}
		return response(http.StatusOK, ""), nil
	})}

	m.tick(nil, nil)
	m.tick(nil, nil)
	m.tick(nil, nil)
	for range 4 {
		m.tick(map[string]any{"initialblockdownload": false}, nil)
	}
	if got, want := strings.Join(paths, ","), "/private-uuid/fail,/private-uuid/fail,/private-uuid/fail"; got != want {
		t.Fatalf("paths = %q, want %q", got, want)
	}
	m.tick(map[string]any{"initialblockdownload": false}, nil)
	if len(paths) != 4 || paths[3] != "/private-uuid" {
		t.Fatalf("paths after cadence = %v", paths)
	}
}

func TestUpdateCheckKeepsBadgeAndDoesNotRepeatAlert(t *testing.T) {
	var telegrams int
	m := configuredMonitor(t, func(r *http.Request) (*http.Response, error) {
		switch r.URL.Host {
		case "api.github.com":
			if strings.Contains(r.URL.Path, "bitcoin-starter-stack") {
				return response(http.StatusOK, `{"tag_name":"v1.3.0"}`), nil
			}
			return response(http.StatusOK, `{"tag_name":"v32.0"}`), nil
		case "api.telegram.org":
			telegrams++
			return response(http.StatusOK, ""), nil
		default:
			t.Fatalf("unexpected host %q", r.URL.Host)
			return nil, nil
		}
	})

	m.checkUpdates("/Satoshi:31.1.0/")
	m.checkUpdates("/Satoshi:31.1.0/")
	want := "stack v1.3.0 available (running v1.2.0); Bitcoin Core 32.0 available (running 31.1.0)"
	if got := m.UpdateNote(); got != want {
		t.Fatalf("UpdateNote() = %q, want %q", got, want)
	}
	if telegrams != 2 {
		t.Fatalf("telegram sends = %d, want 2", telegrams)
	}
	if newer("31.1", "31.1.0") || newer("1.12.0", "1.12.1") || !newer("32.0", "31.1.0") {
		t.Fatal("numeric version ordering changed")
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
	m.sendTelegram("🔴 node down")
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
		return response(http.StatusOK, ""), nil
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
	m.sendTelegram("hello")
	m.pingHealthchecks(true)
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
