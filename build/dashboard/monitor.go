package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const (
	torProxy             = "172.29.0.25:9050"
	stackReleasesURL     = "https://api.github.com/repos/VijitSingh97/bitcoin-starter-stack/releases/latest"
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
	chainKnown    bool
	ibd           bool
	syncPending   bool
	lastBlock     int64
	hasLastBlock  bool
	pendingBlock  int64
	diskAlerted   bool
	ticks         int
	pingDue       int
	notifiedStack string
}

type persistedMonitorState struct {
	NotifiedStack string `json:"notified_stack"`
}

type Monitor struct {
	releaseBaseline string
	dataDir         string
	eventsLog       string
	statePath       string
	nodeName        string

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
	statePath := filepath.Join(stateDir, "monitor_state.json")
	baseline := notificationSettingsFromEnv()
	settings, overridden, settingsErr := loadNotificationSettings(settingsPath, baseline)
	if settingsErr != nil {
		settings = notificationSettings{}
	}
	releaseBaseline := version
	if !releaseVersion.MatchString(releaseBaseline) {
		releaseBaseline = readVersionFile("VERSION")
	}
	monitor := &Monitor{
		releaseBaseline:    releaseBaseline,
		dataDir:            dataDir,
		eventsLog:          eventsLog,
		statePath:          statePath,
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
	monitor.loadState()
	return monitor
}

func (m *Monitor) Run(ctx context.Context, blockchain func() map[string]any, network func() map[string]any) {
	onlinePending := true
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
		if onlinePending && info != nil {
			if ibd, ok := info["initialblockdownload"].(bool); ok {
				onlinePending = false
				if !ibd {
					m.sendTelegram("🚀 node monitor online")
				}
			}
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
	ibd, hasIBD := false, false
	if healthy {
		ibd, hasIBD = info["initialblockdownload"].(bool)
		if m.state.ibd && hasIBD && !ibd {
			m.state.syncPending = true
		}
		if hasIBD {
			m.state.chainKnown = true
			m.state.ibd = ibd
		}
		if m.state.downAlerted && hasIBD && !ibd {
			if m.sendOperationalTelegram("🟢 node recovered — RPC is answering again") {
				m.state.downAlerted = false
			}
		}
		m.state.fails = 0
		if m.state.syncPending && hasIBD && !ibd && m.sendOperationalTelegram("✅ initial sync complete at height "+valueString(info["blocks"])) {
			m.state.syncPending = false
		}

		if blocks, ok := integer(info["blocks"]); ok {
			if m.notificationSettings().AlertNewBlock && m.state.hasLastBlock && hasIBD && !ibd && blocks > m.state.lastBlock && blocks-m.state.lastBlock <= 6 {
				m.state.pendingBlock = blocks
			}
			m.state.lastBlock = blocks
			m.state.hasLastBlock = true
		}
		if !m.notificationSettings().AlertNewBlock {
			m.state.pendingBlock = 0
		} else if m.state.pendingBlock != 0 && m.sendOperationalTelegram("🟧 new block "+strconv.FormatInt(m.state.pendingBlock, 10)) {
			m.state.pendingBlock = 0
		}

		free, err := m.diskFreeGB(m.dataDir)
		if err != nil {
			m.writeOutput("Monitor tick failed: disk usage unavailable")
			return
		}
		if free < diskWarnFreeGB && hasIBD && !ibd {
			if !m.state.diskAlerted {
				m.state.diskAlerted = m.sendOperationalTelegram(fmt.Sprintf("💾 disk low: %.0f GB free", free))
			}
		} else {
			m.state.diskAlerted = false
		}
	} else {
		m.state.fails++
		if m.state.fails >= downAfterTicks && !m.state.downAlerted && m.state.chainKnown && !m.state.ibd {
			message := fmt.Sprintf("🔴 node down — RPC unreachable for %d minutes", downAfterTicks)
			m.state.downAlerted = m.sendOperationalTelegram(message)
		}
	}

	if m.state.ticks >= m.state.pingDue && (healthy || m.state.fails >= downAfterTicks) && m.pingHealthchecks(healthy) {
		m.state.pingDue = m.state.ticks + pingEveryTicks
	}
	if healthy && network != nil && m.state.ticks%updateCheckEveryTick == 0 {
		m.checkUpdatesWithNotification(hasIBD && !ibd)
	}
	m.state.ticks++
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
