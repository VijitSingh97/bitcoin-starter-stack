import { test } from "node:test";
import assert from "node:assert/strict";
import { project, gridCell, isRollover, nextDisplayed, expectedFill, utcMinutes, smooth, towerLayout, GRID, PER_LAYER } from "./tower.js";

test("a layer is 12x12 = 144 blocks (~one day)", () => {
  assert.equal(GRID, 12);
  assert.equal(PER_LAYER, 144);
});

test("gridCell fills row by row, back to front", () => {
  assert.deepEqual(gridCell(0), { gx: 0, gy: 0 });
  assert.deepEqual(gridCell(11), { gx: 11, gy: 0 });
  assert.deepEqual(gridCell(12), { gx: 0, gy: 1 });
  assert.deepEqual(gridCell(143), { gx: 11, gy: 11 });
});

test("isRollover fires only on a big drop (new day / restart), not a wobble", () => {
  assert.equal(isRollover(0, 140), true); // midnight: 140 -> 0
  assert.equal(isRollover(5, 140), true); // restart mid-day
  assert.equal(isRollover(139, 140), false); // a reorg of a block or two
  assert.equal(isRollover(141, 140), false); // still climbing
});

test("nextDisplayed snaps down on a dip and never overshoots up", () => {
  assert.equal(nextDisplayed(100, 98, 1000), 98);
  assert.equal(nextDisplayed(100, 100, 1000), 100);
  assert.equal(nextDisplayed(100, 101, 100000), 101);
});

test("nextDisplayed catches up a big gap (fresh page mid-day)", () => {
  const after = nextDisplayed(0, 100, 1000); // gap 100 > 24 -> 0.06/ms
  assert.equal(after, 60);
});

test("nextDisplayed drifts a single new block in over ~0.8s", () => {
  assert.ok(Math.abs(nextDisplayed(50, 51, 800) - 51) < 1e-9);
  assert.ok(nextDisplayed(50, 51, 400) < 51);
});

test("expectedFill: one cube per 10 UTC minutes, capped at a full day", () => {
  assert.equal(expectedFill(0), 0);       // 00:00
  assert.equal(expectedFill(600), 60);    // 10:00 -> 60
  assert.equal(expectedFill(720), 72);    // 12:00 -> half a day
  assert.equal(expectedFill(695), 69.5);  // fills continuously, not in steps
  assert.equal(expectedFill(1440), 144);  // 24:00 -> full layer
  assert.equal(expectedFill(2000), 144);  // never exceeds a layer
  assert.equal(expectedFill(-5), 0);      // never negative
});

test("utcMinutes: minutes past UTC midnight, with seconds", () => {
  assert.equal(utcMinutes(new Date("2026-07-11T00:00:00Z")), 0);
  assert.equal(utcMinutes(new Date("2026-07-11T11:33:00Z")), 693);
  assert.equal(utcMinutes(new Date("2026-07-11T23:38:30Z")), 23 * 60 + 38 + 0.5);
});

test("project: height moves the point up; the diamond is symmetric", () => {
  assert.equal(project(2, 2, 1, 40, 20, 0, 0).y, project(2, 2, 0, 40, 20, 0, 0).y - 20);
  assert.equal(project(1, 0, 0, 40, 20, 0, 0).x, 20);
  assert.equal(project(0, 1, 0, 40, 20, 0, 0).x, -20);
});

test("smooth clamps to [0,1] and eases the ends", () => {
  assert.equal(smooth(-1), 0);
  assert.equal(smooth(2), 1);
  assert.equal(smooth(0.5), 0.5);
  assert.ok(smooth(0.25) < 0.25);
});

test("towerLayout stacks (centres the tower) below the wide breakpoint", () => {
  for (const W of [375, 900, 1023]) {  // phones through the awkward mid-range
    const m = towerLayout(W);
    assert.equal(m.wide, false, `W=${W} should stack`);
    assert.equal(m.ox, W / 2);
  }
});

test("towerLayout keeps the tower clear of the card zone on wide screens", () => {
  for (const W of [1024, 1280, 1920]) {
    const { wide, ox, tw } = towerLayout(W, GRID);
    assert.equal(wide, true);
    assert.ok(ox - (GRID * tw) / 2 >= 500, `W=${W} overlaps card`);
    assert.ok(ox + (GRID * tw) / 2 <= W + 1, `W=${W} runs off screen`);
  }
});
