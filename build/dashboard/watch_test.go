package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestDescriptorParityVectors(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("parity", "oracle.json"))
	if err != nil {
		t.Fatal(err)
	}
	var oracle struct {
		Slip132 struct {
			Versions []struct {
				Input       string       `json:"input"`
				Descriptors []descriptor `json:"descriptors"`
			} `json:"versions"`
			BadChecksum struct {
				Input string `json:"input"`
			} `json:"bad_checksum"`
		} `json:"slip132"`
		Descriptors []struct {
			Input       string       `json:"input"`
			Descriptors []descriptor `json:"descriptors"`
		} `json:"descriptors"`
		Helpers struct {
			WalletNames []struct {
				Input  string `json:"input"`
				Output string `json:"output"`
			} `json:"wallet_names"`
			Birthdays []struct {
				Input     string `json:"input"`
				Timestamp int64  `json:"timestamp"`
			} `json:"birthdays"`
			BTCFormat []struct {
				Input  float64 `json:"input"`
				Output string  `json:"output"`
			} `json:"btc_format"`
		} `json:"helpers"`
	}
	if err := json.Unmarshal(b, &oracle); err != nil {
		t.Fatal(err)
	}
	for _, vector := range oracle.Slip132.Versions {
		got, err := descriptorsFor(vector.Input)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(got, vector.Descriptors) {
			t.Fatalf("descriptors for %.4s = %#v, want %#v", vector.Input, got, vector.Descriptors)
		}
	}
	if _, err := descriptorsFor(oracle.Slip132.BadChecksum.Input); err == nil {
		t.Fatal("bad checksum accepted")
	}
	for _, vector := range oracle.Descriptors {
		got, err := descriptorsFor(vector.Input)
		if err != nil || !reflect.DeepEqual(got, vector.Descriptors) {
			t.Fatalf("descriptor %q = %#v, %v; want %#v", vector.Input, got, err, vector.Descriptors)
		}
	}
	for _, vector := range oracle.Helpers.WalletNames {
		if got := walletName(vector.Input); got != vector.Output {
			t.Errorf("walletName(%q) = %q, want %q", vector.Input, got, vector.Output)
		}
	}
	for _, vector := range oracle.Helpers.Birthdays {
		if got := birthdayTimestamp(vector.Input); got != vector.Timestamp {
			t.Errorf("birthdayTimestamp(%q) = %d, want %d", vector.Input, got, vector.Timestamp)
		}
	}
	for _, vector := range oracle.Helpers.BTCFormat {
		if got := formatBTC(vector.Input); got != vector.Output {
			t.Errorf("formatBTC(%v) = %q, want %q", vector.Input, got, vector.Output)
		}
	}
}

func TestPrivateMaterialRejected(t *testing.T) {
	for _, prefix := range privatePrefixes {
		malformed := prefix + strings.Repeat("1", 60)
		if !hasPrivateMaterial("wpkh(" + malformed + ")") {
			t.Errorf("private prefix %s was not detected", prefix)
		}
	}
	versions := []string{
		"0488ade4", "049d7878", "04b2430c", "04358394", "044a4e28", "045f18bc",
		"0295b005", "02aa7a99", "024285b5", "02575048",
	}
	for _, version := range versions {
		private := syntheticExtendedPrivate(version)
		for _, value := range []string{private, "wpkh(" + private + "/0/*)"} {
			if !hasPrivateMaterial(value) {
				t.Errorf("private extended key version %s was not detected", version)
			}
			if _, err := descriptorsFor(value); err == nil || !strings.Contains(err.Error(), "private key") {
				t.Errorf("descriptorsFor private version %s error = %v", version, err)
			}
		}
	}
	unknownVersion := make([]byte, 78)
	copy(unknownVersion, mustHex("deadbeef"))
	for index := 4; index < len(unknownVersion); index++ {
		unknownVersion[index] = byte(index)
	}
	unknownVersion[45] = 0
	if private := base58EncodeCheck(unknownVersion); !hasPrivateMaterial("wpkh(" + private + "/0/*)") {
		t.Fatal("extended private key with an unknown version was not detected")
	}
	for _, version := range []byte{0x80, 0xef} {
		for _, compressed := range []bool{false, true} {
			payload := append([]byte{version}, make([]byte, 32)...)
			if compressed {
				payload = append(payload, 1)
			}
			private := base58EncodeCheck(payload)
			if !hasPrivateMaterial("pkh(" + private + ")") {
				t.Errorf("WIF version %x compressed=%v was not detected", version, compressed)
			}
		}
	}
	if hasPrivateMaterial(parityZpub) || hasPrivateMaterial("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa") {
		t.Fatal("public watch material identified as private")
	}
}

