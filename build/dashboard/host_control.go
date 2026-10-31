package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"time"
)

type hostControlCapability struct {
	Timestamp        int64  `json:"timestamp"`
	Platform         string `json:"platform"`
	BootKind         string `json:"boot_kind"`
	InstallSupported bool   `json:"install_supported"`
	BootSupported    bool   `json:"boot_supported"`
	BootEnabled      bool   `json:"boot_enabled"`
	ConfigPending    bool   `json:"config_pending"`
	ConfigRevision   string `json:"config_revision"`
}

type hostControlNode struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Installed bool   `json:"installed"`
}

type hostControlInput struct {
	Action   string `json:"action"`
	Node     string `json:"node,omitempty"`
	Enabled  *bool  `json:"enabled,omitempty"`
	Revision string `json:"config_revision,omitempty"`
}

type hostControlRequest struct {
	ID          string `json:"id"`
	Action      string `json:"action"`
	Node        string `json:"node,omitempty"`
	Enabled     *bool  `json:"enabled,omitempty"`
	Revision    string `json:"config_revision,omitempty"`
	RequestedAt int64  `json:"requested_at"`
}

type hostControlStatus struct {
	ID        string `json:"id,omitempty"`
	Action    string `json:"action,omitempty"`
	Node      string `json:"node,omitempty"`
	Enabled   *bool  `json:"enabled,omitempty"`
	State     string `json:"state"`
	Message   string `json:"message,omitempty"`
	ErrorCode string `json:"error_code,omitempty"`
}

type hostControlView struct {
	Available        bool               `json:"available"`
	InstallSupported bool               `json:"install_supported"`
	BootSupported    bool               `json:"boot_supported"`
	BootEnabled      bool               `json:"boot_enabled"`
	BootKind         string             `json:"boot_kind"`
	ConfigPending    bool               `json:"config_pending"`
	ConfigRevision   string             `json:"config_revision,omitempty"`
	Nodes            []hostControlNode  `json:"nodes"`
	Status           *hostControlStatus `json:"status,omitempty"`
}

func decodeHostControlCapability(b []byte) (hostControlCapability, bool) {
	var capability hostControlCapability
	decoder := json.NewDecoder(bytes.NewReader(b))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&capability) != nil || ensureJSONEnd(decoder) != nil {
		return capability, false
	}
	validPlatform := capability.Platform == "linux" || capability.Platform == "mac" || capability.Platform == "source"
	validBootKind := capability.BootKind == "boot" || capability.BootKind == "login" || capability.BootKind == "unsupported"
	validRevision := !capability.ConfigPending && capability.ConfigRevision == "" || capability.ConfigPending && len(capability.ConfigRevision) == 64 && len(bytes.Trim([]byte(capability.ConfigRevision), "0123456789abcdef")) == 0
	if capability.Timestamp <= 0 || !validPlatform || !validBootKind || !validRevision {
		return capability, false
	}
	now := time.Now().Unix()
	if capability.Timestamp > now+30 || now-capability.Timestamp > int64(nodeControlCapabilityAge/time.Second) {
		return capability, false
	}
	return capability, true
}

func (a *app) hostControlCapability() (hostControlCapability, bool) {
	b, err := readSmallFile(a.nodeControlPath("capability"), 1024)
	if err != nil {
		return hostControlCapability{}, false
	}
	return decodeHostControlCapability(b)
}

func validHostAction(action string) bool {
	return action == "install" || action == "launch_at_boot" || action == "apply_config"
}

func validHostControlShape(action, node string, enabled *bool) bool {
	return action == "install" && normalizeNodeID(node) != "" && enabled == nil ||
		action == "launch_at_boot" && node == "" && enabled != nil ||
		action == "apply_config" && node == "" && enabled == nil
}

func canonicalHostStatusMessage(status hostControlStatus) string {
	if status.State == "applied" {
		switch status.Action {
		case "install":
			if normalizeNodeID(status.Node) == "" {
				return "Node installed."
			}
			return nodeDisplayName(status.Node) + " installed."
		case "launch_at_boot":
			if status.Enabled == nil {
				return "Automatic launch setting updated."
			}
			if *status.Enabled {
				return "Automatic launch enabled."
			}
			return "Automatic launch disabled."
		case "apply_config":
			return "New configuration applied."
		}
	}
	messages := map[string]string{
		"config_pending":     "Apply the pending configuration first.",
		"config_changed":     "The config changed again. Review and apply the latest version.",
		"already_installed":  "That node is already installed.",
		"validation_failed":  "The requested host change did not pass validation.",
		"apply_failed":       "The host could not apply that change.",
		"approval_failed":    "The config could not be approved.",
		"rollback_failed":    "The host could not restore its previous configuration.",
		"unsupported":        "That host action is not supported by this installation.",
		"ownership_conflict": "The node data directory is managed by another installation.",
		"unchanged":          "The host already has that setting.",
	}
	if message := messages[status.ErrorCode]; message != "" {
		return message
	}
	if status.State == "rejected" {
		return "Host change was rejected."
	}
	return "Host change could not be applied."
}

