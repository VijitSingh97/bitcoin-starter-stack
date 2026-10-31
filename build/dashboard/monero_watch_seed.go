package main

import (
	"context"
	"errors"
)

const (
	moneroPublicExampleName      = "Monero General Fund"
	moneroPublicExampleAddress   = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
	moneroPublicExampleViewKey   = "f359631075708155cc3d92a32b75a7d02a5dcf27756707b47a2b31b21c389501"
	moneroPublicExampleSourceURL = "https://www.getmonero.org/get-started/contributing/"
)

var errMoneroPublicExampleSuperseded = errors.New("Monero public example was superseded")

func (s *MoneroWatchStore) ensurePublicExample(ctx context.Context) {
	s.mu.RLock()
	pending := s.publicExamplePending
	s.mu.RUnlock()
	if !pending {
		return
	}
	_, _ = s.add(ctx, moneroPublicExampleName, moneroPublicExampleAddress, moneroPublicExampleViewKey, 0, true, moneroPublicExampleSourceURL)
}

func (s *MoneroWatchStore) PublicList() ([]MoneroWatchWallet, bool) {
	wallets := s.List()
	for _, wallet := range wallets {
		if !wallet.Example {
			return nil, false
		}
	}
	return wallets, true
}

func validMoneroPublicExample(wallet MoneroWatchWallet) bool {
	return wallet.Name == moneroPublicExampleName && wallet.Address == moneroPublicExampleAddress && wallet.SourceURL == moneroPublicExampleSourceURL && wallet.RestoreHeight == 0
}
