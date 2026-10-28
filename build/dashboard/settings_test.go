package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func settingsRequest(handler http.Handler, method, password, body string, csrf bool) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, "/api/settings", strings.NewReader(body))
	req.RemoteAddr = "192.0.2.10:12345"
	req.Host = "spoofed-address.onion"
	req.Header.Set("X-Forwarded-Proto", "https")
	if password != "" {
		req.SetBasicAuth("dashboard", password)
	}
	if csrf {
		req.Header.Set("X-Requested-With", "fetch")
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	return w
}

func TestSettingsAPIRequiresPasswordAndNeverReturnsSecrets(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "123:top-secret")
	t.Setenv("TELEGRAM_CHAT_ID", "-10042")
	t.Setenv("HEALTHCHECKS_URL", "https://hc-ping.com/private-uuid")
	t.Setenv("ALERT_NEW_BLOCK", "1")

	_, noPasswordHandler := testApp(t, &rpcFixture{}, "")
	if got := settingsRequest(noPasswordHandler, http.MethodGet, "", "", false); got.Code != http.StatusForbidden {
		t.Fatalf("GET without configured password = %d, want 403", got.Code)
	}

	_, handler := testApp(t, &rpcFixture{}, "dashboard-secret")
	if got := settingsRequest(handler, http.MethodGet, "", "", false); got.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated GET = %d, want 401", got.Code)
	}
	if got := settingsRequest(handler, http.MethodGet, "wrong-password", "", false); got.Code != http.StatusUnauthorized {
		t.Fatalf("wrong-password GET = %d, want 401", got.Code)
	}
	response := settingsRequest(handler, http.MethodGet, "dashboard-secret", "", false)
	if response.Code != http.StatusOK {
		t.Fatalf("GET status = %d: %s", response.Code, response.Body.String())
	}
	body := response.Body.String()
	if strings.Contains(body, "top-secret") || strings.Contains(body, "private-uuid") {
		t.Fatalf("GET leaked a secret: %s", body)
	}
	var view map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	if view["telegram_enabled"] != true || view["telegram_bot_token_set"] != true || view["telegram_chat_id"] != "-10042" || view["healthchecks_enabled"] != true || view["healthchecks_url_set"] != true || view["alert_new_block"] != true || view["overridden"] != false {
		t.Fatalf("unexpected settings view: %#v", view)
	}
	if view["can_configure"] != true {
		t.Fatalf("authenticated LAN settings view is not configurable: %#v", view)
	}
}

func TestSettingsLANWriteRequiresAuthAndCSRFPersistsAcrossRestart(t *testing.T) {
	a, handler := testApp(t, &rpcFixture{}, "dashboard-secret")
	body := `{"telegram_enabled":false,"telegram_chat_id":"","healthchecks_enabled":false,"alert_new_block":true}`
	if got := settingsRequest(handler, http.MethodPost, "", body, true); got.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated LAN POST = %d, want 401", got.Code)
	}
	if got := settingsRequest(handler, http.MethodPost, "wrong-password", body, true); got.Code != http.StatusUnauthorized {
		t.Fatalf("wrong-password LAN POST = %d, want 401", got.Code)
	}
	if got := settingsRequest(handler, http.MethodPost, "dashboard-secret", body, false); got.Code != http.StatusForbidden {
		t.Fatalf("LAN POST without CSRF header = %d, want 403", got.Code)
	}
	if a.monitor.settingsOverridden {
		t.Fatal("rejected LAN POST changed settings")
	}
	post := settingsRequest(handler, http.MethodPost, "dashboard-secret", body, true)
	if post.Code != http.StatusOK {
		t.Fatalf("authenticated LAN POST = %d: %s", post.Code, post.Body.String())
	}

	root := filepath.Dir(sourceFile(t))
	restarted, err := newApp(a.cfg, a.rpc, filepath.Join(root, "index.html"), filepath.Join(root, "static"), log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	get := settingsRequest(restarted.routes(), http.MethodGet, "dashboard-secret", "", false)
	var view map[string]any
	if get.Code != http.StatusOK || json.Unmarshal(get.Body.Bytes(), &view) != nil {
		t.Fatalf("restarted LAN GET = %d %#v", get.Code, view)
	}
	if view["can_configure"] != true || view["overridden"] != true || view["alert_new_block"] != true {
		t.Fatalf("restarted LAN settings view = %#v", view)
	}
}

