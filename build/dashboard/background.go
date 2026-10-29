package main

import (
	"context"
	"math"
	"time"
)

func (a *app) recordFee(value float64) {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return
	}
	a.feesMu.Lock()
	defer a.feesMu.Unlock()
	a.fees = append(a.fees, value)
	if len(a.fees) > maxFees {
		a.fees = append([]float64{}, a.fees[len(a.fees)-maxFees:]...)
	}
}

func (a *app) startBackground(ctx context.Context) {
	a.ctx = ctx
	entries := a.watch.Entries()
	for _, entry := range entries {
		a.watch.SetPending(entry.Key, true)
	}
	chain := func() map[string]any {
		result, _ := a.nodeRPC("getblockchaininfo", nil).(map[string]any)
		return result
	}
	network := func() map[string]any { result, _ := a.nodeRPC("getnetworkinfo", nil).(map[string]any); return result }
	go a.prices.Run(ctx)
	go a.monitor.Run(ctx, chain, network)
	go a.every(ctx, time.Minute, func(ctx context.Context) {
		var info blockchainInfo
		if a.rpc.call(ctx, "getblockchaininfo", nil, &info) != nil || info.InitialBlockDownload {
			return
		}
		var estimate feeEstimate
		if a.rpc.call(ctx, "estimatesmartfee", []any{1}, &estimate) == nil && estimate.FeeRate != nil {
			a.recordFee(math.RoundToEven(*estimate.FeeRate*1000000) / 10)
		}
	})
	go a.every(ctx, 10*time.Minute, func(context.Context) {
		info := chain()
		if info != nil && info["initialblockdownload"] != true {
			a.watch.Sample(a.walletRPC)
		}
	})
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for {
			if info := chain(); info != nil {
				for _, entry := range a.watch.Entries() {
					a.watch.SetPending(entry.Key, true)
					a.provision(entry, info["pruned"] == true)
				}
				return
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
}

func (a *app) provision(entry WatchEntry, pruned bool) {
	if !a.watch.Contains(entry) {
		return
	}
	defer a.watch.ClearPendingIfCurrent(entry)
	name, ok := ProvisionOne(a.nodeRPC, a.walletRPC, entry, pruned)
	if !ok {
		return
	}
	if !a.watch.SetCoreWalletIfCurrent(entry, name) {
		a.watch.DeprovisionNameIfUnused(a.nodeRPC, a.walletRPC, entry, name)
	}
}

func (a *app) every(ctx context.Context, interval time.Duration, fn func(context.Context)) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return
		}
		fn(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
