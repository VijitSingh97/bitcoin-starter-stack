package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
)

const maxWatchWallets = 20

var (
	base58Alphabet  = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
	addressPattern  = regexp.MustCompile(`^(?:(?:bc1|tb1|bcrt1)[0-9a-z]{20,}|[13][1-9A-HJ-NP-Za-km-z]{25,34})$`)
	base58Token     = regexp.MustCompile(`[1-9A-HJ-NP-Za-km-z]{50,}`)
	privatePrefixes = []string{"xprv", "yprv", "zprv", "tprv", "uprv", "vprv", "Yprv", "Zprv", "Uprv", "Vprv"}
	privateVersions = map[string]bool{
		"0488ade4": true,
		"049d7878": true,
		"04b2430c": true,
		"04358394": true,
		"044a4e28": true,
		"045f18bc": true,
		"0295b005": true,
		"02aa7a99": true,
		"024285b5": true,
		"02575048": true,
	}
	chmodExistingFile = os.Chmod
	extendedVersions  = map[string]struct {
		version []byte
		wrapper string
	}{
		"0488b21e": {mustHex("0488b21e"), "pkh({})"},
		"049d7cb2": {mustHex("0488b21e"), "sh(wpkh({}))"},
		"04b24746": {mustHex("0488b21e"), "wpkh({})"},
		"043587cf": {mustHex("043587cf"), "pkh({})"},
		"044a5262": {mustHex("043587cf"), "sh(wpkh({}))"},
		"045f1cf6": {mustHex("043587cf"), "wpkh({})"},
	}
)

type WatchEntry struct {
	Name     string `json:"name"`
	Key      string `json:"key"`
	Birthday string `json:"birthday"`
}

type descriptor struct {
	Desc     string `json:"desc"`
	Internal bool   `json:"internal"`
}

type WatchStore struct {
	mu           sync.Mutex
	path         string
	entries      []WatchEntry
	history      *balanceHistory
	unsafeRoster bool
}

func mustHex(s string) []byte {
	b, _ := hex.DecodeString(s)
	return b
}

func base58DecodeCheck(value string) ([]byte, error) {
	n := new(big.Int)
	base := big.NewInt(58)
	for _, char := range value {
		index := strings.IndexRune(base58Alphabet, char)
		if index < 0 {
			return nil, errors.New("invalid base58 character")
		}
		n.Mul(n, base)
		n.Add(n, big.NewInt(int64(index)))
	}
	raw := n.Bytes()
	for i := 0; i < len(value) && value[i] == '1'; i++ {
		raw = append([]byte{0}, raw...)
	}
	if len(raw) < 4 {
		return nil, errors.New("bad base58 checksum")
	}
	data, checksum := raw[:len(raw)-4], raw[len(raw)-4:]
	first := sha256.Sum256(data)
	second := sha256.Sum256(first[:])
	if !equalBytes(checksum, second[:4]) {
		return nil, errors.New("bad base58 checksum")
	}
	return data, nil
}

func base58EncodeCheck(data []byte) string {
	first := sha256.Sum256(data)
	second := sha256.Sum256(first[:])
	raw := append(append([]byte(nil), data...), second[:4]...)
	n := new(big.Int).SetBytes(raw)
	base := big.NewInt(58)
	zero := big.NewInt(0)
	var encoded []byte
	for n.Cmp(zero) > 0 {
		quotient, remainder := new(big.Int), new(big.Int)
		quotient.QuoRem(n, base, remainder)
		encoded = append(encoded, base58Alphabet[remainder.Int64()])
		n = quotient
	}
	for _, b := range raw {
		if b != 0 {
			break
		}
		encoded = append(encoded, '1')
	}
	for left, right := 0, len(encoded)-1; left < right; left, right = left+1, right-1 {
		encoded[left], encoded[right] = encoded[right], encoded[left]
	}
	return string(encoded)
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var different byte
	for i := range a {
		different |= a[i] ^ b[i]
	}
	return different == 0
}

