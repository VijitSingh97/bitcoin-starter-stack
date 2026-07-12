// Refresh the status panel in place instead of reloading the page, so the
// tower animation and the chosen theme never reset. Replaces the old
// <meta http-equiv="refresh">. Fetches the same URL, parses it, and swaps
// only #live — the canvas, theme toggle, and scripts live outside it and
// persist. A loading <-> ready transition is just a different #live.
const INTERVAL_MS = 30000;

async function tick() {
  try {
    const res = await fetch(location.pathname, { headers: { "X-Requested-With": "fetch" } });
    if (!res.ok) return;
    const doc = new DOMParser().parseFromString(await res.text(), "text/html");
    const next = doc.getElementById("live");
    const cur = document.getElementById("live");
    if (next && cur) {
      cur.replaceWith(next);
      // let the fee sparkline redraw into the fresh canvas
      window.dispatchEvent(new Event("live-updated"));
    }
  } catch {
    /* offline or a blip — try again next tick */
  }
}

setInterval(tick, INTERVAL_MS);
