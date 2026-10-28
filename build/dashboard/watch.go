package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
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

const genesisAddress = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
const publicExampleName = "Binance (public)"
const publicExampleAddress = "34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo"

var ErrWatchUnavailable = errors.New("watch wallet storage unavailable")

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
	writeWatchFile    = writePrivateFileAtomic
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
	pending      map[string]bool
	coreNames    map[string]string
	unsafeRoster bool
	storeErr     error
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
		s.storeErr = ErrWatchUnavailable
		return
	}
	b, err := os.ReadFile(s.path)
	if err == nil {
		var items []map[string]any
		if json.Unmarshal(b, &items) != nil || items == nil {
			s.entries = nil
			s.storeErr = ErrWatchUnavailable
			return
		}
		s.entries, s.unsafeRoster = normalizeEntries(items)
		return
	}
	if !os.IsNotExist(err) {
		s.entries = nil
		s.storeErr = ErrWatchUnavailable
		return
	}
	entries, err := loadWatchConfig()
	if err != nil {
		s.entries = nil
		s.storeErr = ErrWatchUnavailable
		return
	}
	s.entries = entries
	if s.saveLocked() != nil {
		s.storeErr = ErrWatchUnavailable
	}
}

func loadWatchConfig() ([]WatchEntry, error) {
	raw := os.Getenv("WATCH_WALLETS_B64")
	if raw == "" {
		return []WatchEntry{}, nil
	}
	b, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, ErrWatchUnavailable
	}
	var items []map[string]any
	if json.Unmarshal(b, &items) != nil || items == nil {
		return nil, ErrWatchUnavailable
	}
	entries, _ := normalizeEntries(items)
	return entries, nil
}

func isPublicExample(entry WatchEntry) bool {
	return entry.Name == publicExampleName && entry.Key == publicExampleAddress && entry.Birthday == ""
}

func normalizeEntries(items []map[string]any) ([]WatchEntry, bool) {
	entries := make([]WatchEntry, 0, len(items))
	privateFound := false
	seenKeys := map[string]bool{}
	for _, item := range items {
		name := strings.TrimSpace(stringValue(item["name"]))
		key := strings.TrimSpace(stringValue(item["key"]))
		if hasPrivateMaterial(key) {
			privateFound = true
			continue
		}
		identity := watchKeyID(key)
		if name != "" && key != "" && !seenKeys[identity] {
			entries = append(entries, WatchEntry{Name: name, Key: key, Birthday: stringValue(item["birthday"])})
			seenKeys[identity] = true
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

func (s *WatchStore) saveLocked() error {
	b, err := json.Marshal(s.entries)
	if err != nil {
		return ErrWatchUnavailable
	}
	if writeWatchFile(s.path, b) != nil {
		return ErrWatchUnavailable
	}
	return nil
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

func writePrivateFileAtomic(path string, data []byte) error {
	if !secureParent(path) {
		return ErrWatchUnavailable
	}
	tmp := path + ".tmp"
	file, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return ErrWatchUnavailable
	}
	if file.Chmod(0o600) != nil {
		_ = file.Close()
		_ = os.Remove(tmp)
		return ErrWatchUnavailable
	}
	if _, err = file.Write(data); err != nil {
		_ = file.Close()
		_ = os.Remove(tmp)
		return ErrWatchUnavailable
	}
	if file.Close() != nil {
		_ = os.Remove(tmp)
		return ErrWatchUnavailable
	}
	if os.Rename(tmp, path) != nil {
		_ = os.Remove(tmp)
		return ErrWatchUnavailable
	}
	return nil
}

func (s *WatchStore) Err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.storeErr
}

func (s *WatchStore) Entries() []WatchEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]WatchEntry(nil), s.entries...)
}

func (s *WatchStore) Contains(entry WatchEntry) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, current := range s.entries {
		if current == entry {
			return true
		}
	}
	return false
}

func (s *WatchStore) UsesKey(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	identity := watchKeyID(key)
	for _, current := range s.entries {
		if watchKeyID(current.Key) == identity {
			return true
		}
	}
	return false
}

func watchKeyID(key string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(key)))
	return hex.EncodeToString(sum[:])
}