func toXpub(key string) (string, string, error) {
	raw, err := base58DecodeCheck(key)
	if err != nil {
		return "", "", err
	}
	if len(raw) != 78 {
		return "", "", errors.New("not an extended key")
	}
	version := hex.EncodeToString(raw[:4])
	mapping, ok := extendedVersions[version]
	if !ok {
		return "", "", fmt.Errorf("unrecognized extended-key version %s", version)
	}
	converted := append(append([]byte(nil), mapping.version...), raw[4:]...)
	return base58EncodeCheck(converted), mapping.wrapper, nil
}

func hasPrivateMaterial(key string) bool {
	for _, token := range base58Token.FindAllString(key, -1) {
		for _, prefix := range privatePrefixes {
			if strings.HasPrefix(token, prefix) {
				return true
			}
		}
		raw, err := base58DecodeCheck(token)
		if err != nil {
			continue
		}
		if len(raw) == 78 && (privateVersions[hex.EncodeToString(raw[:4])] || raw[45] == 0) {
			return true
		}
		if (len(raw) == 33 || len(raw) == 34 && raw[33] == 1) && (raw[0] == 0x80 || raw[0] == 0xef) {
			return true
		}
	}
	return false
}

func descriptorsFor(key string) ([]descriptor, error) {
	key = strings.TrimSpace(key)
	if hasPrivateMaterial(key) {
		return nil, errors.New("private key material is not allowed")
	}
	if strings.Contains(key, "(") {
		body := strings.TrimSpace(strings.SplitN(key, "#", 2)[0])
		if strings.Contains(body, "<0;1>") {
			return []descriptor{
				{Desc: strings.ReplaceAll(body, "<0;1>", "0")},
				{Desc: strings.ReplaceAll(body, "<0;1>", "1"), Internal: true},
			}, nil
		}
		return []descriptor{{Desc: body}}, nil
	}
	xpub, wrapper, err := toXpub(key)
	if err != nil {
		if addressPattern.MatchString(key) {
			return []descriptor{{Desc: "addr(" + key + ")"}}, nil
		}
		return nil, errors.New("not an xpub/ypub/zpub, an output descriptor, or an address")
	}
	return []descriptor{
		{Desc: strings.Replace(wrapper, "{}", xpub+"/0/*", 1)},
		{Desc: strings.Replace(wrapper, "{}", xpub+"/1/*", 1), Internal: true},
	}, nil
}

func walletName(name string) string {
	var safe []rune
	for _, char := range name {
		if len(safe) == 40 {
			break
		}
		if unicode.IsLetter(char) || unicode.IsNumber(char) || char == '-' || char == '_' {
			safe = append(safe, char)
		} else {
			safe = append(safe, '_')
		}
	}
	return "watch_" + string(safe)
}

func birthdayTimestamp(birthday string) int64 {
	if birthday == "" {
		return 0
	}
	parsed, err := time.Parse("2006-01-02", birthday)
	if err != nil {
		return 0
	}
	return parsed.Unix()
}

func formatBTC(btc float64) string {
	formatted := strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.8f", btc), "0"), ".")
	if formatted == "" || formatted == "-0" {
		return "0"
	}
	return formatted
}

func NewWatchStore(stateDir string) *WatchStore {
	if stateDir == "" {
		stateDir = "/state"
	}
	storePath := os.Getenv("WATCH_STORE")
	if storePath == "" {
		storePath = filepath.Join(stateDir, "wallets.json")
	}
	historyPath := os.Getenv("BALANCE_HISTORY")
	if historyPath == "" {
		historyPath = filepath.Join(stateDir, "balance_history.json")
	}
	secureParent(storePath)
	store := &WatchStore{path: storePath, history: newBalanceHistory(historyPath)}
	store.load()
	return store
}

func (s *WatchStore) load() {
	if err := chmodExistingFile(s.path, 0o600); err != nil && !os.IsNotExist(err) {
		s.entries = nil
		s.unsafeRoster = true
		return
	}
	b, err := os.ReadFile(s.path)
	if err == nil {
		var items []map[string]any
		if json.Unmarshal(b, &items) != nil {
			s.entries = []WatchEntry{}
			return
		}
		s.entries, s.unsafeRoster = normalizeEntries(items)
		return
	}
	if !os.IsNotExist(err) {
		s.entries = []WatchEntry{}
		return
	}
	s.entries = loadWatchConfig()
	s.saveLocked()
}

