// A live tower of the blockchain, read as a day-clock. A 12x12 layer is one
// UTC day: it fills to where the day "should" be at Bitcoin's ~10-minute
// spacing (one cube per 10 UTC minutes — block timestamps are Unix/UTC time),
// so the fill tracks the time of day. At the next midnight the layer completes,
// the tower is pushed down, and a fresh day starts on top. The header reads
// "loading block N" — the next block the network is working on.
//
// No history or node lookups: the fill comes straight from the clock, and the
// block height is read from #live's data-next-block. Pure helpers are exported
// for tower.test.mjs; the canvas wiring is guarded on `document`.
export const GRID = 12;
export const PER_LAYER = GRID * GRID; // 144 blocks ≈ one day
export const SCENE_MS = 700;
// Side-by-side card + tower (and balances floating above the tower) only above
// this width; below it everything stacks. Kept in sync with the CSS media
// queries. Set high enough that the ~460px balances block clears the card and
// the viewport edge (a squeeze in the 900–1024 range looked broken).
export const WIDE_MIN = 1024;
const ROLLOVER_DROP = 12; // a fall this far below the shown fill = midnight rolled over
export const NODE_IDS = ["bitcoin", "monero", "tari", "litecoin", "dogecoin", "bitcoincash", "zcash"];
export const NODE_COLORS = {
  bitcoin: "#f2a900",
  monero: "#ff6600",
  tari: "#8f5cff",
  litecoin: "#4d8fd8",
  dogecoin: "#b88746",
  bitcoincash: "#36a852",
  zcash: "#d69c35",
};

// Fill order of cube `index` (0..143): row by row, back to front.
export function gridCell(index, cols = GRID) {
  return { gx: index % cols, gy: Math.floor(index / cols) };
}

// A big drop in the fill target means UTC midnight rolled over — the layer
// completes and a fresh one begins.
export function isRollover(target, displayed) {
  return target < displayed - ROLLOVER_DROP;
}

// How full the day should be `utcMinutes` past UTC midnight, at ~10 min per
// block — one cube per 10 minutes, capped at a full layer. This is the fill.
export function expectedFill(utcMinutes) {
  return Math.max(0, Math.min(PER_LAYER, utcMinutes / 10));
}

// Ease the shown fill toward the target: snap a dip (midnight), rip up a big
// jump (a fresh page mid-day), drift smoothly otherwise.
export function nextDisplayed(current, target, dtMs) {
  if (target <= current) return target;
  const gap = target - current;
  const perMs = gap > 24 ? 0.06 : 0.0015; // catch up vs. a smooth minute-by-minute crawl
  return Math.min(target, current + perMs * dtMs);
}

// Minutes (with seconds) past UTC midnight for a Date — the fill clock.
export function utcMinutes(date) {
  return date.getUTCHours() * 60 + date.getUTCMinutes() + date.getUTCSeconds() / 60;
}

export function project(gx, gy, z, tw, bh, ox, oy) {
  return { x: ox + (gx - gy) * (tw / 2), y: oy + (gx + gy) * (tw / 4) - z * bh };
}

export function smooth(t) {
  const x = Math.min(1, Math.max(0, t));
  return x * x * (3 - 2 * x);
}

export function nextHighlight(current, active, dtMs) {
  const target = active ? 1 : 0;
  const amount = 1 - Math.exp(-Math.max(0, dtMs) / 120);
  return current + (target - current) * amount;
}

export function retainedSyncProgress(value, previous = null) {
  if (value === null || value === undefined || String(value).trim() === "") return previous;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.min(100, Math.max(0, parsed)) : previous;
}

export function nextBuildProgress(current, target, dtMs, reduce = false) {
  const from = Math.min(1, Math.max(0, Number(current) || 0));
  const to = Math.min(1, Math.max(0, Number(target) || 0));
  if (reduce || from === to) return to;
  const next = from + (to - from) * (1 - Math.exp(-Math.max(0, dtMs) / 360));
  return Math.abs(next - to) < 0.0005 ? to : next;
}

