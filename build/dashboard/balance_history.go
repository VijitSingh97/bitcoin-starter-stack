package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	balanceMinInterval = time.Hour
	balanceMaxPoints   = 2160
)

type balanceHistory struct {
	mu        sync.Mutex
	path      string
	data      map[string][][]float64
	loaded    bool
	maxPoints int
}

func newBalanceHistory(path string) *balanceHistory {
	secureParent(path)
	return &balanceHistory{path: path, maxPoints: balanceMaxPoints}
}

func keyID(key string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(key)))
	return hex.EncodeToString(sum[:])[:16]
}

func (h *balanceHistory) loadLocked() {
	if h.loaded {
		return
	}
	h.loaded = true
	h.data = map[string][][]float64{}
	if err := chmodExistingFile(h.path, 0o600); err != nil && !os.IsNotExist(err) {
		return
	}
	b, err := os.ReadFile(h.path)
	if err == nil {
		var loaded map[string][][]float64
		if json.Unmarshal(b, &loaded) == nil {
			h.data = loaded
		}
	}
	if h.data == nil {
		h.data = map[string][][]float64{}
	}
}

func (h *balanceHistory) saveLocked() {
	b, err := json.Marshal(h.data)
	if err != nil {
		return
	}
	_ = writePrivateFileAtomic(h.path, b)
}

func (h *balanceHistory) record(key string, btc float64, now time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.loadLocked()
	kid := keyID(key)
	series := h.data[kid]
	ts := float64(now.UnixNano()) / float64(time.Second)
	if len(series) > 0 && ts-series[len(series)-1][0] < balanceMinInterval.Seconds() {
		return
	}
	point := []float64{math.RoundToEven(ts*1000) / 1000, math.RoundToEven(btc*1e8) / 1e8}
	series = append(series, point)
	if len(series) > h.maxPoints {
		series = append([][]float64(nil), series[len(series)-h.maxPoints:]...)
	}
	h.data[kid] = series
	h.saveLocked()
}

func (h *balanceHistory) series(key string) []float64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.loadLocked()
	points := h.data[keyID(key)]
	values := make([]float64, 0, len(points))
	for _, point := range points {
		if len(point) > 1 {
			values = append(values, point[1])
		}
	}
	return values
}
