import { test } from "node:test";
import assert from "node:assert/strict";
import { project, layerFill, gridCell, nextDisplayed, smooth, towerLayout, GRID, PER_LAYER } from "./tower.js";

test("a layer is 12x12 = 144 blocks (~one day)", () => {
  assert.equal(GRID, 12);
  assert.equal(PER_LAYER, 144);
});

test("layerFill splits height into completed layers and the top fill", () => {
  assert.deepEqual(layerFill(0), { layer: 0, fill: 0 });
  assert.deepEqual(layerFill(143), { layer: 0, fill: 143 });
  assert.deepEqual(layerFill(144), { layer: 1, fill: 0 });
  assert.deepEqual(layerFill(150), { layer: 1, fill: 6 });
  assert.deepEqual(layerFill(-5), { layer: 0, fill: 0 });
});

test("gridCell fills row by row, back to front", () => {
  assert.deepEqual(gridCell(0), { gx: 0, gy: 0 });
  assert.deepEqual(gridCell(11), { gx: 11, gy: 0 }); // end of the back row
  assert.deepEqual(gridCell(12), { gx: 0, gy: 1 }); // next row starts
  assert.deepEqual(gridCell(143), { gx: 11, gy: 11 }); // last cube
});

test("nextDisplayed snaps down on a reorg and never overshoots up", () => {
  assert.equal(nextDisplayed(100, 98, 1000), 98); // dip -> snap
  assert.equal(nextDisplayed(100, 100, 1000), 100); // equal
  assert.equal(nextDisplayed(100, 101, 100000), 101); // clamped to target
});

test("nextDisplayed rips upward when far behind (initial sync)", () => {
  // gap 5000 >> 2*144 -> fast rate 0.36/ms
  const after = nextDisplayed(0, 5000, 1000);
  assert.ok(after > 300 && after <= 5000, `fast catch-up, got ${after}`);
  assert.equal(after, 360);
});

test("nextDisplayed drifts a single synced block in over ~0.8s", () => {
  // gap 1 -> slow rate 0.00125/ms -> ~800ms to add one block
  assert.ok(Math.abs(nextDisplayed(500, 501, 800) - 501) < 1e-9);
  assert.ok(nextDisplayed(500, 501, 400) < 501); // still arriving at 400ms
});

test("project: height moves the point up; the diamond is symmetric", () => {
  assert.equal(project(2, 2, 1, 40, 20, 0, 0).y, project(2, 2, 0, 40, 20, 0, 0).y - 20);
  assert.equal(project(1, 0, 0, 40, 20, 0, 0).x, 20);
  assert.equal(project(0, 1, 0, 40, 20, 0, 0).x, -20);
});

test("towerLayout centres behind the card on mobile", () => {
  const m = towerLayout(375);
  assert.equal(m.wide, false);
  assert.equal(m.ox, 187.5);
});

test("towerLayout puts the tower right of the card zone on wide screens, no overlap", () => {
  for (const W of [900, 1024, 1280, 1920]) {
    const { wide, ox, tw } = towerLayout(W, GRID);
    assert.equal(wide, true, `W=${W} should be wide`);
    // the tower's left-most vertex must clear the 500px card zone
    const leftExtent = ox - (GRID * tw) / 2;
    assert.ok(leftExtent >= 500, `W=${W}: tower overlaps card (leftExtent ${leftExtent})`);
    // and it must stay on screen
    assert.ok(ox + (GRID * tw) / 2 <= W + 1, `W=${W}: tower runs off screen`);
  }
});

test("smooth clamps to [0,1] and eases the ends", () => {
  assert.equal(smooth(-1), 0);
  assert.equal(smooth(2), 1);
  assert.equal(smooth(0.5), 0.5);
  assert.ok(smooth(0.25) < 0.25);
});
