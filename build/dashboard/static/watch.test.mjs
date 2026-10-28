import { test } from "node:test";
import assert from "node:assert/strict";
import {
  balanceLabel,
  editAccess,
  genesisNote,
  isBareExtendedPublicKey,
  publicExampleNote,
  shortKey,
  totalLabel,
  walletKeyForPost,
  walletView,
} from "./watch.js";

test("balanceLabel shows the balance when ready", () => {
  assert.equal(balanceLabel({ state: "ok", btc: "1.5" }), "1.5 BTC");
  assert.equal(balanceLabel({ state: "ok", btc: "0" }), "0 BTC");
});

test("balanceLabel shows pending history while a rescan runs", () => {
  assert.equal(balanceLabel({ state: "pending", btc: null }), "Pending history…");
  assert.equal(balanceLabel({ state: "scanning", btc: null }), "Pending history…");
});

test("balanceLabel keeps an accurate zero after rescan without history", () => {
  assert.equal(balanceLabel({ state: "ok", btc: "0", history: [] }), "0 BTC");
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

test("walletView displays an alias but preserves the delete identifier", () => {
  assert.deepEqual(walletView({ name: "Satoshi", display_name: "Genesis" }), {
    label: "Genesis",
    deleteName: "Satoshi",
  });
  assert.deepEqual(walletView({ name: "Cold storage" }), {
    label: "Cold storage",
    deleteName: "Cold storage",
  });
  assert.deepEqual(walletView({ name: "Binance (public)", display_name: "Binance", example: true }), {
    label: "Binance (public)",
    deleteName: "Binance (public)",
  });
});

test("public example is explicitly separated from personal assets and reserves", () => {
  assert.match(publicExampleNote({ example: true }), /excluded from your totals/);
  assert.match(publicExampleNote({ example: true }), /not Binance's total reserves/);
  assert.equal(publicExampleNote({}), "");
});

test("genesisNote applies only to the genesis public address", () => {
  assert.equal(
    genesisNote({ key: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa" }),
    "Bitcoin Core balance excludes the unspendable 50 BTC genesis reward",
  );
  assert.equal(genesisNote({ key: "bc1qexample" }), "");
});

test("editAccess keeps a passwordless watch list read-only", () => {
  assert.deepEqual(editAccess({ has_password: false }), {
    enabled: false,
    warning: "Set a dashboard password to add or remove watch-only wallets.",
  });
  assert.deepEqual(editAccess({ has_password: true }), { enabled: true, warning: "" });
});

test("bare xpub script choice is explicit and defaults to legacy", () => {
  const xpub = `xpub${"A".repeat(107)}`;
  const tpub = `tpub${"B".repeat(107)}`;
  assert.equal(isBareExtendedPublicKey(xpub), true);
  assert.equal(isBareExtendedPublicKey(tpub), true);
  assert.equal(walletKeyForPost(xpub, "legacy"), xpub);
  assert.equal(walletKeyForPost(xpub, "native"), `wpkh(${xpub}/<0;1>/*)`);
  assert.equal(walletKeyForPost(tpub, "nested"), `sh(wpkh(${tpub}/<0;1>/*))`);
});

test("script choice never rewrites non-bare or private keys", () => {
  const descriptor = "wpkh(xpub661/example/*)";
  const zpub = "zpub6rFR7y4Q2AijBEqTU";
  const xprv = "xprv9s21ZrQH143Kprivate";
  assert.equal(walletKeyForPost(descriptor, "native"), descriptor);
  assert.equal(walletKeyForPost(zpub, "nested"), zpub);
  assert.equal(walletKeyForPost(xprv, "native"), xprv);
  assert.equal(walletKeyForPost("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", "native"),
    "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa");
});

test("totalLabel does not show a partial balance while wallets are unresolved", () => {
  assert.equal(totalLabel({ total_state: "pending", total: "0" }), "Pending history…");
  assert.equal(totalLabel({ total_state: "unavailable", total: "1.5" }), "—");
  assert.equal(totalLabel({ total_state: "ok", total: "1.5" }), "1.5 BTC");
  assert.equal(totalLabel({ total: "2" }), "2 BTC");
});