func TestPrivateEntriesFilteredWithoutRewritingExistingRoster(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "wallets.json")
	private := syntheticExtendedPrivate("0488ade4")
	original, err := json.Marshal([]WatchEntry{
		{Name: "Private", Key: "wpkh(" + private + "/0/*)"},
		{Name: "Public", Key: parityZpub},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, original, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WATCH_STORE", path)
	t.Setenv("BALANCE_HISTORY", filepath.Join(dir, "balance_history.json"))
	store := NewWatchStore(dir)
	if got := store.Entries(); len(got) != 1 || got[0].Name != "Public" {
		t.Fatalf("filtered entries = %#v", got)
	}
	if _, err := store.Add("Rejected", private, ""); err == nil {
		t.Fatal("private key was added")
	}
	if _, err := store.Add("Another", parityZpub, ""); err == nil || !strings.Contains(err.Error(), "remove it manually") {
		t.Fatalf("public add with unsafe legacy roster error = %v", err)
	}
	if store.Remove("Public") {
		t.Fatal("remove modified an unsafe legacy roster")
	}
	unchanged, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(unchanged, original) {
		t.Fatal("loading filtered private material rewrote the existing roster")
	}
	view, err := json.Marshal(store.List(func(string, string, []any, time.Duration) any { return nil }))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(view), private) {
		t.Fatal("private material exposed by List")
	}
	assertMode(t, dir, 0o700)
	assertMode(t, path, 0o600)
}

func TestPrivateConfigSeedDroppedBeforePersistence(t *testing.T) {
	dir := t.TempDir()
	private := syntheticExtendedPrivate("04358394")
	seed, err := json.Marshal([]WatchEntry{{Name: "Private", Key: private}, {Name: "Public", Key: parityZpub}})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "wallets.json")
	t.Setenv("WATCH_STORE", path)
	t.Setenv("BALANCE_HISTORY", filepath.Join(dir, "balance_history.json"))
	t.Setenv("WATCH_WALLETS_B64", base64.StdEncoding.EncodeToString(seed))
	store := NewWatchStore(dir)
	if got := store.Entries(); len(got) != 1 || got[0].Name != "Public" {
		t.Fatalf("seeded entries = %#v", got)
	}
	persisted, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(persisted), private) {
		t.Fatal("private seed was persisted")
	}
	assertMode(t, path, 0o600)
}

func TestWatchStoreFailsClosedWhenExistingFileCannotBeSecured(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "wallets.json")
	original := []byte(`[{"name":"Public","key":"` + parityZpub + `"}]`)
	if err := os.WriteFile(path, original, 0o644); err != nil {
		t.Fatal(err)
	}
	originalChmod := chmodExistingFile
	chmodExistingFile = func(candidate string, mode os.FileMode) error {
		if candidate == path {
			return os.ErrPermission
		}
		return originalChmod(candidate, mode)
	}
	t.Cleanup(func() { chmodExistingFile = originalChmod })
	t.Setenv("WATCH_STORE", path)
	t.Setenv("BALANCE_HISTORY", filepath.Join(dir, "balance_history.json"))
	store := NewWatchStore(dir)
	if got := store.Entries(); len(got) != 0 {
		t.Fatalf("entries loaded after chmod failure: %#v", got)
	}
	if _, err := store.Add("Another", parityZpub, ""); err == nil || !strings.Contains(err.Error(), "remove it manually") {
		t.Fatalf("add after chmod failure error = %v", err)
	}
	unchanged, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(unchanged, original) {
		t.Fatal("chmod failure rewrote the existing roster")
	}
}

