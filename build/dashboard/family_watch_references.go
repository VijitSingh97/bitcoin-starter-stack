package main

func familyWatchReferences(id string) []familyWatchWalletView {
	var label, address, source string
	switch id {
	case nodeDogecoin:
		label = "Dogecoin Foundation"
		address = "D89DhnsgKncmN12RejxudfU8AwXp3946q1"
		source = "https://foundation.dogecoin.com/about/"
	case nodeZcash:
		label = "Tor Project"
		address = "t1NnsSG46uPPPMr3D3MdBCKrMpr9XXis8sz"
		source = "https://donate.torproject.org/cryptocurrency/"
	default:
		return []familyWatchWalletView{}
	}
	return []familyWatchWalletView{{
		ID: familyWatchID(address), Label: label, Address: address,
		SourceURL: source, Example: true, State: "unavailable", History: []familyWatchHistory{},
	}}
}
