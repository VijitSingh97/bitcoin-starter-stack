// Refresh the status panel in place instead of reloading the page, so the
// tower animation and the chosen theme never reset. Replaces the old
// <meta http-equiv="refresh">. Fetches the same URL, parses it, and swaps
// only #live — the canvas, theme toggle, and scripts live outside it and
// persist. Loading/ready shell transitions reload so persistent features mount.
const INTERVAL_MS = 30000;

function layout(doc) {
  return `${!!doc.getElementById("watch")}:${!!doc.getElementById("btc-price")}`;
}

export function needsFullReload(current, next) {
  return layout(current) !== layout(next);
}

export function replaceUpdateViews(current, next) {
  for (const id of ["update-notice", "settings-update"]) {
    const currentView = current.getElementById(id);
    const nextView = next.getElementById(id);
    if (currentView && nextView) currentView.replaceWith(nextView);
  }
}

if (typeof document !== "undefined") {
  let reloading = false;

  async function tick() {
    try {
      const res = await fetch(location.pathname, { headers: { "X-Requested-With": "fetch" } });
      if (!res.ok) return;
      const doc = new DOMParser().parseFromString(await res.text(), "text/html");
      if (needsFullReload(document, doc)) {
        if (!reloading) {
          reloading = true;
          window.location.reload();
        }
        return;
      }
      replaceUpdateViews(document, doc);
      const next = doc.getElementById("live");
      const cur = document.getElementById("live");
      if (next && cur) {
        const price = document.getElementById("btc-price");
        const nextPrice = next.querySelector("#btc-price");
        if (price && nextPrice) nextPrice.replaceWith(price);
        cur.replaceWith(next);
        // let the fee sparkline redraw into the fresh canvas
        window.dispatchEvent(new Event("live-updated"));
      }
    } catch {
      /* offline or a blip — try again next tick */
    }
  }

  window.addEventListener("node-power-updated", event => {
    if (event.detail?.id === "bitcoin" && event.detail?.active) tick();
  });
  setInterval(tick, INTERVAL_MS);
}
