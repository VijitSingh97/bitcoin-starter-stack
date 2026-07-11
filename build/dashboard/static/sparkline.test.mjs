import { test } from "node:test";
import assert from "node:assert/strict";
import { points } from "./sparkline.js";

test("points needs at least two values", () => {
  assert.deepEqual(points([], 100, 30), []);
  assert.deepEqual(points([5], 100, 30), []);
});

test("points map min to the bottom and max to the top, within padding", () => {
  const pts = points([0, 10], 100, 30, 2);
  assert.equal(pts.length, 2);
  assert.equal(pts[0].x, 2); // first at left padding
  assert.equal(pts[1].x, 98); // last at right edge - padding
  assert.equal(pts[0].y, 28); // min -> bottom (h - pad)
  assert.equal(pts[1].y, 2); // max -> top (pad)
});

test("points handle a flat series without dividing by zero", () => {
  const pts = points([7, 7, 7], 100, 30);
  assert.equal(pts.length, 3);
  assert.ok(pts.every((p) => Number.isFinite(p.y)));
});

test("points ignore non-numeric samples", () => {
  const pts = points([1, null, 2, undefined, 3], 100, 30);
  assert.equal(pts.length, 3); // only the three real numbers
});
