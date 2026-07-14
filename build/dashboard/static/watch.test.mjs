import { test } from "node:test";
import assert from "node:assert/strict";
import { balanceLabel, shortKey } from "./watch.js";

test("balanceLabel shows the balance when ready", () => {
  assert.equal(balanceLabel({ state: "ok", btc: "1.5" }), "1.5 BTC");
  assert.equal(balanceLabel({ state: "ok", btc: "0" }), "0 BTC");
});

test("balanceLabel shows scanning while a rescan runs", () => {
  assert.equal(balanceLabel({ state: "scanning", btc: null }), "scanning…");
});

test("balanceLabel falls back to a dash on error / not-ready", () => {
  assert.equal(balanceLabel({ state: "error", btc: null }), "—");
  assert.equal(balanceLabel({ state: "whatever" }), "—");
});

test("balanceLabel shows the cached value when stale (node unreachable)", () => {
  assert.equal(balanceLabel({ state: "stale", btc: "1.25" }), "1.25 BTC");
});

test("shortKey shows first 4 … last 4, or the whole thing when short", () => {
  assert.equal(shortKey("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"), "1A1z…vfNa");
  assert.equal(shortKey("bc1qshort"), "bc1qshort"); // <= 12 chars, shown whole
  assert.equal(shortKey("zpub6rFR7y4Q2AijBEqTU"), "zpub…EqTU");
});