func coreWalletName(entry WatchEntry) string {
	return "watch_" + watchKeyID(entry.Key)
}

func (s *WatchStore) SetPending(key string, pending bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	identity := watchKeyID(key)
	if pending {
		if s.pending == nil {
			s.pending = map[string]bool{}
		}
		s.pending[identity] = true
		return
	}
	delete(s.pending, identity)
}

func (s *WatchStore) ClearPendingIfCurrent(entry WatchEntry) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, current := range s.entries {
		if current == entry {
			delete(s.pending, watchKeyID(entry.Key))
			return true
		}
	}
	return false
}

func (s *WatchStore) SetCoreWallet(key, name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	identity := watchKeyID(key)
	if name == "" {
		delete(s.coreNames, identity)
		return
	}
	if s.coreNames == nil {
		s.coreNames = map[string]string{}
	}
	s.coreNames[identity] = name
}

func (s *WatchStore) SetCoreWalletIfCurrent(entry WatchEntry, name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	current := false
	for _, item := range s.entries {
		if item == entry {
			current = true
			break
		}
	}
	if !current {
		return false
	}
	if s.coreNames == nil {
		s.coreNames = map[string]string{}
	}
	s.coreNames[watchKeyID(entry.Key)] = name
	return true
}

func (s *WatchStore) snapshot() ([]WatchEntry, map[string]bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries := append([]WatchEntry(nil), s.entries...)
	pending := make(map[string]bool, len(s.pending))
	for identity := range s.pending {
		pending[identity] = true
	}
	return entries, pending
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
	if s.storeErr != nil {
		return WatchEntry{}, ErrWatchUnavailable
	}
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
		if watchKeyID(entry.Key) == watchKeyID(key) {
			return WatchEntry{}, errors.New("That watch key is already configured.")
		}
		if walletName(entry.Name) == walletName(name) {
			return WatchEntry{}, errors.New("That wallet name conflicts with an existing wallet.")
		}
	}
	entry := WatchEntry{Name: name, Key: key, Birthday: birthday}
	previous := s.entries
	s.entries = append(s.entries, entry)
	if s.saveLocked() != nil {
		s.entries = previous
		s.storeErr = ErrWatchUnavailable
		return WatchEntry{}, ErrWatchUnavailable
	}
	return entry, nil
}

func (s *WatchStore) Remove(name string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.storeErr != nil {
		return false, ErrWatchUnavailable
	}
	if s.unsafeRoster {
		return false, ErrWatchUnavailable
	}
	for index, entry := range s.entries {
		if entry.Name == name {
			return s.removeIndexLocked(index, entry)
		}
	}
	return false, nil
}

func (s *WatchStore) RemoveExact(entry WatchEntry) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.storeErr != nil {
		return false, ErrWatchUnavailable
	}
	if s.unsafeRoster {
		return false, ErrWatchUnavailable
	}
	for index, current := range s.entries {
		if current == entry {
			return s.removeIndexLocked(index, current)
		}
	}
	return false, nil
}

func (s *WatchStore) removeIndexLocked(index int, entry WatchEntry) (bool, error) {
	previous := s.entries
	next := make([]WatchEntry, 0, len(s.entries)-1)
	next = append(next, s.entries[:index]...)
	next = append(next, s.entries[index+1:]...)
	s.entries = next
	if s.saveLocked() != nil {
		s.entries = previous
		s.storeErr = ErrWatchUnavailable
		return false, ErrWatchUnavailable
	}
	identity := watchKeyID(entry.Key)
	delete(s.pending, identity)
	delete(s.coreNames, identity)
	return true, nil
}

func (s *WatchStore) List(walletRPC WalletRPCFunc, initialBlockDownload bool) map[string]any {
	entries, pending := s.snapshot()
	rows, total := s.walletBalances(walletRPC, entries, pending, initialBlockDownload, nil)
	totalState := "ok"
	personalCount := 0
	for _, row := range rows {
		history := s.history.series(row["key"].(string))
		row["history"] = history
		if row["state"] == "error" && len(history) > 0 {
			row["state"] = "stale"
			row["btc"] = formatBTC(history[len(history)-1])
		}
		if row["example"] == true {
			continue
		}
		personalCount++
		if row["state"] == "pending" || row["state"] == "scanning" {
			totalState = "pending"
		} else if totalState == "ok" && (row["state"] == "error" || row["state"] == "stale") {
			totalState = "unavailable"
		}
	}
	return map[string]any{"wallets": rows, "total": formatBTC(total), "total_state": totalState, "show_total": personalCount > 1}
}

