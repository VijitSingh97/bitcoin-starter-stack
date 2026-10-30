const NODES = new Set(["bitcoin", "monero"]);

export function normalizeNode(node) {
  return NODES.has(node) ? node : "";
}

export function formatUptime(seconds) {
  const value = Math.max(0, Math.floor(Number(seconds) || 0));
  const days = Math.floor(value / 86400);
  const hours = Math.floor((value % 86400) / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  return [days && `${days}d`, (days || hours) && `${hours}h`, `${minutes}m`].filter(Boolean).join(" ");
}

export function formatBytes(bytes) {
  const value = Number(bytes);
  if (!Number.isFinite(value) || value < 0) return "—";
  return `${(value / (1024 ** 3)).toFixed(2)} GiB`;
}

export function moneroView(data) {
  if (!data || data.enabled === false) return { state: "Not configured", badge: "Disabled", details: false };
  if (data.available !== true) return { state: "Connecting...", badge: "Connecting", details: false };
  const height = Math.max(0, Math.floor(Number(data.height) || 0));
  const target = Math.max(height, Math.floor(Number(data.target_height) || 0));
  const progress = Math.max(0, Math.min(100, Number(data.sync_percent) || 0));
  return {
    state: data.synced ? "Synced" : "Synchronizing the Monero blockchain...",
    badge: data.pruned ? "Pruned" : "Full",
    details: true,
    version: String(data.version || "—"),
    uptime: formatUptime(data.uptime_seconds),
    connections: `${Math.max(0, Number(data.incoming_connections) || 0)} in · ${Math.max(0, Number(data.outgoing_connections) || 0)} out`,
    blocks: `${height} / ${target}`,
    progress,
    size: formatBytes(data.database_size_bytes),
    nextBlock: height ? height + 1 : "",
  };
}

export function applySelection(doc, node, focus = true) {
  const selected = normalizeNode(node);
  doc.body.dataset.node = selected;
  const overview = doc.getElementById("node-overview");
  if (overview) overview.hidden = !!selected;
  for (const panel of doc.querySelectorAll("[data-node-panel]")) {
    panel.hidden = panel.dataset.nodePanel !== selected;
  }
  for (const choice of doc.querySelectorAll("[data-select-node]")) {
    choice.setAttribute("aria-expanded", String(choice.dataset.selectNode === selected));
  }
  if (!focus) return selected;
  const target = selected
    ? doc.querySelector(`[data-node-panel="${selected}"] [data-close-node]`)
    : doc.querySelector("[data-select-node].node-choice-bitcoin");
  target?.focus();
  return selected;
}

export function selectionController(doc, onChange = () => {}) {
  let lastChoice = null;
  return {
    open(node, choice) {
      lastChoice = choice || lastChoice;
      const selected = applySelection(doc, node);
      onChange(selected);
      return selected;
    },
    close() {
      applySelection(doc, "", false);
      lastChoice?.focus();
      onChange("");
    },
    refresh() {
      return applySelection(doc, doc.body.dataset.node, false);
    },
  };
}

if (typeof document !== "undefined") {
  const controller = selectionController(document, (node) => {
    window.dispatchEvent(new CustomEvent("node-selected", { detail: { node } }));
  });

  document.addEventListener("click", (event) => {
    const choice = event.target.closest?.("[data-select-node]");
    if (choice) controller.open(choice.dataset.selectNode, choice);
    else if (event.target.closest?.("[data-close-node]") || event.target.id === "node-close-backdrop") controller.close();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && document.body.dataset.node && !document.getElementById("settings-dialog")?.open) controller.close();
  });
  window.addEventListener("live-updated", () => controller.refresh());

  const renderMonero = (data) => {
    const view = moneroView(data);
    document.getElementById("monero-badge").textContent = view.badge;
    document.getElementById("monero-state").textContent = view.state;
    const details = document.getElementById("monero-details");
    details.hidden = !view.details;
    document.getElementById("monero-live").dataset.nextBlock = view.nextBlock || "";
    if (!view.details) return;
    document.getElementById("monero-version").textContent = view.version;
    document.getElementById("monero-uptime").textContent = view.uptime;
    document.getElementById("monero-connections").textContent = view.connections;
    document.getElementById("monero-blocks").textContent = view.blocks;
    document.getElementById("monero-progress").style.width = `${view.progress}%`;
    document.getElementById("monero-sync").textContent = `${view.progress.toFixed(4)}%`;
    document.getElementById("monero-size").textContent = view.size;
    document.getElementById("monero-live").dataset.nextBlock = view.nextBlock;
  };

  async function refreshMonero() {
    try {
      const response = await fetch("/api/monero", { headers: { "X-Requested-With": "fetch" } });
      if (!response.ok) throw new Error("unavailable");
      renderMonero(await response.json());
    } catch {
      renderMonero({ enabled: true, available: false });
    }
  }

  applySelection(document, "", false);
  refreshMonero();
  setInterval(refreshMonero, 30000);
}
