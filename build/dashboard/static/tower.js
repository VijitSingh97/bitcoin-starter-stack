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
// Side-by-side card + tower (and balances floating above the tower) only above
// this width; below it everything stacks. Kept in sync with the CSS media
// queries. Set high enough that the ~460px balances block clears the card and
// the viewport edge (a squeeze in the 900–1024 range looked broken).
export const WIDE_MIN = 1024;
const ROLLOVER_DROP = 12; // a fall this far below the shown fill = midnight rolled over

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

export function nextScene(scene, requested, progress, dtMs, reduce = false) {
  if (reduce) return { node: requested, progress: requested ? 1 : 0 };
  let node = scene;
  let value = progress;
  if (requested !== node && value <= 0.001) node = requested;
  const opening = !!requested && requested === node;
  value = nextHighlight(value, opening, dtMs);
  if (opening && value >= 0.999) value = 1;
  if (!opening && value <= 0.001) {
    value = 0;
    node = requested;
  }
  return { node, progress: value };
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
  return Math.max(10, Math.ceil((H - anchorY - GRID * (tw / 4)) / (tw * 0.5)));
}

export function sceneDepth(H, anchorY, tw, overviewY, overviewTw) {
  return Math.max(previewDepth(H, anchorY, tw), previewDepth(H, overviewY, overviewTw));
}

