import test from "node:test";
import assert from "node:assert/strict";
import { notificationPayload, configurationAccess, configuredNodeVisibility, portControlModel, shouldPollPort, applyTowerLabels } from "./settings.js";

test("settings remain read-only unless the server confirms configuration access", () => {
  assert.equal(configurationAccess({ can_configure: true }), true);
  for (const data of [undefined, {}, { can_configure: false }, { can_configure: "true" }]) {
    assert.equal(configurationAccess(data), false);
  }
});

test("node-specific settings show only configured nodes", () => {
  assert.deepEqual(configuredNodeVisibility({ bitcoin_enabled: true, monero_enabled: false }), { bitcoin: true, monero: false });
  assert.deepEqual(configuredNodeVisibility({ bitcoin_enabled: false, monero_enabled: true }), { bitcoin: false, monero: true });
  assert.deepEqual(configuredNodeVisibility({ bitcoin_enabled: "true", monero_enabled: 1 }), { bitcoin: false, monero: false });
});

test("port controls expose only typed configured ports and trusted states", () => {
  assert.deepEqual(portControlModel({ available: true, ports: [
    { id: "bitcoin_rpc", enabled: true, endpoint: "192.168.1.2:8332" },
    { id: "unknown", enabled: true },
  ], status: { state: "pending", message: "Closing selected port…" } }), {
    available: true,
    ports: { bitcoin_rpc: { id: "bitcoin_rpc", enabled: true, endpoint: "192.168.1.2:8332" } },
    state: "pending",
    message: "Closing selected port…",
  });
  assert.deepEqual(portControlModel({ available: "true", status: { state: "invented", message: "ignored" } }), {
    available: false, ports: {}, state: "", message: "",
  });
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
