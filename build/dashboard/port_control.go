package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

const (
	portControlCapabilityAge = 90 * time.Second
	maxPortControlBody       = 1024
)

var errPortControlBusy = errors.New("port control request already pending")

type portControlPort struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	Endpoint string `json:"endpoint,omitempty"`
	Enabled  bool   `json:"enabled"`
}

type portControlStatus struct {
	ID      string `json:"id,omitempty"`
	State   string `json:"state"`
	Message string `json:"message,omitempty"`
}

type portControlView struct {
	Available bool               `json:"available"`
	Ports     []portControlPort  `json:"ports"`
	Status    *portControlStatus `json:"status,omitempty"`
}

type portControlInput struct {
	Ports []string `json:"ports"`
}

type portControlRequest struct {
	ID          string   `json:"id"`
	Ports       []string `json:"ports"`
	RequestedAt int64    `json:"requested_at"`
}

func (a *app) portControlPath(name string) string {
	return filepath.Join(a.cfg.stateDir, "port-control."+name)
}

func (a *app) portControlPorts() []portControlPort {
	ports := make([]portControlPort, 0, 3)
	if !a.cfg.bitcoinDisabled {
		ports = append(ports, portControlPort{ID: "bitcoin_rpc", Label: "Bitcoin RPC", Endpoint: a.cfg.bitcoinRPCEndpoint, Enabled: a.cfg.bitcoinRPCEndpoint != ""})
	}
	if a.cfg.moneroEnabled {
		ports = append(ports,
			portControlPort{ID: "monero_rpc", Label: "Monero RPC", Endpoint: a.cfg.moneroRPCEndpoint, Enabled: a.cfg.moneroRPCEndpoint != ""},
			portControlPort{ID: "monero_zmq", Label: "Monero ZMQ", Endpoint: a.cfg.moneroZMQEndpoint, Enabled: a.cfg.moneroZMQEndpoint != ""},
		)
	}
	return ports
}

func (a *app) portControlAvailable() bool {
	if a.cfg.dashboardPassword == "" {
		return false
	}
	path := a.portControlPath("capability")
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != int64(len("ready\n")) || time.Since(info.ModTime()) < 0 || time.Since(info.ModTime()) > portControlCapabilityAge {
		return false
	}
	b, err := os.ReadFile(path)
	return err == nil && string(b) == "ready\n"
}

func (a *app) pendingPortControl() (*portControlStatus, bool) {
	for _, name := range []string{"request", "processing"} {
		b, err := readSmallFile(a.portControlPath(name), 4096)
		if err == nil {
			var request portControlRequest
			_ = json.Unmarshal(b, &request)
			return &portControlStatus{ID: request.ID, State: "pending", Message: "Closing selected port…"}, true
		}
		if !os.IsNotExist(err) {
			return &portControlStatus{State: "pending", Message: "Port change is being checked…"}, true
		}
	}
	return nil, false
}

func (a *app) readPortControlStatus() *portControlStatus {
	b, err := readSmallFile(a.portControlPath("status"), 4096)
	if err != nil {
		return nil
	}
	var status portControlStatus
	decoder := json.NewDecoder(bytes.NewReader(b))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&status) != nil || ensureJSONEnd(decoder) != nil || !validPortControlID(status.ID) {
		return nil
	}
	if status.State != "applied" && status.State != "rejected" && status.State != "failed" {
		return nil
	}
	switch status.State {
	case "applied":
		status.Message = "LAN port closed."
	case "rejected":
		status.Message = "Port close request was rejected."
	case "failed":
		status.Message = "Port close is saved but could not be applied."
	}
	return &status
}

func readSmallFile(path string, limit int64) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.New("invalid state file")
	}
	return os.ReadFile(path)
}

func (a *app) portControlView() portControlView {
	view := portControlView{Available: a.portControlAvailable(), Ports: a.portControlPorts()}
	if pending, ok := a.pendingPortControl(); ok {
		view.Status = pending
	} else {
		view.Status = a.readPortControlStatus()
	}
	return view
}

func (a *app) apiPortControlGet(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if a.rejectUnsafeSettingsHost(w, r) {
		return
	}
	writeJSON(w, a.portControlView())
}

func (a *app) apiPortControlPost(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if a.cfg.dashboardPassword == "" {
		http.Error(w, "a dashboard password is required for port control", http.StatusForbidden)
		return
	}
	if rejectCSRF(w, r) {
		return
	}
	if !a.portControlAvailable() {
		http.Error(w, "host port control is unavailable", http.StatusServiceUnavailable)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxPortControlBody)
	var input portControlInput
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || ensureJSONEnd(decoder) != nil {
		http.Error(w, "invalid port control request", http.StatusBadRequest)
		return
	}
	allowed := make(map[string]bool)
	for _, port := range a.portControlPorts() {
		allowed[port.ID] = port.Enabled
	}
	seen := make(map[string]bool)
	if len(input.Ports) == 0 || len(input.Ports) > len(allowed) {
		http.Error(w, "invalid port control request", http.StatusBadRequest)
		return
	}
	for _, port := range input.Ports {
		if !allowed[port] || seen[port] {
			http.Error(w, "requested port is not currently exposed", http.StatusConflict)
			return
		}
		seen[port] = true
	}
	a.portControlMu.Lock()
	defer a.portControlMu.Unlock()
	if _, pending := a.pendingPortControl(); pending {
		http.Error(w, errPortControlBusy.Error(), http.StatusConflict)
		return
	}
	idBytes := make([]byte, 16)
	if _, err := rand.Read(idBytes); err != nil {
		http.Error(w, "port control unavailable", http.StatusServiceUnavailable)
		return
	}
	request := portControlRequest{ID: hex.EncodeToString(idBytes), Ports: input.Ports, RequestedAt: time.Now().Unix()}
	b, err := json.Marshal(request)
	if err != nil || writePrivateFileAtomic(a.portControlPath("request"), append(b, '\n')) != nil {
		http.Error(w, "port control unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, portControlView{Available: true, Ports: a.portControlPorts(), Status: &portControlStatus{ID: request.ID, State: "pending", Message: "Closing selected port…"}})
}

func validPortControlID(value string) bool {
	if len(value) != 32 {
		return false
	}
	for _, character := range value {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return false
		}
	}
	return true
}
