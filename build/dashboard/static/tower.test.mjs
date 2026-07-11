import { test } from "node:test";
import assert from "node:assert/strict";
import { project, layersAt, smooth, GRID } from "./tower.js";

test("footprint is 5x5", () => {
  assert.equal(GRID, 5);
});

test("project places the origin cell at the origin point", () => {
  const p = project(0, 0, 0, 40, 20, 100, 200);
  assert.deepEqual(p, { x: 100, y: 200 });
});

test("project: increasing height moves the point up (smaller y)", () => {
  const base = project(2, 2, 0, 40, 20, 0, 0);
  const up = project(2, 2, 1, 40, 20, 0, 0);
  assert.equal(up.y, base.y - 20); // one block height
  assert.equal(up.x, base.x);
});

test("project: the isometric diamond is symmetric about the origin column", () => {
  const right = project(1, 0, 0, 40, 20, 0, 0); // +x, down
  const left = project(0, 1, 0, 40, 20, 0, 0); // -x, same depth
  assert.equal(right.x, 20);
  assert.equal(left.x, -20);
  assert.equal(right.y, left.y);
});

test("layersAt grows linearly and never goes negative", () => {
  assert.equal(layersAt(0, 2000), 0);
  assert.equal(layersAt(2000, 2000), 1);
  assert.equal(layersAt(5000, 2000), 2.5);
  assert.equal(layersAt(-100, 2000), 0);
});

test("smooth clamps to [0,1] and eases the ends", () => {
  assert.equal(smooth(-1), 0);
  assert.equal(smooth(0), 0);
  assert.equal(smooth(1), 1);
  assert.equal(smooth(2), 1);
  assert.equal(smooth(0.5), 0.5);
  assert.ok(smooth(0.25) < 0.25); // eased in at the start
});
