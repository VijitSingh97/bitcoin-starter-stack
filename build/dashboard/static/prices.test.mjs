import { test } from "node:test";
import assert from "node:assert/strict";
import {
  PRICE_URL,
  formatPrice,
  loadCurrency,
  normalizeCurrency,
  priceView,
  saveCurrency,
} from "./prices.js";

test("price endpoint is same-origin", () => {
  assert.equal(PRICE_URL, "/api/prices");
  assert.equal(PRICE_URL.startsWith("http"), false);
});

test("currency persistence defaults and falls through to USD", () => {
  const values = new Map();
  const storage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };
  assert.equal(loadCurrency(storage), "USD");
  assert.equal(saveCurrency("eur", storage), "EUR");
  assert.equal(loadCurrency(storage), "EUR");
  values.set("btc-price-currency", "DOGE");
  assert.equal(loadCurrency(storage), "USD");
  assert.equal(normalizeCurrency("inr"), "INR");
});

test("currency persistence tolerates blocked storage", () => {
  const blocked = {
    getItem() { throw new Error("blocked"); },
    setItem() { throw new Error("blocked"); },
  };
  assert.equal(loadCurrency(blocked), "USD");
  assert.equal(saveCurrency("GBP", blocked), "GBP");
});

test("rubles and yuan use cached quotes and persist the selected currency", () => {
  const storage = { getItem: () => "cny", setItem() {} };
  assert.equal(loadCurrency(storage), "CNY");
  assert.equal(saveCurrency("rub", storage), "RUB");
  const data = { available: true, stale: false, updated_at: 1700000000,
    prices: { rub: 6500000, cny: 500000 } };
  for (const currency of ["RUB", "CNY"]) {
    const view = priceView(data, currency, () => "now");
    assert.equal(view.currency, currency);
    assert.notEqual(view.value, "—");
    assert.equal(view.status, "As of now");
  }
});

test("formatPrice uses guarded currency formatting", () => {
  const FakeNumberFormat = class {
    constructor(_locale, options) { this.currency = options.currency; }
    format(value) { return `${this.currency}:${value.toFixed(2)}`; }
  };
  assert.equal(formatPrice(57690.48146, "CAD", FakeNumberFormat), "CAD:57690.48");
  const BrokenNumberFormat = class { constructor() { throw new Error("no Intl"); } };
  assert.equal(formatPrice(12.5, "USD", BrokenNumberFormat), "USD 12.50");
});

test("priceView renders current and stale cached prices", () => {
  const current = priceView({
    available: true,
    stale: false,
    updated_at: 1_700_000_000,
    prices: { usd: 57690.48146 },
  }, "USD", () => "Nov 14, 2023, 4:13 PM");
  assert.notEqual(current.value, "—");
  assert.equal(current.status, "As of Nov 14, 2023, 4:13 PM");

  const stale = priceView({
    available: true,
    stale: true,
    updated_at: 1_700_000_000,
    prices: { eur: 51000 },
  }, "EUR", () => "yesterday");
  assert.equal(stale.status, "Stale · as of yesterday");
});

test("priceView never renders zero for unavailable or bad data", () => {
  for (const data of [
    { available: false, prices: { usd: 0 } },
    { available: true, prices: { usd: 0 } },
    { available: true, prices: {} },
    null,
  ]) {
    assert.deepEqual(priceView(data, "USD"), {
      currency: "USD",
      value: "—",
      status: "Price unavailable",
      stale: false,
    });
  }
});
