export function notificationPayload(values) {
  const payload = {
    telegram_enabled: !!values.telegram_enabled,
    telegram_chat_id: values.telegram_enabled ? String(values.telegram_chat_id || "").trim() : "",
    healthchecks_enabled: !!values.healthchecks_enabled,
    alert_new_block: !!values.alert_new_block,
  };
  const token = String(values.telegram_bot_token || "").trim();
  const url = String(values.healthchecks_url || "").trim();
  if (payload.telegram_enabled && token) payload.telegram_bot_token = token;
  if (payload.healthchecks_enabled && url) payload.healthchecks_url = url;
  return payload;
}

export function configurationAccess(data) {
  return data?.can_configure === true;
}

if (typeof document !== "undefined") {
  const byId = (id) => document.getElementById(`settings-${id}`);
  const dialog = byId("dialog");
  const form = byId("form");
  const status = byId("status");
  const token = byId("telegram-token");
  const chat = byId("telegram-chat");
  const url = byId("healthchecks-url");
  const telegramEnabled = byId("telegram-enabled");
  const healthchecksEnabled = byId("healthchecks-enabled");
  const newBlock = byId("new-block");
  const save = byId("save");
  const reset = byId("reset");
  let saved = {};
  let allowed = false;

  const clearSecrets = () => { token.value = ""; url.value = ""; };
  const updateInputs = () => {
    token.disabled = chat.disabled = !allowed || !telegramEnabled.checked;
    url.disabled = !allowed || !healthchecksEnabled.checked;
    chat.required = allowed && telegramEnabled.checked;
    token.required = chat.required && !saved.telegram_bot_token;
    url.required = allowed && healthchecksEnabled.checked && !saved.healthchecks_url;
  };
  const render = (data) => {
    saved = data;
    allowed = configurationAccess(data);
    telegramEnabled.checked = !!data.telegram_enabled;
    healthchecksEnabled.checked = !!data.healthchecks_enabled;
    newBlock.checked = !!data.alert_new_block;
    token.value = data.telegram_bot_token || "";
    chat.value = data.telegram_chat_id || "";
    url.value = data.healthchecks_url || "";
    token.placeholder = "Paste your bot token";
    url.placeholder = "https://hc-ping.com/…";
    byId("source").textContent = data.overridden
      ? "Using settings saved from this dashboard. Use server config to restore the server’s values."
      : "Using the server configuration. Saving here creates a persistent dashboard override.";
    save.disabled = !allowed;
    reset.disabled = !allowed || !data.overridden;
    telegramEnabled.disabled = healthchecksEnabled.disabled = newBlock.disabled = !allowed;
    updateInputs();
  };
  async function request(method = "GET", payload) {
    const response = await fetch("/api/settings", {
      method,
      headers: payload ? { "Content-Type": "application/json", "X-Requested-With": "fetch" } : {},
      ...(payload ? { body: JSON.stringify(payload) } : {}),
    });
    if (!response.ok) {
      const text = (await response.text()).trim();
      throw new Error(text.length <= 200 ? text : "Could not update notification settings.");
    }
    return response.json();
  }
  async function load() {
    allowed = false;
    save.disabled = reset.disabled = true;
    telegramEnabled.disabled = healthchecksEnabled.disabled = newBlock.disabled = true;
    updateInputs();
    status.textContent = "Loading…";
    try {
      render(await request());
      status.textContent = allowed ? "" : "Notification settings are unavailable.";
    }
    catch (error) { status.textContent = error.message; }
  }
  byId("open").addEventListener("click", () => { dialog.showModal(); load(); });
  byId("close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", clearSecrets);
  telegramEnabled.addEventListener("change", updateInputs);
  healthchecksEnabled.addEventListener("change", updateInputs);
  async function persist(payload, message) {
    save.disabled = reset.disabled = true;
    status.textContent = "Saving…";
    try { render(await request("POST", payload)); status.textContent = message; }
    catch (error) {
      clearSecrets();
      status.textContent = error.message;
      save.disabled = !allowed;
      reset.disabled = !allowed || !saved.overridden;
      updateInputs();
    }
  }
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    if (!allowed || !form.reportValidity()) return;
    persist(notificationPayload({
      telegram_enabled: telegramEnabled.checked,
      telegram_bot_token: token.value,
      telegram_chat_id: chat.value,
      healthchecks_enabled: healthchecksEnabled.checked,
      healthchecks_url: url.value,
      alert_new_block: newBlock.checked,
    }), "Notification settings saved.");
  });
  reset.addEventListener("click", () => {
    if (allowed) persist({ reset: true }, "Using the server configuration.");
  });
}
