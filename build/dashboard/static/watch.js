// Watch-only wallets. The card (#watch) is the manager — each wallet's label +
// a truncated key you can click to expand, a remove ✕, and the add form. The
// balances themselves render in gold above the tower (#tower-stats): per-wallet,
// plus a total once there's more than one. Talks to /api/watch.
//
// Lives outside #live so the 30s status refresh never clobbers the add form.
// Every bit of user data (labels, keys) goes in via textContent — no XSS.
import { towerLayout } from "./tower.js";
import { points } from "./sparkline.js";

const CSRF = { "X-Requested-With": "fetch" }; // blocks cross-site form posts
const POLL_MS = 15000;

export function balanceLabel(w) {
  if (w.state === "ok") return `${w.btc} BTC`;
  if (w.state === "scanning") return "scanning…";
  return "—"; // error / not ready
}

// first 4 … last 4 of a key/address/descriptor; full string if it's short.
export function shortKey(k) {
  return k.length > 12 ? `${k.slice(0, 4)}…${k.slice(-4)}` : k;
}

if (typeof document !== "undefined") {
  const card = document.getElementById("watch");
  const stats = document.getElementById("tower-stats");

  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  };

  // --- manager card: heading, wallet list, add form, warning ---
  const list = el("div", "watch-list");
  const msg = el("div", "watch-msg");
  const warn = el("div", "watch-warn");

  const form = el("form", "watch-add");
  const name = el("input");
  name.placeholder = "Label (e.g. Cold storage)";
  name.maxLength = 40;
  const key = el("input");
  key.placeholder = "xpub / zpub / address / descriptor";
  const bday = el("input");
  bday.type = "date";
  bday.title = "Wallet birthday (optional) — bounds the first rescan";
  const add = el("button", null, "Add");
  add.type = "submit";
  form.append(name, key, bday, add);
  const hint = el("div", "watch-hint",
    "Tip: set the birthday (the date the wallet was first used) to skip years of rescanning.");

  card.append(el("h2", null, "Watch-only wallets"), list, form, hint, msg, warn);

  const renderManager = (view) => {
    list.textContent = "";
    for (const w of view.wallets) {
      const row = el("div", "row");
      const left = el("div", "wk-cell");
      left.append(el("span", "label", w.name));
      // truncated key, click to expand/collapse
      const k = el("span", "wk", shortKey(w.key));
      k.title = "click to expand";
      k.addEventListener("click", () => {
        k.textContent = k.textContent === w.key ? shortKey(w.key) : w.key;
      });
      left.append(k);
      row.append(left);
      const x = el("button", "watch-x", "✕");
      x.type = "button";
      x.title = `Remove ${w.name}`;
      x.addEventListener("click", () => remove(w.name));
      row.append(x);
      list.append(row);
    }
    warn.textContent = view.has_password ? "" :
      "No dashboard password set — anyone who can reach this page can add or remove wallets.";
  };

  // --- gold balances above the tower ---
  const renderStats = (view) => {
    stats.textContent = "";
    if (!view.wallets.length) { stats.hidden = true; return; }
    stats.hidden = false;
    for (const w of view.wallets) {
      const row = el("div", "ws-row");
      row.append(el("span", "ws-name", w.name), el("span", null, balanceLabel(w)));
      if (w.history && w.history.length >= 2) {
        const spark = document.createElement("canvas");
        spark.className = "ws-spark";
        row.append(spark);
        drawSpark(spark, w.history);
      }
      stats.append(row);
    }
    if (view.show_total) {
      const t = el("div", "ws-total");
      t.append(el("span", null, `${view.total} BTC`));
      stats.append(el("div", "ws-total-label", "total"), t);
    }
    placeStats();
  };

  // a tiny gold sparkline of a wallet's persisted balance history
  function drawSpark(canvas, values) {
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = 64, h = 16;
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    canvas.style.width = w + "px";
    canvas.style.height = h + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const pts = points(values, w, h);
    if (!pts.length) return;
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
    ctx.strokeStyle = getComputedStyle(document.documentElement)
      .getPropertyValue("--accent").trim() || "#f2a900";
    ctx.lineWidth = 1.2;
    ctx.lineJoin = "round";
    ctx.stroke();
  }

  // On desktop the balances float above the tower, centred on its axis; JS only
  // sets the horizontal centre (the CSS pins the top). On mobile they sit in the
  // normal flow at the top of the column.
  function placeStats() {
    if (window.innerWidth >= 900) {
      stats.style.left = towerLayout(window.innerWidth).ox + "px";
    } else {
      stats.style.left = "";
    }
  }
  window.addEventListener("resize", placeStats);

  let last = { wallets: [] };
  const render = (view) => { last = view; renderManager(view); renderStats(view); };

  async function refresh() {
    try {
      const res = await fetch("/api/watch", { headers: CSRF });
      if (res.ok) render(await res.json());
    } catch { /* blip — next poll */ }
  }

  async function remove(walletName) {
    msg.textContent = "";
    try {
      const res = await fetch(`/api/watch/${encodeURIComponent(walletName)}`,
                             { method: "DELETE", headers: CSRF });
      if (!res.ok) msg.textContent = await res.text();
    } catch { msg.textContent = "Network error."; }
    refresh();
  }

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    msg.textContent = "";
    add.disabled = true;
    try {
      const res = await fetch("/api/watch", {
        method: "POST",
        headers: { ...CSRF, "Content-Type": "application/json" },
        body: JSON.stringify({ name: name.value, key: key.value, birthday: bday.value }),
      });
      if (res.ok) {
        name.value = key.value = bday.value = "";
        msg.textContent = "Added — scanning the chain for its history…";
      } else {
        msg.textContent = await res.text();
      }
    } catch { msg.textContent = "Network error."; }
    add.disabled = false;
    refresh();
  });

  card.hidden = false;
  refresh();
  setInterval(refresh, POLL_MS);
}