export function constructionGeometry(targetAnchor, fullDepth, tw, progress) {
  const depth = Math.max(1, Math.floor(fullDepth));
  const fraction = Math.min(1, Math.max(0, Number(progress) || 0));
  const built = 1 + (depth - 1) * fraction;
  const complete = Math.min(depth, Math.floor(built));
  const layerFill = complete >= depth ? null : (built - complete) * PER_LAYER;
  const bh = tw * 0.5;
  return {
    anchorY: targetAnchor + (depth - complete) * bh,
    depth: complete,
    layerFill,
  };
}

export function nextLayoutPoint(current, target, dtMs, reduce = false) {
  if (!current || reduce) return { ...target };
  const amount = 1 - Math.exp(-Math.max(0, dtMs) / 180);
  const next = {};
  for (const key of ["x", "y", "tw"]) next[key] = current[key] + (target[key] - current[key]) * amount;
  return next;
}

export function loadingHighlight(opacity, pulse, glow) {
  const sceneOpacity = Math.min(1, Math.max(0, opacity));
  return {
    opacity: sceneOpacity * sceneOpacity * (0.2 + 0.7 * pulse),
    glow: (glow + 12 * pulse) * sceneOpacity,
  };
}

export function nextScene(scene, requested, progress, dtMs, reduce = false) {
  if (reduce) return { node: requested, progress: requested ? 1 : 0 };
  let node = scene;
  let value = progress;
  if (requested !== node && value <= 0.001) node = requested;
  const opening = !!requested && requested === node;
  value = Math.min(1, Math.max(0, value + (opening ? 1 : -1) * Math.max(0, dtMs) / SCENE_MS));
  if (value >= 1 - 1e-9) value = 1;
  if (value <= 1e-9) value = 0;
  if (!opening && value === 0) {
    value = 0;
    node = requested;
  }
  return { node, progress: value };
}

export function scenePhase(progress) {
  const value = Math.min(1, Math.max(0, progress));
  return {
    overviewOpacity: 1 - smooth(value / 0.25),
    zoomAmount: smooth((value - 0.25) / 0.75),
  };
}

export function overviewTransition(progress, selected) {
  const opacity = scenePhase(progress).overviewOpacity;
  return {
    opacity,
    hidden: !!selected && opacity <= 0.001,
    interactive: !selected && opacity >= 0.999,
  };
}

export function focusedLabelTransition(progress, nextBlock) {
  const block = String(nextBlock || "").trim();
  const opacity = block ? Math.min(1, Math.max(0, progress)) : 0;
  return { opacity, hidden: !block || opacity <= 0.001 };
}

export function overviewHitWidth(tw) {
  return Math.max(140, GRID * tw * 1.12);
}

export function overviewChoiceGeometry(width, anchor, diamondWidth, minAnchorGap = Infinity, viewportHeight = Infinity) {
  const towerTop = anchor - diamondWidth / 4;
  const towerLabelTop = diamondWidth / 2 + 22;
  if (width > 700) {
    const labelTop = Number.isFinite(viewportHeight)
      ? Math.max(2, Math.min(towerLabelTop, viewportHeight - towerTop - 48))
      : towerLabelTop;
    return { top: towerTop, height: null, shoulder: diamondWidth / 4, labelTop };
  }
  const height = Math.max(44, Math.min(72, minAnchorGap - 4));
  const labelTop = Math.max(2, (height - 44) / 2);
  const desiredTop = towerTop + towerLabelTop - labelTop;
  const top = Number.isFinite(viewportHeight) ? Math.max(0, Math.min(desiredTop, viewportHeight - height - 4)) : desiredTop;
  return { top, height, shoulder: 0, labelTop };
}

