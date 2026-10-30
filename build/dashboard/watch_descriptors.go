package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"time"
	"unicode"
)

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
	extendedVersions = map[string]struct {
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

type descriptor struct {
	Desc     string `json:"desc"`
	Internal bool   `json:"internal"`
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
