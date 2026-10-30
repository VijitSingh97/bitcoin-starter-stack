package main

import (
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMoneroAPIReportsDigestAuthenticatedNode(t *testing.T) {
	for _, algorithm := range []string{"MD5", "SHA-256"} {
		t.Run(algorithm, func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if calls == 1 {
					w.Header().Set("WWW-Authenticate", `Digest realm="monero-rpc", nonce="server-nonce", qop="auth", algorithm=`+algorithm+`, opaque="opaque-value"`)
					w.WriteHeader(http.StatusUnauthorized)
					return
				}
				if !validDigestRequest(r, algorithm, "rpc-user", "rpc-password") {
					http.Error(w, "bad digest", http.StatusUnauthorized)
					return
				}
				var request struct {
					Method string `json:"method"`
				}
				if json.NewDecoder(r.Body).Decode(&request) != nil || request.Method != "get_info" {
					http.Error(w, "bad request", http.StatusBadRequest)
					return
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": "dashboard", "result": map[string]any{
					"synchronized": true, "busy_syncing": false, "height": 3500000, "target_height": 3500000,
					"version": "0.18.4.2-release", "start_time": time.Now().Add(-2 * time.Hour).Unix(),
					"incoming_connections_count": 4, "outgoing_connections_count": 12,
					"pruning_seed": 386, "database_size": 84_000_000_000,
				}})
			}))
			defer server.Close()

			a, _ := testApp(t, &rpcFixture{}, "dashboard-secret")
			a.cfg.moneroEnabled = true
			a.cfg.moneroRPCURL = server.URL
			a.cfg.moneroRPCUser = "rpc-user"
			a.cfg.moneroRPCPassword = "rpc-password"
			response := request(t, a.routes(), http.MethodGet, "/api/monero", "dashboard-secret")
			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
			}
			var status moneroStatus
			if err := json.Unmarshal(response.Body.Bytes(), &status); err != nil {
				t.Fatal(err)
			}
			if calls != 2 || !status.Enabled || !status.Available || !status.Synced || status.SyncPercent != 100 || status.Height != 3500000 || status.Version != "0.18.4.2-release" || status.IncomingConnections != 4 || status.OutgoingConnections != 12 || !status.Pruned || status.DatabaseSizeBytes != 84_000_000_000 || status.UptimeSeconds < 7198 {
				t.Fatalf("calls = %d, status = %#v", calls, status)
			}
			if response.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("cache control = %q", response.Header().Get("Cache-Control"))
			}
		})
	}
}

func TestMoneroAPIDisabledAndUnavailableRemainJSON(t *testing.T) {
	a, handler := testApp(t, &rpcFixture{}, "dashboard-secret")
	disabled := request(t, handler, http.MethodGet, "/api/monero", "dashboard-secret")
	assertMoneroResponseShape(t, disabled, http.StatusOK, false, false, "")

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("WWW-Authenticate", `Digest realm="monero-rpc", nonce="server-nonce", qop="auth", algorithm=MD5`)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()
	a.cfg.moneroEnabled = true
	a.cfg.moneroRPCURL = server.URL
	a.cfg.moneroRPCUser = "wrong-user"
	a.cfg.moneroRPCPassword = "wrong-password"
	unavailable := request(t, a.routes(), http.MethodGet, "/api/monero", "dashboard-secret")
	assertMoneroResponseShape(t, unavailable, http.StatusServiceUnavailable, true, false, "Monero RPC unavailable")
	if strings.Contains(unavailable.Body.String(), "wrong-user") || strings.Contains(unavailable.Body.String(), "wrong-password") || strings.Contains(unavailable.Body.String(), server.URL) {
		t.Fatal("unavailable response disclosed RPC connection details")
	}
}

