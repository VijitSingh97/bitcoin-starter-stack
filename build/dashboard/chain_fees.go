package main

import "net/http"

func (a *app) recordAdditionalFee(id string, value float64) {
	a.additionalFeesMu.Lock()
	defer a.additionalFeesMu.Unlock()
	fees := append(a.additionalFees[id], value)
	if len(fees) > maxFees {
		fees = append([]float64{}, fees[len(fees)-maxFees:]...)
	}
	a.additionalFees[id] = fees
}

func (a *app) apiAdditionalFees(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("node")
	if _, ok := a.additionalNode(id); !ok {
		http.NotFound(w, r)
		return
	}
	a.additionalFeesMu.RLock()
	fees := append([]float64{}, a.additionalFees[id]...)
	a.additionalFeesMu.RUnlock()
	writeJSON(w, map[string]any{"fee": fees})
}