func TestSettingsPersistRestartAndResetToServerConfig(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "123:server-token")
	t.Setenv("TELEGRAM_CHAT_ID", "server-chat")
	t.Setenv("HEALTHCHECKS_URL", "https://hc-ping.com/server-id")
	t.Setenv("ALERT_NEW_BLOCK", "0")
	stateDir := t.TempDir()
	m := NewMonitor("dev", t.TempDir(), stateDir)

	update := settingsUpdate{
		TelegramEnabled:     boolPointer(true),
		TelegramBotToken:    stringPointer("456:dashboard-token"),
		TelegramChatID:      stringPointer("dashboard-chat"),
		HealthchecksEnabled: boolPointer(true),
		HealthchecksURL:     stringPointer("https://hc-ping.com/dashboard-id/"),
		AlertNewBlock:       boolPointer(true),
	}
	if err := m.updateSettings(update); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(stateDir, "notification_settings.json")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("settings mode = %o, want 600", info.Mode().Perm())
	}

	restarted := NewMonitor("dev", t.TempDir(), stateDir)
	got := restarted.notificationSettings()
	if got.TelegramBotToken != "456:dashboard-token" || got.TelegramChatID != "dashboard-chat" || got.HealthchecksURL != "https://hc-ping.com/dashboard-id" || !got.AlertNewBlock {
		t.Fatalf("restarted settings = %#v", got)
	}
	view, err := restarted.settingsView(true)
	if err != nil || view["overridden"] != true {
		t.Fatalf("restarted view = %#v, %v", view, err)
	}

	if err := restarted.resetSettings(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("override still exists after reset: %v", err)
	}
	got = restarted.notificationSettings()
	if got.TelegramBotToken != "123:server-token" || got.TelegramChatID != "server-chat" || got.HealthchecksURL != "https://hc-ping.com/server-id" || got.AlertNewBlock {
		t.Fatalf("reset settings = %#v", got)
	}
}

func TestSettingsAPIValidationCSRFAndSecretReplacement(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "123:original-token")
	t.Setenv("TELEGRAM_CHAT_ID", "original-chat")
	t.Setenv("HEALTHCHECKS_URL", "https://hc-ping.com/original-id")
	a, handler := testApp(t, &rpcFixture{}, "dashboard-secret")

	valid := `{"telegram_enabled":true,"telegram_bot_token":"","telegram_chat_id":"new-chat","healthchecks_enabled":true,"healthchecks_url":"","alert_new_block":true}`
	if got := settingsRequest(handler, http.MethodPost, "dashboard-secret", valid, false); got.Code != http.StatusForbidden {
		t.Fatalf("POST without CSRF header = %d, want 403", got.Code)
	}
	response := settingsRequest(handler, http.MethodPost, "dashboard-secret", valid, true)
	if response.Code != http.StatusOK {
		t.Fatalf("valid POST = %d: %s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "original-token") || strings.Contains(response.Body.String(), "original-id") {
		t.Fatalf("POST response leaked a secret: %s", response.Body.String())
	}
	var savedView map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &savedView); err != nil || savedView["overridden"] != true || savedView["telegram_chat_id"] != "new-chat" {
		t.Fatalf("POST response view = %#v, %v", savedView, err)
	}
	settings := a.monitor.notificationSettings()
	if settings.TelegramBotToken != "123:original-token" || settings.TelegramChatID != "new-chat" || settings.HealthchecksURL != "https://hc-ping.com/original-id" || !settings.AlertNewBlock {
		t.Fatalf("empty replacements did not keep secrets: %#v", settings)
	}

	invalid := []string{
		`{"telegram_enabled":true,"telegram_chat_id":"new-chat","healthchecks_enabled":true,"alert_new_block":true,"unexpected":1}`,
		`{"telegram_enabled":true,"telegram_bot_token":"bad token","telegram_chat_id":"new-chat","healthchecks_enabled":true,"healthchecks_url":"https://hc-ping.com/id","alert_new_block":true}`,
		`{"telegram_enabled":true,"telegram_bot_token":"ok","telegram_chat_id":"new-chat","healthchecks_enabled":true,"healthchecks_url":"http://hc-ping.com/id","alert_new_block":true}`,
		`{"reset":true,"alert_new_block":true}`,
		`{"reset":true,"alert_new_block":null}`,
		`{"reset":false}`,
	}
	for _, body := range invalid {
		if got := settingsRequest(handler, http.MethodPost, "dashboard-secret", body, true); got.Code != http.StatusBadRequest {
			t.Fatalf("invalid POST %s = %d, want 400", body, got.Code)
		}
	}

	disable := `{"telegram_enabled":false,"telegram_chat_id":"","healthchecks_enabled":false,"alert_new_block":false}`
	response = settingsRequest(handler, http.MethodPost, "dashboard-secret", disable, true)
	if response.Code != http.StatusOK {
		t.Fatalf("disable POST = %d: %s", response.Code, response.Body.String())
	}
	settings = a.monitor.notificationSettings()
	if settings.TelegramBotToken != "" || settings.TelegramChatID != "" || settings.HealthchecksURL != "" {
		t.Fatalf("disabled services retained credentials: %#v", settings)
	}
}

