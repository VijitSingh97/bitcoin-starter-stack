import { test } from "node:test";
import assert from "node:assert/strict";
import { project, gridCell, isRollover, nextDisplayed, expectedFill, utcMinutes, smooth, nextHighlight, loadingHighlight, nextScene, scenePhase, overviewTransition, focusedLabelTransition, overviewHitWidth, overviewChoiceGeometry, overviewLabelPosition, towerLayout, overviewLayout, previewDepth, sceneDepth, overviewBlockLabels, NODE_IDS, GRID, PER_LAYER, SCENE_MS } from "./tower.js";

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

test("nextHighlight eases both into and out of the highlighted state", () => {
  const growing = nextHighlight(0, true, 60);
  assert.ok(growing > 0 && growing < 1);
  assert.ok(nextHighlight(growing, true, 60) > growing);
  const shrinking = nextHighlight(1, false, 60);
  assert.ok(shrinking > 0 && shrinking < 1);
  assert.ok(nextHighlight(shrinking, false, 60) < shrinking);
});

test("loading highlight fades faster than its tower and shrinks its glow", () => {
  assert.deepEqual(loadingHighlight(1, 0.5, 10), { opacity: 0.55, glow: 16 });
  assert.deepEqual(loadingHighlight(0.5, 0.5, 10), { opacity: 0.1375, glow: 8 });
  assert.deepEqual(loadingHighlight(0, 0.5, 10), { opacity: 0, glow: 0 });
});

test("nextScene reverses cleanly and changes towers through the overview", () => {
  const opening = nextScene("", "bitcoin", 0, 60);
  assert.equal(opening.node, "bitcoin");
  assert.ok(opening.progress > 0 && opening.progress < 1);

  const reversing = nextScene("bitcoin", "", opening.progress, 30);
  assert.equal(reversing.node, "bitcoin");
  assert.ok(reversing.progress < opening.progress);
  assert.ok(nextScene("bitcoin", "bitcoin", reversing.progress, 30).progress > reversing.progress);

  const switching = nextScene("bitcoin", "monero", 0, 16);
  assert.equal(switching.node, "monero");
  assert.ok(switching.progress > 0);
  const pendingSwitch = nextScene("bitcoin", "monero", 0.8, 30);
  assert.equal(pendingSwitch.node, "bitcoin");
  assert.ok(pendingSwitch.progress < 0.8);
  assert.deepEqual(nextScene("bitcoin", "monero", 1, 16, true), { node: "monero", progress: 1 });
});

test("scene timing is frame-rate independent and reverses without jumping", () => {
  const advance = (step) => {
    let scene = { node: "", progress: 0 };
    for (let elapsed = 0; elapsed < SCENE_MS; elapsed += step) {
      scene = nextScene(scene.node, "bitcoin", scene.progress, Math.min(step, SCENE_MS - elapsed));
    }
    return scene;
  };
  assert.deepEqual(advance(10), { node: "bitcoin", progress: 1 });
  assert.deepEqual(advance(100), { node: "bitcoin", progress: 1 });

  const halfway = nextScene("bitcoin", "bitcoin", 0, SCENE_MS / 2);
  const reversing = nextScene(halfway.node, "", halfway.progress, 140);
  const resumed = nextScene(reversing.node, "bitcoin", reversing.progress, 140);
  assert.equal(reversing.progress, 0.3);
  assert.equal(resumed.progress, halfway.progress);
});

test("neighbors disappear before zoom and return only after the camera is home", () => {
  for (const progress of [0, 0.1, 0.24, 0.25, 0.4, 0.7, 1]) {
    const phase = scenePhase(progress);
    if (phase.zoomAmount > 0) assert.equal(phase.overviewOpacity, 0, `progress=${progress}`);
    if (phase.overviewOpacity > 0) assert.equal(phase.zoomAmount, 0, `progress=${progress}`);
  }
  assert.deepEqual(scenePhase(0), { overviewOpacity: 1, zoomAmount: 0 });
  assert.deepEqual(scenePhase(1), { overviewOpacity: 0, zoomAmount: 1 });
});

test("overview controls fade with the other towers and only receive input when settled", () => {
  assert.deepEqual(overviewTransition(0, ""), { opacity: 1, hidden: false, interactive: true });
  assert.deepEqual(overviewTransition(0.125, "bitcoin"), { opacity: 0.5, hidden: false, interactive: false });
  assert.deepEqual(overviewTransition(0.5, "bitcoin"), { opacity: 0, hidden: true, interactive: false });
  assert.deepEqual(overviewTransition(1, "bitcoin"), { opacity: 0, hidden: true, interactive: false });
  assert.deepEqual(overviewTransition(0, "bitcoin"), { opacity: 1, hidden: false, interactive: false });
});

