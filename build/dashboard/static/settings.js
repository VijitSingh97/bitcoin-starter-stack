const extraNodes = ["tari", "litecoin", "dogecoin", "bitcoincash", "zcash"];
const allNodes = ["bitcoin", "monero", ...extraNodes];
const allPortIDs = ["bitcoin_rpc", "monero_rpc", "monero_zmq", "tari_grpc", "litecoin_rpc", "dogecoin_rpc", "bitcoincash_rpc", "zcash_rpc"];

export function notificationPayload(values) {
  const payload = {
    telegram_enabled: !!values.telegram_enabled,
    telegram_chat_id: values.telegram_enabled ? String(values.telegram_chat_id || "").trim() : "",
    healthchecks_enabled: !!values.healthchecks_enabled,
    alert_new_block: !!values.alert_new_block_bitcoin,
    alert_new_block_monero: !!values.alert_new_block_monero,
    tower_labels: !!values.tower_labels,
    default_currency: normalizeDefaultCurrency(values.default_currency),
  };
  for (const node of extraNodes) payload[`alert_new_block_${node}`] = !!values[`alert_new_block_${node}`];
  const token = String(values.telegram_bot_token || "").trim();
  const url = String(values.healthchecks_url || "").trim();
  if (payload.telegram_enabled && token) payload.telegram_bot_token = token;
  if (payload.healthchecks_enabled && url) payload.healthchecks_url = url;
  return payload;
}

export function configurationAccess(data) {
  return data?.can_configure === true;
}

export function notificationChanged(saved, payload) {
  const fields = ["telegram_enabled", "telegram_chat_id", "healthchecks_enabled", "alert_new_block_monero", "tower_labels"];
  if (extraNodes.some(node => payload[`alert_new_block_${node}`] !== !!saved?.[`alert_new_block_${node}`])) return true;
  if (fields.some((field) => payload[field] !== saved?.[field])) return true;
  if (payload.default_currency !== normalizeDefaultCurrency(saved?.default_currency)) return true;
  if (payload.alert_new_block !== (saved?.alert_new_block_bitcoin ?? saved?.alert_new_block)) return true;
  if (Object.hasOwn(payload, "telegram_bot_token") && payload.telegram_bot_token !== saved?.telegram_bot_token) return true;
  return Object.hasOwn(payload, "healthchecks_url") && payload.healthchecks_url !== saved?.healthchecks_url;
}

export function configuredNodeVisibility(data) {
  return Object.fromEntries(allNodes.map(node => [node, data?.[`${node}_enabled`] === true]));
}

export function portControlModel(data) {
  const portIDs = allPortIDs;
  const ports = {};
  for (const port of Array.isArray(data?.ports) ? data.ports : []) {
    if (!portIDs.includes(port?.id)) continue;
    ports[port.id] = {
      id: port.id,
      enabled: port.enabled === true,
      bind_ip: typeof port.bind_ip === "string" ? port.bind_ip : "",
      host_port: Number.isInteger(port.host_port) && port.host_port >= 1 && port.host_port <= 65535 ? port.host_port : 0,
    };
  }
  const state = ["pending", "applied", "rejected", "failed"].includes(data?.status?.state) ? data.status.state : "";
  const affectedServices = Array.isArray(data?.status?.affected_services)
    ? data.status.affected_services.filter((service) => ["tor", "dashboard"].includes(service)) : [];
  const errorCode = data?.status?.error_code === "port_in_use" ? "port_in_use" : "";
  const errorPort = errorCode && portIDs.includes(data?.status?.port) ? data.status.port : "";
  return {
    available: data?.available === true,
    ports,
    state,
    message: state ? String(data.status.message || "") : "",
    affected_services: [...new Set(affectedServices)],
    error_code: state ? errorCode : "",
    port: state ? errorPort : "",
  };
}

export function portChanges(ports, draft) {
  const changes = [];
  for (const id of allPortIDs) {
    const before = ports?.[id];
    const after = draft?.[id];
    if (!before || !after) continue;
    const enabled = after.enabled === true;
    const hostPort = Number(after.host_port);
    if (enabled === before.enabled && (!enabled || hostPort === before.host_port)) continue;
    const change = { port: id, enabled };
    if (enabled) change.host_port = hostPort;
    changes.push(change);
  }
  return changes;
}

export function portCollision(changes, draft, ports) {
  for (const change of changes || []) {
    if (!change.enabled) continue;
    const bindIP = ports?.[change.port]?.bind_ip;
    const conflict = Object.entries(draft || {}).some(([id, port]) => id !== change.port
      && port?.enabled === true && Number(port.host_port) === change.host_port && ports?.[id]?.bind_ip === bindIP);
    if (conflict) return change.port;
  }
  return "";
}