func (s *WatchStore) Sample(walletRPC WalletRPCFunc) {
	entries, pending := s.snapshot()
	s.walletBalances(walletRPC, entries, pending, false, func(key string, btc float64) {
		s.history.record(key, btc, time.Now())
	})
}

func (s *WatchStore) resolveWallet(walletRPC WalletRPCFunc, entry WatchEntry) (string, map[string]any) {
	identity := watchKeyID(entry.Key)
	s.mu.Lock()
	name := s.coreNames[identity]
	s.mu.Unlock()
	if name != "" {
		if info := mapValue(walletRPC(name, "getwalletinfo", []any{}, 8*time.Second)); safeWatchWallet(info) {
			return name, info
		}
		s.SetCoreWallet(entry.Key, "")
	}
	name, info := resolveWallet(walletRPC, entry)
	if name != "" {
		s.SetCoreWallet(entry.Key, name)
	}
	return name, info
}

func (s *WatchStore) walletBalances(walletRPC WalletRPCFunc, entries []WatchEntry, pending map[string]bool, initialBlockDownload bool, sample func(string, float64)) ([]map[string]any, float64) {
	rows := make([]map[string]any, 0, len(entries))
	total := 0.0
	for _, entry := range entries {
		name, info := s.resolveWallet(walletRPC, entry)
		example := isPublicExample(entry)
		row := map[string]any{"name": entry.Name, "key": entry.Key, "btc": nil}
		if example {
			row["example"] = true
			row["display_name"] = "Binance"
		}
		isPending := pending[watchKeyID(entry.Key)] || initialBlockDownload
		if entry.Name == "Satoshi" && entry.Key == genesisAddress {
			row["display_name"] = "Genesis"
		}
		if info == nil {
			if isPending {
				row["state"] = "pending"
			} else {
				row["state"] = "error"
			}
		} else if truthy(info["scanning"]) {
			row["state"] = "scanning"
		} else if isPending {
			row["state"] = "pending"
		} else {
			balances := mapValue(walletRPC(name, "getbalances", []any{}, 8*time.Second))
			mine := mapValue(valueFrom(balances, "mine"))
			trusted, ok := mine["trusted"]
			if balances == nil || mine == nil || !ok {
				row["state"] = "error"
				rows = append(rows, row)
				continue
			}
			btc, valid := balanceValue(trusted)
			if !valid {
				row["state"] = "error"
				rows = append(rows, row)
				continue
			}
			if !example {
				total += btc
			}
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

func descriptorIdentity(item descriptor) string {
	return strings.SplitN(item.Desc, "#", 2)[0]
}

func descriptorTimestamp(value any) (int64, bool) {
	switch timestamp := value.(type) {
	case float64:
		return int64(timestamp), true
	case int:
		return int64(timestamp), true
	case int64:
		return timestamp, true
	case json.Number:
		result, err := timestamp.Int64()
		return result, err == nil
	default:
		return 0, false
	}
}

func descriptorRangeCovers(value any) bool {
	values, ok := value.([]any)
	if !ok || len(values) != 2 {
		return false
	}
	start, startOK := balanceValue(values[0])
	end, endOK := balanceValue(values[1])
	return startOK && endOK && start <= 0 && end >= 999
}

func walletMatches(walletRPC WalletRPCFunc, name string, entry WatchEntry) bool {
	descriptors, err := descriptorsFor(entry.Key)
	if err != nil {
		return false
	}
	type expectation struct {
		internal bool
		ranged   bool
	}
	want := make(map[string]expectation, len(descriptors))
	for _, item := range descriptors {
		info := mapValue(walletRPC(name, "getdescriptorinfo", []any{item.Desc}, 8*time.Second))
		canonical := stringValue(info["descriptor"])
		hasPrivateKeys, public := info["hasprivatekeys"].(bool)
		if canonical == "" || !public || hasPrivateKeys {
			return false
		}
		want[descriptorIdentity(descriptor{Desc: canonical})] = expectation{item.Internal, strings.Contains(canonical, "/*")}
	}
	listed := mapValue(walletRPC(name, "listdescriptors", []any{false}, 8*time.Second))
	values, ok := listed["descriptors"].([]any)
	if !ok || len(values) != len(want) {
		return false
	}
	seen := make(map[string]bool, len(values))
	requested := birthdayTimestamp(entry.Birthday)
	for _, value := range values {
		item := mapValue(value)
		identity := descriptorIdentity(descriptor{Desc: stringValue(item["desc"])})
		expectedDescriptor, expected := want[identity]
		if !expected || seen[identity] {
			return false
		}
		if internal, present := item["internal"]; present {
			role, valid := internal.(bool)
			if !valid || role != expectedDescriptor.internal {
				return false
			}
		}
		if expectedDescriptor.ranged && !descriptorRangeCovers(item["range"]) {
			return false
		}
		timestamp, present := item["timestamp"]
		if !present {
			return false
		}
		existing, valid := descriptorTimestamp(timestamp)
		if !valid {
			return false
		}
		if existing > requested && !(requested == 0 && existing <= 1) {
			return false
		}
		seen[identity] = true
	}
	return len(seen) == len(want)
}

func resolveWallet(walletRPC WalletRPCFunc, entry WatchEntry) (string, map[string]any) {
	for _, name := range []string{walletName(entry.Name), coreWalletName(entry)} {
		info := mapValue(walletRPC(name, "getwalletinfo", []any{}, 8*time.Second))
		if safeWatchWallet(info) && walletMatches(walletRPC, name, entry) {
			return name, info
		}
	}
	return "", nil
}

func safeWatchWallet(info map[string]any) bool {
	descriptors, descriptorsOK := info["descriptors"].(bool)
	privateKeys, privateKeysOK := info["private_keys_enabled"].(bool)
	return descriptorsOK && descriptors && privateKeysOK && !privateKeys
}

func probeCandidate(rpc RPCFunc, walletRPC WalletRPCFunc, name string) (bool, bool, bool) {
	if info := mapValue(walletRPC(name, "getwalletinfo", []any{}, 8*time.Second)); info != nil {
		return true, false, safeWatchWallet(info)
	}
	if rpc("loadwallet", []any{name}) == nil {
		return false, false, false
	}
	info := mapValue(walletRPC(name, "getwalletinfo", []any{}, 8*time.Second))
	return true, true, safeWatchWallet(info)
}

func importRequests(rpc RPCFunc, entry WatchEntry) ([]any, bool) {
	descriptors, err := descriptorsFor(entry.Key)
	if err != nil {
		return nil, false
	}
	requests := make([]any, 0, len(descriptors))
	for _, item := range descriptors {
		info := mapValue(rpc("getdescriptorinfo", []any{item.Desc}))
		hasPrivateKeys, public := info["hasprivatekeys"].(bool)
		if len(info) == 0 || !public || hasPrivateKeys || stringValue(info["descriptor"]) == "" {
			return nil, false
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
	return requests, len(requests) == len(descriptors)
}

func retryImportRequests(walletRPC WalletRPCFunc, name string, requests []any) ([]any, bool) {
	want := make(map[string]map[string]any, len(requests))
	for _, value := range requests {
		request := mapValue(value)
		identity := descriptorIdentity(descriptor{Desc: stringValue(request["desc"])})
		if identity == "" || want[identity] != nil {
			return nil, false
		}
		want[identity] = request
	}
	listed := mapValue(walletRPC(name, "listdescriptors", []any{false}, 8*time.Second))
	values, ok := listed["descriptors"].([]any)
	if !ok || len(values) > len(want) {
		return nil, false
	}
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		item := mapValue(value)
		identity := descriptorIdentity(descriptor{Desc: stringValue(item["desc"])})
		request := want[identity]
		if request == nil || seen[identity] {
			return nil, false
		}
		expectedInternal, expectedInternalOK := request["internal"].(bool)
		if !expectedInternalOK {
			return nil, false
		}
		if internal, present := item["internal"]; present {
			role, valid := internal.(bool)
			if !valid || role != expectedInternal {
				return nil, false
			}
		}
		_, ranged := request["range"]
		if ranged && !descriptorRangeCovers(item["range"]) {
			return nil, false
		}
		existing, valid := descriptorTimestamp(item["timestamp"])
		requested, requestedOK := descriptorTimestamp(request["timestamp"])
		if !valid || !requestedOK || existing > requested && !(requested == 0 && existing <= 1) {
			return nil, false
		}
		seen[identity] = true
	}
	missing := make([]any, 0, len(requests)-len(seen))
	for _, value := range requests {
		identity := descriptorIdentity(descriptor{Desc: stringValue(mapValue(value)["desc"])})
		if !seen[identity] {
			missing = append(missing, value)
		}
	}
	return missing, true
}

func importDescriptors(walletRPC WalletRPCFunc, name string, requests []any) bool {
	results, ok := walletRPC(name, "importdescriptors", []any{requests}, time.Hour).([]any)
	if !ok || len(results) != len(requests) {
		return false
	}
	for _, result := range results {
		if !truthy(valueFrom(mapValue(result), "success")) {
			return false
		}
	}
	return true
}

func ProvisionOne(rpc RPCFunc, walletRPC WalletRPCFunc, entry WatchEntry, pruned bool) (string, bool) {
	legacy := walletName(entry.Name)
	legacyExists, legacyLoaded, legacySafe := probeCandidate(rpc, walletRPC, legacy)
	if legacyExists {
		if legacySafe && walletMatches(walletRPC, legacy, entry) {
			return legacy, true
		}
		if legacyLoaded {
			rpc("unloadwallet", []any{legacy, false})
		}
	}
	name := coreWalletName(entry)
	hashExists, hashLoaded, hashSafe := probeCandidate(rpc, walletRPC, name)
	if hashExists && hashSafe && walletMatches(walletRPC, name, entry) {
		return name, true
	}
	if pruned {
		if hashLoaded {
			rpc("unloadwallet", []any{name, false})
		}
		return "", false
	}
	requests, valid := importRequests(rpc, entry)
	if !valid {
		if hashLoaded {
			rpc("unloadwallet", []any{name, false})
		}
		return "", false
	}
	if hashExists {
		missing, compatible := retryImportRequests(walletRPC, name, requests)
		if hashSafe && compatible && len(missing) > 0 && importDescriptors(walletRPC, name, missing) {
			return name, true
		}
		if hashLoaded {
			rpc("unloadwallet", []any{name, false})
		}
		return "", false
	}
	if rpc("createwallet", []any{name, true, true, "", false, true, true}) == nil {
		return "", false
	}
	if !importDescriptors(walletRPC, name, requests) {
		return "", false
	}
	return name, true
}

func (s *WatchStore) DeprovisionNameIfUnused(rpc RPCFunc, walletRPC WalletRPCFunc, entry WatchEntry, name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	identity := watchKeyID(entry.Key)
	for _, current := range s.entries {
		if watchKeyID(current.Key) == identity {
			return
		}
	}
	if name != walletName(entry.Name) && name != coreWalletName(entry) {
		return
	}
	info := mapValue(walletRPC(name, "getwalletinfo", []any{}, 8*time.Second))
	if safeWatchWallet(info) && walletMatches(walletRPC, name, entry) {
		rpc("unloadwallet", []any{name, false})
	}
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

func balanceValue(value any) (float64, bool) {
	var btc float64
	switch amount := value.(type) {
	case float64:
		btc = amount
	case float32:
		btc = float64(amount)
	case int:
		btc = float64(amount)
	case int64:
		btc = float64(amount)
	case json.Number:
		var err error
		btc, err = amount.Float64()
		if err != nil {
			return 0, false
		}
	default:
		return 0, false
	}
	return btc, !math.IsNaN(btc) && !math.IsInf(btc, 0) && btc >= 0
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