export function overviewLabelPosition(width, ox, anchorY, tw) {
  const diamondWidth = GRID * tw * 1.12;
  const offset = width > 700 && width < WIDE_MIN && ox !== width / 2
    ? Math.sign(ox - width / 2) * (diamondWidth / 2 - 8)
    : 0;
  return { left: ox + offset, top: Math.max(8, anchorY - GRID * (tw / 4) - 32) };
}

export function towerLayout(W, cols = GRID) {
  if (W < WIDE_MIN) {
    return { wide: false, ox: W / 2, tw: Math.max(30, Math.min(52, W / 22)) };
  }
  const cardZone = 500; // left padding + 420px card + a gap
  const tw = Math.max(26, Math.min(52, (W - cardZone) / cols - 2, W / 22));
  return { wide: true, ox: (cardZone + W) / 2, tw };
}

export function previewDepth(H, anchorY, tw) {
  return Math.max(10, Math.ceil((H - anchorY) / (tw * 0.5)));
}

export function sceneDepth(H, anchorY, tw, overviewY, overviewTw) {
  return Math.max(previewDepth(H, anchorY, tw), previewDepth(H, overviewY, overviewTw));
}

export function overviewBlockLabels(nextBlocks, labelsEnabled, overviewSettled) {
  const label = (value) => {
    const block = String(value || "").trim();
    return /^\d+$/.test(block) ? `loading block ${block}` : "";
  };
  return Object.fromEntries(Object.keys(nextBlocks || {}).map((node) => [node,
    labelsEnabled && overviewSettled ? label(nextBlocks?.[node]) : ""]));
}

export function overviewLayout(width, count = NODE_IDS.length, height = 900) {
  if (count <= 0) return { contentWidth: width, tw: 0, positions: [], anchors: [] };
  if (count <= 2) {
    const mobile = width <= 700;
    return { contentWidth:width, tw:mobile ? Math.max(12,Math.min(20,width/28)) : Math.max(26,Math.min(46,width/36)), positions:count===1 ? [width/2] : [width*(mobile?0.27:0.32),width*(mobile?0.73:0.68)], anchors:Array(count).fill(height*0.3) };
  }
  const contentWidth = Math.max(width,320);
  const spread = Math.min(contentWidth*0.94,1800);
  const towerSpread = Math.min(spread,1350);
  const patterns = {
    3:[[0.5,0.52],[0.28,0.32],[0.72,0.3]],
    4:[[0.44,0.55],[0.23,0.38],[0.74,0.36],[0.5,0.23]],
    5:[[0.5,0.57],[0.24,0.42],[0.76,0.4],[0.35,0.25],[0.64,0.23]],
    6:[[0.44,0.6],[0.22,0.43],[0.77,0.4],[0.32,0.26],[0.66,0.23],[0.61,0.52]],
    7:[[0.43,0.6],[0.22,0.47],[0.77,0.42],[0.31,0.27],[0.66,0.24],[0.48,0.35],[0.64,0.55]],
  };
  const points=patterns[count]||patterns[7];
  let anchors=points.map(([,y])=>Math.max(155,height*y));
  if(width<=700&&count===7){
    const step=Math.max(52,Math.min(75,(height-265)/6));
    anchors=[6,4,3,1,0,2,5].map((rank)=>155+rank*step);
  }
  return {contentWidth,tw:towerSpread*0.205/GRID,positions:points.map(([x])=>contentWidth/2+(x-0.5)*spread),anchors};
}

