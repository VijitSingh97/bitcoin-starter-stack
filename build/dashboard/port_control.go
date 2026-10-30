package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	portControlCapabilityAge = 90 * time.Second
	maxPortControlBody       = 4096
)

var errPortControlBusy = errors.New("port control request already pending")

type portControlPort struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	Enabled  bool   `json:"enabled"`
	BindIP   string `json:"bind_ip"`
	HostPort int    `json:"host_port"`
}

type portControlStatus struct {
	ID               string   `json:"id,omitempty"`
	State            string   `json:"state"`
	Message          string   `json:"message,omitempty"`
	AffectedServices []string `json:"affected_services,omitempty"`
}

type portControlView struct {
	Available bool               `json:"available"`
	Ports     []portControlPort  `json:"ports"`
	Status    *portControlStatus `json:"status,omitempty"`
}

type portControlChangeInput struct {
	Port            string  `json:"port"`
	Enabled         *bool   `json:"enabled"`
	BindIP          *string `json:"bind_ip,omitempty"`
	HostPort        *int    `json:"host_port,omitempty"`
	bindIPPresent   bool
	hostPortPresent bool
}

type portControlInput struct {
	Changes []portControlChangeInput `json:"changes"`
}

type portControlChange struct {
	Port     string `json:"port"`
	Enabled  bool   `json:"enabled"`
	BindIP   string `json:"bind_ip,omitempty"`
	HostPort int    `json:"host_port,omitempty"`
}

type portControlRequest struct {
	ID          string              `json:"id"`
	Changes     []portControlChange `json:"changes"`
	RequestedAt int64               `json:"requested_at"`
}

func (input *portControlChangeInput) UnmarshalJSON(data []byte) error {
	type wireInput struct {
		Port     string  `json:"port"`
		Enabled  *bool   `json:"enabled"`
		BindIP   *string `json:"bind_ip"`
		HostPort *int    `json:"host_port"`
	}
	var wire wireInput
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&wire); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	input.Port, input.Enabled, input.BindIP, input.HostPort = wire.Port, wire.Enabled, wire.BindIP, wire.HostPort
	_, input.bindIPPresent = fields["bind_ip"]
	_, input.hostPortPresent = fields["host_port"]
	return nil
}

func (a *app) portControlPath(name string) string {
	return filepath.Join(a.cfg.stateDir, "port-control."+name)
}

func configuredPort(id, label, endpoint, bindEnv, portEnv, defaultPort string) portControlPort {
	bindIP := strings.TrimSpace(os.Getenv(bindEnv))
	hostPort, _ := strconv.Atoi(strings.TrimSpace(os.Getenv(portEnv)))
	if hostPort == 0 {
		hostPort, _ = strconv.Atoi(defaultPort)
	}
	if endpoint != "" {
		if host, port, err := net.SplitHostPort(endpoint); err == nil {
			bindIP = host
			if parsed, err := strconv.Atoi(port); err == nil {
				hostPort = parsed
			}
		}
	}
	return portControlPort{ID: id, Label: label, Enabled: endpoint != "", BindIP: bindIP, HostPort: hostPort}
}

func (a *app) portControlPorts() []portControlPort {
	ports := make([]portControlPort, 0, 3)
	if !a.cfg.bitcoinDisabled {
		ports = append(ports, configuredPort("bitcoin_rpc", "Bitcoin RPC", a.cfg.bitcoinRPCEndpoint, "BITCOIN_RPC_BIND_IP", "BITCOIN_RPC_PORT", "8332"))
	}
	if a.cfg.moneroEnabled {
		ports = append(ports,
			configuredPort("monero_rpc", "Monero RPC", a.cfg.moneroRPCEndpoint, "MONERO_RPC_BIND_IP", "MONERO_RPC_PORT", "18081"),
			configuredPort("monero_zmq", "Monero ZMQ", a.cfg.moneroZMQEndpoint, "MONERO_ZMQ_BIND_IP", "MONERO_ZMQ_PORT", "18083"),
		)
	}
	return ports
}