func loadWatchConfig() []WatchEntry {
	raw := os.Getenv("WATCH_WALLETS_B64")
	if raw == "" {
		return []WatchEntry{}
	}
	b, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return []WatchEntry{}
	}
	var items []map[string]any
	if json.Unmarshal(b, &items) != nil {
		return []WatchEntry{}
	}
	entries, _ := normalizeEntries(items)
	return entries
}

func normalizeEntries(items []map[string]any) ([]WatchEntry, bool) {
	entries := make([]WatchEntry, 0, len(items))
	privateFound := false
	for _, item := range items {
		name := strings.TrimSpace(stringValue(item["name"]))
		key := strings.TrimSpace(stringValue(item["key"]))
		if hasPrivateMaterial(key) {
			privateFound = true
			continue
		}
		if name != "" && key != "" {
			entries = append(entries, WatchEntry{Name: name, Key: key, Birthday: stringValue(item["birthday"])})
		}
	}
	return entries, privateFound
}

func stringValue(value any) string {
	if value == nil {
		return ""
	}
	if text, ok := value.(string); ok {
		return text
	}
	return fmt.Sprint(value)
}

func (s *WatchStore) saveLocked() {
	b, err := json.Marshal(s.entries)
	if err != nil {
		return
	}
	writePrivateFileAtomic(s.path, b)
}

func secureParent(path string) bool {
	dir := filepath.Dir(path)
	if dir == "." || dir == string(filepath.Separator) {
		return true
	}
	if os.MkdirAll(dir, 0o700) != nil {
		return false
	}
	return os.Chmod(dir, 0o700) == nil
}

func writePrivateFileAtomic(path string, data []byte) {
	if !secureParent(path) {
		return
	}
	tmp := path + ".tmp"
	file, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return
	}
	if file.Chmod(0o600) != nil {
		_ = file.Close()
		_ = os.Remove(tmp)
		return
	}
	if _, err = file.Write(data); err != nil {
		_ = file.Close()
		_ = os.Remove(tmp)
		return
	}
	if file.Close() != nil {
		_ = os.Remove(tmp)
		return
	}
	if os.Rename(tmp, path) != nil {
		_ = os.Remove(tmp)
		return
	}
	_ = os.Chmod(path, 0o600)
}

func (s *WatchStore) Entries() []WatchEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]WatchEntry(nil), s.entries...)
}

