import test from "node:test";
import assert from "node:assert/strict";
import { familyAccessView, familyAmount, familyHistoryPoints, familySourceURL, familyWalletView } from "./family-watch.js";

test("family amounts preserve the backend decimal string including verified zero", () => {
  assert.equal(familyAmount("0.00000000"), "0.00000000");
  assert.equal(familyAmount("9007199254740993.12345678"), "9007199254740993.12345678");
  for (const value of [0, "1", "1.2", "01.00000000", "1.000000000"]) assert.equal(familyAmount(value), "");
});

test("wallet states never present pending or failed scans as zero", () => {
  assert.equal(familyWalletView({ state: "pending", amount: null }, "litecoin").balance, "Scanning for confirmed funds…");
  assert.equal(familyWalletView({ state: "waiting", amount: null }, "litecoin").balance, "Waiting for node sync…");
  assert.equal(familyWalletView({ state: "error", amount: null }, "litecoin").balance, "Scan failed");
  assert.equal(familyWalletView({ state: "ok", amount: "0.00000000" }, "litecoin").balance, "0.00000000 LTC");
});

test("stale balances remain visible and are marked with their cached snapshot", () => {
  const view = familyWalletView({ state: "stale", amount: "12.34567890", scan_height: 3_000_000, scan_time: "2026-10-31T12:00:00Z" }, "bitcoincash");
  assert.equal(view.balance, "12.34567890 BCH");
  assert.equal(view.stale, true);
  assert.match(view.note, /Cached balance/);
  assert.match(view.note, /Block 3000000/);
  assert.match(view.note, /Scanned 2026-10-31T12:00:00Z/);
});

test("public examples are clearly excluded from personal assets", () => {
  const view = familyWalletView({ label: "Linux Mint", address: "Lexample", example: true, state: "ok", amount: "1.00000000" }, "litecoin");
  assert.equal(view.label, "Linux Mint");
  assert.equal(view.address, "Lexample");
  assert.match(view.note, /Public example; excluded from your assets/);
});

test("editing requires a supported active node and dashboard password", () => {
  assert.equal(familyAccessView({ supported: true, enabled: true, active: true, has_password: true }, "litecoin").canEdit, true);
  assert.match(familyAccessView({ supported: true, enabled: true, active: true, has_password: false }, "litecoin").status, /dashboard password/);
  assert.equal(familyAccessView({ supported: false, reason: "Dogecoin scanner details." }, "dogecoin").status, "Wallet balance not available.");
  assert.equal(familyAccessView({ supported: false, reason: "Zcash scanner details." }, "zcash").status, "Wallet balance not available.");
  assert.equal(familyAccessView({ supported: false, reason: "Tari wallet service unavailable." }, "tari").status, "Tari wallet service unavailable.");
  assert.equal(familyAccessView({ supported: true, enabled: true, active: false, reason: "Litecoin is inactive." }, "litecoin").status, "Litecoin is inactive.");
});

test("source links accept HTTPS only", () => {
  assert.equal(familySourceURL("http://example.com"), "");
  assert.equal(familySourceURL("javascript:alert(1)"), "");
  assert.equal(familySourceURL("https://www.linuxmint.com/donors.php"), "https://www.linuxmint.com/donors.php");
});

test("native Unix scan timestamps stay visible with the confirmed block", () => {
  const view = familyWalletView({ state: "ok", amount: "1.00000000", scan_height: 123, scan_time: 1793448000 }, "litecoin");
  assert.match(view.note, /Block 123/);
  assert.match(view.note, /Scanned /);
});

test("saved balance charts preserve a single atomic-unit change", () => {
  const chart = familyHistoryPoints([{ amount: "9007199254740993.00000000" }, { amount: "9007199254740993.00000001" }]);
  assert.equal(chart.length, 2);
  assert.ok(chart[0].y > chart[1].y);
  assert.deepEqual(familyHistoryPoints([{ amount: "0.00000000" }]), []);
});