export function portStatusMessage(view) {
  const labels = { bitcoin_rpc: "Bitcoin RPC", monero_rpc: "Monero RPC", monero_zmq: "Monero ZMQ", tari_grpc: "Tari gRPC", litecoin_rpc: "Litecoin RPC", dogecoin_rpc: "Dogecoin RPC", bitcoincash_rpc: "Bitcoin Cash RPC", zcash_rpc: "Zcash RPC" };
  if (view?.error_code === "port_in_use" && labels[view.port]) return `Selected port for ${labels[view.port]} is already in use.`;
  return String(view?.message || "");
}

export function portDraftAfterStatus(draft, state, requestMatches) {
  return requestMatches && state === "applied" ? undefined : draft;
}

export function portSubmissionOutcome(view, changes) {
  if (view?.state === "pending") return "queued";
  if (!Array.isArray(changes) || changes.length === 0) return "unknown";
  const applied = changes.every((change) => {
    const port = view?.ports?.[change.port];
    if (!port || port.enabled !== change.enabled) return false;
    return !change.enabled || port.host_port === change.host_port;
  });
  return applied ? "applied" : "unknown";
}

export function shouldPollPort(dialogOpen, state) {
  return dialogOpen === true && state === "pending";
}

export function settingsSaveMessage(settingsSaved) {
  return settingsSaved ? "Settings saved." : "";
}

const defaultCurrencies = ["USD", "EUR", "GBP", "INR", "CAD", "AUD", "JPY", "RUB", "CNY"];

export function normalizeDefaultCurrency(value) {
  const currency = String(value || "").toUpperCase();
  return defaultCurrencies.includes(currency) ? currency : "USD";
}