func TestWatchStoreCRUDAndStaleBalance(t *testing.T) {
	t.Setenv("WATCH_STORE", filepath.Join(t.TempDir(), "wallets.json"))
	t.Setenv("BALANCE_HISTORY", filepath.Join(t.TempDir(), "history.json"))
	store := NewWatchStore(t.TempDir())
	key := parityZpub
	if _, err := store.Add("Cold", key, "2021-01-01"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Add("cold", key, ""); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("duplicate error = %v", err)
	}
	store.history.record(key, 1.25, time.Unix(0, 0))
	walletRPC := func(wallet, method string, params []any, timeout time.Duration) any { return nil }
	view := store.List(walletRPC)
	rows := view["wallets"].([]map[string]any)
	if rows[0]["state"] != "stale" || rows[0]["btc"] != "1.25" {
		t.Fatalf("stale row = %#v", rows[0])
	}
	if !store.Remove("Cold") || store.Remove("Cold") {
		t.Fatal("remove result mismatch")
	}
	if got := store.history.series(key); !reflect.DeepEqual(got, []float64{1.25}) {
		t.Fatalf("history after removal = %v", got)
	}
}

func TestProvisionCreatesWatchOnlyWallet(t *testing.T) {
	var nodeCalls []rpcCall
	var walletCalls []walletCall
	rpc := func(method string, params []any) any {
		nodeCalls = append(nodeCalls, rpcCall{method, params})
		switch method {
		case "createwallet":
			return map[string]any{"name": params[0]}
		case "getdescriptorinfo":
			return map[string]any{"descriptor": params[0].(string) + "#test", "isrange": true}
		}
		return nil
	}
	walletRPC := func(wallet, method string, params []any, timeout time.Duration) any {
		walletCalls = append(walletCalls, walletCall{wallet, method, params, timeout})
		return nil
	}
	ProvisionOne(rpc, walletRPC, WatchEntry{Name: "Cold", Key: parityZpub, Birthday: "2021-01-01"}, false)
	var create []any
	for _, call := range nodeCalls {
		if call.method == "createwallet" {
			create = call.params
		}
	}
	if len(create) != 7 || create[1] != true || create[5] != true || create[6] != true {
		t.Fatalf("createwallet params = %#v", create)
	}
	if got := walletCalls[len(walletCalls)-1]; got.method != "importdescriptors" || got.timeout != time.Hour {
		t.Fatalf("import call = %#v", got)
	}
}

func TestProvisionShortCircuitsWithoutCreating(t *testing.T) {
	tests := []struct {
		name      string
		key       string
		pruned    bool
		loaded    bool
		readd     bool
		wantCalls []string
	}{
		{name: "loaded", key: parityZpub, loaded: true},
		{name: "readd", key: parityZpub, readd: true, wantCalls: []string{"loadwallet"}},
		{name: "pruned", key: parityZpub, pruned: true, wantCalls: []string{"loadwallet"}},
		{name: "bad key", key: "not-a-key", wantCalls: []string{"loadwallet"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var calls []string
			rpc := func(method string, params []any) any {
				calls = append(calls, method)
				if method == "loadwallet" && test.readd {
					return map[string]any{"name": params[0]}
				}
				return nil
			}
			walletRPC := func(wallet, method string, params []any, timeout time.Duration) any {
				if test.loaded {
					return map[string]any{"scanning": false}
				}
				return nil
			}
			ProvisionOne(rpc, walletRPC, WatchEntry{Name: "Cold", Key: test.key}, test.pruned)
			if !reflect.DeepEqual(calls, test.wantCalls) {
				t.Fatalf("calls = %v, want %v", calls, test.wantCalls)
			}
		})
	}
}

type rpcCall struct {
	method string
	params []any
}

type walletCall struct {
	wallet  string
	method  string
	params  []any
	timeout time.Duration
}

func syntheticExtendedPrivate(version string) string {
	payload := make([]byte, 78)
	copy(payload, mustHex(version))
	for index := 4; index < len(payload); index++ {
		payload[index] = byte(index)
	}
	return base58EncodeCheck(payload)
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("%s mode = %o, want %o", path, got, want)
	}
}

const parityZpub = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"
