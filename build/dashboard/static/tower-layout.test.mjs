import test from "node:test";
import assert from "node:assert/strict";
import { assignOverviewSlots, overviewLayout } from "./tower.js";

test("shorter syncing towers take the foreground slots", () => {
  const ids = ["bitcoin", "monero", "tari", "litecoin", "dogecoin", "bitcoincash", "zcash"];
  const progress = { bitcoin: 100, monero: 62, tari: 33, litecoin: 82, dogecoin: 48, bitcoincash: 94, zcash: 100 };
  const assignment = assignOverviewSlots(ids, progress, overviewLayout(1840, ids.length, 960));

  assert.ok(assignment.tari.y > assignment.dogecoin.y);
  assert.ok(assignment.dogecoin.y > assignment.monero.y);
  assert.ok(assignment.monero.y > assignment.litecoin.y);
  assert.ok(assignment.litecoin.y > assignment.bitcoincash.y);
  assert.ok(assignment.bitcoincash.y > assignment.bitcoin.y);
  assert.ok(assignment.bitcoin.y > assignment.zcash.y);
  assert.notEqual(assignment.dogecoin.x, assignment.zcash.x);
});

test("equal progress has a stable chain order", () => {
  const ids = ["zcash", "dogecoin", "bitcoin"];
  const assignment = assignOverviewSlots(ids, { bitcoin: 100, dogecoin: 100, zcash: 100 }, overviewLayout(1200, 3, 800));

  assert.ok(assignment.bitcoin.y > assignment.dogecoin.y);
  assert.ok(assignment.dogecoin.y > assignment.zcash.y);
});

for (const [width, count] of [[872, 6], [1840, 7]]) {
  test(`${count} installed towers keep unknown and zero-progress nodes clear in front at ${width}px`, () => {
    const ids = ["bitcoin", "monero", "tari", "litecoin", "dogecoin", "bitcoincash", "zcash"].slice(0, count);
    const progress = { monero: 100, tari: 80, litecoin: 60, dogecoin: 0, bitcoincash: 90, zcash: 100 };
    const layout = overviewLayout(width, count, 900);
    const assignment = assignOverviewSlots(ids, progress, layout);
    const front = [assignment.bitcoin.y, assignment.dogecoin.y];
    const remaining = ids.filter((node) => !["bitcoin", "dogecoin"].includes(node)).map((node) => assignment[node].y);

    assert.ok(Math.min(...front) > Math.max(...remaining));
    assert.equal(new Set(Object.values(assignment).map(({ x, y }) => `${x}:${y}`)).size, count);
    for (const { x, y, tw } of Object.values(assignment)) {
      assert.ok(Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(tw));
      assert.ok(x > 0 && x < layout.contentWidth);
    }
  });
}
