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
	coinGeckoPriceURL     = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,monero&vs_currencies=usd,eur,gbp,inr,cad,aud,jpy,rub,cny&include_last_updated_at=true"
	priceUserAgent        = "bitcoin-starter-stack-dashboard (+https://github.com/VijitSingh97/bitcoin-starter-stack)"
	priceRefreshEvery     = 5 * time.Minute
	priceStaleAfter       = 15 * time.Minute
	maxPriceResponseBytes = 64 << 10
)

var priceCurrencies = []string{"usd", "eur", "gbp", "inr", "cad", "aud", "jpy", "rub", "cny"}
var priceAssets = []string{"bitcoin", "monero"}

type PriceCache struct {
	client       *http.Client
	url          string
	now          func() time.Time
	refreshEvery time.Duration

	mu                sync.RWMutex
	prices            map[string]float64
	updatedAt         int64
	moneroPrices      map[string]float64
	moneroUpdatedAt   int64
	lastFetchFailed   bool
	moneroFetchFailed bool
}

func NewPriceCache() *PriceCache {
	return &PriceCache{
		client:            newTorHTTPClient(torProxy),
		url:               coinGeckoPriceURL,
		now:               time.Now,
		refreshEvery:      priceRefreshEvery,
		prices:            make(map[string]float64),
		moneroPrices:      make(map[string]float64),
		lastFetchFailed:   true,
		moneroFetchFailed: true,
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

func (c *PriceCache) Snapshot(asset ...string) map[string]any {
	selected := "bitcoin"
	if len(asset) > 0 {
		selected = asset[0]
	}
	return c.SnapshotAsset(selected)
}

func (c *PriceCache) SnapshotAsset(asset string) map[string]any {
	if asset == "" {
		asset = "bitcoin"
	}
	c.mu.RLock()
	assetPrices, updatedAt := c.prices, c.updatedAt
	if asset == "monero" {
		assetPrices, updatedAt = c.moneroPrices, c.moneroUpdatedAt
	} else if asset != "bitcoin" {
		assetPrices, updatedAt = nil, 0
	}
	prices := make(map[string]float64, len(assetPrices))
	for currency, price := range assetPrices {
		prices[currency] = price
	}
	failed := c.lastFetchFailed
	if asset == "monero" {
		failed = c.moneroFetchFailed
	} else if asset != "bitcoin" {
		failed = true
	}
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
	req.Header.Set("User-Agent", priceUserAgent)
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

	var payload map[string]map[string]json.Number
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&payload); err != nil {
		return c.fail(errors.New("price provider response invalid"))
	}
	if err := ensureJSONEnd(decoder); err != nil {
		return c.fail(errors.New("price provider response invalid"))
	}

	now := c.now()
	prices := make(map[string]map[string]float64, len(priceAssets))
	updatedAt := make(map[string]int64, len(priceAssets))
	for _, asset := range priceAssets {
		assetUpdatedAt, err := payload[asset]["last_updated_at"].Int64()
		if err != nil || assetUpdatedAt <= 0 || time.Unix(assetUpdatedAt, 0).After(now.Add(priceRefreshEvery)) {
			if asset == "bitcoin" {
				return c.fail(errors.New("price provider response invalid"))
			}
			continue
		}
		assetPrices := make(map[string]float64, len(priceCurrencies))
		valid := true
		for _, currency := range priceCurrencies {
			price, err := payload[asset][currency].Float64()
			if err != nil || math.IsNaN(price) || math.IsInf(price, 0) || price <= 0 {
				valid = false
				break
			}
			assetPrices[currency] = price
		}
		if !valid {
			if asset == "bitcoin" {
				return c.fail(errors.New("price provider response invalid"))
			}
			continue
		}
		prices[asset] = assetPrices
		updatedAt[asset] = assetUpdatedAt
	}

	c.mu.Lock()
	c.prices, c.updatedAt = prices["bitcoin"], updatedAt["bitcoin"]
	if prices["monero"] != nil {
		c.moneroPrices, c.moneroUpdatedAt = prices["monero"], updatedAt["monero"]
		c.moneroFetchFailed = false
	} else {
		c.moneroFetchFailed = true
	}
	c.lastFetchFailed = false
	c.mu.Unlock()
	return nil
}

func (c *PriceCache) fail(err error) error {
	c.mu.Lock()
	c.lastFetchFailed = true
	c.moneroFetchFailed = true
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
