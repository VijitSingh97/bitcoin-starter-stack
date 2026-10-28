package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	torProxy             = "172.29.0.25:9050"
	stackReleasesURL     = "https://api.github.com/repos/VijitSingh97/bitcoin-starter-stack/releases/latest"
	coreReleasesURL      = "https://api.github.com/repos/bitcoin/bitcoin/releases/latest"
	pingEveryTicks       = 5
	downAfterTicks       = 3
	updateCheckEveryTick = 1440
	diskWarnFreeGB       = 50
	eventLogCap          = 1_000_000
)

var (
	releaseVersion = regexp.MustCompile(`^\d+\.\d+\.\d+$`)
	versionNumber  = regexp.MustCompile(`\d+`)
)

type monitorState struct {
	fails         int
	downAlerted   bool
	ibd           bool
	lastBlock     int64
	hasLastBlock  bool
	diskAlerted   bool
	ticks         int
	pingDue       int
	notifiedStack string
	notifiedCore  string
}

type Monitor struct {
	version   string
	dataDir   string
	eventsLog string
	nodeName  string

	settingsMu         sync.RWMutex
	settings           notificationSettings
	settingsBaseline   notificationSettings
	settingsPath       string
	settingsErr        error
	settingsOverridden bool

	client     *http.Client
	now        func() time.Time
	diskFreeGB func(string) (float64, error)
	output     io.Writer
	tickEvery  time.Duration

	state monitorState

	mu         sync.RWMutex
	updateNote string
	logMu      sync.Mutex
}

func NewMonitor(version, dataDir, stateDir string) *Monitor {
	eventsLog := filepath.Join(stateDir, "events.log")
	if value, ok := os.LookupEnv("EVENTS_LOG"); ok {
		eventsLog = value
	}
	settingsPath := filepath.Join(stateDir, "notification_settings.json")
	baseline := notificationSettingsFromEnv()
	settings, overridden, settingsErr := loadNotificationSettings(settingsPath, baseline)
	if settingsErr != nil {
		settings = notificationSettings{}
	}
	return &Monitor{
		version:            version,
		dataDir:            dataDir,
		eventsLog:          eventsLog,
		nodeName:           envOr("NODE_NAME", "bitcoin-node"),
		settings:           settings,
		settingsBaseline:   baseline,
		settingsPath:       settingsPath,
		settingsErr:        settingsErr,
		settingsOverridden: overridden,
		client:             newTorHTTPClient(torProxy),
		now:                time.Now,
		diskFreeGB:         freeGB,
		output:             os.Stdout,
		tickEvery:          time.Minute,
	}
}

