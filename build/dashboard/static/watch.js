// Watch-only wallets card: list balances, add a key, remove one. Talks to
// /api/watch. Lives outside #live so the 30s status refresh never clobbers the
// add form mid-typing; the list re-renders on its own poll.
//
// The pure label helper is exported for watch.test.mjs. Wallet names are user
// input, so every name goes in via textContent (never innerHTML) — no XSS.

const CSRF = { "X-Requested-With": "fetch" }; // blocks cross-site form posts
const POLL_MS = 15000;

export function balanceLabel(w) {
  if (w.state === "ok") return `${w.btc} BTC`;
  if (w.state === "scanning") return "scanning…";
  return "—"; // error / not ready
}

if (typeof document !== "undefined") {
  const card = document.getElementById("watch");

  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  };

  // Build the static shell once: heading, live list, add form, warning slot.
  const list = el("div", "watch-list");
  const msg = el("div", "watch-msg");
  const warn = el("div", "watch-warn");

  const form = el("form", "watch-add");
  const name = el("input");
  name.placeholder = "Label (e.g. Cold storage)";
  name.maxLength = 40;
  const key = el("input");
  key.placeholder = "xpub / zpub / descriptor";
  const bday = el("input");
  bday.type = "date";
  bday.title = "Wallet birthday (optional) — bounds the first rescan";
  const add = el("button", null, "Add");
  add.type = "submit";
  form.append(name, key, bday, add);

  const shell = () => {
    card.append(el("h2", null, "Watch-only balances"), list, form, msg, warn);
  };

  const renderList = (view) => {
    list.textContent = "";
    for (const w of view.wallets) {
      const row = el("div", "row");
      row.append(el("span", "label", w.name));
      const right = el("span", "watch-right");
      right.append(el("span", null, balanceLabel(w)));
      const x = el("button", "watch-x", "✕");
      x.type = "button";
      x.title = `Remove ${w.name}`;
      x.addEventListener("click", () => remove(w.name));
      right.append(x);
      row.append(right);
      list.append(row);
    }
    if (view.show_total) {
      const t = el("div", "row total");
      t.append(el("span", "label", "Total"), el("span", null, `${view.total} BTC`));
      list.append(t);
    }
    warn.textContent = view.has_password ? "" :
      "No dashboard password set — anyone who can reach this page can add or remove wallets.";
  };

  async function refresh() {
    try {
      const res = await fetch("/api/watch", { headers: CSRF });
      if (res.ok) renderList(await res.json());
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

  shell();
  card.hidden = false;
  refresh();
  setInterval(refresh, POLL_MS);
}
