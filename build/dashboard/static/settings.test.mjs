import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { notificationPayload, notificationChanged, configurationAccess, configuredNodeVisibility, portControlModel, portChanges, portCollision, portStatusMessage, portStatusNode, portDraftAfterStatus, portSubmissionOutcome, shouldPollPort, settingsSaveMessage, normalizeDefaultCurrency, applyAppearance, requestSettings, scopedSettingsPayload } from "./settings.js";

test("settings remain read-only unless the server confirms configuration access", () => {
  assert.equal(configurationAccess({ can_configure: true }), true);
  for (const data of [undefined, {}, { can_configure: false }, { can_configure: "true" }]) {
    assert.equal(configurationAccess(data), false);
  }
});

test("a port-only save does not create an unnecessary notification override", () => {
  const saved = {
    telegram_enabled: false, telegram_chat_id: "", healthchecks_enabled: false,
    alert_new_block: false, alert_new_block_bitcoin: false, alert_new_block_monero: false, alert_new_block_tari:false, alert_new_block_litecoin:false, alert_new_block_dogecoin:false, alert_new_block_bitcoincash:false, alert_new_block_zcash:false, tower_labels: false, default_currency: "USD",
  };
  assert.equal(notificationChanged(saved, notificationPayload({})), false);
  assert.equal(notificationChanged(saved, notificationPayload({ alert_new_block_monero: true })), true);
  assert.equal(notificationChanged(saved, notificationPayload({ default_currency: "CNY" })), true);
});

test("node-specific settings show only configured nodes", () => {
  assert.deepEqual(configuredNodeVisibility({ bitcoin_enabled: true, monero_enabled: false }), { bitcoin: true, monero: false, tari:false, litecoin:false, dogecoin:false, bitcoincash:false, zcash:false });
  assert.deepEqual(configuredNodeVisibility({ bitcoin_enabled: false, monero_enabled: true }), { bitcoin: false, monero: true, tari:false, litecoin:false, dogecoin:false, bitcoincash:false, zcash:false });
  assert.deepEqual(configuredNodeVisibility({ bitcoin_enabled: "true", monero_enabled: 1 }), { bitcoin: false, monero: false, tari:false, litecoin:false, dogecoin:false, bitcoincash:false, zcash:false });
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
    error_code: "",
    port: "",
  });
  assert.deepEqual(portControlModel({ available: "true", status: { state: "invented", message: "ignored" } }), {
    available: false, ports: {}, state: "", message: "", affected_services: [], error_code: "", port: "",
  });
});

test("port changes stay staged and never send an editable bind address", () => {
  const ports = {
    bitcoin_rpc: { id: "bitcoin_rpc", enabled: true, bind_ip: "192.168.1.2", host_port: 8332 },
    monero_rpc: { id: "monero_rpc", enabled: false, bind_ip: "192.168.1.2", host_port: 18081 },
  };
  assert.deepEqual(portChanges(ports, {
    bitcoin_rpc: { enabled: false, host_port: 8332 },
    monero_rpc: { enabled: true, host_port: "28081" },
  }), [
    { port: "bitcoin_rpc", enabled: false },
    { port: "monero_rpc", enabled: true, host_port: 28081 },
  ]);
  assert.deepEqual(portChanges(ports, ports), []);
});

test("port collisions name the affected listener", () => {
  const draft = {
    bitcoin_rpc: { enabled: true, host_port: 8332 },
    monero_rpc: { enabled: true, host_port: 8332 },
  };
  const sameBind = {
    bitcoin_rpc: { bind_ip: "192.168.1.2" },
    monero_rpc: { bind_ip: "192.168.1.2" },
  };
  assert.equal(portCollision([{ port: "monero_rpc", enabled: true, host_port: 8332 }], draft, sameBind), "monero_rpc");
  assert.equal(portCollision([{ port: "monero_rpc", enabled: true, host_port: 8332 }], draft, {
    ...sameBind, monero_rpc: { bind_ip: "192.168.1.3" },
  }), "");
  assert.equal(portStatusMessage({ error_code: "port_in_use", port: "monero_rpc" }), "Selected port for Monero RPC is already in use.");
});

test("a rejected helper result preserves the user's port draft", () => {
  const draft = { monero_rpc: { enabled: true, host_port: 28081 } };
  assert.equal(portDraftAfterStatus(draft, "rejected", true), draft);
  assert.equal(portDraftAfterStatus(draft, "failed", true), draft);
  assert.equal(portDraftAfterStatus(draft, "applied", false), draft);
  assert.equal(portDraftAfterStatus(draft, "applied", true), undefined);
});

test("a lost port POST response reconciles without claiming the request failed", () => {
  const changes = [{ port: "bitcoin_rpc", enabled: true, host_port: 8332 }];
  assert.equal(portSubmissionOutcome({ state: "pending", ports: {} }, changes), "queued");
  assert.equal(portSubmissionOutcome({ state: "", ports: {
    bitcoin_rpc: { enabled: true, host_port: 8332 },
  } }, changes), "applied");
  assert.equal(portSubmissionOutcome({ state: "", ports: {
    bitcoin_rpc: { enabled: false, host_port: 8332 },
  } }, changes), "unknown");
  assert.equal(portSubmissionOutcome({ state: "", ports: {} }, changes), "unknown");
});

test("port status polling stops when the settings dialog closes", () => {
  assert.equal(shouldPollPort(true, "pending"), true);
  assert.equal(shouldPollPort(false, "pending"), false);
  assert.equal(shouldPollPort(true, "failed"), false);
});

