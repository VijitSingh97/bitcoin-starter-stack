package main

import "time"

type RPCFunc func(string, []any) any

type WalletRPCFunc func(string, string, []any, time.Duration) any
