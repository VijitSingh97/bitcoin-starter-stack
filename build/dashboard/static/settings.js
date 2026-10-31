import { credentialSettingsController } from "./credentials.js";

const extraNodes = ["tari", "litecoin", "dogecoin", "bitcoincash", "zcash"];
const allNodes = ["bitcoin", "monero", ...extraNodes];
const allPortIDs = ["bitcoin_rpc", "monero_rpc", "monero_zmq", "tari_grpc", "litecoin_rpc", "dogecoin_rpc", "bitcoincash_rpc", "zcash_rpc"];
const nodePortIDs = {
  bitcoin: ["bitcoin_rpc"], monero: ["monero_rpc", "monero_zmq"], tari: ["tari_grpc"],
  litecoin: ["litecoin_rpc"], dogecoin: ["dogecoin_rpc"], bitcoincash: ["bitcoincash_rpc"], zcash: ["zcash_rpc"],
};

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
  return Object.entries(payload).some(([field, value]) => {
    const previous = field === "alert_new_block" ? saved?.alert_new_block_bitcoin ?? saved?.alert_new_block
      : field === "default_currency" ? normalizeDefaultCurrency(saved?.default_currency)
      : saved?.[field];
    return value !== previous;
  });
}

export function settingsEndpoint(scope = "global", method = "GET") {
  return scope === "global" ? (method === "GET" ? "/api/settings" : "/api/settings?scope=global") : "/api/settings?scope=nodes";
}

export function portStatusNode(port, submittedNode = "", changedNodes = []) {
  return Object.keys(nodePortIDs).find((node) => nodePortIDs[node].includes(port))
    || (allNodes.includes(submittedNode) ? submittedNode : "")
    || changedNodes.find((node) => allNodes.includes(node))
    || "";
}

export function scopedSettingsPayload(scope, values) {
  if (scope !== "global") {
    const field = scope === "bitcoin" ? "alert_new_block" : `alert_new_block_${scope}`;
    return { [field]: values?.[field] === true };
  }
  const payload = notificationPayload(values || {});
  for (const field of Object.keys(payload)) if (field.startsWith("alert_new_block")) delete payload[field];
  return payload;
}

