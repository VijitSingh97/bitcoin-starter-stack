package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"unicode"
)

const maxSettingsBody = 16 << 10

var (
	ErrSettingsUnavailable = errors.New("notification settings unavailable")
	ErrSettingsInvalid     = errors.New("invalid notification settings")
	writeSettingsFile      = writePrivateFileAtomic
	removeSettingsFile     = os.Remove
)

type notificationSettings struct {
	TelegramEnabled     bool   `json:"telegram_enabled"`
	TelegramBotToken    string `json:"telegram_bot_token"`
	TelegramChatID      string `json:"telegram_chat_id"`
	HealthchecksEnabled bool   `json:"healthchecks_enabled"`
	HealthchecksURL     string `json:"healthchecks_url"`
	AlertNewBlock       bool   `json:"alert_new_block"`
}

type settingsUpdate struct {
	Reset               *bool   `json:"reset,omitempty"`
	TelegramEnabled     *bool   `json:"telegram_enabled,omitempty"`
	TelegramBotToken    *string `json:"telegram_bot_token,omitempty"`
	TelegramChatID      *string `json:"telegram_chat_id,omitempty"`
	HealthchecksEnabled *bool   `json:"healthchecks_enabled,omitempty"`
	HealthchecksURL     *string `json:"healthchecks_url,omitempty"`
	AlertNewBlock       *bool   `json:"alert_new_block,omitempty"`
	present             map[string]bool
}

func notificationSettingsFromEnv() notificationSettings {
	token := strings.TrimSpace(os.Getenv("TELEGRAM_BOT_TOKEN"))
	chatID := strings.TrimSpace(os.Getenv("TELEGRAM_CHAT_ID"))
	healthchecks := strings.TrimRight(strings.TrimSpace(os.Getenv("HEALTHCHECKS_URL")), "/")
	return notificationSettings{
		TelegramEnabled:     token != "" && chatID != "",
		TelegramBotToken:    token,
		TelegramChatID:      chatID,
		HealthchecksEnabled: healthchecks != "",
		HealthchecksURL:     healthchecks,
		AlertNewBlock:       enabled(os.Getenv("ALERT_NEW_BLOCK")),
	}
}

func loadNotificationSettings(path string, baseline notificationSettings) (notificationSettings, bool, error) {
	if err := os.Chmod(path, 0o600); err != nil {
		if os.IsNotExist(err) {
			return baseline, false, nil
		}
		return notificationSettings{}, false, err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return notificationSettings{}, false, err
	}
	var settings notificationSettings
	decoder := json.NewDecoder(bytes.NewReader(b))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&settings); err != nil {
		return notificationSettings{}, false, err
	}
	if err := ensureJSONEnd(decoder); err != nil {
		return notificationSettings{}, false, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(b, &fields); err != nil {
		return notificationSettings{}, false, err
	}
	for _, name := range []string{"telegram_enabled", "telegram_bot_token", "telegram_chat_id", "healthchecks_enabled", "healthchecks_url", "alert_new_block"} {
		value, ok := fields[name]
		if !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return notificationSettings{}, false, errors.New("notification settings field missing")
		}
	}
	if err := validateStoredSettings(settings); err != nil {
		return notificationSettings{}, false, err
	}
	return settings, true, nil
}

func validateStoredSettings(settings notificationSettings) error {
	if settings.TelegramEnabled {
		if err := validateSecret(settings.TelegramBotToken, 10, 256); err != nil {
			return err
		}
		if err := validateSecret(settings.TelegramChatID, 1, 100); err != nil {
			return err
		}
	} else if settings.TelegramBotToken != "" || settings.TelegramChatID != "" {
		return errors.New("disabled Telegram settings contain credentials")
	}
	if settings.HealthchecksEnabled {
		return validateHealthchecksURL(settings.HealthchecksURL)
	}
	if settings.HealthchecksURL != "" {
		return errors.New("disabled Healthchecks settings contain a URL")
	}
	return nil
}

func validateSecret(value string, min, max int) error {
	if len(value) < min || len(value) > max || strings.TrimSpace(value) != value {
		return errors.New("invalid value length")
	}
	for _, r := range value {
		if unicode.IsControl(r) || unicode.IsSpace(r) {
			return errors.New("invalid control or whitespace character")
		}
	}
	return nil
}

func validateHealthchecksURL(value string) error {
	if len(value) > 2048 || strings.TrimSpace(value) != value {
		return errors.New("invalid Healthchecks URL")
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return errors.New("invalid Healthchecks URL")
		}
	}
	endpoint, err := url.Parse(value)
	if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() == "" || endpoint.User != nil || endpoint.Fragment != "" {
		return errors.New("Healthchecks URL must be HTTPS without credentials or a fragment")
	}
	return nil
}

func decodeSettingsUpdate(body io.Reader) (settingsUpdate, error) {
	var update settingsUpdate
	b, err := io.ReadAll(body)
	if err != nil {
		return update, err
	}
	decoder := json.NewDecoder(bytes.NewReader(b))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&update); err != nil {
		return update, err
	}
	if err := ensureJSONEnd(decoder); err != nil {
		return update, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(b, &fields); err != nil {
		return update, err
	}
	update.present = make(map[string]bool, len(fields))
	for name, value := range fields {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return settingsUpdate{}, errors.New("null settings field")
		}
		update.present[name] = true
	}
	return update, nil
}

