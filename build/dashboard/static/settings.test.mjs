import test from "node:test";
import assert from "node:assert/strict";
import { notificationPayload, configurationAccess, applyTowerLabels } from "./settings.js";

test("settings remain read-only unless the server confirms configuration access", () => {
  assert.equal(configurationAccess({ can_configure: true }), true);
  for (const data of [undefined, {}, { can_configure: false }, { can_configure: "true" }]) {
    assert.equal(configurationAccess(data), false);
  }
});

test("blank secret fields keep saved secrets without copying them into the request", () => {
  assert.deepEqual(notificationPayload({ telegram_enabled: true, telegram_chat_id: " -10042 ",
    healthchecks_enabled: true, alert_new_block: false }), {
    telegram_enabled: true, telegram_chat_id: "-10042", healthchecks_enabled: true, alert_new_block: false,
    tower_labels: false,
  });
});

test("disabled services do not send stale secrets or chat IDs", () => {
  assert.deepEqual(notificationPayload({ telegram_enabled: false, telegram_chat_id: "42",
    telegram_bot_token: "not-a-real-token", healthchecks_enabled: false,
    healthchecks_url: "https://example.com/not-a-real-ping", alert_new_block: true }), {
    telegram_enabled: false, telegram_chat_id: "", healthchecks_enabled: false, alert_new_block: true,
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
    healthchecks_url: " https://example.com/ping ", alert_new_block: true });
  assert.equal(payload.telegram_bot_token, "sample-token");
  assert.equal(payload.healthchecks_url, "https://example.com/ping");
});