export async function requestSettings(scope = "global", method = "GET", payload, fetcher = fetch) {
  const response = await fetcher(settingsEndpoint(scope, method), {
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
  const nodeAccents = { bitcoin: "#f2a900", monero: "#ff6600", tari: "#8f5cff", litecoin: "#4d8fd8", dogecoin: "#b88746", bitcoincash: "#36a852", zcash: "#d69c35" };
  const nodeViews = {};
  for (const node of allNodes) {
    const details = byId(`${node}-alerts`);
    const panel = document.querySelector(`[data-node-panel="${node}"]`);
    const power = panel?.querySelector(".node-power-card");
    if (!details || !power) continue;
    details.querySelector("summary").textContent = "Alerts and LAN access";
    const card = document.createElement("section");
    card.className = "card node-settings-card";
    card.style.setProperty("--node-accent", nodeAccents[node]);
    const heading = document.createElement("h2");
    heading.textContent = "Node settings";
    const nodeForm = document.createElement("form");
    nodeForm.dataset.nodeSettingsForm = node;
    const nodeStatus = document.createElement("p");
    nodeStatus.className = "settings-note";
    nodeStatus.setAttribute("role", "status");
    nodeStatus.setAttribute("aria-live", "polite");
    const impact = document.createElement("p");
    impact.className = "settings-note";
    impact.textContent = "Will restart services: Tor relay, dashboard.";
    impact.hidden = true;
    const actions = document.createElement("div");
    actions.className = "settings-actions";
    const nodeSave = document.createElement("button");
    nodeSave.type = "submit";
    nodeSave.textContent = "Save";
    actions.append(nodeSave);
    details.append(nodeStatus, impact, actions);
    nodeForm.append(details);
    card.append(heading, nodeForm);
    power.before(card);
    nodeViews[node] = { card, form: nodeForm, status: nodeStatus, impact, save: nodeSave };
  }
  byId("port-status")?.remove();
  byId("port-impact")?.remove();
  const credentialSettings = credentialSettingsController(dialog, document);
  let saved = {};
  let savedPorts = {};
  let allowed = false;
  let portAvailable = false;
  let portState = "";
  let portPoll;
  let portRequestID = "";
  let ambiguousPortDraft;
  let ambiguousStatusPrefix = "";
  let ambiguousStatusTarget;
  let submittedPortNode = "";
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
  const changesForNode = (node, changes = portChanges(savedPorts, portDraft())) => changes.filter((change) => nodePortIDs[node].includes(change.port));

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
    for (const [node, view] of Object.entries(nodeViews)) {
      const nodeChanges = changesForNode(node, changes);
      view.impact.hidden = nodeChanges.length === 0;
      view.save.textContent = nodeChanges.length > 0 ? (pending ? "Restart pending" : "Save & restart") : "Save";
      view.save.disabled = !allowed || pending;
    }
    save.textContent = "Save";
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
    const message = portStatusMessage(view);
    const changedNodes = Object.keys(nodeViews).filter((node) => changesForNode(node).length);
    const messageNode = portStatusNode(view.port, submittedPortNode, changedNodes);
    for (const [node, nodeView] of Object.entries(nodeViews)) {
      nodeView.status.textContent = message && node === messageNode
        ? message
        : !view.available && nodePortIDs[node].some((id) => view.ports[id])
          ? "LAN port changes require a dashboard password and the installed host helper."
          : "";
    }
    clearTimeout(portPoll);
    if (shouldPollPort(dialog.open || !!document.body.dataset.node, view.state)) portPoll = setTimeout(loadPortControl, 2000);
    updatePortPlan();
    if (requestMatches && view.state === "applied" && document.body.dataset.node) credentialSettings.openNode();
    if (view.state && view.state !== "pending") submittedPortNode = "";
    return view;
  };

  const clearSecrets = () => { token.value = ""; chat.value = ""; url.value = ""; };
  const updateInputs = () => {
    token.disabled = chat.disabled = !allowed || !telegramEnabled.checked;
    url.disabled = !allowed || !healthchecksEnabled.checked;
    chat.required = allowed && telegramEnabled.checked;
    token.required = chat.required && !saved.telegram_bot_token;
    url.required = allowed && healthchecksEnabled.checked && !saved.healthchecks_url;
  };
  const render = (data, scope = "global") => {
    saved = { ...saved, ...data };
    allowed = configurationAccess(data);
    if (scope === "global") {
      telegramEnabled.checked = !!data.telegram_enabled;
      healthchecksEnabled.checked = !!data.healthchecks_enabled;
    }
    if (Object.hasOwn(data, "alert_new_block_bitcoin") || Object.hasOwn(data, "alert_new_block")) bitcoinNewBlock.checked = !!(data.alert_new_block_bitcoin ?? data.alert_new_block);
    if (Object.hasOwn(data, "alert_new_block_monero")) moneroNewBlock.checked = !!data.alert_new_block_monero;
    const nodes = configuredNodeVisibility(data);
    for (const node of allNodes) {
      byId(`${node}-alerts`).hidden = !nodes[node];
      if (nodeViews[node]) nodeViews[node].card.hidden = !nodes[node];
    }
    for (const [node,input] of Object.entries(extraNewBlock)) {
      if (Object.hasOwn(data, `alert_new_block_${node}`)) input.checked = !!data[`alert_new_block_${node}`];
      input.disabled = !allowed;
    }
    renderPortControl(data.port_control);
    if (scope === "global") {
      towerLabels.checked = !!data.tower_labels;
      defaultCurrency.value = normalizeDefaultCurrency(data.default_currency);
      applyAppearance(data);
      if (Object.hasOwn(data, "telegram_chat_id")) chat.value = data.telegram_chat_id || "";
      if (dialog.open) {
        if (Object.hasOwn(data, "telegram_bot_token")) token.value = data.telegram_bot_token || "";
        if (Object.hasOwn(data, "healthchecks_url")) url.value = data.healthchecks_url || "";
      } else clearSecrets();
    }
    token.placeholder = "Paste your bot token";
    url.placeholder = "https://hc-ping.com/…";
    reset.disabled = !allowed || !data.overridden;
    telegramEnabled.disabled = healthchecksEnabled.disabled = bitcoinNewBlock.disabled = moneroNewBlock.disabled = towerLabels.disabled = defaultCurrency.disabled = !allowed;
    updateInputs();
    updatePortPlan();
  };
  async function request(method = "GET", payload, scope = "global") {
    return requestSettings(scope, method, payload);
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
          (ambiguousStatusTarget || status).textContent = settingsSaveMessage(ambiguousStatusPrefix !== "");
        } else if (outcome === "applied") {
          ambiguousPortDraft = undefined;
          stagedPortDraft = undefined;
          updatePortPlan(false);
          (ambiguousStatusTarget || status).textContent = settingsSaveMessage(ambiguousStatusPrefix !== "");
        } else {
          ambiguousPortDraft = undefined;
          applyPortDraft(draft);
          (ambiguousStatusTarget || status).textContent = `${ambiguousStatusPrefix}The restart request status is unknown; review the LAN port values before trying again.`;
        }
        ambiguousStatusPrefix = "";
        ambiguousStatusTarget = undefined;
      }
    }
    catch { if (dialog.open || document.body.dataset.node) portPoll = setTimeout(loadPortControl, 2000); }
  }
  async function load(scope = "global") {
    allowed = false;
    save.disabled = reset.disabled = true;
    telegramEnabled.disabled = healthchecksEnabled.disabled = bitcoinNewBlock.disabled = moneroNewBlock.disabled = towerLabels.disabled = defaultCurrency.disabled = true;
    updateInputs();
    updatePortPlan();
    for (const input of Object.values(extraNewBlock)) input.disabled = true;
    status.textContent = "Loading…";
    try {
      render(await request("GET", undefined, scope), scope);
      status.textContent = allowed ? "" : "Settings are unavailable.";
    }
    catch (error) { status.textContent = error.message; }
  }
  byId("open").addEventListener("click", () => { dialog.showModal(); credentialSettings.openPassword(); load(); });
  byId("close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => { clearSecrets(); credentialSettings.closePassword(); delete saved.telegram_bot_token; delete saved.telegram_chat_id; delete saved.healthchecks_url; });
  window.addEventListener("node-selected", (event) => {
    credentialSettings.closeNode();
    if (event.detail?.node) {
      credentialSettings.openNode();
      load("nodes");
    }
  });
  telegramEnabled.addEventListener("change", updateInputs);
  healthchecksEnabled.addEventListener("change", updateInputs);
  for (const row of Object.values(portRows)) {
    for (const input of row.querySelectorAll("input")) input.addEventListener("input", () => updatePortPlan(true));
  }

  const settingsPayload = (scope = "global") => scopedSettingsPayload(scope, scope === "global" ? {
      telegram_enabled: telegramEnabled.checked,
      telegram_bot_token: token.value,
      telegram_chat_id: chat.value,
      healthchecks_enabled: healthchecksEnabled.checked,
      healthchecks_url: url.value,
      tower_labels: towerLabels.checked,
      default_currency: defaultCurrency.value,
    } : { [scope === "bitcoin" ? "alert_new_block" : `alert_new_block_${scope}`]:
      (scope === "bitcoin" ? bitcoinNewBlock : scope === "monero" ? moneroNewBlock : extraNewBlock[scope]).checked });

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

  const saveScope = async (scope, scopeForm, targetStatus, targetSave) => {
    if (!allowed) return;
    const allChanges = updatePortPlan(true);
    const changes = scope === "global" ? [] : changesForNode(scope, allChanges);
    const draft = portDraft();
    const portPlanValid = validatePortPlan(changes);
    const formValid = scopeForm.reportValidity();
    if (!portPlanValid || !formValid) return;
    const payload = settingsPayload(scope);
    const saveNotifications = notificationChanged(saved, payload);
    if (!saveNotifications && changes.length === 0) {
      targetStatus.textContent = "No changes.";
      return;
    }
    targetSave.disabled = true;
    if (scope === "global") reset.disabled = true;
    targetStatus.textContent = "Saving…";
    let settingsView = saved;
    if (saveNotifications) {
      try {
        settingsView = await request("POST", payload, scope);
      } catch (error) {
        clearSecrets();
        targetStatus.textContent = error.message;
        targetSave.disabled = !allowed;
        reset.disabled = !allowed || !saved.overridden;
        updateInputs();
        updatePortPlan();
        return;
      }
    }
    if (changes.length === 0) {
      render(settingsView, scope);
      targetStatus.textContent = "Settings saved.";
      return;
    }
    render(settingsView, scope);
    submittedPortNode = scope;
    try {
      const portView = await requestPortControl("POST", { changes });
      if (/^[0-9a-f]{32}$/.test(String(portView?.status?.id || ""))) {
        portRequestID = portView.status.id;
        try { localStorage.setItem("nodeStackPortRequest", portRequestID); } catch {}
      }
      renderPortControl(portView);
      targetStatus.textContent = portStatusMessage(portControlModel(portView)) || settingsSaveMessage(saveNotifications);
    } catch (error) {
      applyPortDraft(draft);
      const prefix = saveNotifications ? "Settings saved, but " : "";
      if (error.definitive) {
        submittedPortNode = "";
        targetStatus.textContent = `${prefix}LAN port changes were rejected: ${error.message}`;
      } else {
        ambiguousPortDraft = { draft, changes };
        ambiguousStatusPrefix = saveNotifications ? "Settings saved. " : "";
        ambiguousStatusTarget = targetStatus;
        targetStatus.textContent = `${ambiguousStatusPrefix}Checking whether the restart was queued…`;
        loadPortControl();
      }
    }
  };
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    saveScope("global", form, status, save);
  });
  for (const [node, view] of Object.entries(nodeViews)) {
    view.form.addEventListener("submit", (event) => {
      event.preventDefault();
      saveScope(node, view.form, view.status, view.save);
    });
  }
  reset.addEventListener("click", async () => {
    if (!allowed) return;
    save.disabled = reset.disabled = true;
    status.textContent = "Saving…";
    try {
      render(await request("POST", { reset: true }), "global");
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
  credentialSettings.start();
  load("nodes");
}
