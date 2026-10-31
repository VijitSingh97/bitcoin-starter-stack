import { test } from "node:test";
import assert from "node:assert/strict";
import { formatXMR, moneroWalletView, moneroTotal, moneroHistoryValues, walletImport, keyImagesImport } from "./monero-watch.js";

test("Monero atomic amounts retain all twelve decimals without floating point rounding", () => {
  assert.equal(formatXMR("123456789012345678"), "123456.789012345678");
  assert.equal(formatXMR("0"), "0.000000000000");
  assert.equal(formatXMR(null), "—");
  assert.equal(formatXMR(123456789012345678), "—");
});

test("view-only incoming funds never claim to be a verified current balance", () => {
  const view = moneroWalletView({ name: "Cold", state: "ready", received_atomic: "1250000000000", balance_atomic: "1250000000000", spending_status: "unknown" });
  assert.equal(view.balance, "1.25 XMR received");
  assert.match(view.note, /Spending status unknown/);
  assert.equal(view.verified, false);
});

test("only ready wallets with complete current key-image coverage show a verified balance", () => {
  const wallet = { state: "ready", received_atomic: "2000000000000", balance_atomic: "1250000000000", spending_status: "verified", key_images: { complete: true } };
  assert.equal(moneroWalletView(wallet).balance, "1.25 XMR");
  assert.equal(moneroWalletView({ ...wallet, key_images: { complete: false } }).verified, false);
  assert.equal(moneroWalletView({ ...wallet, spending_status: "stale" }).verified, false);
  assert.equal(moneroWalletView({ ...wallet, balance_atomic: "" }).verified, false);
  assert.equal(moneroWalletView({ ...wallet, state: "pending", scan_height: 50, target_height: 100 }).balance, "Pending scan…");
});

test("Monero total never mixes incoming-only funds with verified balances", () => {
  const wallet = { state: "ready", balance_atomic: "1250000000000", spending_status: "verified", key_images: { complete: true } };
  assert.equal(moneroTotal([wallet, wallet]), "2.5 XMR");
  assert.equal(moneroTotal([wallet, { ...wallet, spending_status: "unknown" }]), "Pending…");
});

test("public example stays received-only and is excluded from personal totals", () => {
  const example = { example: true, state: "ready", received_atomic: "9000000000000", balance_atomic: "8000000000000", spending_status: "verified", key_images: { complete: true } };
  const personal = { state: "ready", balance_atomic: "1250000000000", spending_status: "verified", key_images: { complete: true } };
  const view = moneroWalletView(example);
  assert.equal(view.balance, "9 XMR received");
  assert.equal(view.verified, false);
  assert.match(view.note, /current balance unknown/);
  assert.equal(moneroTotal([example, personal]), "1.25 XMR");
  assert.equal(moneroTotal([example]), "—");
});

test("snapshot charts preserve single-atomic-unit changes at large balances", () => {
  const history = ["10000000000000000000", "10000000000000000001", "10000000000000000002"].map(amount_atomic => ({ amount_atomic }));
  assert.deepEqual(moneroHistoryValues(history), [0, 0.5, 1]);
  assert.deepEqual(moneroHistoryValues([{ amount_atomic: "oops" }]), []);
});

test("view-only JSON accepts a private view key and rejects spend keys or seeds", () => {
  const value = { address: "4".repeat(95), view_key: "a".repeat(64), restore_height: 10 };
  assert.equal(walletImport(value).restore_height, 10);
  assert.throws(() => walletImport({ ...value, spendkey: "b".repeat(64) }));
  assert.throws(() => walletImport({ ...value, seed: "words" }));
  assert.throws(() => walletImport({ ...value, restore_height: -1 }));
});

test("signed key-image uploads accept native RPC exports and reject malformed signatures", () => {
  const signed_key_images = [{ key_image: "a".repeat(64), signature: "b".repeat(128) }];
  assert.deepEqual(keyImagesImport({ result: { offset: 3, signed_key_images } }), { offset: 3, signed_key_images });
  assert.throws(() => keyImagesImport({ signed_key_images: [{ key_image: "a", signature: "b" }] }));
  assert.throws(() => keyImagesImport({ offset: -1, signed_key_images }));
});