func (a *app) hostControlStatus() (*hostControlStatus, bool) {
	for _, name := range []string{"request", "processing"} {
		b, err := readSmallFile(a.nodeControlPath(name), 4096)
		if err == nil {
			var request hostControlRequest
			decoder := json.NewDecoder(bytes.NewReader(b))
			decoder.DisallowUnknownFields()
			if decoder.Decode(&request) == nil && ensureJSONEnd(decoder) == nil && validPortControlID(request.ID) && validHostControlShape(request.Action, request.Node, request.Enabled) {
				return &hostControlStatus{ID: request.ID, Action: request.Action, Node: normalizeNodeID(request.Node), Enabled: request.Enabled, State: "pending", Message: "Applying host change…"}, true
			}
			return nil, true
		}
		if !os.IsNotExist(err) {
			return nil, true
		}
	}
	b, err := readSmallFile(a.nodeControlPath("status"), 4096)
	if err != nil {
		return nil, false
	}
	var status hostControlStatus
	decoder := json.NewDecoder(bytes.NewReader(b))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&status) != nil || ensureJSONEnd(decoder) != nil || !validPortControlID(status.ID) || !validHostAction(status.Action) || status.Node != "" && normalizeNodeID(status.Node) == "" || status.State != "applied" && status.State != "rejected" && status.State != "failed" {
		return nil, false
	}
	status.Message = canonicalHostStatusMessage(status)
	status.ErrorCode = ""
	return &status, false
}

func (a *app) hostControlView() hostControlView {
	capability, available := a.hostControlCapability()
	nodes := make([]hostControlNode, 0, len(nodeOrder))
	for _, id := range nodeOrder {
		configured, _ := a.nodeConfigured(id)
		nodes = append(nodes, hostControlNode{ID: id, Name: nodeDisplayName(id), Installed: configured})
	}
	status, _ := a.hostControlStatus()
	return hostControlView{Available: available, InstallSupported: available && capability.InstallSupported, BootSupported: available && capability.BootSupported, BootEnabled: capability.BootEnabled, BootKind: capability.BootKind, ConfigPending: capability.ConfigPending, ConfigRevision: capability.ConfigRevision, Nodes: nodes, Status: status}
}

func (a *app) apiHostControlGet(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if a.rejectUnsafeSettingsHost(w, r) {
		return
	}
	writeJSON(w, a.hostControlView())
}

func decodeHostControlInput(w http.ResponseWriter, r *http.Request) (hostControlInput, error) {
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	var input hostControlInput
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || ensureJSONEnd(decoder) != nil || !validHostAction(input.Action) {
		return input, errors.New("invalid host control request")
	}
	validRevision := len(input.Revision) == 64 && len(bytes.Trim([]byte(input.Revision), "0123456789abcdef")) == 0
	valid := input.Action == "install" && normalizeNodeID(input.Node) != "" && input.Enabled == nil && input.Revision == "" || input.Action == "launch_at_boot" && input.Node == "" && input.Enabled != nil && input.Revision == "" || input.Action == "apply_config" && input.Node == "" && input.Enabled == nil && validRevision
	if !valid {
		return input, errors.New("invalid host control request")
	}
	return input, nil
}

func (a *app) apiHostControlPost(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if rejectCredentialCSRF(w, r) || a.rejectUnsafeSettingsHost(w, r) {
		return
	}
	input, err := decodeHostControlInput(w, r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	capability, available := a.hostControlCapability()
	if !available || input.Action == "install" && !capability.InstallSupported || input.Action == "launch_at_boot" && !capability.BootSupported || input.Action == "apply_config" && (!capability.ConfigPending || input.Revision != capability.ConfigRevision) {
		http.Error(w, "host control is unavailable", http.StatusServiceUnavailable)
		return
	}
	if capability.ConfigPending && input.Action != "apply_config" {
		http.Error(w, "apply the pending configuration first", http.StatusConflict)
		return
	}
	if input.Action == "install" {
		configured, _ := a.nodeConfigured(input.Node)
		if configured {
			http.Error(w, "node is already installed", http.StatusConflict)
			return
		}
	}
	a.controlMu.Lock()
	defer a.controlMu.Unlock()
	if a.controlRequestPending() {
		http.Error(w, "another host change is already pending", http.StatusConflict)
		return
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		http.Error(w, "host control unavailable", http.StatusServiceUnavailable)
		return
	}
	request := hostControlRequest{ID: hex.EncodeToString(id), Action: input.Action, Node: input.Node, Enabled: input.Enabled, Revision: input.Revision, RequestedAt: time.Now().Unix()}
	b, _ := json.Marshal(request)
	if writePrivateFileAtomic(a.nodeControlPath("request"), append(b, '\n')) != nil {
		http.Error(w, "host control unavailable", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, hostControlStatus{ID: request.ID, Action: request.Action, Node: request.Node, Enabled: request.Enabled, State: "pending", Message: "Applying host change…"})
}