func (m *Monitor) Run(ctx context.Context, blockchain func() map[string]any, network func() map[string]any) {
	m.sendTelegram("🚀 node monitor online")
	ticker := time.NewTicker(m.tickEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		var info map[string]any
		if blockchain != nil {
			info = blockchain()
		}
		var netInfo map[string]any
		if info != nil && network != nil && m.state.ticks%updateCheckEveryTick == 0 {
			netInfo = network()
			if netInfo == nil {
				netInfo = map[string]any{}
			}
		}
		m.tick(info, netInfo)

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (m *Monitor) UpdateNote() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.updateNote
}

func (m *Monitor) tick(info, network map[string]any) {
	healthy := info != nil
	if healthy {
		if m.state.downAlerted {
			m.sendTelegram("🟢 node recovered — RPC is answering again")
			m.state.downAlerted = false
		}
		m.state.fails = 0

		ibd, hasIBD := info["initialblockdownload"].(bool)
		if m.state.ibd && hasIBD && !ibd {
			m.sendTelegram("✅ initial sync complete at height " + valueString(info["blocks"]))
		}
		m.state.ibd = hasIBD && ibd

		if blocks, ok := integer(info["blocks"]); ok {
			if m.notificationSettings().AlertNewBlock && m.state.hasLastBlock && hasIBD && !ibd && blocks > m.state.lastBlock && blocks-m.state.lastBlock <= 6 {
				m.sendTelegram("🟧 new block " + strconv.FormatInt(blocks, 10))
			}
			m.state.lastBlock = blocks
			m.state.hasLastBlock = true
		}

		free, err := m.diskFreeGB(m.dataDir)
		if err != nil {
			m.writeOutput("Monitor tick failed: disk usage unavailable")
			return
		}
		if free < diskWarnFreeGB {
			if !m.state.diskAlerted {
				m.sendTelegram(fmt.Sprintf("💾 disk low: %.0f GB free", free))
				m.state.diskAlerted = true
			}
		} else {
			m.state.diskAlerted = false
		}
	} else {
		m.state.fails++
		if m.state.fails == downAfterTicks && !m.state.downAlerted {
			m.sendTelegram(fmt.Sprintf("🔴 node down — RPC unreachable for %d minutes", downAfterTicks))
			m.state.downAlerted = true
		}
	}

	if m.state.ticks >= m.state.pingDue && m.pingHealthchecks(healthy) {
		m.state.pingDue = m.state.ticks + pingEveryTicks
	}
	if healthy && network != nil && m.state.ticks%updateCheckEveryTick == 0 {
		subversion, _ := network["subversion"].(string)
		m.checkUpdates(subversion)
	}
	m.state.ticks++
}

func (m *Monitor) sendTelegram(text string) {
	m.logEvent(text)
	settings := m.notificationSettings()
	if !settings.TelegramEnabled || settings.TelegramBotToken == "" || settings.TelegramChatID == "" {
		return
	}
	payload, err := json.Marshal(map[string]string{
		"chat_id": settings.TelegramChatID,
		"text":    "[" + m.nodeName + "] " + text,
	})
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.telegram.org/bot"+settings.TelegramBotToken+"/sendMessage", bytes.NewReader(payload))
	if err != nil {
		m.writeOutput("Telegram send failed")
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := m.client.Do(req)
	if err != nil {
		m.writeOutput("Telegram send failed")
		return
	}
	resp.Body.Close()
}

func (m *Monitor) pingHealthchecks(healthy bool) bool {
	settings := m.notificationSettings()
	if !settings.HealthchecksEnabled || settings.HealthchecksURL == "" {
		return true
	}
	endpoint, err := url.Parse(settings.HealthchecksURL)
	if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() == "" || endpoint.User != nil {
		m.logEvent("healthchecks ping failed: HTTPS URL required")
		return false
	}
	url := settings.HealthchecksURL
	if !healthy {
		url += "/fail"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		m.logEvent("healthchecks ping failed: request failed")
		return false
	}
	resp, err := m.client.Do(req)
	if err != nil {
		m.logEvent("healthchecks ping failed: request failed")
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		m.logEvent(fmt.Sprintf("healthchecks ping failed: HTTP %d", resp.StatusCode))
		return false
	}
	return true
}

func (m *Monitor) checkUpdates(subversion string) {
	notes := make([]string, 0, 2)
	latestStack := m.latestReleaseTag(stackReleasesURL)
	if releaseVersion.MatchString(m.version) && latestStack != "" && newer(latestStack, m.version) {
		note := fmt.Sprintf("stack v%s available (running v%s)", latestStack, m.version)
		notes = append(notes, note)
		if m.state.notifiedStack != latestStack {
			m.sendTelegram("🆕 " + note)
			m.state.notifiedStack = latestStack
		}
	}

	currentCore := strings.ReplaceAll(strings.Trim(subversion, "/"), "Satoshi:", "")
	latestCore := m.latestReleaseTag(coreReleasesURL)
	if currentCore != "" && latestCore != "" && newer(latestCore, currentCore) {
		note := fmt.Sprintf("Bitcoin Core %s available (running %s)", latestCore, currentCore)
		notes = append(notes, note)
		if m.state.notifiedCore != latestCore {
			m.sendTelegram("🆕 " + note)
			m.state.notifiedCore = latestCore
		}
	}

	m.mu.Lock()
	m.updateNote = strings.Join(notes, "; ")
	m.mu.Unlock()
}

func (m *Monitor) latestReleaseTag(url string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := m.client.Do(req)
	if err != nil {
		m.writeOutput("Release check failed")
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var release struct {
		Tag string `json:"tag_name"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&release) != nil {
		return ""
	}
	return strings.TrimLeft(release.Tag, "v")
}

func newer(latest, current string) bool {
	a := numericParts(latest)
	b := numericParts(current)
	if len(a) == 0 {
		return false
	}
	for i := 0; i < len(a) && i < len(b); i++ {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return len(a) > len(b)
}

func numericParts(version string) []uint64 {
	parts := versionNumber.FindAllString(version, -1)
	result := make([]uint64, 0, len(parts))
	for _, part := range parts {
		n, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			return nil
		}
		result = append(result, n)
	}
	return result
}

func (m *Monitor) logEvent(text string) {
	m.logMu.Lock()
	defer m.logMu.Unlock()
	m.writeOutput(text)
	if stat, err := os.Stat(m.eventsLog); err == nil && stat.Size() > eventLogCap {
		if err := rotateEventLog(m.eventsLog); err != nil {
			m.writeOutput("Event log write failed")
			return
		}
	}
	f, err := os.OpenFile(m.eventsLog, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		m.writeOutput("Event log write failed")
		return
	}
	defer f.Close()
	if _, err := fmt.Fprintf(f, "%s %s\n", m.now().UTC().Format(time.RFC3339), text); err != nil {
		m.writeOutput("Event log write failed")
	}
}

func rotateEventLog(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), eventLogCap+1)
	lines := make([]string, 0, 65536)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	closeErr := f.Close()
	if err := scanner.Err(); err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	lines = lines[len(lines)/2:]
	var content strings.Builder
	for _, line := range lines {
		content.WriteString(line)
		content.WriteByte('\n')
	}
	return os.WriteFile(path, []byte(content.String()), 0o600)
}

func (m *Monitor) writeOutput(text string) {
	if m.output != nil {
		fmt.Fprintln(m.output, text)
	}
}

func newTorHTTPClient(proxy string) *http.Client {
	transport := &http.Transport{
		Proxy:                 nil,
		DialContext:           socks5DialContext(proxy),
		ForceAttemptHTTP2:     true,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		IdleConnTimeout:       90 * time.Second,
	}
	return &http.Client{
		Transport: transport,
		Timeout:   30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func socks5DialContext(proxy string) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		if network != "tcp" && network != "tcp4" && network != "tcp6" {
			return nil, errors.New("SOCKS5 only supports TCP")
		}
		conn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", proxy)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, errors.New("SOCKS5 proxy unavailable")
		}
		handshakeDeadline := time.Now().Add(10 * time.Second)
		if deadline, ok := ctx.Deadline(); ok && deadline.Before(handshakeDeadline) {
			handshakeDeadline = deadline
		}
		_ = conn.SetDeadline(handshakeDeadline)
		stopCancel := context.AfterFunc(ctx, func() { conn.Close() })
		if err := socks5Connect(conn, address); err != nil {
			stopCancel()
			conn.Close()
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, err
		}
		if !stopCancel() || ctx.Err() != nil {
			conn.Close()
			return nil, ctx.Err()
		}
		_ = conn.SetDeadline(time.Time{})
		return conn, nil
	}
}

func socks5Connect(conn net.Conn, address string) error {
	if _, err := conn.Write([]byte{5, 1, 0}); err != nil {
		return errors.New("SOCKS5 handshake failed")
	}
	response := make([]byte, 2)
	if _, err := io.ReadFull(conn, response); err != nil || response[0] != 5 || response[1] != 0 {
		return errors.New("SOCKS5 handshake failed")
	}
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return errors.New("SOCKS5 destination invalid")
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil {
		return errors.New("SOCKS5 destination invalid")
	}
	request := []byte{5, 1, 0}
	if ip := net.ParseIP(host); ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			request = append(request, 1)
			request = append(request, ip4...)
		} else {
			request = append(request, 4)
			request = append(request, ip.To16()...)
		}
	} else {
		if len(host) == 0 || len(host) > 255 {
			return errors.New("SOCKS5 destination invalid")
		}
		request = append(request, 3, byte(len(host)))
		request = append(request, host...)
	}
	request = binary.BigEndian.AppendUint16(request, uint16(port))
	if _, err := conn.Write(request); err != nil {
		return errors.New("SOCKS5 connect failed")
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(conn, header); err != nil || header[0] != 5 || header[2] != 0 {
		return errors.New("SOCKS5 connect failed")
	}
	if header[1] != 0 {
		return fmt.Errorf("SOCKS5 connect failed (code %d)", header[1])
	}
	var addressLength int
	switch header[3] {
	case 1:
		addressLength = 4
	case 3:
		length := make([]byte, 1)
		if _, err := io.ReadFull(conn, length); err != nil {
			return errors.New("SOCKS5 connect failed")
		}
		addressLength = int(length[0])
	case 4:
		addressLength = 16
	default:
		return errors.New("SOCKS5 connect failed")
	}
	if _, err := io.CopyN(io.Discard, conn, int64(addressLength+2)); err != nil {
		return errors.New("SOCKS5 connect failed")
	}
	return nil
}

func freeGB(path string) (float64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, err
	}
	return float64(stat.Bavail) * float64(stat.Bsize) / float64(uint64(1)<<30), nil
}

func integer(value any) (int64, bool) {
	switch n := value.(type) {
	case int:
		return int64(n), true
	case int64:
		return n, true
	case float64:
		v := int64(n)
		return v, float64(v) == n
	case json.Number:
		v, err := n.Int64()
		return v, err == nil
	default:
		return 0, false
	}
}

func valueString(value any) string {
	if n, ok := integer(value); ok {
		return strconv.FormatInt(n, 10)
	}
	return fmt.Sprint(value)
}

func envOr(name, fallback string) string {
	if value, ok := os.LookupEnv(name); ok {
		return value
	}
	return fallback
}

func enabled(value string) bool {
	return value != "" && value != "0" && value != "false" && value != "False"
}
