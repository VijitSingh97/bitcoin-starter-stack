package main

import (
	"encoding/json"
	"math"
	"time"
)

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
