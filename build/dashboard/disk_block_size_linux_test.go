//go:build linux

package main

import (
	"syscall"
	"testing"
)

func TestStatfsBlockSizeUsesFragmentSize(t *testing.T) {
	stat := syscall.Statfs_t{Bsize: 1 << 20, Frsize: 4096}
	if got := statfsBlockSize(&stat); got != 4096 {
		t.Fatalf("block size = %d", got)
	}
	stat.Frsize = 0
	if got := statfsBlockSize(&stat); got != 1<<20 {
		t.Fatalf("fallback block size = %d", got)
	}
}
