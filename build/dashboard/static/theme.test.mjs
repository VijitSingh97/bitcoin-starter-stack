import { test } from "node:test";
import assert from "node:assert/strict";
import { nextTheme, label, MODES } from "./theme.js";

test("nextTheme cycles auto -> light -> dark -> auto", () => {
  assert.equal(nextTheme("auto"), "light");
  assert.equal(nextTheme("light"), "dark");
  assert.equal(nextTheme("dark"), "auto");
});

test("nextTheme treats an unknown value as auto's predecessor", () => {
  // unknown -> indexOf -1 -> (0) -> "auto", so the next click lands on a valid mode
  assert.ok(MODES.includes(nextTheme("garbage")));
  assert.equal(nextTheme("garbage"), "auto");
});

test("label is human-readable and defaults to Auto", () => {
  assert.equal(label("auto"), "Auto");
  assert.equal(label("light"), "Light");
  assert.equal(label("dark"), "Dark");
  assert.equal(label(undefined), "Auto");
});
