package main

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

func writePendingNodeTransition(t *testing.T, a *app, node string) {
	t.Helper()
	request := fmt.Sprintf(`{"id":"11111111111111111111111111111111","node":%q,"active":false,"confirmation":"deactivate","requested_at":%d}`, node, time.Now().Unix())
	if err := os.WriteFile(a.nodeControlPath("processing"), []byte(request), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestBitcoinBackgroundWorkersPauseDuringNodeTransition(t *testing.T) {
	fixture := &rpcFixture{}
	a, _ := testApp(t, fixture, "")
	entry, err := a.watch.Add("Cold", genesisAddress, "")
	if err != nil {
		t.Fatal(err)
	}
	writePendingNodeTransition(t, a, nodeBitcoin)
	ctx, cancel := context.WithCancel(t.Context())
	done := a.startBackground(ctx)
	time.Sleep(50 * time.Millisecond)
	if fixture.count() != 0 {
		t.Fatalf("pending Bitcoin transition allowed %d RPC calls", fixture.count())
	}
	if _, pending := a.watch.snapshot(); pending[watchKeyID(entry.Key)] {
		t.Fatal("pending Bitcoin transition started wallet provisioning")
	}
	if a.scanner.enqueue(entry, true) {
		t.Fatal("pending Bitcoin transition queued a balance scan")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("paused background workers did not stop")
	}
}

func TestMoneroWalletWorkerDropsQueuedRefreshWhileInactive(t *testing.T) {
	store := &MoneroWatchStore{enabled: true, queue: make(chan string, 1), wallets: []MoneroWatchWallet{{ID: "wallet"}}}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan struct{})
	go func() {
		store.run(ctx, func() bool { return false })
		close(done)
	}()
	store.Queue("wallet")
	time.Sleep(25 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("inactive Monero wallet worker did not stop")
	}
}
