package main

import (
	"strings"
	"testing"
)

func TestTariWalletConfigRequiresPrivateEndpointAndSeparateLogin(t *testing.T) {
	t.Setenv("BITCOIN_ENABLED", "false")
	t.Setenv("TARI_ENABLED", "true")
	t.Setenv("TARI_WALLET_ENABLED", "true")
	t.Setenv("TARI_WALLET_RPC_USER", "tari-wallet")
	t.Setenv("TARI_WALLET_RPC_PASSWORD", "test-password")
	t.Setenv("TARI_WALLET_GRPC_URL", "http://172.29.0.37:18143")
	t.Setenv("TARI_WALLET_DIR", "/tari-wallet")
	cfg, err := envConfig()
	if err != nil || !cfg.tariWalletEnabled || cfg.tariWalletURL != "http://172.29.0.37:18143" || cfg.tariWalletDir != "/tari-wallet" {
		t.Fatalf("Tari wallet configuration: %v", err)
	}
	t.Setenv("TARI_WALLET_RPC_PASSWORD", "")
	if _, err := envConfig(); err == nil || !strings.Contains(err.Error(), "TARI_WALLET_RPC_PASSWORD") {
		t.Fatalf("missing wallet login accepted: %v", err)
	}
	t.Setenv("TARI_WALLET_RPC_PASSWORD", "test-password")
	t.Setenv("TARI_WALLET_GRPC_URL", "http://rpc.public.example:18143")
	if _, err := envConfig(); err == nil || !strings.Contains(err.Error(), "internal HTTP URL") {
		t.Fatalf("public wallet endpoint accepted: %v", err)
	}
	t.Setenv("TARI_WALLET_GRPC_URL", "http://172.29.0.37:18143")
	t.Setenv("TARI_WALLET_DIR", ".")
	if _, err := envConfig(); err == nil || !strings.Contains(err.Error(), "absolute path") {
		t.Fatalf("relative wallet volume accepted: %v", err)
	}
	t.Setenv("TARI_WALLET_DIR", "/tari-wallet")
	t.Setenv("TARI_ENABLED", "false")
	cfg, err = envConfig()
	if err != nil || cfg.tariWalletEnabled {
		t.Fatalf("wallet enabled without Tari node: %v", err)
	}
}
