import { test } from "node:test";
import assert from "node:assert/strict";
import { needsFullReload, replaceUpdateViews } from "./refresh.js";

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

test("release checks refresh the overview notice and Settings instructions", () => {
  const replaced = [];
  const current = { getElementById: (id) => ({ replaceWith: (next) => replaced.push([id, next.id]) }) };
  const next = { getElementById: (id) => ({ id: `next-${id}` }) };
  replaceUpdateViews(current, next);
  assert.deepEqual(replaced, [
    ["update-notice", "next-update-notice"],
    ["settings-update", "next-settings-update"],
  ]);
});
