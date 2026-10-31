package main

import "testing"

func TestPublicReferencesDoNotClaimQueryableBalances(t *testing.T) {
	for _, id := range []string{nodeDogecoin, nodeZcash} {
		wallets := familyWatchReferences(id)
		if len(wallets) != 1 || !wallets[0].Example || wallets[0].Amount != nil || wallets[0].State != "unavailable" || wallets[0].SourceURL == "" || len(wallets[0].History) != 0 {
			t.Fatalf("%s reference must identify a public address without claiming a balance: %#v", id, wallets)
		}
		if supported, _ := familyWatchCapability(id); supported {
			t.Fatalf("%s must not offer address mutations through the reference card", id)
		}
	}
	if len(familyWatchReferences(nodeTari)) != 0 {
		t.Fatal("Tari has no verified public view-key example")
	}
}
