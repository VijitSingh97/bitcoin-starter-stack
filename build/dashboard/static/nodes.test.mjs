import test from "node:test";
import assert from "node:assert/strict";
import { applyHover, formatBytes, formatCompactBytes, formatHashrate, formatUptime, moneroView, selectionController } from "./nodes.js";

function dashboard() {
  const overview = { hidden: false };
  const bitcoinClose = { focused: 0, focus() { this.focused++; } };
  const moneroClose = { focused: 0, focus() { this.focused++; } };
  const panels = [
    { hidden: true, dataset: { nodePanel: "bitcoin" } },
    { hidden: true, dataset: { nodePanel: "monero" } },
  ];
  const choices = ["bitcoin", "monero"].map((node) => ({ dataset: { selectNode: node },
    setAttribute(name, value) { this[name] = value; } }));
  return {
    body: { dataset: { node: "" } }, overview, panels, choices, bitcoinClose, moneroClose,
    getElementById: (id) => id === "node-overview" ? overview : null,
    querySelectorAll: (selector) => selector === "[data-node-panel]" ? panels : choices,
    querySelector: (selector) => selector.includes("bitcoin") ? bitcoinClose : moneroClose,
  };
}

test("tower selection opens one panel, survives refresh, and closes to the chosen tower", () => {
  const doc = dashboard();
  const events = [];
  const bitcoinChoice = { focused: 0, focus() { this.focused++; } };
  const controller = selectionController(doc, (node) => events.push(node));

  controller.open("bitcoin", bitcoinChoice);
  assert.equal(doc.body.dataset.node, "bitcoin");
  assert.equal(doc.overview.hidden, true);
  assert.deepEqual(doc.panels.map((panel) => panel.hidden), [false, true]);
  assert.deepEqual(doc.choices.map((choice) => choice["aria-expanded"]), ["true", "false"]);
  assert.equal(doc.bitcoinClose.focused, 1);

  doc.panels[0].hidden = true;
  controller.refresh();
  assert.equal(doc.panels[0].hidden, false);

  controller.close();
  assert.equal(doc.body.dataset.node, "");
  assert.equal(doc.overview.hidden, false);
  assert.deepEqual(doc.panels.map((panel) => panel.hidden), [true, true]);
  assert.deepEqual(doc.choices.map((choice) => choice["aria-expanded"]), ["false", "false"]);
  assert.equal(bitcoinChoice.focused, 1);
  assert.deepEqual(events, ["bitcoin", ""]);
});

test("tower hover only records supported nodes", () => {
  const doc = dashboard();
  applyHover(doc, "monero");
  assert.equal(doc.body.dataset.hoverNode, "monero");
  applyHover(doc, "other");
  assert.equal(doc.body.dataset.hoverNode, "");
});

test("Monero status does not invent metrics while disabled or unreachable", () => {
  assert.deepEqual(moneroView({ enabled: false }), { state: "Not configured", badge: "Disabled", details: false });
  assert.deepEqual(moneroView({ enabled: true, available: false, height: 99 }), { state: "Connecting...", badge: "Connecting", details: false });
});

test("available Monero metrics are clamped and formatted for the status card", () => {
  const view = moneroView({ enabled: true, available: true, synced: false, height: 120, target_height: 125,
    sync_percent: 96, version: "0.18.4.2", uptime_seconds: 90061, incoming_connections: 2,
    outgoing_connections: 8, pruned: true, database_size_bytes: 10 * 1024 ** 3,
    disk_available: true, disk_total_bytes: 20 * 1024 ** 3, disk_free_bytes: 8 * 1024 ** 3,
    mempool_txs: 3, mempool_txs_available: true, mempool_bytes_available: true, mempool_bytes: 1536, difficulty: 1234567,
    hashrate_available: true, network_hashrate: 1234567, latest_block_available: true,
    latest_block_age_seconds: 42, rpc_exposure_enabled: true, rpc_endpoint: "192.168.1.2:18081" });
  assert.equal(view.state, "Synchronizing the Monero blockchain...");
  assert.equal(view.badge, "Pruned");
  assert.equal(view.blocks, "120 / 125");
  assert.equal(view.uptime, "1d 1h 1m");
  assert.equal(view.connections, "2 in · 8 out");
  assert.equal(view.size, "10.00 GiB");
  assert.equal(view.diskCapacity, "20.00 GiB");
  assert.equal(view.diskFree, "8.00 GiB");
  assert.equal(view.mempool, "3 tx · 1.5 KiB");
  assert.equal(view.difficulty, "1,234,567");
  assert.equal(view.hashrate, "1.23 MH/s");
  assert.equal(view.lastBlock, "<1m ago");
  assert.equal(view.rpcExposure, "192.168.1.2:18081 · LAN");
  assert.equal(view.zmqExposure, "Disabled");
  assert.equal(formatUptime(-1), "0m");
  assert.equal(formatBytes(undefined), "—");
  assert.equal(formatCompactBytes(1024 ** 2), "1.0 MiB");
  assert.equal(formatHashrate(-1), "—");
});

test("missing Monero mempool fields remain unavailable", () => {
  const view = moneroView({ enabled: true, available: true });
  assert.equal(view.mempool, "—");
});