export function applyAppearance(data, root = typeof document === "undefined" ? undefined : document.body, target = typeof document === "undefined" ? undefined : document) {
  const detail = { tower_labels: data?.tower_labels === true, default_currency: normalizeDefaultCurrency(data?.default_currency) };
  if (root?.dataset) root.dataset.towerLabels = detail.tower_labels ? "1" : "0";
  if (target?.dispatchEvent) target.dispatchEvent(new CustomEvent("appearance-updated", { detail }));
  return detail;
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
  const extraNewBlock = Object.fromEntries(extraNodes.map(node => [node, byId(`${node}-new-block`)]));
  const towerLabels = byId("tower-labels");
  const defaultCurrency = byId("default-currency");
  const save = byId("save");
  const reset = byId("reset");
  const portImpact = byId("port-impact");
  let saved = {};
  let savedPorts = {};
  let allowed = false;
  let portAvailable = false;
  let portState = "";
  let portPoll;
  let portRequestID = "";
  let ambiguousPortDraft;
  let ambiguousStatusPrefix = "";
  let stagedPortDraft;
  try { portRequestID = localStorage.getItem("nodeStackPortRequest") || ""; } catch {}

  const portRows = {
    bitcoin_rpc: byId("port-bitcoin-rpc"),
    monero_rpc: byId("port-monero-rpc"),
    monero_zmq: byId("port-monero-zmq"),
    ...Object.fromEntries(extraNodes.map(node => [`${node}_${node === "tari" ? "grpc" : "rpc"}`, byId(`port-${node}-${node === "tari" ? "grpc" : "rpc"}`)])),
  };

  const portDraft = () => Object.fromEntries(Object.entries(portRows).map(([id, row]) => [id, {
    enabled: row.querySelector("[data-port-enabled]").checked,
    host_port: Number(row.querySelector("[data-port-number]").value),
  }]));

  const applyPortDraft = (draft, remember = true) => {
    for (const [id, values] of Object.entries(draft || {})) {
      const row = portRows[id];
      if (!row) continue;
      row.querySelector("[data-port-enabled]").checked = values.enabled === true;
      row.querySelector("[data-port-number]").value = values.host_port || "";
    }
    if (remember) stagedPortDraft = draft;
    updatePortPlan(false);
  };

  const updatePortPlan = (remember = false) => {
    const pending = portState === "pending";
    const draft = portDraft();
    const changes = portChanges(savedPorts, draft);
    if (remember) stagedPortDraft = changes.length ? draft : undefined;
    for (const row of Object.values(portRows)) {
      const enabled = row.querySelector("[data-port-enabled]");
      const locked = !allowed || !portAvailable || pending || row.hidden;
      enabled.disabled = locked;
      row.querySelector("[data-port-number]").disabled = locked || !enabled.checked;
    }
    portImpact.hidden = changes.length === 0 && !pending;
    save.textContent = changes.length > 0 ? "Save & restart" : pending ? "Restart pending" : "Save";
    save.disabled = !allowed || pending;
    reset.disabled = !allowed || pending || !saved.overridden;
    return changes;
  };

  const renderPortControl = (data) => {
    const view = portControlModel(data);
    const statusID = String(data?.status?.id || "");
    const requestMatches = !!portRequestID && statusID === portRequestID;
    if (view.state === "pending" && /^[0-9a-f]{32}$/.test(String(data?.status?.id || ""))) {
      portRequestID = data.status.id;
      try { localStorage.setItem("nodeStackPortRequest", portRequestID); } catch {}
    } else if (view.state && data?.status?.id !== portRequestID) {
      view.state = "";
      view.message = "";
      view.error_code = "";
      view.port = "";
    } else if (view.state && view.state !== "pending") {
      try { localStorage.removeItem("nodeStackPortRequest"); } catch {}
      portRequestID = "";
    }
    stagedPortDraft = portDraftAfterStatus(stagedPortDraft, view.state, requestMatches);
    savedPorts = view.ports;
    portAvailable = view.available;
    portState = view.state;
    for (const [id, row] of Object.entries(portRows)) {
      const port = view.ports[id];
      row.hidden = !port;
      if (!port) continue;
      row.querySelector("[data-port-enabled]").checked = port.enabled;
      row.querySelector("[data-port-number]").value = port.host_port || "";
    }
    if (stagedPortDraft) applyPortDraft(stagedPortDraft, false);
    byId("port-status").textContent = portStatusMessage(view) || (!view.available && Object.keys(view.ports).length
      ? "LAN port changes require a dashboard password and the installed host helper."
      : "");
    clearTimeout(portPoll);
    if (shouldPollPort(dialog.open, view.state)) portPoll = setTimeout(loadPortControl, 2000);
    updatePortPlan();
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
    for (const node of allNodes) byId(`${node}-alerts`).hidden = !nodes[node];
    for (const [node,input] of Object.entries(extraNewBlock)) { input.checked = !!data[`alert_new_block_${node}`]; input.disabled = !allowed; }
    byId("node-alerts").hidden = !Object.values(nodes).some(Boolean);
    renderPortControl(data.port_control);
    towerLabels.checked = !!data.tower_labels;
    defaultCurrency.value = normalizeDefaultCurrency(data.default_currency);
    applyAppearance(data);
    token.value = data.telegram_bot_token || "";
    chat.value = data.telegram_chat_id || "";
    url.value = data.healthchecks_url || "";
    token.placeholder = "Paste your bot token";
    url.placeholder = "https://hc-ping.com/…";
    reset.disabled = !allowed || !data.overridden;
    telegramEnabled.disabled = healthchecksEnabled.disabled = bitcoinNewBlock.disabled = moneroNewBlock.disabled = towerLabels.disabled = defaultCurrency.disabled = !allowed;
    updateInputs();
    updatePortPlan();
  };
  async function request(method = "GET", payload) {
    const response = await fetch("/api/settings", {
      method,
      headers: payload ? { "Content-Type": "application/json", "X-Requested-With": "fetch" } : {},
      ...(payload ? { body: JSON.stringify(payload) } : {}),
    });
    if (!response.ok) {
      const text = (await response.text()).trim();
      throw new Error(text.length <= 200 ? text : "Could not update settings.");
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
      const error = new Error(text.length <= 200 ? text : "Could not update LAN ports.");
      error.definitive = true;
      throw error;
    }
    return response.json();
  }
  async function loadPortControl() {
    try {
      const data = await requestPortControl();
      const view = portControlModel(data);
      renderPortControl(data);
      if (ambiguousPortDraft) {
        const { draft, changes } = ambiguousPortDraft;
        const outcome = portSubmissionOutcome(view, changes);
        if (outcome === "queued") {
          ambiguousPortDraft = undefined;
          status.textContent = settingsSaveMessage(ambiguousStatusPrefix !== "");
        } else if (outcome === "applied") {
          ambiguousPortDraft = undefined;
          stagedPortDraft = undefined;
          updatePortPlan(false);
          status.textContent = settingsSaveMessage(ambiguousStatusPrefix !== "");
        } else {
          ambiguousPortDraft = undefined;
          applyPortDraft(draft);
          status.textContent = `${ambiguousStatusPrefix}The restart request status is unknown; review the LAN port values before trying again.`;
        }
        ambiguousStatusPrefix = "";
      }
    }
    catch { if (dialog.open) portPoll = setTimeout(loadPortControl, 2000); }
  }
  async function load() {
    allowed = false;
    save.disabled = reset.disabled = true;
    telegramEnabled.disabled = healthchecksEnabled.disabled = bitcoinNewBlock.disabled = moneroNewBlock.disabled = towerLabels.disabled = defaultCurrency.disabled = true;
    updateInputs();
    updatePortPlan();
    for (const input of Object.values(extraNewBlock)) input.disabled = true;
    status.textContent = "Loading…";
    try {
      render(await request());
      status.textContent = allowed ? "" : "Settings are unavailable.";
    }
    catch (error) { status.textContent = error.message; }
  }
  byId("open").addEventListener("click", () => { dialog.showModal(); load(); });
  byId("close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => { clearSecrets(); clearTimeout(portPoll); });
  telegramEnabled.addEventListener("change", updateInputs);
  healthchecksEnabled.addEventListener("change", updateInputs);
  for (const row of Object.values(portRows)) {
    for (const input of row.querySelectorAll("input")) input.addEventListener("input", () => updatePortPlan(true));
  }

  const settingsPayload = () => notificationPayload({
    telegram_enabled: telegramEnabled.checked,
    telegram_bot_token: token.value,
    telegram_chat_id: chat.value,
    healthchecks_enabled: healthchecksEnabled.checked,
    healthchecks_url: url.value,
    alert_new_block_bitcoin: bitcoinNewBlock.checked,
    alert_new_block_monero: moneroNewBlock.checked,
    ...Object.fromEntries(Object.entries(extraNewBlock).map(([node,input]) => [`alert_new_block_${node}`,input.checked])),
    tower_labels: towerLabels.checked,
    default_currency: defaultCurrency.value,
  });

  const validatePortPlan = (changes) => {
    for (const row of Object.values(portRows)) row.querySelector("[data-port-number]").setCustomValidity("");
    for (const change of changes) {
      if (!change.enabled || Number.isInteger(change.host_port) && change.host_port >= 1 && change.host_port <= 65535) continue;
      portRows[change.port].querySelector("[data-port-number]").setCustomValidity("Enter a port from 1 to 65535.");
      return false;
    }
    const collision = portCollision(changes, portDraft(), savedPorts);
    if (collision) {
      portRows[collision].querySelector("[data-port-number]").setCustomValidity(portStatusMessage({ error_code: "port_in_use", port: collision }));
      return false;
    }
    return true;
  };

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!allowed) return;
    const changes = updatePortPlan(true);
    const draft = portDraft();
    const portPlanValid = validatePortPlan(changes);
    const formValid = form.reportValidity();
    if (!portPlanValid || !formValid) return;
    const payload = settingsPayload();
    const saveNotifications = notificationChanged(saved, payload);
    if (!saveNotifications && changes.length === 0) {
      status.textContent = "No changes.";
      return;
    }
    save.disabled = reset.disabled = true;
    status.textContent = "Saving…";
    let settingsView = saved;
    if (saveNotifications) {
      try {
        settingsView = await request("POST", payload);
      } catch (error) {
        clearSecrets();
        status.textContent = error.message;
        save.disabled = !allowed;
        reset.disabled = !allowed || !saved.overridden;
        updateInputs();
        return;
      }
    }
    if (changes.length === 0) {
      render(settingsView);
      status.textContent = "Settings saved.";
      return;
    }
    try {
      const portView = await requestPortControl("POST", { changes });
      render(settingsView);
      if (/^[0-9a-f]{32}$/.test(String(portView?.status?.id || ""))) {
        portRequestID = portView.status.id;
        try { localStorage.setItem("nodeStackPortRequest", portRequestID); } catch {}
      }
      renderPortControl(portView);
      status.textContent = settingsSaveMessage(saveNotifications);
    } catch (error) {
      render(settingsView);
      applyPortDraft(draft);
      const prefix = saveNotifications ? "Settings saved, but " : "";
      if (error.definitive) {
        status.textContent = `${prefix}LAN port changes were rejected: ${error.message}`;
      } else {
        ambiguousPortDraft = { draft, changes };
        ambiguousStatusPrefix = saveNotifications ? "Settings saved. " : "";
        status.textContent = `${ambiguousStatusPrefix}Checking whether the restart was queued…`;
        loadPortControl();
      }
    }
  });
  reset.addEventListener("click", async () => {
    if (!allowed) return;
    save.disabled = reset.disabled = true;
    status.textContent = "Saving…";
    try {
      render(await request("POST", { reset: true }));
      status.textContent = "Using the server configuration.";
    } catch (error) {
      status.textContent = error.message;
      save.disabled = !allowed;
      reset.disabled = !allowed || !saved.overridden;
    }
  });
  fetch("/api/settings?scope=appearance")
    .then((response) => response.ok ? response.json() : Promise.reject())
    .then(applyAppearance)
    .catch(() => applyAppearance({}));
}