test("port progress stays in the live port status", () => {
  assert.equal(settingsSaveMessage(false), "");
  assert.equal(settingsSaveMessage(true), "Settings saved.");
  assert.equal(portStatusNode("", "monero", []), "monero");
  assert.equal(portStatusNode("litecoin_rpc", "monero", []), "litecoin");
  assert.equal(portStatusNode("", "", ["zcash"]), "zcash");
});

test("blank secret fields keep saved secrets without copying them into the request", () => {
  assert.deepEqual(notificationPayload({ telegram_enabled: true, telegram_chat_id: " -10042 ",
    healthchecks_enabled: true, alert_new_block_bitcoin: false, alert_new_block_monero: true }), {
    telegram_enabled: true, telegram_chat_id: "-10042", healthchecks_enabled: true, alert_new_block: false,
    alert_new_block_monero: true,
    alert_new_block_tari:false, alert_new_block_litecoin:false, alert_new_block_dogecoin:false, alert_new_block_bitcoincash:false, alert_new_block_zcash:false,
    tower_labels: false,
    default_currency: "USD",
  });
});

test("disabled services do not send stale secrets or chat IDs", () => {
  assert.deepEqual(notificationPayload({ telegram_enabled: false, telegram_chat_id: "42",
    telegram_bot_token: "not-a-real-token", healthchecks_enabled: false,
    healthchecks_url: "https://example.com/not-a-real-ping", alert_new_block_bitcoin: true }), {
    telegram_enabled: false, telegram_chat_id: "", healthchecks_enabled: false, alert_new_block: true,
    alert_new_block_monero: false,
    alert_new_block_tari:false, alert_new_block_litecoin:false, alert_new_block_dogecoin:false, alert_new_block_bitcoincash:false, alert_new_block_zcash:false,
    tower_labels: false,
    default_currency: "USD",
  });
});

test("appearance defaults are applied and broadcast together", () => {
  const root = { dataset: {} };
  const events = [];
  const target = { dispatchEvent: (event) => events.push(event) };
  assert.deepEqual(applyAppearance({}, root, target), { tower_labels: false, default_currency: "USD" });
  assert.equal(root.dataset.towerLabels, "0");
  assert.deepEqual(applyAppearance({ tower_labels: true, default_currency: "cny" }, root, target), { tower_labels: true, default_currency: "CNY" });
  assert.equal(root.dataset.towerLabels, "1");
  assert.equal(events.at(-1).type, "appearance-updated");
  assert.deepEqual(events.at(-1).detail, { tower_labels: true, default_currency: "CNY" });
  assert.equal(normalizeDefaultCurrency("btc"), "USD");
});

test("replacement secrets are sent only for enabled services", () => {
  const payload = notificationPayload({ telegram_enabled: true, telegram_chat_id: "42",
    telegram_bot_token: " sample-token ", healthchecks_enabled: true,
    healthchecks_url: " https://example.com/ping ", alert_new_block_bitcoin: true, alert_new_block_monero: false });
  assert.equal(payload.telegram_bot_token, "sample-token");
  assert.equal(payload.healthchecks_url, "https://example.com/ping");
});

test("node and global saves use independent HTTP scopes and payloads", async () => {
  const requests = [];
  const fetcher = async (url, options) => {
    requests.push({ url, method: options.method, body: options.body ? JSON.parse(options.body) : undefined });
    return { ok: true, json: async () => ({ can_configure: true }) };
  };
  await requestSettings("bitcoin", "GET", undefined, fetcher);
  const nodePayload = scopedSettingsPayload("monero", { alert_new_block_monero: true, telegram_bot_token: "must-not-leak" });
  await requestSettings("monero", "POST", nodePayload, fetcher);
  const globalPayload = scopedSettingsPayload("global", {
    telegram_enabled: true,
    telegram_bot_token: "replacement-token",
    telegram_chat_id: "42",
    healthchecks_enabled: true,
    healthchecks_url: "https://example.com/ping",
    tower_labels: true,
    default_currency: "CNY",
    alert_new_block_monero: true,
  });
  await requestSettings("global", "POST", globalPayload, fetcher);
  assert.deepEqual(requests[0], { url: "/api/settings?scope=nodes", method: "GET", body: undefined });
  assert.deepEqual(requests[1], {
    url: "/api/settings?scope=nodes", method: "POST", body: { alert_new_block_monero: true },
  });
  assert.equal(requests[2].url, "/api/settings?scope=global");
  assert.equal(requests[2].body.telegram_bot_token, "replacement-token");
  assert.equal(requests[2].body.healthchecks_url, "https://example.com/ping");
  assert.equal(requests[2].body.tower_labels, true);
  assert.equal(requests[2].body.default_currency, "CNY");
  assert.equal(Object.keys(requests[2].body).some((field) => field.startsWith("alert_new_block")), false);
  await assert.rejects(
    requestSettings("bitcoin", "POST", { alert_new_block: true }, async () => ({ ok: false, text: async () => "node settings rejected" })),
    /node settings rejected/,
  );
});

test("node settings move into each tower ahead of node deactivation", async () => {
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  const source = await readFile(new URL("./settings.js", import.meta.url), "utf8");
  assert.match(html, /<fieldset id="settings-node-alerts" hidden>/);
  assert.match(source, /card\.className = "card node-settings-card"/);
  assert.match(source, /nodeForm\.dataset\.nodeSettingsForm = node/);
  assert.match(source, /details\.append\(nodeStatus, impact, actions\)/);
  assert.match(source, /power\.before\(card\)/);
  assert.match(source, /saveScope\(node, view\.form, view\.status, view\.save\)/);
});
