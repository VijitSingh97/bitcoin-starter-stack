// A 5x5 isometric tower of blocks that endlessly builds upward behind the
// card, in the bitcoin-yellow accent. The base sits at the bottom of the
// page; the camera climbs so new layers keep appearing while older ones
// scroll off — "built from the bottom, up and up".
//
// Pure projection/timing helpers are exported for tower.test.mjs; the canvas
// wiring is guarded on `document` so importing in Node touches nothing.
export const GRID = 5;

// Screen point of lattice vertex (gx, gy) at height level z, given tile
// width tw (tile height = tw/2) and block height bh, around an origin.
export function project(gx, gy, z, tw, bh, ox, oy) {
  return {
    x: ox + (gx - gy) * (tw / 2),
    y: oy + (gx + gy) * (tw / 4) - z * bh,
  };
}

// Layers built after `ms` at `layerMs` each (float: the fraction is the
// newest layer easing in). Never negative.
export function layersAt(ms, layerMs) {
  return Math.max(0, ms) / layerMs;
}

// Smoothstep for the newest layer's fade-in.
export function smooth(t) {
  const x = Math.min(1, Math.max(0, t));
  return x * x * (3 - 2 * x);
}

if (typeof document !== "undefined") {
  const canvas = document.getElementById("tower");
  if (canvas) {
    const ctx = canvas.getContext("2d");
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const N = GRID;
    const LAYER_MS = 2000; // a new layer every 2s — slow and deliberate

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
      // light mode needs darker, more opaque gold to read on a white page
      return effectiveLight()
        ? { top: "#e0a72a", left: "#c07f12", right: "#8a5c06", edge: "#9c6500", alpha: 0.5, glow: 0 }
        : { top: "#ffce5e", left: "#f2a900", right: "#9a6a08", edge: "#ffdd8a", alpha: 0.92, glow: 14 };
    }

    function quad(pts, fill, stroke, glow) {
      ctx.beginPath();
      ctx.moveTo(pts[0].x, pts[0].y);
      for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
      ctx.closePath();
      ctx.fillStyle = fill;
      ctx.fill();
      ctx.shadowBlur = glow;
      ctx.shadowColor = stroke;
      ctx.strokeStyle = stroke;
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.shadowBlur = 0;
    }

    // Fade layers into darkness near the top and bottom of the viewport so
    // the pillar emerges from and dissolves into the background.
    function edgeFade(y) {
      const top = H * 0.16, bot = H * 0.86;
      if (y < top) return smooth(y / top);
      if (y > bot) return smooth((H - y) / (H - bot));
      return 1;
    }

    function render(built) {
      ctx.clearRect(0, 0, W, H);
      const pal = palette();

      // tile + block size scale with viewport; the tower is a touch wider
      // than the 420px card so its edges flank it
      const tw = Math.max(48, Math.min(104, W / 12));
      const bh = tw * 0.5;
      const ox = W / 2;

      // origin scrolls upward over time: an endless pillar whose blocks
      // rise from the bottom and flow off the top
      const oy = H * 0.95 - built * bh;
      const p = (gx, gy, z) => project(gx, gy, z, tw, bh, ox, oy);

      // only the vertical band of levels that intersects the viewport
      const front = oy + (2 * N - 2) * (tw / 4);
      const zLo = Math.floor((front - H - bh) / bh);
      const zHi = Math.ceil((front + bh) / bh);

      for (let z = zLo; z <= zHi; z++) {
        const a = pal.alpha * edgeFade(p(2, 2, z).y);
        if (a <= 0.01) continue;
        ctx.globalAlpha = a;
        for (let i = 0; i < N; i++) {
          // left wall (j = N face)
          quad([p(i, N, z), p(i + 1, N, z), p(i + 1, N, z + 1), p(i, N, z + 1)],
            pal.left, pal.edge, pal.glow);
        }
        for (let j = 0; j < N; j++) {
          // right wall (i = N face)
          quad([p(N, j, z), p(N, j + 1, z), p(N, j + 1, z + 1), p(N, j, z + 1)],
            pal.right, pal.edge, pal.glow);
        }
      }
      ctx.globalAlpha = 1;
    }

    const START_LAYERS = 4; // start part-built so the tower fills the screen
    render(START_LAYERS); // paint at once (also covers an already-hidden tab)
    if (!reduce) {
      // ~30fps is plenty for a slow drift and halves the CPU vs. rAF's 60
      const FRAME_MS = 1000 / 30;
      const start = performance.now() - START_LAYERS * LAYER_MS; // continue from the static frame
      let last = 0;
      const frame = (now) => {
        requestAnimationFrame(frame);
        if (document.hidden || now - last < FRAME_MS) return;
        last = now;
        render(layersAt(now - start, LAYER_MS));
      };
      requestAnimationFrame(frame);
    }
  }
}
