package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestBalanceHistoryHourlyCapAndReload(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "balance_history.json")
	if err := os.WriteFile(path, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	history := newBalanceHistory(path)
	history.maxPoints = 3
	for _, sample := range []struct {
		at  int64
		btc float64
	}{{0, 1}, {1000, 9}, {3600, 2}, {7200, 3}, {10800, 4}} {
		history.record(" xpub-AAA ", sample.btc, time.Unix(sample.at, 0))
	}
	if got := history.series("xpub-AAA"); !reflect.DeepEqual(got, []float64{2, 3, 4}) {
		t.Fatalf("series = %v", got)
	}
	reloaded := newBalanceHistory(path)
	if got := reloaded.series("xpub-AAA"); !reflect.DeepEqual(got, []float64{2, 3, 4}) {
		t.Fatalf("reloaded series = %v", got)
	}
	if keyID(" xpub-AAA ") != "c10385f90e2190f9" {
		t.Fatalf("key id = %s", keyID(" xpub-AAA "))
	}
	assertMode(t, dir, 0o700)
	assertMode(t, path, 0o600)
}

func TestBalanceHistoryDeclinesLoadWhenExistingFileCannotBeSecured(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "balance_history.json")
	key := "xpub-AAA"
	data := []byte(`{"` + keyID(key) + `":[[0,1.5]]}`)
	if err := os.WriteFile(path, data, 0o644); err != nil {
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
	history := newBalanceHistory(path)
	if got := history.series(key); len(got) != 0 {
		t.Fatalf("history loaded after chmod failure: %v", got)
	}
}
