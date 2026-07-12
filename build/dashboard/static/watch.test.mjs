import { test } from "node:test";
import assert from "node:assert/strict";
import { balanceLabel } from "./watch.js";

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
