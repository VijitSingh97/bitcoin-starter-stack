package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"sync"
	"time"
)

const (
	coinGeckoPriceURL     = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd,eur,gbp,inr,cad,aud,jpy,rub,cny&include_last_updated_at=true"
	priceRefreshEvery     = 5 * time.Minute
	priceStaleAfter       = 15 * time.Minute
	maxPriceResponseBytes = 64 << 10
)

var priceCurrencies = []string{"usd", "eur", "gbp", "inr", "cad", "aud", "jpy", "rub", "cny"}

type PriceCache struct {
	client       *http.Client
	url          string
	now          func() time.Time
	refreshEvery time.Duration

	mu              sync.RWMutex
	prices          map[string]float64
	updatedAt       int64
	lastFetchFailed bool
}

func NewPriceCache() *PriceCache {
	return &PriceCache{
		client:          newTorHTTPClient(torProxy),
		url:             coinGeckoPriceURL,
		now:             time.Now,
		refreshEvery:    priceRefreshEvery,
		prices:          make(map[string]float64),
		lastFetchFailed: true,
	}
}

func (c *PriceCache) Run(ctx context.Context) {
	_ = c.refresh(ctx)
	if ctx.Err() != nil {
		return
	}
	ticker := time.NewTicker(c.refreshEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_ = c.refresh(ctx)
		}
	}
}

func (c *PriceCache) Snapshot() map[string]any {
	c.mu.RLock()
	prices := make(map[string]float64, len(c.prices))
	for currency, price := range c.prices {
		prices[currency] = price
	}
	updatedAt := c.updatedAt
	failed := c.lastFetchFailed
	c.mu.RUnlock()

	available := len(prices) != 0
	stale := failed || !available || c.now().Sub(time.Unix(updatedAt, 0)) > priceStaleAfter
	return map[string]any{
		"prices":     prices,
		"updated_at": updatedAt,
		"stale":      stale,
		"available":  available,
	}
}

func (c *PriceCache) refresh(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url, nil)
	if err != nil {
		return c.fail(errors.New("price provider request failed"))
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return c.fail(errors.New("price provider request failed"))
	}
	if resp.Body == nil {
		return c.fail(errors.New("price provider response failed"))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return c.fail(errors.New("price provider response failed"))
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxPriceResponseBytes+1))
	if err != nil || len(body) > maxPriceResponseBytes {
		return c.fail(errors.New("price provider response failed"))
	}

	var payload struct {
		Bitcoin map[string]json.Number `json:"bitcoin"`
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&payload); err != nil {
		return c.fail(errors.New("price provider response invalid"))
	}
	if err := ensureJSONEnd(decoder); err != nil {
		return c.fail(errors.New("price provider response invalid"))
	}

	updatedAt, err := payload.Bitcoin["last_updated_at"].Int64()
	now := c.now()
	if err != nil || updatedAt <= 0 || time.Unix(updatedAt, 0).After(now.Add(priceRefreshEvery)) {
		return c.fail(errors.New("price provider response invalid"))
	}
	prices := make(map[string]float64, len(priceCurrencies))
	for _, currency := range priceCurrencies {
		price, err := payload.Bitcoin[currency].Float64()
		if err != nil || math.IsNaN(price) || math.IsInf(price, 0) || price <= 0 {
			return c.fail(errors.New("price provider response invalid"))
		}
		prices[currency] = price
	}

	c.mu.Lock()
	c.prices = prices
	c.updatedAt = updatedAt
	c.lastFetchFailed = false
	c.mu.Unlock()
	return nil
}

func (c *PriceCache) fail(err error) error {
	c.mu.Lock()
	c.lastFetchFailed = true
	c.mu.Unlock()
	return err
}

func ensureJSONEnd(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("trailing JSON")
		}
		return err
	}
	return nil
}
