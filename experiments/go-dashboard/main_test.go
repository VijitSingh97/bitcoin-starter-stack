package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type rpcFixture struct {
	mu      sync.Mutex
	calls   []string
	invalid bool
}

func (f *rpcFixture) handler(w http.ResponseWriter, r *http.Request) {
	if user, password, ok := r.BasicAuth(); !ok || user != "rpc-user" || password != "rpc-password" {
		http.Error(w, "bad auth", http.StatusUnauthorized)
		return
	}
	var request struct {
		Method string `json:"method"`
	}
	if json.NewDecoder(r.Body).Decode(&request) != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	f.mu.Lock()
	f.calls = append(f.calls, request.Method)
	f.mu.Unlock()
	if f.invalid {
		_, _ = io.WriteString(w, "not json")
		return
	}
	results := map[string]any{
		"getblockchaininfo": map[string]any{"blocks": 900000, "headers": 900001, "verificationprogress": 0.9999, "initialblockdownload": false, "pruned": true, "prune_target_size": 10 * 1024 * 1024 * 1024, "size_on_disk": 11 * 1024 * 1024 * 1024},
		"getnetworkinfo":    map[string]any{"subversion": `<script>alert("x")</script>`, "connections": 10},
		"getpeerinfo":       []any{map[string]any{"inbound": true}, map[string]any{"inbound": false}},
		"uptime":            90061,
		"getmempoolinfo":    map[string]any{"size": 4200, "bytes": 12 * 1024 * 1024},
		"estimatesmartfee":  map[string]any{"feerate": 0.0001},
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"result": results[request.Method], "error": nil, "id": "go-dashboard"})
}

func (f *rpcFixture) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func testApp(t *testing.T, fixture *rpcFixture, password string) (*app, http.Handler) {
	t.Helper()
	rpcServer := httptest.NewServer(http.HandlerFunc(fixture.handler))
	t.Cleanup(rpcServer.Close)
	root := filepath.Dir(sourceFile(t))
	cfg := config{rpcURL: rpcServer.URL, rpcUser: "rpc-user", rpcPassword: "rpc-password", dashboardPassword: password, dataDir: t.TempDir(), stateDir: t.TempDir(), version: "1.31.1"}
	rpc := &rpcClient{url: cfg.rpcURL, user: cfg.rpcUser, password: cfg.rpcPassword, client: &http.Client{Timeout: time.Second}}
	a, err := newApp(cfg, rpc, filepath.Join(root, "index.html"), filepath.Join(root, "../../build/dashboard/static"), log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	return a, a.routes()
}

func sourceFile(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, "main_test.go")
}