func affectedPortServices() []string {
	return []string{"tor", "dashboard"}
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
			return &portControlStatus{ID: request.ID, State: "pending", Message: "Applying LAN port changes…", AffectedServices: affectedPortServices()}, true
		}
		if !os.IsNotExist(err) {
			return &portControlStatus{State: "pending", Message: "Port changes are being checked…", AffectedServices: affectedPortServices()}, true
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
		status.Message = "LAN port changes applied."
	case "rejected":
		status.Message = "LAN port changes were rejected."
	case "failed":
		status.Message = "LAN port changes were saved but could not be applied."
	}
	status.AffectedServices = affectedPortServices()
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

func validatePortControlChanges(input portControlInput, ports []portControlPort) ([]portControlChange, error) {
	allowed := make(map[string]portControlPort, len(ports))
	desired := make(map[string]portControlPort, len(ports))
	for _, port := range ports {
		allowed[port.ID] = port
		desired[port.ID] = port
	}
	if len(input.Changes) == 0 || len(input.Changes) > len(allowed) {
		return nil, errors.New("invalid port changes")
	}
	seen := make(map[string]bool, len(input.Changes))
	changes := make([]portControlChange, 0, len(input.Changes))
	for _, inputChange := range input.Changes {
		current, ok := allowed[inputChange.Port]
		if !ok || seen[inputChange.Port] || inputChange.Enabled == nil {
			return nil, errors.New("invalid port change")
		}
		seen[inputChange.Port] = true
		change := portControlChange{Port: inputChange.Port, Enabled: *inputChange.Enabled}
		if change.Enabled {
			if !inputChange.bindIPPresent || !inputChange.hostPortPresent || inputChange.BindIP == nil || inputChange.HostPort == nil || strings.TrimSpace(*inputChange.BindIP) != *inputChange.BindIP {
				return nil, errors.New("enabled port requires a private LAN address and host port")
			}
			address, err := netip.ParseAddr(*inputChange.BindIP)
			if err != nil || !address.Is4() || !address.IsPrivate() || *inputChange.HostPort < 1 || *inputChange.HostPort > 65535 {
				return nil, errors.New("enabled port requires a private LAN address and host port")
			}
			change.BindIP, change.HostPort = *inputChange.BindIP, *inputChange.HostPort
			if current.Enabled && current.BindIP == change.BindIP && current.HostPort == change.HostPort {
				return nil, errors.New("port change has no effect")
			}
		} else if inputChange.bindIPPresent || inputChange.hostPortPresent || !current.Enabled {
			return nil, errors.New("disabled port change is invalid")
		}
		next := current
		next.Enabled, next.BindIP, next.HostPort = change.Enabled, change.BindIP, change.HostPort
		desired[change.Port] = next
		changes = append(changes, change)
	}
	endpoints := make(map[string]bool)
	for _, port := range desired {
		if !port.Enabled {
			continue
		}
		endpoint := net.JoinHostPort(port.BindIP, strconv.Itoa(port.HostPort))
		if endpoints[endpoint] {
			return nil, errors.New("LAN ports conflict")
		}
		endpoints[endpoint] = true
	}
	return changes, nil
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
	changes, err := validatePortControlChanges(input, a.portControlPorts())
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
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
	request := portControlRequest{ID: hex.EncodeToString(idBytes), Changes: changes, RequestedAt: time.Now().Unix()}
	b, err := json.Marshal(request)
	if err != nil || writePrivateFileAtomic(a.portControlPath("request"), append(b, '\n')) != nil {
		http.Error(w, "port control unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	status := &portControlStatus{ID: request.ID, State: "pending", Message: "Applying LAN port changes…", AffectedServices: affectedPortServices()}
	writeJSON(w, portControlView{Available: true, Ports: a.portControlPorts(), Status: status})
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
