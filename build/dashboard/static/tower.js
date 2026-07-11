// A live tower of the blockchain: a 12x12 layer is 144 blocks — about one
// day (a block every ~10 min). Each real block adds a cube to the top layer;
// when a layer fills (a full day), the tower is pushed down a level and the
// oldest layers slide off the bottom of the page. During initial sync, blocks
// pour in and the tower builds up fast. Colours follow the bitcoin accent and
// the light/dark theme.
//
// The block height is read from the #live panel's data-blocks attribute, which
// the server renders and refresh.js keeps current. Pure model helpers are
// exported for tower.test.mjs; the canvas wiring is guarded on `document`.
export const GRID = 12;
export const PER_LAYER = GRID * GRID; // 144 blocks ≈ one day

// Split a height into a completed-layer count and the fill of the top layer.
export function layerFill(height, perLayer = PER_LAYER) {
  const h = Math.max(0, height);
  return { layer: Math.floor(h / perLayer), fill: h - Math.floor(h / perLayer) * perLayer };
}

// Fill order of cube `index` (0..143) within a layer: row by row, back to
// front, so the layer accretes toward the viewer.
export function gridCell(index, cols = GRID) {
  return { gx: index % cols, gy: Math.floor(index / cols) };
}

// Ease the displayed height toward the real one: snap on a dip (reorg), rip
// upward when far behind (initial sync), and let a single new block drift in
// over ~0.8s when synced.
export function nextDisplayed(current, target, dtMs) {
  if (target <= current) return target;
  const gap = target - current;
  const perMs = gap > 2 * PER_LAYER ? 0.36 : 0.00125; // 360/s catching up, ~1.25/s synced
  return Math.min(target, current + perMs * dtMs);
}

// Screen point of lattice vertex (gx, gy) at height z.
export function project(gx, gy, z, tw, bh, ox, oy) {
  return { x: ox + (gx - gy) * (tw / 2), y: oy + (gx + gy) * (tw / 4) - z * bh };
}

export function smooth(t) {
  const x = Math.min(1, Math.max(0, t));
  return x * x * (3 - 2 * x);
}

if (typeof document !== "undefined") {
  const canvas = document.getElementById("tower");
  const ctx = canvas && canvas.getContext("2d");
  if (ctx) {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const N = GRID;
    const PUSH_MS = 800; // layer-complete push-down duration

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
    function palette() {
      return effectiveLight()
        ? { top: "#e6ad2e", side: "#c07f12", dark: "#8a5c06", grid: "#b98a2e", empty: "#c9962e", edge: "#9c6500", alpha: 0.55, glow: 0 }
        : { top: "#ffd873", side: "#f2a900", dark: "#9a6a08", grid: "#5a4413", empty: "#3a2e10", edge: "#ffe08a", alpha: 0.95, glow: 10 };
    }

    // The real block height, or null on the loading page (RPC not up yet).
    function realHeight() {
      const el = document.getElementById("live");
      const b = el && el.dataset ? el.dataset.blocks : "";
      const n = parseInt(b, 10);
      return Number.isFinite(n) ? n : null;
    }

    function poly(pts, fill, stroke, glow) {
      ctx.beginPath();
      ctx.moveTo(pts[0].x, pts[0].y);
      for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
      ctx.closePath();
      ctx.fillStyle = fill;
      ctx.fill();
      if (glow) { ctx.shadowBlur = glow; ctx.shadowColor = stroke; }
      ctx.strokeStyle = stroke;
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.shadowBlur = 0;
    }

    let displayed = null;   // eased height
    let lastLayer = null;   // to detect a completed layer
    let pushStart = -1e9;   // time the last push-down began
    let synthetic = 0;      // fallback build when no real height yet
    let prev = performance.now();

    function render(now) {
      const dt = Math.min(100, now - prev);
      prev = now;

      // resolve the target height (real, else a slow synthetic climb)
      let target = realHeight();
      if (target === null) {
        synthetic += dt * 0.0006; // ~1 block / 1.6s on the loading screen
        target = Math.floor(synthetic);
      } else if (displayed === null) {
        displayed = Math.max(0, target - 300); // brief intro build on first load
      }
      if (displayed === null) displayed = target;
      displayed = nextDisplayed(displayed, target, dt);

      const { layer: L, fill } = layerFill(displayed);
      if (lastLayer !== null && L !== lastLayer) pushStart = now;
      lastLayer = L;

      ctx.clearRect(0, 0, W, H);
      const pal = palette();
      const tw = Math.max(30, Math.min(52, W / 22));
      const bh = tw * 0.5;
      const ox = W / 2;
      const anchorY = H * 0.6;                 // top layer's centre sits here
      const push = (1 - smooth((now - pushStart) / PUSH_MS)) * bh; // eases bh -> 0

      // vertex of cell (gx,gy) on the top surface of layer `k` (k=L is the
      // in-progress top; smaller k are completed layers below)
      const p = (gx, gy, k) =>
        project(gx, gy, 0, tw, bh, ox, anchorY + (L - k) * bh - push - N * (tw / 4));

      // completed layers below the top, near-to-far so lower ones sit behind
      const visible = Math.min(22, Math.ceil((H - anchorY) / bh) + 2);
      for (let d = visible; d >= 1; d--) {
        const k = L - d;
        if (k < 0) continue;
        const fade = Math.max(0.15, 1 - d * 0.06);
        ctx.globalAlpha = pal.alpha * fade;
        for (let i = 0; i < N; i++) {
          poly([p(i, N, k), p(i + 1, N, k), p(i + 1, N, k - 1), p(i, N, k - 1)], pal.side, pal.edge, 0);
        }
        for (let j = 0; j < N; j++) {
          poly([p(N, j, k), p(N, j + 1, k), p(N, j + 1, k - 1), p(N, j, k - 1)], pal.dark, pal.edge, 0);
        }
      }

      // in-progress top layer: a 12x12 grid filling cube by cube
      const done = Math.floor(fill);
      const frac = fill - done;
      for (let idx = 0; idx < PER_LAYER; idx++) {
        const { gx, gy } = gridCell(idx);
        const face = [p(gx, gy, L), p(gx + 1, gy, L), p(gx + 1, gy + 1, L), p(gx, gy + 1, L)];
        if (idx < done) {
          ctx.globalAlpha = pal.alpha;
          poly(face, pal.top, pal.edge, pal.glow);
        } else if (idx === done) {
          ctx.globalAlpha = pal.alpha * frac; // the arriving block fades in
          poly(face, pal.top, pal.edge, pal.glow);
        } else {
          ctx.globalAlpha = pal.alpha * 0.5;
          poly(face, pal.empty, pal.grid, 0); // waiting slot
        }
      }
      ctx.globalAlpha = 1;
    }

    if (reduce) {
      prev = performance.now();
      render(performance.now()); // one static frame
    } else {
      const FRAME_MS = 1000 / 30; // 30fps is plenty and halves the CPU
      let last = 0;
      const frame = (now) => {
        requestAnimationFrame(frame);
        if (document.hidden) { prev = now; return; }
        if (now - last < FRAME_MS) return;
        last = now;
        render(now);
      };
      requestAnimationFrame(frame);
    }
  }
}
