package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testZcashCookie        = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
	testZcashRotatedCookie = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="
)

func zcashProxyApp(t *testing.T, upstream, user, password string) *app {
	t.Helper()
	cookie := filepath.Join(t.TempDir(), ".cookie")
	if err := os.WriteFile(cookie, []byte("__cookie__:"+testZcashCookie), 0o600); err != nil {
		t.Fatal(err)
	}
	return &app{cfg: config{nodes: map[string]nodeConfig{nodeZcash: {ID: nodeZcash, RPCURL: upstream, RPCUser: user, RPCPassword: password, RPCCookiePath: cookie}}}}
}

func performZcashProxyRequest(handler http.Handler, body, user, password string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
	if user != "" || password != "" {
		request.SetBasicAuth(user, password)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func TestZcashProxyRequiresAuthAndAllowsReadOnlyMethod(t *testing.T) {
	var upstreamAuth string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamAuth = r.Header.Get("Authorization")
		body, _ := io.ReadAll(r.Body)
		var request map[string]any
		if json.Unmarshal(body, &request) != nil || request["method"] != "getblockchaininfo" {
			t.Fatalf("upstream request = %s", body)
		}
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":1,"result":{"blocks":1}}`)
	}))
	defer upstream.Close()
	a := zcashProxyApp(t, upstream.URL, "zcash-user", "zcash-password")
	handler := a.zcashRPCProxy()
	body := `{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}`
	for _, credentials := range [][2]string{{}, {"zcash-user", "wrong"}, {"wrong", "zcash-password"}} {
		if got := performZcashProxyRequest(handler, body, credentials[0], credentials[1]); got.Code != http.StatusUnauthorized || strings.Contains(got.Body.String(), "blocks") {
			t.Fatalf("unauthorized response = %d %s", got.Code, got.Body.String())
		}
	}
	got := performZcashProxyRequest(handler, body, "zcash-user", "zcash-password")
	if got.Code != http.StatusOK || !strings.Contains(got.Body.String(), `"blocks":1`) || !strings.HasPrefix(upstreamAuth, "Basic ") {
		t.Fatalf("authorized response = %d %s upstream auth=%q", got.Code, got.Body.String(), upstreamAuth)
	}
}

func TestZcashProxyRejectsWritesBatchesAndOversizedBodies(t *testing.T) {
	upstreamCalls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		upstreamCalls++
		_, _ = io.WriteString(w, `{}`)
	}))
	defer upstream.Close()
	a := zcashProxyApp(t, upstream.URL, "user", "password")
	handler := a.zcashRPCProxy()
	for _, body := range []string{
		`{"jsonrpc":"2.0","id":1,"method":"sendrawtransaction","params":["00"]}`,
		`[{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}]`,
		`{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[],"extra":true}`,
		`{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":"bad"}`,
		strings.Repeat("x", maxZcashProxyRequest+1),
	} {
		got := performZcashProxyRequest(handler, body, "user", "password")
		if got.Code != http.StatusForbidden && got.Code != http.StatusBadRequest {
			t.Fatalf("rejected body response = %d %s", got.Code, got.Body.String())
		}
	}
	if upstreamCalls != 0 {
		t.Fatalf("rejected requests reached native RPC: %d", upstreamCalls)
	}
}

func TestZcashProxyRejectsInvalidUpstreamResponse(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "not-json") }))
	defer upstream.Close()
	a := zcashProxyApp(t, upstream.URL, "user", "password")
	body := `{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}`
	if got := performZcashProxyRequest(a.zcashRPCProxy(), body, "user", "password"); got.Code != http.StatusBadGateway {
		t.Fatalf("invalid upstream response = %d %s", got.Code, got.Body.String())
	}
}

func TestZcashProxyReloadsRotatedNativeCookieAndFailsClosed(t *testing.T) {
	var passwords []string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, password, _ := r.BasicAuth()
		passwords = append(passwords, password)
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":1,"result":1}`)
	}))
	defer upstream.Close()
	a := zcashProxyApp(t, upstream.URL, "user", "password")
	node := a.cfg.nodes[nodeZcash]
	body := `{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}`
	if got := performZcashProxyRequest(a.zcashRPCProxy(), body, "user", "password"); got.Code != http.StatusOK {
		t.Fatalf("first cookie request = %d %s", got.Code, got.Body.String())
	}
	if err := os.WriteFile(node.RPCCookiePath, []byte("__cookie__:"+testZcashRotatedCookie), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := performZcashProxyRequest(a.zcashRPCProxy(), body, "user", "password"); got.Code != http.StatusOK {
		t.Fatalf("rotated cookie request = %d %s", got.Code, got.Body.String())
	}
	if len(passwords) != 2 || passwords[0] != testZcashCookie || passwords[1] != testZcashRotatedCookie {
		t.Fatalf("native cookie passwords = %#v", passwords)
	}
	if err := os.WriteFile(node.RPCCookiePath, []byte("malformed"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := performZcashProxyRequest(a.zcashRPCProxy(), body, "user", "password"); got.Code != http.StatusBadGateway || len(passwords) != 2 {
		t.Fatalf("malformed cookie response = %d %s calls=%d", got.Code, got.Body.String(), len(passwords))
	}
}