func TestSettingsFailureAndCorruptionLeaveNotificationsDisabled(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "123:server-token")
	t.Setenv("TELEGRAM_CHAT_ID", "server-chat")
	stateDir := t.TempDir()
	m := NewMonitor("dev", t.TempDir(), stateDir)
	before := m.notificationSettings()
	originalWriter := writeSettingsFile
	writeSettingsFile = func(string, []byte) error { return errors.New("disk full") }
	t.Cleanup(func() { writeSettingsFile = originalWriter })
	update := settingsUpdate{
		TelegramEnabled: boolPointer(false), TelegramChatID: stringPointer(""),
		HealthchecksEnabled: boolPointer(false), AlertNewBlock: boolPointer(true),
	}
	if err := m.updateSettings(update); !errors.Is(err, ErrSettingsUnavailable) {
		t.Fatalf("write failure = %v", err)
	}
	if got := m.notificationSettings(); got != before {
		t.Fatalf("active settings changed after failed write: %#v", got)
	}

	corruptDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(corruptDir, "notification_settings.json"), []byte(`{"telegram_enabled":true,"telegram_bot_token":"secret"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	corrupt := NewMonitor("dev", t.TempDir(), corruptDir)
	if _, err := corrupt.settingsView(true); !errors.Is(err, ErrSettingsUnavailable) {
		t.Fatalf("corrupt settings status = %v", err)
	}
	if got := corrupt.notificationSettings(); got != (notificationSettings{}) {
		t.Fatalf("corrupt settings did not fail closed: %#v", got)
	}
}

func TestCorruptSettingsLogRedactedStartupWarning(t *testing.T) {
	stateDir := t.TempDir()
	settingsPath := filepath.Join(stateDir, "notification_settings.json")
	if err := os.WriteFile(settingsPath, []byte(`{"telegram_bot_token":"top-secret"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	root := filepath.Dir(sourceFile(t))
	var logs strings.Builder
	cfg := config{stateDir: stateDir, dataDir: t.TempDir(), version: "dev"}
	if _, err := newApp(cfg, &rpcClient{}, filepath.Join(root, "index.html"), filepath.Join(root, "static"), log.New(&logs, "", 0)); err != nil {
		t.Fatal(err)
	}
	got := logs.String()
	if !strings.Contains(got, "notification settings unavailable; alerts disabled") {
		t.Fatalf("startup warning missing: %q", got)
	}
	if strings.Contains(got, "top-secret") || strings.Contains(got, settingsPath) {
		t.Fatalf("startup warning leaked settings details: %q", got)
	}
}

func TestSettingsResetFailureKeepsActiveOverride(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "123:server-token")
	t.Setenv("TELEGRAM_CHAT_ID", "server-chat")
	m := NewMonitor("dev", t.TempDir(), t.TempDir())
	if err := m.updateSettings(settingsUpdate{
		TelegramEnabled: boolPointer(false), TelegramChatID: stringPointer(""),
		HealthchecksEnabled: boolPointer(false), AlertNewBlock: boolPointer(true),
	}); err != nil {
		t.Fatal(err)
	}
	originalRemover := removeSettingsFile
	removeSettingsFile = func(string) error { return errors.New("read-only filesystem") }
	t.Cleanup(func() { removeSettingsFile = originalRemover })
	if err := m.resetSettings(); !errors.Is(err, ErrSettingsUnavailable) {
		t.Fatalf("reset failure = %v", err)
	}
	settings := m.notificationSettings()
	if !settings.AlertNewBlock || !m.settingsOverridden {
		t.Fatalf("failed reset changed active settings: %#v", settings)
	}
}

func TestSettingsLiveReadsAreRaceSafe(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	m := NewMonitor("dev", t.TempDir(), t.TempDir())
	m.output = io.Discard
	m.client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return response(http.StatusOK, ""), nil
	})}
	var wg sync.WaitGroup
	for i := range 20 {
		wg.Add(3)
		go func() {
			defer wg.Done()
			m.sendTelegram("test")
			_ = m.pingHealthchecks(true)
		}()
		go func() {
			defer wg.Done()
			_ = m.notificationSettings()
		}()
		go func(enabled bool) {
			defer wg.Done()
			_ = m.updateSettings(settingsUpdate{
				TelegramEnabled: boolPointer(false), TelegramChatID: stringPointer(""),
				HealthchecksEnabled: boolPointer(false), AlertNewBlock: boolPointer(enabled),
			})
		}(i%2 == 0)
	}
	wg.Wait()
}

func TestSettingsBodyLimit(t *testing.T) {
	_, handler := testApp(t, &rpcFixture{}, "dashboard-secret")
	body := bytes.Repeat([]byte("x"), maxSettingsBody+1)
	req := httptest.NewRequest(http.MethodPost, "/api/settings", bytes.NewReader(body))
	req.RemoteAddr = "127.0.0.1:12345"
	req.SetBasicAuth("dashboard", "dashboard-secret")
	req.Header.Set("X-Requested-With", "fetch")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("oversized body = %d, want 400", w.Code)
	}
}

func boolPointer(value bool) *bool       { return &value }
func stringPointer(value string) *string { return &value }
