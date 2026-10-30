import { test } from "node:test";
import assert from "node:assert/strict";
import { needsFullReload } from "./refresh.js";

function page(...ids) {
  const elements = new Set(ids);
  return { getElementById: (id) => elements.has(id) ? {} : null };
}

test("loading to ready needs a full reload to mount persistent features", () => {
  assert.equal(needsFullReload(page("live"), page("live", "watch", "btc-price")), true);
});

test("stable loading and stable ready pages keep the in-place refresh", () => {
  assert.equal(needsFullReload(page("live"), page("live")), false);
  assert.equal(needsFullReload(
    page("live", "watch", "btc-price"),
    page("live", "watch", "btc-price"),
  ), false);
});

test("ready to loading needs a full reload", () => {
  assert.equal(needsFullReload(page("live", "watch", "btc-price"), page("live")), true);
});
