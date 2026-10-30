import test from "node:test";
import assert from "node:assert/strict";
import { notificationPayload, notificationChanged, configurationAccess, configuredNodeVisibility, portControlModel, portChanges, privateLANIPv4, portSubmissionOutcome, shouldPollPort, applyTowerLabels } from "./settings.js";

test("settings remain read-only unless the server confirms configuration access", () => {
  assert.equal(configurationAccess({ can_configure: true }), true);
  for (const data of [undefined, {}, { can_configure: false }, { can_configure: "true" }]) {
    assert.equal(configurationAccess(data), false);
  }
});

test("a port-only save does not create an unnecessary notification override", () => {
  const saved = {
    telegram_enabled: false, telegram_chat_id: "", healthchecks_enabled: false,
    alert_new_block: false, alert_new_block_bitcoin: false, alert_new_block_monero: false, tower_labels: false,
  };
  assert.equal(notificationChanged(saved, notificationPayload({})), false);
  assert.equal(notificationChanged(saved, notificationPayload({ alert_new_block_monero: true })), true);
});

test("node-specific settings show only configured nodes", () => {
  assert.deepEqual(configuredNodeVisibility({ bitcoin_enabled: true, monero_enabled: false }), { bitcoin: true, monero: false });
  assert.deepEqual(configuredNodeVisibility({ bitcoin_enabled: false, monero_enabled: true }), { bitcoin: false, monero: true });
  assert.deepEqual(configuredNodeVisibility({ bitcoin_enabled: "true", monero_enabled: 1 }), { bitcoin: false, monero: false });
});

test("port controls expose only typed configured ports and trusted states", () => {
  assert.deepEqual(portControlModel({ available: true, ports: [
    { id: "bitcoin_rpc", enabled: true, bind_ip: "192.168.1.2", host_port: 8332 },
    { id: "unknown", enabled: true },
  ], status: { state: "pending", message: "Applying LAN port changes…", affected_services: ["tor", "dashboard", "bitcoin"] } }), {
    available: true,
    ports: { bitcoin_rpc: { id: "bitcoin_rpc", enabled: true, bind_ip: "192.168.1.2", host_port: 8332 } },
    state: "pending",
    message: "Applying LAN port changes…",
    affected_services: ["tor", "dashboard"],
  });
  assert.deepEqual(portControlModel({ available: "true", status: { state: "invented", message: "ignored" } }), {
    available: false, ports: {}, state: "", message: "", affected_services: [],
  });
});

test("port changes stay staged and include open details only when enabled", () => {
  const ports = {
    bitcoin_rpc: { id: "bitcoin_rpc", enabled: true, bind_ip: "192.168.1.2", host_port: 8332 },
    monero_rpc: { id: "monero_rpc", enabled: false, bind_ip: "192.168.1.2", host_port: 18081 },
  };
  assert.deepEqual(portChanges(ports, {
    bitcoin_rpc: { enabled: false, bind_ip: "192.168.1.2", host_port: 8332 },
    monero_rpc: { enabled: true, bind_ip: " 192.168.1.3 ", host_port: "28081" },
  }), [
    { port: "bitcoin_rpc", enabled: false },
    { port: "monero_rpc", enabled: true, bind_ip: "192.168.1.3", host_port: 28081 },
  ]);
  assert.deepEqual(portChanges(ports, ports), []);
});

test("LAN port inputs accept RFC1918 IPv4 only", () => {
  for (const address of ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.2"]) assert.equal(privateLANIPv4(address), true);
  for (const address of ["127.0.0.1", "172.32.0.1", "8.8.8.8", "fc00::1", "192.168.001.2", ""]) assert.equal(privateLANIPv4(address), false);
});

test("a lost port POST response reconciles without claiming the request failed", () => {
  const draft = { bitcoin_rpc: { enabled: true, bind_ip: "192.168.1.2", host_port: 8332 } };
  assert.equal(portSubmissionOutcome({ state: "pending", ports: {} }, draft), "queued");
  assert.equal(portSubmissionOutcome({ state: "", ports: draft }, draft), "applied");
  assert.equal(portSubmissionOutcome({ state: "", ports: {
    bitcoin_rpc: { enabled: false, bind_ip: "192.168.1.2", host_port: 8332 },
  } }, draft), "unknown");
});

test("port status polling stops when the settings dialog closes", () => {
  assert.equal(shouldPollPort(true, "pending"), true);
  assert.equal(shouldPollPort(false, "pending"), false);
  assert.equal(shouldPollPort(true, "failed"), false);
});

test("blank secret fields keep saved secrets without copying them into the request", () => {
  assert.deepEqual(notificationPayload({ telegram_enabled: true, telegram_chat_id: " -10042 ",
    healthchecks_enabled: true, alert_new_block_bitcoin: false, alert_new_block_monero: true }), {
    telegram_enabled: true, telegram_chat_id: "-10042", healthchecks_enabled: true, alert_new_block: false,
    alert_new_block_monero: true,
    tower_labels: false,
  });
});

test("disabled services do not send stale secrets or chat IDs", () => {
  assert.deepEqual(notificationPayload({ telegram_enabled: false, telegram_chat_id: "42",
    telegram_bot_token: "not-a-real-token", healthchecks_enabled: false,
    healthchecks_url: "https://example.com/not-a-real-ping", alert_new_block_bitcoin: true }), {
    telegram_enabled: false, telegram_chat_id: "", healthchecks_enabled: false, alert_new_block: true,
    alert_new_block_monero: false,
    tower_labels: false,
  });
});

test("tower labels default off and update the page dataset", () => {
  const root = { dataset: {} };
  assert.equal(applyTowerLabels({}, root), "0");
  assert.equal(root.dataset.towerLabels, "0");
  assert.equal(applyTowerLabels({ tower_labels: true }, root), "1");
  assert.equal(root.dataset.towerLabels, "1");
  assert.equal(applyTowerLabels({ tower_labels: "true" }, root), "0");
});

test("replacement secrets are sent only for enabled services", () => {
  const payload = notificationPayload({ telegram_enabled: true, telegram_chat_id: "42",
    telegram_bot_token: " sample-token ", healthchecks_enabled: true,
    healthchecks_url: " https://example.com/ping ", alert_new_block_bitcoin: true, alert_new_block_monero: false });
  assert.equal(payload.telegram_bot_token, "sample-token");
  assert.equal(payload.healthchecks_url, "https://example.com/ping");
});