if (typeof document !== "undefined") {
  const canvas = document.getElementById("tower");
  const ctx = canvas && canvas.getContext("2d");
  const label = document.getElementById("tower-label");
  const overview = document.getElementById("node-overview");
  const choices = () => [...document.querySelectorAll("[data-select-node]")]
    .filter((choice) => NODE_IDS.includes(choice.dataset.selectNode));
  const overviewLabels = Object.fromEntries(NODE_IDS.map((node) =>
    [node, document.getElementById(`tower-overview-label-${node}`)]));
  if (ctx) {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const N = GRID;
    const PUSH_MS = 800;

    let W = 0, H = 0, dpr = 1;
    function resize() {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = window.innerWidth;
      H = window.innerHeight;
      canvas.width = W * dpr;
      canvas.height = H * dpr;
      canvas.style.width = W + "px";
      canvas.style.height = H + "px";
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    window.addEventListener("resize", resize);
    resize();

    function effectiveLight() {
      const t = document.documentElement.getAttribute("data-theme");
      if (t === "light") return true;
      if (t === "dark") return false;
      return window.matchMedia("(prefers-color-scheme: light)").matches;
    }
    function shade(hex, factor) {
      const value = Number.parseInt(hex.slice(1), 16);
      const channel = (shift) => Math.max(0, Math.min(255, Math.round(((value >> shift) & 255) * factor)));
      return `rgb(${channel(16)}, ${channel(8)}, ${channel(0)})`;
    }
    function palette(node = "bitcoin", active = true) {
      if (!active) {
        return effectiveLight()
          ? { top: "#b7b7b7", side: "#8f8f8f", dark: "#666", grid: "#aaa", edge: "#777", alpha: 0.45, glow: 0 }
          : { top: "#999", side: "#6f6f6f", dark: "#444", grid: "#555", edge: "#aaa", alpha: 0.62, glow: 4 };
      }
      const top = NODE_COLORS[node] || NODE_COLORS.bitcoin;
      return effectiveLight()
        ? { top, side: shade(top, 0.78), dark: shade(top, 0.52), grid: shade(top, 0.78), edge: shade(top, 0.62), alpha: 0.58, glow: 0 }
        : { top, side: shade(top, 0.82), dark: shade(top, 0.48), grid: shade(top, 0.62), edge: shade(top, 1.12), alpha: 0.9, glow: 10 };
    }

    const liveElement = (node) => document.getElementById(node === "bitcoin" ? "live" : `${node}-live`);
    const nextBlocks = () => Object.fromEntries(NODE_IDS.map((node) =>
      [node, liveElement(node)?.dataset?.nextBlock]));

    const activeNode = (node) => document.querySelector(`[data-select-node="${node}"]`)?.dataset.nodeActive !== "0";

    function hideOverviewLabels() {
      for (const element of Object.values(overviewLabels)) if (element) element.hidden = true;
    }

    function showOverviewLabel(node, text, ox, anchorY, tw, opacity = 1) {
      const element = overviewLabels[node];
      if (!element || !text || opacity <= 0.001) return;
      const number = element.querySelector("b");
      number.textContent = text.slice("loading block ".length);
      number.style.color = activeNode(node) ? NODE_COLORS[node] : NODE_COLORS.zcash;
      const position = overviewLabelPosition(W, ox, anchorY, tw);
      element.style.left = `${position.left}px`;
      element.style.top = `${position.top}px`;
      element.style.opacity = String(opacity);
      element.hidden = false;
    }

    function showFocusedLabel(node, progress, ox, anchorY, tw, push = 0) {
      if (!label) return;
      const next = node ? liveElement(node)?.dataset?.nextBlock : "";
      const state = focusedLabelTransition(progress, next);
      label.hidden = state.hidden;
      label.style.opacity = String(state.opacity);
      if (state.hidden) return;
      label.style.setProperty("--accent", activeNode(node) ? NODE_COLORS[node] : NODE_COLORS.zcash);
      const topY = project(0, 0, 0, tw, tw * 0.5, ox, anchorY - push - N * (tw / 4)).y;
      label.style.left = `${ox}px`;
      label.style.top = `${Math.max(8, topY - 40)}px`;
      label.innerHTML = `loading block <b>${next}</b>`;
    }

    function poly(pts, fill, stroke, glow) {
      ctx.beginPath();
      ctx.moveTo(pts[0].x, pts[0].y);
      for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
      ctx.closePath();
      if (fill) {
        ctx.fillStyle = fill;
        ctx.fill();
      }
      if (glow) { ctx.shadowBlur = glow; ctx.shadowColor = stroke; }
      if (stroke) {
        ctx.strokeStyle = stroke;
        ctx.lineWidth = 1;
        ctx.stroke();
      }
      ctx.shadowBlur = 0;
    }

    function line(from, to, stroke) {
      ctx.beginPath();
      ctx.moveTo(from.x, from.y);
      ctx.lineTo(to.x, to.y);
      ctx.strokeStyle = stroke;
      ctx.lineWidth = 1;
      ctx.stroke();
    }

    function drawTowerGlow(p, depth, pal, highlight, opacity = 1, topLayer = 0) {
      if (highlight <= 0.01 || opacity <= 0.01) return;
      ctx.save();
      ctx.globalAlpha = opacity * highlight * (effectiveLight() ? 0.45 : 0.7);
      ctx.shadowBlur = 24 * highlight;
      ctx.shadowColor = pal.top;
      ctx.strokeStyle = pal.top;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(p(0, 0, topLayer).x, p(0, 0, topLayer).y);
      for (const point of [p(GRID, 0, topLayer), p(GRID, 0, -depth - 1), p(GRID, GRID, -depth - 1), p(0, GRID, -depth - 1), p(0, GRID, topLayer)]) {
        ctx.lineTo(point.x, point.y);
      }
      ctx.closePath();
      ctx.stroke();
      ctx.restore();
    }

    function drawTower(node, ox, anchorY, tw, depthCount, fill, pulse, highlight, opacity = 1, push = 0, layerFill = null) {
      const pal = palette(node, activeNode(node));
      const bh = tw * 0.5;
      const p = (gx, gy, layer) => project(gx, gy, 0, tw, bh, ox, anchorY - push - layer * bh - GRID * (tw / 4));
      ctx.globalAlpha=opacity;
      poly([p(0,0,0),p(GRID,0,0),p(GRID,0,-depthCount-1),p(GRID,GRID,-depthCount-1),p(0,GRID,-depthCount-1),p(0,GRID,0)],effectiveLight()?"#f4f4f5":"#0f0f0f",null,0);
      for (let depth = depthCount; depth >= 1; depth--) {
        const fade = Math.max(0.18, 1 - depth / (depthCount * 1.2));
        ctx.globalAlpha = opacity * pal.alpha * fade;
        poly([p(0, GRID, -depth), p(GRID, GRID, -depth), p(GRID, GRID, -depth - 1), p(0, GRID, -depth - 1)], pal.side, pal.edge, 0);
        poly([p(GRID, 0, -depth), p(GRID, GRID, -depth), p(GRID, GRID, -depth - 1), p(GRID, 0, -depth - 1)], pal.dark, pal.edge, 0);
      }
      ctx.globalAlpha = opacity * pal.alpha * 0.55;
      for (let i = 1; i < GRID; i++) line(p(i, GRID, 0), p(i, GRID, -depthCount - 1), pal.edge);
      for (let j = 1; j < GRID; j++) line(p(GRID, j, 0), p(GRID, j, -depthCount - 1), pal.edge);
      const topFill = layerFill === null ? fill : PER_LAYER;
      const done = Math.floor(topFill);
      for (let idx = 0; idx < PER_LAYER; idx++) {
        const { gx, gy } = gridCell(idx);
        const face = [p(gx, gy, 0), p(gx + 1, gy, 0), p(gx + 1, gy + 1, 0), p(gx, gy + 1, 0)];
        if (idx < done) {
          ctx.globalAlpha = opacity * pal.alpha;
          poly(face, pal.top, pal.edge, 0);
        } else if (idx === done) {
          const loading = loadingHighlight(opacity, pulse, pal.glow);
          ctx.globalAlpha = pal.alpha * loading.opacity;
          poly(face, pal.top, pal.edge, loading.glow);
        } else {
          ctx.globalAlpha = opacity * pal.alpha * 0.35;
          poly(face, null, pal.grid, 0);
        }
      }
      if (layerFill !== null) {
        const building = Math.floor(layerFill);
        for (let idx = 0; idx <= building && idx < PER_LAYER; idx++) {
          const { gx, gy } = gridCell(idx);
          const top = [p(gx, gy, 1), p(gx + 1, gy, 1), p(gx + 1, gy + 1, 1), p(gx, gy + 1, 1)];
          if (idx < building) {
            ctx.globalAlpha = opacity * pal.alpha;
            poly([p(gx, gy + 1, 1), p(gx + 1, gy + 1, 1), p(gx + 1, gy + 1, 0), p(gx, gy + 1, 0)], pal.side, pal.edge, 0);
            poly([p(gx + 1, gy, 1), p(gx + 1, gy + 1, 1), p(gx + 1, gy + 1, 0), p(gx + 1, gy, 0)], pal.dark, pal.edge, 0);
            poly(top, pal.top, pal.edge, 0);
          } else {
            const loading = loadingHighlight(opacity, pulse, pal.glow);
            ctx.globalAlpha = pal.alpha * loading.opacity;
            poly(top, pal.top, pal.edge, loading.glow);
          }
        }
      }
      drawTowerGlow(p, depthCount, pal, highlight, opacity, layerFill === null ? 0 : 1);
      ctx.globalAlpha = 1;
    }

    let displayed = null;   // eased fill of today's layer
    let pushStart = -1e9;   // time the last midnight push began
    const previewHighlight = Object.fromEntries(NODE_IDS.map((node) => [node, 0]));
    const knownProgress = Object.fromEntries(NODE_IDS.map((node) => [node, null]));
    const buildProgress = Object.fromEntries(NODE_IDS.map((node) => [node, 0]));
    const previewGeometry = {};
    let scene = { node: "", progress: 0 };
    let prev = performance.now();

    function render(now) {
      const dt = Math.min(100, now - prev);
      prev = now;

      // the fill is the time of day: one cube per 10 UTC minutes
      const target = expectedFill(utcMinutes(new Date()));
      if (displayed === null) displayed = target;
      if (isRollover(target, displayed)) {
        pushStart = now;        // midnight: animate the finished day sliding down
        displayed = target;     // begin the new day
      } else {
        displayed = nextDisplayed(displayed, target, dt);
      }
      const fill = Math.max(0, Math.min(PER_LAYER, displayed));
      const pulse = reduce ? 0.65 : 0.5 + 0.5 * Math.sin(now / 300);

      ctx.clearRect(0, 0, W, H);
      hideOverviewLabels();
      const selected = document.body.dataset.node;
      scene = nextScene(scene.node, selected, scene.progress, dt, reduce);
      const overviewState = overviewTransition(scene.progress, selected);
      const ids = choices().filter(choice => !choice.hidden).map(choice=>choice.dataset.selectNode);
      const layout = overviewLayout(W,ids.length,H);
      const scrollLeft = overview?.scrollLeft || 0;
      for (const node of ids) {
        const index = ids.indexOf(node);
        previewGeometry[node] = nextLayoutPoint(previewGeometry[node], {
          x: layout.positions[index], y: layout.anchors[index], tw: layout.tw,
        }, dt, reduce);
        knownProgress[node] = retainedSyncProgress(liveElement(node)?.dataset?.syncPercent, knownProgress[node]);
        buildProgress[node] = nextBuildProgress(buildProgress[node], (knownProgress[node] ?? 0) / 100, dt, reduce);
      }
      const baseTw = layout.tw;
      const overviewY = (node) => previewGeometry[node]?.y ?? H*0.3;
      const overviewTw = (node) => previewGeometry[node]?.tw ?? baseTw;
      const hovered = document.body.dataset.hoverNode;
      const overviewDepth = (node) => previewDepth(H, overviewY(node), overviewTw(node));
      const overviewX = (node) => (previewGeometry[node]?.x ?? W/2) - scrollLeft;
      const overviewBuild = (node, tw = overviewTw(node), anchorY = overviewY(node), depth = overviewDepth(node)) =>
        constructionGeometry(anchorY, depth, tw, buildProgress[node]);
      const constructionTop = (construction, tw) =>
        construction.anchorY - (construction.layerFill === null ? 0 : tw * 0.5);
      const overviewTop = (node) => constructionTop(overviewBuild(node), overviewTw(node));
      const drawOrder=[...ids].sort((a,b)=>overviewTop(a)-overviewTop(b));
      const sortedAnchors = layout.anchors.slice().sort((a,b)=>a-b);
      const minAnchorGap = Math.min(...sortedAnchors.slice(1).map((anchor,index)=>anchor-sortedAnchors[index]));
      if (overview) {
        overview.hidden = overviewState.hidden;
        overview.style.opacity = String(overviewState.opacity);
        overview.style.pointerEvents = overviewState.interactive ? "" : "none";
        overview.style.setProperty("--overview-width", `${layout.contentWidth}px`);
        choices().forEach((choice) => {
          const index = ids.indexOf(choice.dataset.selectNode);
          if(index<0) return;
          const node = choice.dataset.selectNode;
          choice.style.left = `${previewGeometry[node].x}px`;
          const tw = overviewTw(node);
          const construction = overviewBuild(node, tw);
          const diamondWidth=GRID*tw*1.12;
          const hitWidth=overviewHitWidth(tw);
          const actualTop = constructionTop(construction, tw);
          const controlAnchor = W <= 700 ? Math.min(actualTop, overviewY(node)) : actualTop;
          const geometry=overviewChoiceGeometry(W,controlAnchor,diamondWidth,minAnchorGap,H);
          choice.style.width=`${hitWidth}px`;
          choice.style.top=`${geometry.top}px`;
          choice.style.height=`${geometry.height ?? H-geometry.top}px`;
          choice.style.zIndex=String(Math.round(overviewTop(node)));
          choice.style.paddingTop="0";
          choice.style.setProperty("--tower-shoulder",`${geometry.shoulder}px`);
          choice.style.setProperty("--label-top",`${geometry.labelTop}px`);
        });
      }
      if (!selected && scene.progress === 0) {
        for (const node of drawOrder) {
          previewHighlight[node] = reduce
            ? (hovered === node ? 1 : 0)
            : nextHighlight(previewHighlight[node], hovered === node, dt);
          const tw = overviewTw(node) * (1 + 0.12 * previewHighlight[node]);
          const fullDepth = sceneDepth(H, overviewY(node), tw, overviewY(node), overviewTw(node));
          const construction = overviewBuild(node, tw, overviewY(node), fullDepth);
          drawTower(node, overviewX(node), construction.anchorY, tw,
            construction.depth, fill, pulse, previewHighlight[node], activeNode(node) ? 1 : 0.62, 0, construction.layerFill);
        }
        const blockLabels = overviewBlockLabels(nextBlocks(), document.body.dataset.towerLabels === "1", true);
        for (const node of ids) {
          const tw = overviewTw(node) * (1 + 0.12 * previewHighlight[node]);
          const construction = overviewBuild(node, tw);
          showOverviewLabel(node, blockLabels[node], overviewX(node), constructionTop(construction, tw), tw);
        }
        showFocusedLabel("", 0, 0, 0, 0);
        return;
      }
      if (scene.progress < 1 || selected !== scene.node) {
        const amount = scenePhase(scene.progress).zoomAmount;
        const { ox: focusedX, tw: focusedTw } = towerLayout(W);
        const focusedY = H * 0.6;
        if (scene.node) {
          const startHighlight = previewHighlight[scene.node];
          const startTw = overviewTw(scene.node) * (1 + 0.12 * startHighlight);
          const tw = startTw + (focusedTw - startTw) * amount;
          for (const node of drawOrder) {
            if (node === scene.node) {
              const source = overviewBuild(node, startTw);
              const destination = overviewBuild(node, focusedTw, focusedY, previewDepth(H, focusedY, focusedTw));
              const anchorY = source.anchorY + (destination.anchorY - source.anchorY) * amount;
              drawTower(
                node,
                overviewX(node) + (focusedX - overviewX(node)) * amount,
                anchorY,
                tw,
                source.depth,
                fill,
                pulse,
                startHighlight + (1 - startHighlight) * amount,
                activeNode(node) ? 1 : 0.62 + 0.38 * amount,
                0,
                source.layerFill,
              );
              const focusedConstruction = { ...source, anchorY };
              showFocusedLabel(scene.node, amount,
                overviewX(scene.node) + (focusedX - overviewX(scene.node)) * amount, constructionTop(focusedConstruction, tw), tw);
            } else if (overviewState.opacity > 0.001) {
              const construction = overviewBuild(node);
              drawTower(node, overviewX(node), construction.anchorY, overviewTw(node), construction.depth, fill, pulse, 0,
                (activeNode(node) ? 1 : 0.62) * overviewState.opacity, 0, construction.layerFill);
            }
          }
        } else {
          for (const node of drawOrder) {
            const construction = overviewBuild(node);
            drawTower(node, overviewX(node), construction.anchorY, overviewTw(node), construction.depth, fill, pulse, 0,
              activeNode(node) ? 1 : 0.62, 0, construction.layerFill);
          }
          showFocusedLabel("", 0, 0, 0, 0);
        }
        const blockLabels = overviewBlockLabels(nextBlocks(), document.body.dataset.towerLabels === "1", true);
        for (const node of ids) {
          const tw = overviewTw(node) * (1 + 0.12 * previewHighlight[node]);
          const construction = overviewBuild(node, tw);
          showOverviewLabel(node, blockLabels[node], overviewX(node), constructionTop(construction, tw),
            tw, overviewState.opacity);
        }
        return;
      }
      const { ox, tw } = towerLayout(W);
      const bh = tw * 0.5;
      const anchorY = H * 0.6;
      const push = (1 - smooth((now - pushStart) / PUSH_MS)) * bh; // eases bh -> 0 after a rollover
      const sourceTw = overviewTw(selected) * (1 + 0.12 * previewHighlight[selected]);
      const source = overviewBuild(selected, sourceTw);
      const destination = overviewBuild(selected, tw, anchorY, previewDepth(H, anchorY, tw));
      const construction = { ...source, anchorY: destination.anchorY };
      drawTower(selected, ox, construction.anchorY, tw, construction.depth, fill, pulse, 1, 1, push, construction.layerFill);

      showFocusedLabel(selected, 1, ox, constructionTop(construction, tw), tw, push);
    }

    render(performance.now()); // one static frame (also covers a hidden tab)
    if (!reduce) {
      const frame = (now) => {
        requestAnimationFrame(frame);
        if (document.hidden) { prev = now; return; }
        render(now);
      };
      requestAnimationFrame(frame);
    } else {
      const observer = new MutationObserver(() => render(performance.now()));
      observer.observe(document.body, {
        attributes: true,
        attributeFilter: ["data-hover-node", "data-node", "data-tower-labels"],
      });
      for (const node of NODE_IDS.filter((node) => node !== "bitcoin")) {
        const live = liveElement(node);
        if (live) observer.observe(live, { attributes: true, attributeFilter: ["data-next-block", "data-sync-percent"] });
      }
      window.addEventListener("live-updated", () => render(performance.now()));
      window.addEventListener("node-status-updated", () => render(performance.now()));
    }
    overview?.addEventListener("scroll", () => render(performance.now()), { passive: true });
    window.addEventListener("node-status-updated", () => { if (!reduce) render(performance.now()); });
  }
}