func (s *WatchStore) Add(name, key, birthday string) (WatchEntry, error) {
	name, key, birthday = strings.TrimSpace(name), strings.TrimSpace(key), strings.TrimSpace(birthday)
	if name == "" || key == "" {
		return WatchEntry{}, errors.New("Name and key are both required.")
	}
	if birthday != "" && birthdayTimestamp(birthday) == 0 {
		return WatchEntry{}, errors.New("Birthday must be a date like 2021-03-15.")
	}
	if _, err := descriptorsFor(key); err != nil {
		return WatchEntry{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.unsafeRoster {
		return WatchEntry{}, errors.New("wallet roster contains private key material; remove it manually before making changes")
	}
	if len(s.entries) >= maxWatchWallets {
		return WatchEntry{}, fmt.Errorf("At most %d wallets.", maxWatchWallets)
	}
	for _, entry := range s.entries {
		if strings.EqualFold(entry.Name, name) {
			return WatchEntry{}, errors.New("A wallet with that name already exists.")
		}
	}
	entry := WatchEntry{Name: name, Key: key, Birthday: birthday}
	s.entries = append(s.entries, entry)
	s.saveLocked()
	return entry, nil
}

func (s *WatchStore) Remove(name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.unsafeRoster {
		return false
	}
	for index, entry := range s.entries {
		if entry.Name == name {
			s.entries = append(s.entries[:index], s.entries[index+1:]...)
			s.saveLocked()
			return true
		}
	}
	return false
}

func (s *WatchStore) List(walletRPC WalletRPCFunc) map[string]any {
	entries := s.Entries()
	rows, total := walletBalances(walletRPC, entries, nil)
	for _, row := range rows {
		history := s.history.series(row["key"].(string))
		row["history"] = history
		if row["state"] == "error" && len(history) > 0 {
			row["state"] = "stale"
			row["btc"] = formatBTC(history[len(history)-1])
		}
	}
	return map[string]any{"wallets": rows, "total": formatBTC(total), "show_total": len(rows) > 1}
}

func (s *WatchStore) Sample(walletRPC WalletRPCFunc) {
	entries := s.Entries()
	walletBalances(walletRPC, entries, func(key string, btc float64) {
		s.history.record(key, btc, time.Now())
	})
}

func walletBalances(walletRPC WalletRPCFunc, entries []WatchEntry, sample func(string, float64)) ([]map[string]any, float64) {
	rows := make([]map[string]any, 0, len(entries))
	total := 0.0
	for _, entry := range entries {
		info := mapValue(walletRPC(walletName(entry.Name), "getwalletinfo", []any{}, 8*time.Second))
		row := map[string]any{"name": entry.Name, "key": entry.Key, "btc": nil}
		if info == nil {
			row["state"] = "error"
		} else if truthy(info["scanning"]) {
			row["state"] = "scanning"
		} else {
			balances := mapValue(walletRPC(walletName(entry.Name), "getbalances", []any{}, 8*time.Second))
			mine := mapValue(valueFrom(balances, "mine"))
			btc := numberValue(valueFrom(mine, "trusted"))
			total += btc
			row["state"] = "ok"
			row["btc"] = formatBTC(btc)
			if sample != nil {
				sample(entry.Key, btc)
			}
		}
		rows = append(rows, row)
	}
	return rows, total
}

func ProvisionOne(rpc RPCFunc, walletRPC WalletRPCFunc, entry WatchEntry, pruned bool) {
	name := walletName(entry.Name)
	if walletRPC(name, "getwalletinfo", []any{}, 8*time.Second) != nil {
		return
	}
	if rpc("loadwallet", []any{name}) != nil {
		return
	}
	descriptors, err := descriptorsFor(entry.Key)
	if err != nil || pruned {
		return
	}
	if rpc("createwallet", []any{name, true, true, "", false, true, true}) == nil {
		return
	}
	requests := make([]any, 0, len(descriptors))
	for _, item := range descriptors {
		info := mapValue(rpc("getdescriptorinfo", []any{item.Desc}))
		if len(info) == 0 {
			continue
		}
		request := map[string]any{
			"desc": info["descriptor"], "timestamp": birthdayTimestamp(entry.Birthday),
			"active": false, "internal": item.Internal,
		}
		if truthy(info["isrange"]) {
			request["range"] = 1000
		}
		requests = append(requests, request)
	}
	if len(requests) > 0 {
		walletRPC(name, "importdescriptors", []any{requests}, time.Hour)
	}
}

func EnsureWallets(rpc RPCFunc, walletRPC WalletRPCFunc, entries []WatchEntry, pruned bool) {
	for _, entry := range entries {
		ProvisionOne(rpc, walletRPC, entry, pruned)
	}
}

func Deprovision(rpc RPCFunc, name string) {
	rpc("unloadwallet", []any{walletName(name), false})
}

func mapValue(value any) map[string]any {
	result, _ := value.(map[string]any)
	return result
}

func valueFrom(values map[string]any, key string) any {
	if values == nil {
		return nil
	}
	return values[key]
}

func numberValue(value any) float64 {
	switch number := value.(type) {
	case float64:
		return number
	case float32:
		return float64(number)
	case int:
		return float64(number)
	case int64:
		return float64(number)
	case json.Number:
		result, _ := number.Float64()
		return result
	default:
		return 0
	}
}

func truthy(value any) bool {
	switch typed := value.(type) {
	case nil:
		return false
	case bool:
		return typed
	case string:
		return typed != ""
	case float64:
		return typed != 0
	case int:
		return typed != 0
	case map[string]any:
		return len(typed) > 0
	case []any:
		return len(typed) > 0
	default:
		return true
	}
}
