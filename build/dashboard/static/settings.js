export function notificationPayload(values) {
  const payload = {
    telegram_enabled: !!values.telegram_enabled,
    telegram_chat_id: values.telegram_enabled ? String(values.telegram_chat_id || "").trim() : "",
    healthchecks_enabled: !!values.healthchecks_enabled,
    alert_new_block: !!values.alert_new_block_bitcoin,
    alert_new_block_monero: !!values.alert_new_block_monero,
    tower_labels: !!values.tower_labels,
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

export function configuredNodeVisibility(data) {
  return { bitcoin: data?.bitcoin_enabled === true, monero: data?.monero_enabled === true };
}

export function portControlModel(data) {
  const ports = {};
  for (const port of Array.isArray(data?.ports) ? data.ports : []) {
    if (["bitcoin_rpc", "monero_rpc", "monero_zmq"].includes(port?.id)) ports[port.id] = port;
  }
  const state = ["pending", "applied", "rejected", "failed"].includes(data?.status?.state) ? data.status.state : "";
  return { available: data?.available === true, ports, state, message: state ? String(data.status.message || "") : "" };
}

export function shouldPollPort(dialogOpen, state) {
  return dialogOpen === true && state === "pending";
}

export function applyTowerLabels(data, root = typeof document === "undefined" ? undefined : document.body) {
  const value = data?.tower_labels === true ? "1" : "0";
  if (root?.dataset) root.dataset.towerLabels = value;
  return value;
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
  const bitcoinNewBlock = byId("bitcoin-new-block");
  const moneroNewBlock = byId("monero-new-block");
  const towerLabels = byId("tower-labels");
  const save = byId("save");
  const reset = byId("reset");
  let saved = {};
  let allowed = false;
  let portPoll;
  let portRequestID = "";
  try { portRequestID = localStorage.getItem("nodeStackPortRequest") || ""; } catch {}

  const portRows = {
    bitcoin_rpc: byId("port-bitcoin-rpc"),
    monero_rpc: byId("port-monero-rpc"),
    monero_zmq: byId("port-monero-zmq"),
  };

  const renderPortControl = (data) => {
    const view = portControlModel(data);
    if (view.state === "pending" && /^[0-9a-f]{32}$/.test(String(data?.status?.id || ""))) {
      portRequestID = data.status.id;
      try { localStorage.setItem("nodeStackPortRequest", portRequestID); } catch {}
    } else if (view.state && data?.status?.id !== portRequestID) {
      view.state = "";
      view.message = "";
    } else if (view.state && view.state !== "pending") {
      try { localStorage.removeItem("nodeStackPortRequest"); } catch {}
      portRequestID = "";
    }
    const pending = view.state === "pending";
    for (const [id, row] of Object.entries(portRows)) {
      const port = view.ports[id];
      row.hidden = !port;
      if (!port) continue;
      const state = row.querySelector("[data-port-state]");
      const button = row.querySelector("[data-close-port]");
      if (port.enabled === true) {
        state.textContent = `${String(port.endpoint || "Configured")} · LAN${view.available ? "" : " · close in config.json"}`;
        button.hidden = false;
        button.disabled = !allowed || !view.available || pending;
      } else {
        state.textContent = "Disabled. Reopen through the server configuration.";
        button.hidden = true;
      }
    }
    byId("port-status").textContent = view.message || (!view.available && Object.values(view.ports).some((port) => port.enabled)
      ? "Dashboard port closing requires a dashboard password and the installed host helper."
      : "");
    clearTimeout(portPoll);
    if (shouldPollPort(dialog.open, view.state)) portPoll = setTimeout(loadPortControl, 2000);
    return view;
  };

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
    bitcoinNewBlock.checked = !!(data.alert_new_block_bitcoin ?? data.alert_new_block);
    moneroNewBlock.checked = !!data.alert_new_block_monero;
    const nodes = configuredNodeVisibility(data);
    byId("bitcoin-alerts").hidden = !nodes.bitcoin;
    byId("monero-alerts").hidden = !nodes.monero;
    byId("node-alerts").hidden = !nodes.bitcoin && !nodes.monero;
    renderPortControl(data.port_control);
    towerLabels.checked = !!data.tower_labels;
    applyTowerLabels(data);
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
    telegramEnabled.disabled = healthchecksEnabled.disabled = bitcoinNewBlock.disabled = moneroNewBlock.disabled = towerLabels.disabled = !allowed;
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
  async function requestPortControl(method = "GET", payload) {
    const response = await fetch("/api/settings/ports", {
      method,
      headers: payload ? { "Content-Type": "application/json", "X-Requested-With": "fetch" } : {},
      ...(payload ? { body: JSON.stringify(payload) } : {}),
    });
    if (!response.ok) {
      const text = (await response.text()).trim();
      throw new Error(text.length <= 200 ? text : "Could not update port settings.");
    }
    return response.json();
  }
  async function loadPortControl() {
    try { renderPortControl(await requestPortControl()); }
    catch { if (dialog.open) portPoll = setTimeout(loadPortControl, 2000); }
  }
  async function load() {
    allowed = false;
    save.disabled = reset.disabled = true;
    telegramEnabled.disabled = healthchecksEnabled.disabled = bitcoinNewBlock.disabled = moneroNewBlock.disabled = towerLabels.disabled = true;
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
  dialog.addEventListener("close", () => { clearSecrets(); clearTimeout(portPoll); });
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
      alert_new_block_bitcoin: bitcoinNewBlock.checked,
      alert_new_block_monero: moneroNewBlock.checked,
      tower_labels: towerLabels.checked,
    }), "Settings saved.");
  });
  reset.addEventListener("click", () => {
    if (allowed) persist({ reset: true }, "Using the server configuration.");
  });
  for (const button of document.querySelectorAll("[data-close-port]")) {
    button.addEventListener("click", async () => {
      if (!allowed) return;
      button.disabled = true;
      byId("port-status").textContent = "Queuing port change…";
      try {
        const response = await requestPortControl("POST", { ports: [button.dataset.closePort] });
        if (/^[0-9a-f]{32}$/.test(String(response?.status?.id || ""))) {
          portRequestID = response.status.id;
          try { localStorage.setItem("nodeStackPortRequest", portRequestID); } catch {}
        }
        renderPortControl(response);
      }
      catch (error) { byId("port-status").textContent = error.message; loadPortControl(); }
    });
  }
  fetch("/api/settings?scope=appearance")
    .then((response) => response.ok ? response.json() : Promise.reject())
    .then(applyTowerLabels)
    .catch(() => applyTowerLabels({}));
}
