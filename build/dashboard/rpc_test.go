package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestNodeRPCDoesNotFollowRedirects(t *testing.T) {
	var reached atomic.Bool
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached.Store(true)
		writeJSON(w, map[string]any{"result": map[string]any{}, "error": nil})
	}))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()
	client := redirect.Client()
	rpc := rpcClient{url: redirect.URL, user: "test-user", password: "test-password", client: client}
	var result map[string]any
	if rpc.call(context.Background(), "getblockchaininfo", nil, &result) == nil {
		t.Fatal("redirect was accepted as a node response")
	}
	if reached.Load() {
		t.Fatal("node RPC followed a redirect")
	}
	if client.CheckRedirect != nil {
		t.Fatal("shared client was mutated")
	}
}
