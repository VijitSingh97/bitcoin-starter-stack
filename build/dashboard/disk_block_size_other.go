//go:build !linux

package main

import "syscall"

func statfsBlockSize(stat *syscall.Statfs_t) uint64 {
	return uint64(stat.Bsize)
}