test("focused label follows opening, closing, switching, and reduced-motion scenes", () => {
  let scene = nextScene("", "bitcoin", 0, 200);
  const opening = focusedLabelTransition(scenePhase(scene.progress).zoomAmount, "974001");
  assert.equal(opening.hidden, false);
  assert.ok(opening.opacity > 0 && opening.opacity < 1);

  scene = nextScene(scene.node, "", scene.progress, 30);
  const closing = focusedLabelTransition(scenePhase(scene.progress).zoomAmount, "974001");
  assert.ok(closing.opacity < opening.opacity);

  scene = nextScene("bitcoin", "monero", 0, 200);
  const switched = focusedLabelTransition(scenePhase(scene.progress).zoomAmount, scene.node === "monero" ? "3512002" : "974001");
  assert.equal(scene.node, "monero");
  assert.ok(switched.opacity > 0 && switched.opacity < 1);

  scene = nextScene("bitcoin", "monero", 1, 16, true);
  assert.deepEqual(focusedLabelTransition(scene.progress, "3512002"), { opacity: 1, hidden: false });
  assert.deepEqual(focusedLabelTransition(0.5, ""), { opacity: 0, hidden: true });
});

test("renderer keeps the focused label live through opening, switching, and closing frames", async () => {
  const style = () => ({ setProperty(name, value) { this[name] = value; } });
  const context = new Proxy({}, { get(target, key) { return target[key] || (() => {}); } });
  const canvas = { getContext: () => context, style: style() };
  const label = { hidden: true, innerHTML: "", style: style() };
  const overview = { hidden: false, scrollLeft: 0, style: style(), addEventListener() {} };
  const choices = NODE_IDS.map((node) => ({
    dataset: { selectNode: node, nodeActive: "1" }, hidden: false, style: style(),
  }));
  const overviewLabels = Object.fromEntries(NODE_IDS.map((node) => [node, {
    hidden: true, style: style(), querySelector: () => ({ style: style(), textContent: "" }),
  }]));
  const live = Object.fromEntries(NODE_IDS.map((node) => [node, {
    dataset: { nextBlock: node === "bitcoin" ? "974001" : node === "monero" ? "3512002" : "1" },
  }]));
  const elements = { tower: canvas, "tower-label": label, "node-overview": overview };
  for (const node of NODE_IDS) {
    elements[`tower-overview-label-${node}`] = overviewLabels[node];
    elements[node === "bitcoin" ? "live" : `${node}-live`] = live[node];
  }
  const body = { dataset: { node: "", towerLabels: "1" } };
  const frames = [];
  globalThis.document = {
    body,
    hidden: false,
    documentElement: { getAttribute: () => "dark" },
    getElementById: (id) => elements[id] || null,
    querySelectorAll: () => choices,
    querySelector: (selector) => choices.find((choice) => selector.includes(`"${choice.dataset.selectNode}"`)) || null,
  };
  globalThis.window = {
    devicePixelRatio: 1,
    innerWidth: 1280,
    innerHeight: 900,
    matchMedia: () => ({ matches: false }),
    addEventListener() {},
  };
  globalThis.requestAnimationFrame = (callback) => { frames.push(callback); };
  let now = performance.now() + 100;
  const step = (dt) => {
    now += dt;
    const frame = frames.shift();
    assert.ok(frame, "renderer should schedule another frame");
    frame(now);
  };

  try {
    await import(`./tower.js?render-frames=${Date.now()}`);
    body.dataset.node = "bitcoin";
    step(60);
    assert.equal(label.hidden, true);
    assert.ok(Number(overview.style.opacity) > 0 && Number(overview.style.opacity) < 1);

    step(100);
    const openingOpacity = Number(label.style.opacity);
    const openingLeft = label.style.left;
    assert.match(label.innerHTML, /974001/);
    assert.ok(openingOpacity > 0 && openingOpacity < 1);
    assert.equal(label.hidden, false);

    step(60);
    assert.notEqual(label.style.left, openingLeft);
    assert.equal(overview.style.opacity, "0");
    body.dataset.node = "monero";
    step(30);
    assert.match(label.innerHTML, /974001/);
    assert.ok(Number(label.style.opacity) < 1);
    for (let i = 0; i < 12 && !label.innerHTML.includes("3512002"); i++) step(100);
    assert.match(label.innerHTML, /3512002/);
    assert.equal(label.hidden, false);
    for (let i = 0; i < 8 && Number(label.style.opacity) < 0.8; i++) step(100);

    const beforeClose = Number(label.style.opacity);
    body.dataset.node = "";
    step(50);
    assert.ok(Number(label.style.opacity) < beforeClose);
    assert.equal(overview.style.opacity, "0");
    for (let i = 0; i < 12 && !label.hidden; i++) step(100);
    assert.equal(label.hidden, true);
  } finally {
    delete globalThis.document;
    delete globalThis.window;
    delete globalThis.requestAnimationFrame;
  }
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

test("overview bouquet spreads farther on large screens without enlarging the towers", () => {
  const span = ({ positions }) => Math.max(...positions) - Math.min(...positions);
  const laptop = overviewLayout(1440, 7, 900);
  const desktop = overviewLayout(1920, 7, 900);
  assert.ok(span(desktop) > span(laptop) * 1.2);
  assert.equal(desktop.tw, laptop.tw);
});

test("seven-tower mobile bouquet stays compact, contained, and selectable", () => {
  for (const width of [320, 375, 560]) {
    const layout = overviewLayout(width, 7, 700);
    const hitWidth = overviewHitWidth(layout.tw);
    const sortedAnchors = layout.anchors.slice().sort((a, b) => a - b);
    const minGap = Math.min(...sortedAnchors.slice(1).map((y, index) => y - sortedAnchors[index]));
    const targets = sortedAnchors.map((anchor) => overviewChoiceGeometry(width, anchor, 12 * layout.tw * 1.12, minGap));
    assert.equal(layout.positions.length, 7);
    assert.equal(layout.contentWidth, width);
    assert.ok(hitWidth >= 140);
    assert.ok(layout.positions.every((x) => x - hitWidth / 2 >= 0 && x + hitWidth / 2 <= layout.contentWidth));
    assert.ok(minGap >= 52);
    assert.ok(targets.every(({ height }) => height >= 44));
    assert.ok(targets.slice(1).every(({ top }, index) => top >= targets[index].top + targets[index].height));
  }
});

test("intermediate overview block labels clear neighboring name cards", () => {
  const width = 872;
  const layout = overviewLayout(width, 7, 888);
  const nodes = ["bitcoin", "monero", "tari", "litecoin", "dogecoin", "bitcoincash", "zcash"];
  const centers = Object.fromEntries(nodes
    .map((node, index) => [node, overviewLabelPosition(width, layout.positions[index], layout.anchors[index], layout.tw).left]));
  const labelWidth = 168;
  const nameCardWidth = 112;
  const clear = (labelNode, cardNode) => Math.abs(centers[labelNode] - layout.positions[nodes.indexOf(cardNode)]) >= (labelWidth + nameCardWidth) / 2;
  assert.ok(clear("monero", "litecoin"));
  assert.ok(clear("tari", "dogecoin"));
  assert.ok(Object.values(centers).every((center) => center - labelWidth / 2 >= 0 && center + labelWidth / 2 <= width));
  const towerHalfWidth = GRID * layout.tw * 1.12 / 2;
  assert.ok(nodes.every((node, index) => Math.abs(centers[node] - layout.positions[index]) <= towerHalfWidth));
});

test("preview tower reaches the viewport bottom", () => {
  for (const [H, anchorY, tw] of [[667, 200, 14], [900, 270, 40], [2160, 648, 46]]) {
    const depth = previewDepth(H, anchorY, tw);
    for (const [gx, gy] of [[GRID, 0], [0, GRID], [GRID, GRID]]) {
      const bottom = project(gx, gy, 0, tw, tw * 0.5, 0, anchorY - GRID * (tw / 4) + (depth + 1) * tw * 0.5).y;
      assert.ok(bottom > H, `H=${H} corner=${gx},${gy} stops at ${bottom}`);
    }
  }
});

test("zoom keeps at least the overview tower depth throughout the transition", () => {
  const H = 900;
  const overviewY = H * 0.3;
  const overviewTw = 40;
  const initialDepth = previewDepth(H, overviewY, overviewTw);
  for (const progress of [0, 0.25, 0.5, 0.75, 1]) {
    const anchorY = overviewY + (H * 0.6 - overviewY) * progress;
    const tw = overviewTw + (52 - overviewTw) * progress;
    const depth = sceneDepth(H, anchorY, tw, overviewY, overviewTw);
    assert.ok(depth >= initialDepth, `progress=${progress} shrank from ${initialDepth} to ${depth}`);
    for (const [gx, gy] of [[GRID, 0], [0, GRID], [GRID, GRID]]) {
      const bottom = project(gx, gy, 0, tw, tw * 0.5, 0, anchorY - GRID * (tw / 4) + (depth + 1) * tw * 0.5).y;
      assert.ok(bottom > H, `progress=${progress} corner=${gx},${gy} stops at ${bottom}`);
    }
  }
});

test("overview block labels use each live node height only when labels are enabled", () => {
  assert.deepEqual(overviewBlockLabels({ bitcoin: "974001", monero: "3512002" }, true, true), {
    bitcoin: "loading block 974001",
    monero: "loading block 3512002",
  });
  assert.deepEqual(overviewBlockLabels({ bitcoin: "974001", monero: "" }, true, true), {
    bitcoin: "loading block 974001",
    monero: "",
  });
  assert.deepEqual(overviewBlockLabels({ bitcoin: "974001", monero: "3512002" }, false, true), { bitcoin: "", monero: "" });
  assert.deepEqual(overviewBlockLabels({ bitcoin: "974001", monero: "3512002" }, true, false), { bitcoin: "", monero: "" });
});