if (typeof document !== "undefined") {
  const canvas = document.getElementById("tower");
  const ctx = canvas && canvas.getContext("2d");
  const label = document.getElementById("tower-label");
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
    function palette(node = "bitcoin") {
      if (node === "monero") {
        return effectiveLight()
          ? { top: "#ff8a3d", side: "#d94f00", dark: "#943800", grid: "#d28a5b", edge: "#b64200", alpha: 0.6, glow: 0 }
          : { top: "#ff9b59", side: "#ff6600", dark: "#9f3f00", grid: "#704227", edge: "#ffb17d", alpha: 0.95, glow: 10 };
      }
      return effectiveLight()
        ? { top: "#e6ad2e", side: "#c07f12", dark: "#8a5c06", grid: "#caa250", edge: "#9c6500", alpha: 0.55, glow: 0 }
        : { top: "#ffd873", side: "#f2a900", dark: "#9a6a08", grid: "#6b5320", edge: "#ffe08a", alpha: 0.95, glow: 10 };
    }

    const liveData = () => {
      const el = document.body.dataset.node === "monero"
        ? document.getElementById("monero-live")
        : document.getElementById("live");
      return (el && el.dataset) || {};
    };

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
      ctx.strokeStyle = stroke;
      ctx.lineWidth = 1;
      ctx.stroke();
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

    function drawTowerGlow(p, depth, pal, highlight, opacity = 1) {
      if (highlight <= 0.01 || opacity <= 0.01) return;
      ctx.save();
      ctx.globalAlpha = opacity * highlight * (effectiveLight() ? 0.45 : 0.7);
      ctx.shadowBlur = 24 * highlight;
      ctx.shadowColor = pal.top;
      ctx.strokeStyle = pal.top;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(p(0, 0, 0).x, p(0, 0, 0).y);
      for (const point of [p(GRID, 0, 0), p(GRID, 0, -depth - 1), p(GRID, GRID, -depth - 1), p(0, GRID, -depth - 1), p(0, GRID, 0)]) {
        ctx.lineTo(point.x, point.y);
      }
      ctx.closePath();
      ctx.stroke();
      ctx.restore();
    }

    function drawTower(node, ox, anchorY, tw, depthCount, fill, pulse, highlight, opacity = 1, push = 0) {
      const pal = palette(node);
      const bh = tw * 0.5;
      const p = (gx, gy, layer) => project(gx, gy, 0, tw, bh, ox, anchorY - push - layer * bh - GRID * (tw / 4));
      for (let depth = depthCount; depth >= 1; depth--) {
        const fade = Math.max(0.18, 1 - depth / (depthCount * 1.2));
        ctx.globalAlpha = opacity * pal.alpha * fade;
        poly([p(0, GRID, -depth), p(GRID, GRID, -depth), p(GRID, GRID, -depth - 1), p(0, GRID, -depth - 1)], pal.side, pal.edge, 0);
        poly([p(GRID, 0, -depth), p(GRID, GRID, -depth), p(GRID, GRID, -depth - 1), p(GRID, 0, -depth - 1)], pal.dark, pal.edge, 0);
      }
      ctx.globalAlpha = opacity * pal.alpha * 0.55;
      for (let i = 1; i < GRID; i++) line(p(i, GRID, 0), p(i, GRID, -depthCount - 1), pal.edge);
      for (let j = 1; j < GRID; j++) line(p(GRID, j, 0), p(GRID, j, -depthCount - 1), pal.edge);
      const done = Math.floor(fill);
      for (let idx = 0; idx < PER_LAYER; idx++) {
        const { gx, gy } = gridCell(idx);
        const face = [p(gx, gy, 0), p(gx + 1, gy, 0), p(gx + 1, gy + 1, 0), p(gx, gy + 1, 0)];
        if (idx < done) {
          ctx.globalAlpha = opacity * pal.alpha;
          poly(face, pal.top, pal.edge, 0);
        } else if (idx === done) {
          ctx.globalAlpha = opacity * pal.alpha * (0.2 + 0.7 * pulse);
          poly(face, pal.top, pal.edge, pal.glow + 12 * pulse);
        } else {
          ctx.globalAlpha = opacity * pal.alpha * 0.35;
          poly(face, null, pal.grid, 0);
        }
      }
      drawTowerGlow(p, depthCount, pal, highlight, opacity);
      ctx.globalAlpha = 1;
    }

    let displayed = null;   // eased fill of today's layer
    let pushStart = -1e9;   // time the last midnight push began
    const previewHighlight = { bitcoin: 0, monero: 0 };
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
      const selected = document.body.dataset.node;
      scene = nextScene(scene.node, selected, scene.progress, dt, reduce);
      const mobile = W <= 700;
      const baseTw = mobile ? Math.max(12, Math.min(20, W / 28)) : Math.max(26, Math.min(46, W / 36));
      const overviewY = H * 0.3;
      const hovered = document.body.dataset.hoverNode;
      const overviewDepth = previewDepth(H, overviewY, baseTw);
      if (!selected && scene.progress === 0) {
        for (const node of ["bitcoin", "monero"]) {
          previewHighlight[node] = reduce
            ? (hovered === node ? 1 : 0)
            : nextHighlight(previewHighlight[node], hovered === node, dt);
        }
        const bitcoinTw = baseTw * (1 + 0.12 * previewHighlight.bitcoin);
        const moneroTw = baseTw * (1 + 0.12 * previewHighlight.monero);
        drawTower("bitcoin", W * (mobile ? 0.27 : 0.32), overviewY, bitcoinTw, sceneDepth(H, overviewY, bitcoinTw, overviewY, baseTw), fill, pulse, previewHighlight.bitcoin);
        drawTower("monero", W * (mobile ? 0.73 : 0.68), overviewY, moneroTw, sceneDepth(H, overviewY, moneroTw, overviewY, baseTw), fill, pulse, previewHighlight.monero);
        if (label) {
          label.hidden = true;
          label.style.opacity = "0";
        }
        return;
      }
      if (scene.progress < 1 || selected !== scene.node) {
        const amount = smooth(scene.progress);
        const { ox: focusedX, tw: focusedTw } = towerLayout(W);
        const focusedY = H * 0.6;
        const overviewX = (node) => W * (mobile ? (node === "bitcoin" ? 0.27 : 0.73) : (node === "bitcoin" ? 0.32 : 0.68));
        const other = scene.node === "bitcoin" ? "monero" : "bitcoin";
        if (scene.node) {
          const startHighlight = previewHighlight[scene.node];
          const startTw = baseTw * (1 + 0.12 * startHighlight);
          if (amount < 0.99) drawTower(other, overviewX(other), overviewY, baseTw, overviewDepth, fill, pulse, 0, 1 - amount);
          const anchorY = overviewY + (focusedY - overviewY) * amount;
          const tw = startTw + (focusedTw - startTw) * amount;
          drawTower(
            scene.node,
            overviewX(scene.node) + (focusedX - overviewX(scene.node)) * amount,
            anchorY,
            tw,
            sceneDepth(H, anchorY, tw, overviewY, baseTw),
            fill,
            pulse,
            startHighlight + (1 - startHighlight) * amount,
          );
        } else {
          drawTower("bitcoin", overviewX("bitcoin"), overviewY, baseTw, overviewDepth, fill, pulse, 0);
          drawTower("monero", overviewX("monero"), overviewY, baseTw, overviewDepth, fill, pulse, 0);
        }
        if (label) {
          label.hidden = true;
          label.style.opacity = "0";
        }
        return;
      }
      if (label) label.hidden = false;
      const { ox, tw } = towerLayout(W);
      const bh = tw * 0.5;
      const anchorY = H * 0.6;
      const push = (1 - smooth((now - pushStart) / PUSH_MS)) * bh; // eases bh -> 0 after a rollover
      const visible = sceneDepth(H, anchorY, tw, overviewY, baseTw);
      drawTower(selected, ox, anchorY, tw, visible, fill, pulse, 1, 1, push);

      // "loading block N" header above the tower's back corner
      if (label) {
        const next = liveData().nextBlock;
        if (next) {
          const topY = project(0, 0, 0, tw, bh, ox, anchorY - push - N * (tw / 4)).y;
          label.style.left = ox + "px";
          label.style.top = Math.max(8, topY - 40) + "px";
          label.innerHTML = 'loading block <b>' + next + "</b>";
          label.style.opacity = "1";
        } else {
          label.style.opacity = "0";
        }
      }
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
      new MutationObserver(() => render(performance.now())).observe(document.body, {
        attributes: true,
        attributeFilter: ["data-hover-node", "data-node"],
      });
    }
  }
}