func request(t *testing.T, handler http.Handler, method, path, password string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	if password != "" {
		req.SetBasicAuth("any-user", password)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	return w
}

func TestIndexAuthRPCParityAndEscaping(t *testing.T) {
	fixture := &rpcFixture{}
	_, handler := testApp(t, fixture, "dashboard-secret")
	if got := request(t, handler, http.MethodGet, "/", ""); got.Code != http.StatusUnauthorized || got.Header().Get("WWW-Authenticate") == "" {
		t.Fatalf("unauthenticated response = %d, challenge %q", got.Code, got.Header().Get("WWW-Authenticate"))
	}
	if got := request(t, handler, http.MethodGet, "/", "wrong"); got.Code != http.StatusUnauthorized {
		t.Fatalf("wrong password = %d", got.Code)
	}
	got := request(t, handler, http.MethodGet, "/", "dashboard-secret")
	if got.Code != http.StatusOK {
		t.Fatalf("status = %d", got.Code)
	}
	body := got.Body.String()
	for _, want := range []string{"Go prototype · read-only benchmark", "900000 / 900001", "4200 tx", "10 / 10 / 10", "Pruned"} {
		if !strings.Contains(body, want) {
			t.Errorf("body missing %q", want)
		}
	}
	if strings.Contains(body, `<script>alert("x")</script>`) || !strings.Contains(body, "&lt;script&gt;") {
		t.Error("RPC value was not HTML escaped")
	}
	if fixture.count() != 8 {
		t.Fatalf("root RPC calls = %d, want 8", fixture.count())
	}
}

func TestInvalidRPCRendersLoading(t *testing.T) {
	fixture := &rpcFixture{invalid: true}
	_, handler := testApp(t, fixture, "")
	got := request(t, handler, http.MethodGet, "/", "")
	if got.Code != http.StatusOK || !strings.Contains(got.Body.String(), "Bitcoin Node Initializing") {
		t.Fatalf("response = %d %q", got.Code, got.Body.String())
	}
}

func TestRPCNilParamsUsesEmptyArray(t *testing.T) {
	var params json.RawMessage
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Params json.RawMessage `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		params = body.Params
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"blocks": 1}, "error": nil})
	}))
	defer server.Close()
	rpc := &rpcClient{url: server.URL, client: server.Client()}
	var result blockchainInfo
	if err := rpc.call(t.Context(), "getblockchaininfo", nil, &result); err != nil {
		t.Fatal(err)
	}
	if string(params) != "[]" {
		t.Fatalf("params = %s, want []", params)
	}
}

func TestMetricsAndReadAPIs(t *testing.T) {
	fixture := &rpcFixture{}
	a, handler := testApp(t, fixture, "")
	a.recordFee(4.2)
	metrics := request(t, handler, http.MethodGet, "/metrics", "")
	for _, want := range []string{"bitcoin_node_up 1", "bitcoin_blocks 900000", `bitcoin_peers{direction="in"} 1`, `bitcoin_fee_sat_vb{blocks="6"} 10`} {
		if !strings.Contains(metrics.Body.String(), want) {
			t.Errorf("metrics missing %q", want)
		}
	}
	if fixture.count() != 8 {
		t.Fatalf("metrics RPC calls = %d, want 8", fixture.count())
	}
	fees := request(t, handler, http.MethodGet, "/api/fees", "")
	if fees.Code != http.StatusOK || !strings.Contains(fees.Body.String(), "4.2") {
		t.Fatalf("fees = %d %q", fees.Code, fees.Body.String())
	}
	watch := request(t, handler, http.MethodGet, "/api/watch", "")
	if watch.Code != http.StatusOK || !strings.Contains(watch.Body.String(), `"wallets":[]`) {
		t.Fatalf("watch = %d %q", watch.Code, watch.Body.String())
	}
	upgrade := request(t, handler, http.MethodGet, "/api/upgrade", "")
	if upgrade.Code != http.StatusOK || !strings.Contains(upgrade.Body.String(), `"enabled":false`) {
		t.Fatalf("upgrade = %d %q", upgrade.Code, upgrade.Body.String())
	}
}

func TestMutationsRejected(t *testing.T) {
	fixture := &rpcFixture{}
	_, handler := testApp(t, fixture, "")
	for _, target := range []string{"/", "/api/watch", "/api/watch/test", "/api/upgrade", "/metrics"} {
		got := request(t, handler, http.MethodPost, target, "")
		if got.Code != http.StatusMethodNotAllowed || got.Header().Get("Allow") != "GET, HEAD" {
			t.Errorf("POST %s = %d, Allow %q", target, got.Code, got.Header().Get("Allow"))
		}
	}
	if fixture.count() != 0 {
		t.Fatalf("mutations made %d RPC calls", fixture.count())
	}
}

func TestFeeHistoryBoundedAndPersisted(t *testing.T) {
	fixture := &rpcFixture{}
	a, _ := testApp(t, fixture, "")
	for i := 0; i < maxFees+2; i++ {
		a.recordFee(float64(i))
	}
	if len(a.fees) != maxFees || a.fees[0] != 2 {
		t.Fatalf("fees len/first = %d/%v", len(a.fees), a.fees[0])
	}
	b, err := os.ReadFile(filepath.Join(a.cfg.stateDir, "fee_history.json"))
	if err != nil || len(b) == 0 {
		t.Fatalf("persisted fees: %v", err)
	}
}

func TestRuntimeConfigRequiresDashboardPassword(t *testing.T) {
	t.Setenv("RPC_USER", "rpc-user")
	t.Setenv("RPC_PASSWORD", "rpc-password")
	t.Setenv("DASHBOARD_PASSWORD", "")
	if _, err := envConfig(); err == nil || !strings.Contains(err.Error(), "DASHBOARD_PASSWORD") {
		t.Fatalf("envConfig error = %v", err)
	}
	t.Setenv("DASHBOARD_PASSWORD", "dashboard-secret")
	if _, err := envConfig(); err != nil {
		t.Fatalf("valid envConfig: %v", err)
	}
}
