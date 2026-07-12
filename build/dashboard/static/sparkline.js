// A tiny fee sparkline from /api/fees. No dependencies — a polyline scaled to
// the canvas. The pure `points()` helper is unit-tested; the drawing/fetch
// wiring is guarded on `document`.
export function points(values, w, h, pad = 2) {
  const clean = values.filter((v) => typeof v === "number" && isFinite(v));
  if (clean.length < 2) return [];
  const lo = Math.min(...clean), hi = Math.max(...clean);
  const span = hi - lo || 1;
  const stepX = (w - 2 * pad) / (clean.length - 1);
  return clean.map((v, i) => ({
    x: pad + i * stepX,
    y: h - pad - ((v - lo) / span) * (h - 2 * pad),
  }));
}

if (typeof document !== "undefined") {
  const accent = () =>
    getComputedStyle(document.documentElement).getPropertyValue("--accent").trim() || "#f2a900";

  function draw(canvas, values) {
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = canvas.clientWidth || 160, h = canvas.clientHeight || 28;
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    const pts = points(values, w, h);
    if (!pts.length) return;
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
    ctx.strokeStyle = accent();
    ctx.lineWidth = 1.5;
    ctx.lineJoin = "round";
    ctx.stroke();
    const last = pts[pts.length - 1]; // dot on the latest value
    ctx.fillStyle = accent();
    ctx.beginPath();
    ctx.arc(last.x, last.y, 2, 0, Math.PI * 2);
    ctx.fill();
  }

  let cache = [];
  const render = () => draw(document.getElementById("spark-fee"), cache);

  async function refresh() {
    try {
      const res = await fetch("/api/fees");
      if (!res.ok) return;
      cache = (await res.json()).fee || [];
      render();
    } catch {
      /* offline; keep the last drawing */
    }
  }

  // redraw into the fresh canvas after refresh.js swaps #live, without refetching
  window.addEventListener("live-updated", render);
  refresh();
  setInterval(refresh, 60000);
}
