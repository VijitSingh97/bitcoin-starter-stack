// Opt-in Upgrade button. Appears only when the host has enabled
// `dashboard.control` AND a newer release is available. Clicking asks the
// host-side `./stack upgrade-agent` to run the upgrade — the dashboard itself
// has no host/docker access; it only drops a request marker.
const box = document.getElementById("upgrade");

async function refresh() {
  if (!box) return;
  let s;
  try {
    s = await (await fetch("/api/upgrade")).json();
  } catch {
    return; // node/dashboard busy — try again next tick
  }
  if (!s.enabled || (!s.update && !s.pending)) {
    box.hidden = true;
    return;
  }
  box.hidden = false;
  if (s.pending) {
    box.textContent =
      "⏳ Upgrade requested — the host agent is applying it; this page will refresh to the new version.";
    return;
  }
  // an update is available and nothing is pending → offer the button
  box.textContent = "";
  box.appendChild(document.createTextNode(`🆕 ${s.update} `));
  const btn = document.createElement("button");
  btn.textContent = "Upgrade now";
  btn.className = "upgrade-btn";
  btn.setAttribute("aria-label", "Upgrade the stack to the latest release");
  btn.addEventListener("click", async () => {
    btn.disabled = true;
    btn.textContent = "Requesting…";
    try {
      const r = await fetch("/api/upgrade", {
        method: "POST",
        headers: { "X-Requested-With": "fetch" },
      });
      if (!r.ok) throw new Error((await r.text()) || r.status);
      box.textContent = "⏳ Upgrade requested — applying on the host…";
    } catch (e) {
      btn.disabled = false;
      btn.textContent = "Upgrade now";
      box.appendChild(document.createTextNode(` (failed: ${e.message})`));
    }
  });
  box.appendChild(btn);
}

refresh();
setInterval(refresh, 15000);
