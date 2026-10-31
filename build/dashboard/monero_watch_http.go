package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"time"
)

func (a *app) apiMoneroWatchList(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !a.cfg.moneroEnabled {
		http.Error(w, "Monero node is not configured", http.StatusServiceUnavailable)
		return
	}
	if !a.cfg.moneroWalletEnabled {
		writeJSON(w, map[string]any{"wallets": []MoneroWatchWallet{}, "has_password": a.cfg.dashboardPassword != "", "available": false})
		return
	}
	if a.moneroWatch.Err() != nil {
		http.Error(w, "Monero watch-only wallet storage unavailable", http.StatusServiceUnavailable)
		return
	}
	wallets := a.moneroWatch.List()
	if a.cfg.dashboardPassword == "" {
		var public bool
		wallets, public = a.moneroWatch.PublicList()
		if !public {
			http.Error(w, "set dashboard.password to access personal Monero watch-only wallets", http.StatusForbidden)
			return
		}
	}
	writeJSON(w, map[string]any{"wallets": wallets, "has_password": a.cfg.dashboardPassword != "", "available": true})
}

func (a *app) apiMoneroWatchAdd(w http.ResponseWriter, r *http.Request) {
	if a.rejectMoneroWatchMutation(w, r) {
		return
	}
	var input struct {
		Name          string `json:"name"`
		Address       string `json:"address"`
		ViewKey       string `json:"view_key"`
		RestoreHeight uint64 `json:"restore_height"`
	}
	if !decodeStrictJSON(w, r, 64<<10, &input) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	wallet, err := a.moneroWatch.Add(ctx, input.Name, input.Address, input.ViewKey, input.RestoreHeight)
	input.ViewKey = ""
	if err != nil {
		if errors.Is(err, errMoneroWatchUnavailable) {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	a.moneroWatch.Queue(wallet.ID)
	writeJSON(w, map[string]any{"ok": true, "id": wallet.ID})
}

func (a *app) apiMoneroWatchRemove(w http.ResponseWriter, r *http.Request) {
	if a.rejectMoneroWatchMutation(w, r) {
		return
	}
	id := r.PathValue("id")
	if !validMoneroWalletID(id) {
		http.Error(w, "no such wallet", http.StatusNotFound)
		return
	}
	removed, err := a.moneroWatch.Remove(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	if !removed {
		http.Error(w, "no such wallet", http.StatusNotFound)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

func (a *app) apiMoneroWatchKeyImages(w http.ResponseWriter, r *http.Request) {
	if a.rejectMoneroWatchMutation(w, r) {
		return
	}
	id := r.PathValue("id")
	if !validMoneroWalletID(id) {
		http.Error(w, "no such wallet", http.StatusNotFound)
		return
	}
	var upload moneroKeyImageUpload
	if !decodeStrictJSON(w, r, 4<<20, &upload) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	if err := a.moneroWatch.ImportKeyImages(ctx, id, upload); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			http.Error(w, "no such wallet", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	a.moneroWatch.Queue(id)
	writeJSON(w, map[string]any{"ok": true})
}

func (a *app) rejectMoneroWatchMutation(w http.ResponseWriter, r *http.Request) bool {
	if !a.cfg.moneroEnabled {
		http.Error(w, "Monero node is not configured", http.StatusServiceUnavailable)
		return true
	}
	if !a.cfg.moneroWalletEnabled {
		http.Error(w, "Monero watch-only wallet service is not configured", http.StatusServiceUnavailable)
		return true
	}
	if a.cfg.dashboardPassword == "" {
		http.Error(w, "set dashboard.password to manage Monero watch-only wallets", http.StatusForbidden)
		return true
	}
	if rejectCSRF(w, r) {
		return true
	}
	if a.moneroWatch.Err() != nil {
		http.Error(w, "Monero watch-only wallet storage unavailable", http.StatusServiceUnavailable)
		return true
	}
	return false
}

func decodeStrictJSON(w http.ResponseWriter, r *http.Request, limit int64, value any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil || ensureJSONEnd(decoder) != nil {
		http.Error(w, "Invalid request.", http.StatusBadRequest)
		return false
	}
	return true
}

func validMoneroWalletID(id string) bool {
	return len(id) == 24 && strings.Trim(id, "0123456789abcdef") == ""
}