func TestMoneroAPIMalformedResponseAndDashboardAuth(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "not json")
	}))
	defer server.Close()
	a, _ := testApp(t, &rpcFixture{}, "dashboard-secret")
	a.cfg.moneroEnabled = true
	a.cfg.moneroRPCURL = server.URL
	a.cfg.moneroRPCUser = "rpc-user"
	a.cfg.moneroRPCPassword = "rpc-password"
	handler := a.routes()
	if response := request(t, handler, http.MethodGet, "/api/monero", ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d", response.Code)
	}
	malformed := request(t, handler, http.MethodGet, "/api/monero", "dashboard-secret")
	assertMoneroResponseShape(t, malformed, http.StatusServiceUnavailable, true, false, "Monero RPC unavailable")
}

func TestMoneroRPCCancellationStopsRequest(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer func() {
		close(release)
		server.Close()
	}()
	rpc := moneroRPC{url: server.URL, user: "user", password: "password", client: server.Client()}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() {
		var info moneroInfo
		done <- rpc.call(ctx, "get_info", &info)
	}()
	<-started
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled request succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("Monero RPC request ignored cancellation")
	}
}

func TestMoneroEnvironmentRequiresSeparateCredentials(t *testing.T) {
	t.Setenv("RPC_USER", "bitcoin-user")
	t.Setenv("RPC_PASSWORD", "bitcoin-password")
	t.Setenv("MONERO_ENABLED", "true")
	t.Setenv("MONERO_RPC_URL", "")
	t.Setenv("MONERO_RPC_USER", "monero-user")
	t.Setenv("MONERO_RPC_PASSWORD", "monero-password")
	defaultConfig, err := envConfig()
	if err != nil || defaultConfig.moneroRPCURL != "http://172.29.0.30:18085" {
		t.Fatalf("default Monero RPC configuration = %#v, %v", defaultConfig, err)
	}
	t.Setenv("MONERO_RPC_URL", "http://monero:18081")
	cfg, err := envConfig()
	if err != nil || !cfg.moneroEnabled || cfg.moneroRPCUser != "monero-user" || cfg.moneroRPCPassword != "monero-password" {
		t.Fatalf("configuration = %#v, %v", cfg, err)
	}
	t.Setenv("MONERO_RPC_PASSWORD", "")
	if _, err := envConfig(); err == nil {
		t.Fatal("enabled Monero accepted missing separate credentials")
	}
	t.Setenv("MONERO_RPC_PASSWORD", "monero-password")
	t.Setenv("MONERO_RPC_URL", "http://embedded:secret@monero:18081")
	if _, err := envConfig(); err == nil {
		t.Fatal("Monero URL accepted embedded credentials")
	}
}

func assertMoneroResponseShape(t *testing.T, response *httptest.ResponseRecorder, code int, enabled, available bool, message string) {
	t.Helper()
	if response.Code != code || response.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("response = %d %q, content type = %q", response.Code, response.Body.String(), response.Header().Get("Content-Type"))
	}
	var raw map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	if len(raw) != 13 || raw["enabled"] != enabled || raw["available"] != available || raw["error"] != message {
		t.Fatalf("response shape = %#v", raw)
	}
}

func validDigestRequest(r *http.Request, algorithm, username, password string) bool {
	authorization := r.Header.Get("Authorization")
	if !strings.HasPrefix(authorization, "Digest ") {
		return false
	}
	parameters := parseDigestParameters(strings.TrimPrefix(authorization, "Digest "))
	if parameters["username"] != username || parameters["realm"] != "monero-rpc" || parameters["nonce"] != "server-nonce" || parameters["uri"] != "/json_rpc" || parameters["qop"] != "auth" || parameters["nc"] != "00000001" || parameters["opaque"] != "opaque-value" {
		return false
	}
	var digest func(string) string
	if algorithm == "SHA-256" {
		digest = func(value string) string {
			sum := sha256.Sum256([]byte(value))
			return hex.EncodeToString(sum[:])
		}
	} else {
		digest = func(value string) string {
			sum := md5.Sum([]byte(value))
			return hex.EncodeToString(sum[:])
		}
	}
	ha1 := digest(username + ":monero-rpc:" + password)
	ha2 := digest(r.Method + ":" + parameters["uri"])
	expected := digest(strings.Join([]string{ha1, "server-nonce", parameters["nc"], parameters["cnonce"], "auth", ha2}, ":"))
	return parameters["response"] == expected
}