func (update settingsUpdate) isReset() bool {
	return update.Reset != nil && *update.Reset && len(update.present) == 1 && update.present["reset"]
}

func (update settingsUpdate) apply(current notificationSettings) (notificationSettings, error) {
	if update.Reset != nil || update.TelegramEnabled == nil || update.TelegramChatID == nil || update.HealthchecksEnabled == nil || update.AlertNewBlock == nil {
		return notificationSettings{}, errors.New("all settings fields are required")
	}
	next := current
	next.TelegramEnabled = *update.TelegramEnabled
	next.HealthchecksEnabled = *update.HealthchecksEnabled
	next.AlertNewBlock = *update.AlertNewBlock
	if next.TelegramEnabled {
		if update.TelegramBotToken != nil && *update.TelegramBotToken != "" {
			next.TelegramBotToken = *update.TelegramBotToken
		}
		next.TelegramChatID = *update.TelegramChatID
	} else {
		next.TelegramBotToken = ""
		next.TelegramChatID = ""
	}
	if next.HealthchecksEnabled {
		if update.HealthchecksURL != nil && *update.HealthchecksURL != "" {
			next.HealthchecksURL = strings.TrimRight(*update.HealthchecksURL, "/")
		}
	} else {
		next.HealthchecksURL = ""
	}
	if err := validateStoredSettings(next); err != nil {
		return notificationSettings{}, err
	}
	return next, nil
}

func (m *Monitor) notificationSettings() notificationSettings {
	m.settingsMu.RLock()
	defer m.settingsMu.RUnlock()
	return m.settings
}

func (m *Monitor) settingsView(canConfigure bool) (map[string]any, error) {
	m.settingsMu.RLock()
	defer m.settingsMu.RUnlock()
	if m.settingsErr != nil {
		return nil, ErrSettingsUnavailable
	}
	return map[string]any{
		"telegram_enabled":       m.settings.TelegramEnabled,
		"telegram_bot_token_set": m.settings.TelegramBotToken != "",
		"telegram_chat_id":       m.settings.TelegramChatID,
		"healthchecks_enabled":   m.settings.HealthchecksEnabled,
		"healthchecks_url_set":   m.settings.HealthchecksURL != "",
		"alert_new_block":        m.settings.AlertNewBlock,
		"overridden":             m.settingsOverridden,
		"can_configure":          canConfigure,
	}, nil
}

func (m *Monitor) updateSettings(update settingsUpdate) error {
	m.settingsMu.Lock()
	defer m.settingsMu.Unlock()
	if m.settingsErr != nil {
		return ErrSettingsUnavailable
	}
	next, err := update.apply(m.settings)
	if err != nil {
		return errors.Join(ErrSettingsInvalid, err)
	}
	b, err := json.Marshal(next)
	if err != nil {
		return ErrSettingsUnavailable
	}
	if err := writeSettingsFile(m.settingsPath, b); err != nil {
		return ErrSettingsUnavailable
	}
	m.settings = next
	m.settingsOverridden = true
	return nil
}

func (m *Monitor) resetSettings() error {
	m.settingsMu.Lock()
	defer m.settingsMu.Unlock()
	if m.settingsErr != nil {
		return ErrSettingsUnavailable
	}
	if err := removeSettingsFile(m.settingsPath); err != nil && !os.IsNotExist(err) {
		return ErrSettingsUnavailable
	}
	m.settings = m.settingsBaseline
	m.settingsOverridden = false
	return nil
}

func (a *app) apiSettingsGet(w http.ResponseWriter, r *http.Request) {
	if a.cfg.dashboardPassword == "" {
		http.Error(w, "set dashboard.password to manage notification settings", http.StatusForbidden)
		return
	}
	view, err := a.monitor.settingsView(true)
	if err != nil {
		http.Error(w, "notification settings unavailable", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, view)
}

func (a *app) apiSettingsPost(w http.ResponseWriter, r *http.Request) {
	if a.cfg.dashboardPassword == "" {
		http.Error(w, "set dashboard.password to manage notification settings", http.StatusForbidden)
		return
	}
	if rejectCSRF(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxSettingsBody)
	update, err := decodeSettingsUpdate(r.Body)
	if err != nil {
		http.Error(w, "invalid notification settings", http.StatusBadRequest)
		return
	}
	if update.Reset != nil {
		if !update.isReset() {
			http.Error(w, "reset cannot be combined with other settings", http.StatusBadRequest)
			return
		}
		err = a.monitor.resetSettings()
	} else {
		err = a.monitor.updateSettings(update)
	}
	if errors.Is(err, ErrSettingsInvalid) {
		http.Error(w, "invalid notification settings", http.StatusBadRequest)
		return
	}
	if err != nil {
		http.Error(w, "notification settings unavailable", http.StatusServiceUnavailable)
		return
	}
	view, err := a.monitor.settingsView(true)
	if err != nil {
		http.Error(w, "notification settings unavailable", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, view)
}
