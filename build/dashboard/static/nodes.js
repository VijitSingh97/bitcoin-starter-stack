const NODES = new Set(["bitcoin", "monero"]);

export function normalizeNode(node) {
  return NODES.has(node) ? node : "";
}

export function applyHover(doc, node) {
  doc.body.dataset.hoverNode = normalizeNode(node);
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

export function formatCompactBytes(bytes) {
  const value = Number(bytes);
  if (!Number.isFinite(value) || value < 0) return "—";
  if (value < 1024) return `${Math.round(value)} B`;
  if (value < 1024 ** 2) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / 1024 ** 2).toFixed(1)} MiB`;
}

export function formatHashrate(rate) {
  const value = Number(rate);
  if (!Number.isFinite(value) || value < 0) return "—";
  const units = ["H/s", "kH/s", "MH/s", "GH/s", "TH/s"];
  let scaled = value;
  let unit = 0;
  while (scaled >= 1000 && unit < units.length - 1) { scaled /= 1000; unit++; }
  return `${scaled.toFixed(scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2)} ${units[unit]}`;
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
    diskCapacity: data.disk_available ? formatBytes(data.disk_total_bytes) : "—",
    diskFree: data.disk_available ? formatBytes(data.disk_free_bytes) : "—",
    mempool: data.mempool_txs_available ? `${Math.max(0, Math.floor(Number(data.mempool_txs) || 0))} tx${data.mempool_bytes_available ? ` · ${formatCompactBytes(data.mempool_bytes)}` : ""}` : "—",
    difficulty: Number.isFinite(Number(data.difficulty)) ? Math.max(0, Math.floor(Number(data.difficulty))).toLocaleString("en-US") : "—",
    hashrate: data.hashrate_available ? formatHashrate(data.network_hashrate) : "—",
    lastBlock: data.latest_block_available ? `${data.latest_block_age_seconds < 60 ? "<1m" : formatUptime(data.latest_block_age_seconds)} ago` : "—",
    rpcExposure: data.rpc_exposure_enabled ? `${String(data.rpc_endpoint || "—")} · LAN` : "Disabled",
    zmqExposure: data.zmq_exposure_enabled ? `${String(data.zmq_endpoint || "—")} · LAN` : "Disabled",
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
  document.addEventListener("pointerover", (event) => {
    const choice = event.target.closest?.("[data-select-node]");
    if (choice) applyHover(document, choice.dataset.selectNode);
  });
  document.addEventListener("pointerout", (event) => {
    const choice = event.target.closest?.("[data-select-node]");
    if (choice && !choice.contains(event.relatedTarget) && !choice.contains(document.activeElement)) applyHover(document, "");
  });
  document.addEventListener("focusin", (event) => {
    const choice = event.target.closest?.("[data-select-node]");
    if (choice) applyHover(document, choice.dataset.selectNode);
  });
  document.addEventListener("focusout", (event) => {
    const choice = event.target.closest?.("[data-select-node]");
    if (choice && !choice.contains(event.relatedTarget)) applyHover(document, "");
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
    document.getElementById("monero-disk-capacity").textContent = view.diskCapacity;
    document.getElementById("monero-disk-free").textContent = view.diskFree;
    document.getElementById("monero-mempool").textContent = view.mempool;
    document.getElementById("monero-difficulty").textContent = view.difficulty;
    document.getElementById("monero-hashrate").textContent = view.hashrate;
    document.getElementById("monero-last-block").textContent = view.lastBlock;
    document.getElementById("monero-rpc-exposure").textContent = view.rpcExposure;
    document.getElementById("monero-zmq-exposure").textContent = view.zmqExposure;
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
