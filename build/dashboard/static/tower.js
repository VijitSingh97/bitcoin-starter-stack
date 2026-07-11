// A live tower of the blockchain, read as a day-clock. A 12x12 layer is one
// UTC day: the first cube is the first block after 00:00, and cubes fill as
// blocks arrive through the day (~144 of them). At the next midnight the day
// completes, the tower is pushed down a level, and a fresh day starts on top.
// The header reads "loading block N" — the next block the network is working
// on. Colours follow the bitcoin accent and the light/dark theme.
//
// The dashboard renders the counts onto #live (data-day-blocks, data-blocks,
// data-next-block) and refresh.js keeps them current. Pure helpers are
// exported for tower.test.mjs; the canvas wiring is guarded on `document`.
export const GRID = 12;
export const PER_LAYER = GRID * GRID; // 144 blocks ≈ one day
const ROLLOVER_DROP = 12; // a fall this far below the shown fill = a new day (or restart)

// Fill order of cube `index` (0..143): row by row, back to front.
export function gridCell(index, cols = GRID) {
  return { gx: index % cols, gy: Math.floor(index / cols) };
}

// A big drop in the day's block count means the day rolled over (or the
// container restarted) — the layer should complete and a fresh one begin.
export function isRollover(target, displayed) {
  return target < displayed - ROLLOVER_DROP;
}

// Ease the shown fill toward the target: snap a small dip, rip up a big jump
// (a fresh page mid-day), drift a single new block in over ~0.8s.
export function nextDisplayed(current, target, dtMs) {
  if (target <= current) return target;
  const gap = target - current;
  const perMs = gap > 24 ? 0.06 : 0.00125; // catch up vs. a single block drifting in
  return Math.min(target, current + perMs * dtMs);
}

export function project(gx, gy, z, tw, bh, ox, oy) {
  return { x: ox + (gx - gy) * (tw / 2), y: oy + (gx + gy) * (tw / 4) - z * bh };
}

export function smooth(t) {
  const x = Math.min(1, Math.max(0, t));
  return x * x * (3 - 2 * x);
}

export function towerLayout(W, cols = GRID) {
  if (W < 900) {
    return { wide: false, ox: W / 2, tw: Math.max(30, Math.min(52, W / 22)) };
  }
  const cardZone = 500; // left padding + 420px card + a gap
  const tw = Math.max(26, Math.min(52, (W - cardZone) / cols - 2, W / 22));
  return { wide: true, ox: (cardZone + W) / 2, tw };
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
    function palette() {
      return effectiveLight()
        ? { top: "#e6ad2e", side: "#c07f12", dark: "#8a5c06", grid: "#c9962e", empty: "#dcc79a", edge: "#9c6500", alpha: 0.55, glow: 0 }
        : { top: "#ffd873", side: "#f2a900", dark: "#9a6a08", grid: "#5a4413", empty: "#3a2e10", edge: "#ffe08a", alpha: 0.95, glow: 10 };
    }

    const liveData = () => {
      const el = document.getElementById("live");
      return (el && el.dataset) || {};
    };
    function dayBlocks() {
      const n = parseInt(liveData().dayBlocks, 10);
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

    let displayed = null;   // eased fill of today's layer
    let pushStart = -1e9;   // time the last day-rollover push began
    let synthetic = 0;      // gentle fill before the node is up
    let prev = performance.now();

    function render(now) {
      const dt = Math.min(100, now - prev);
      prev = now;

      let target = dayBlocks();
      if (target === null) {
        synthetic = (synthetic + dt * 0.004) % PER_LAYER; // slow loop on the loading screen
        target = synthetic;
      }
      if (displayed === null) displayed = target;
      if (isRollover(target, displayed)) {
        pushStart = now;        // animate the finished day sliding down
        displayed = target;     // begin the new day
      } else {
        displayed = nextDisplayed(displayed, target, dt);
      }
      const fill = Math.max(0, Math.min(PER_LAYER, displayed));

      ctx.clearRect(0, 0, W, H);
      const pal = palette();
      const { ox, tw } = towerLayout(W);
      const bh = tw * 0.5;
      const anchorY = H * 0.6;
      const push = (1 - smooth((now - pushStart) / PUSH_MS)) * bh; // eases bh -> 0 after a rollover

      // vertex of cell (gx,gy) on the top surface of layer `k` (0 = today's
      // top; negative below is a finished day)
      const p = (gx, gy, k) =>
        project(gx, gy, 0, tw, bh, ox, anchorY + (0 - k) * bh - push - N * (tw / 4));

      // finished days below, near-to-far
      const visible = Math.min(22, Math.ceil((H - anchorY) / bh) + 2);
      for (let d = visible; d >= 1; d--) {
        const fade = Math.max(0.15, 1 - d * 0.06);
        ctx.globalAlpha = pal.alpha * fade;
        for (let i = 0; i < N; i++) {
          poly([p(i, N, -d), p(i + 1, N, -d), p(i + 1, N, -d - 1), p(i, N, -d - 1)], pal.side, pal.edge, 0);
        }
        for (let j = 0; j < N; j++) {
          poly([p(N, j, -d), p(N, j + 1, -d), p(N, j + 1, -d - 1), p(N, j, -d - 1)], pal.dark, pal.edge, 0);
        }
      }

      // today's layer: a 12x12 grid filling one cube per block
      const done = Math.floor(fill);
      const frac = fill - done;
      for (let idx = 0; idx < PER_LAYER; idx++) {
        const { gx, gy } = gridCell(idx);
        const face = [p(gx, gy, 0), p(gx + 1, gy, 0), p(gx + 1, gy + 1, 0), p(gx, gy + 1, 0)];
        if (idx < done) {
          ctx.globalAlpha = pal.alpha;
          poly(face, pal.top, pal.edge, pal.glow);
        } else if (idx === done) {
          ctx.globalAlpha = pal.alpha * frac; // the arriving block fades in
          poly(face, pal.top, pal.edge, pal.glow);
        } else {
          ctx.globalAlpha = pal.alpha * 0.5;
          poly(face, pal.empty, pal.grid, 0);
        }
      }
      ctx.globalAlpha = 1;

      // "loading block N" header above the tower's back corner
      if (label) {
        const next = liveData().nextBlock;
        if (next) {
          const topY = p(0, 0, 0).y;
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
      const FRAME_MS = 1000 / 30;
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
