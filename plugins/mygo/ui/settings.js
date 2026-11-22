const byId = (id) => document.getElementById(id);
const effortOptions = [
  ["low", "低"], ["medium", "中"], ["high", "高"], ["xhigh", "很高"], ["max", "最高"],
];
const pending = new Map();
let requestId = 0;
let state = null;
let bridgeReady;
let restartPending = false;

function notify(method, params = {}) {
  window.parent.postMessage({ jsonrpc: "2.0", method, params }, "*");
}

function rpc(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++requestId;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error("设置服务未及时响应，请重新打开面板。"));
    }, 180000);
    pending.set(id, { resolve, reject, timer });
    window.parent.postMessage({ jsonrpc: "2.0", id, method, params }, "*");
  });
}

function updateTheme(theme) {
  if (theme === "light" || theme === "dark") document.documentElement.dataset.theme = theme;
}

window.addEventListener("message", (event) => {
  if (event.source !== window.parent) return;
  const message = event.data;
  if (message?.jsonrpc !== "2.0") return;
  if (message.method === "ui/notifications/host-context-changed") {
    updateTheme(message.params?.theme);
    return;
  }
  if (typeof message.id !== "number") return;
  const request = pending.get(message.id);
  if (!request) return;
  pending.delete(message.id);
  clearTimeout(request.timer);
  if (message.error) request.reject(new Error(message.error.message || "设置服务返回错误。"));
  else request.resolve(message.result);
}, { passive: true });

function report(message, error = false) {
  const notice = byId("notice");
  notice.textContent = message;
  notice.classList.toggle("error", error);
  notice.hidden = false;
}

function resize() {
  notify("ui/notifications/size-changed", {
    height: Math.ceil(document.documentElement.scrollHeight),
  });
}

async function callTool(name, args = {}) {
  await bridgeReady;
  const result = await rpc("tools/call", { name, arguments: args });
  if (result?.isError) throw new Error(result.content?.map((item) => item.text || "").join("\n") || "操作失败。");
  return result?.structuredContent || {};
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function renderProviders() {
  const container = byId("providers");
  const glmPlan = byId("glm-plan")?.value;
  container.replaceChildren();
  const entries = Object.entries(state.credentials || {});
  const ready = entries.filter(([, provider]) => provider.configured).length;
  byId("ready-count").textContent = `${ready} / ${entries.length} 已接入 Magpie`;
  byId("ready-count").classList.toggle("ready", ready === entries.length);
  byId("credential-help").hidden = ready === entries.length;
  for (const [name, provider] of entries) {
    const row = element("div", "provider");
    row.appendChild(element("strong", "provider-name", provider.label));
    const statusText = provider.configured ? "密钥已配置" : provider.environment ? "检测到本机环境变量" : "尚未检测到密钥";
    row.appendChild(element("span", `provider-state${provider.configured ? " ready" : ""}`, statusText));
    if (!provider.configured) {
      if (name === "glm") {
        const planField = byId("glm-plan-field").content.cloneNode(true);
        if (glmPlan) planField.querySelector("select").value = glmPlan;
        row.appendChild(planField);
      }
      const actions = element("div", "provider-actions");
      if (provider.environment) {
        const envButton = element("button", "secondary", "从环境变量导入");
        envButton.addEventListener("click", () => importCredential(name, "environment", envButton));
        actions.appendChild(envButton);
      }
      const promptButton = element("button", "secondary", "打开密码窗口");
      promptButton.addEventListener("click", () => importCredential(name, "prompt", promptButton));
      actions.appendChild(promptButton);
      row.appendChild(actions);
    }
    container.appendChild(row);
  }
}

function hasPendingModels(preferences) {
  return state.v2_configured && Object.entries(preferences.roles).some(([key, role]) =>
    state.model_choices[key].needs_sync.includes(role.model));
}

function renderNativeStatus() {
  const preferences = rolePreferences();
  const needsSync = hasPendingModels(preferences);
  const selectedProviders = new Set(Object.values(preferences.roles).map(role => role.model.split("/")[0]));
  const missingKeys = Object.values(state.credentials).filter(item =>
    !item.configured && selectedProviders.has(item.provider_id));
  const status = byId("v2-status");
  const configured = state.v2_configured;
  const ready = configured && !needsSync && !missingKeys.length;
  status.textContent = missingKeys.length ? `待接入 ${missingKeys.map(item => item.label).join("、")}`
    : !configured ? "尚未启用原生子代理" : needsSync ? "所选模型待同步"
    : restartPending ? "配置已更新，请重启 Codex" : "原生配置已就绪";
  const symbol = byId("native-symbol");
  symbol.textContent = ready ? "✓" : "·";
  symbol.classList.toggle("ready", ready);
  byId("native-details").classList.toggle("compact", ready);
  const action = byId("configure");
  byId("key-link").hidden = !missingKeys.length;
  action.hidden = ready || missingKeys.length > 0;
  action.textContent = needsSync ? "同步所选模型" : "启用原生子代理";
  byId("rewrite").hidden = !ready;
  const cli = state.magpie_version ? `版本 ${state.magpie_version}` : state.magpie_installed ? "版本未识别" : "未检测到";
  byId("cli-detail").textContent = state.magpie_compatible ? cli : `${cli}。下次写入配置时将准备兼容版本。`;
  byId("catalog-detail").textContent = !state.model_catalog ? "未找到本地目录"
    : needsSync ? "待写入所选型号" : configured ? "已关联本地目录" : "已有本地目录，尚未启用";

}

async function importCredential(provider, source, button) {
  button.disabled = true;
  try {
    const args = { provider, source };
    if (provider === "glm") args.glm_plan = byId("glm-plan").value;
    const result = await callTool("import_credential", args);
    report(result.message || "这家供应商已在 Magpie 中配置。请刷新状态。");
  } catch (error) {
    report(error.message, true);
  } finally {
    button.disabled = false;
  }
}

function renderRoles(preferences) {
  const container = byId("roles");
  const expandedRoles = new Set([...container.querySelectorAll(".role details[open]")].map((details) =>
    details.closest(".role").dataset.role));
  container.replaceChildren();
  for (const [key, role] of Object.entries(preferences.roles)) {
    const group = state.model_choices[key];
    const card = element("article", "role");
    card.dataset.role = key;
    const title = element("div", "role-title");
    title.appendChild(element("h3", "", group.provider));
    title.appendChild(element("span", "role-purpose", role.responsibility));
    card.appendChild(title);

    const choices = [...new Set([role.model, ...group.options])].map((id) => {
      const retained = id === group.retained_model || !group.options.includes(id);
      return [id, retained ? `${id} · 现有选择` : id.replace(/^[^/]+\//, "")];
    });
    const model = selectControl("model", role.model, choices);
    model.setAttribute("aria-label", `${group.provider} 型号`);
    const modelField = element("div", "model-field");
    const note = element("a", "model-note", "此型号需要同步到原生 V2");
    note.href = "#native-heading";
    const updateModelNote = () => {
      note.hidden = !state.v2_configured || !group.needs_sync.includes(model.value);
    };
    model.addEventListener("change", () => {
      updateModelNote();
      renderNativeStatus();
    });
    updateModelNote();
    modelField.append(model, note);
    card.appendChild(modelField);

    const name = element("input");
    name.type = "text";
    name.name = "label";
    name.maxLength = 60;
    name.value = role.label;
    const effort = selectControl("effort", role.effort, effortOptions);
    const fieldRow = element("div", "field-row");
    fieldRow.append(field("角色名称", name), field("推理强度", effort));

    const responsibility = element("textarea");
    responsibility.name = "responsibility";
    responsibility.maxLength = 1000;
    responsibility.rows = 2;
    responsibility.value = role.responsibility;
    const settings = element("details", "role-settings");
    settings.open = expandedRoles.has(key);
    const fields = element("div", "role-settings-fields");
    fields.append(fieldRow, field("默认职责", responsibility));
    settings.append(element("summary", "", "分工设置"), fields);
    card.appendChild(settings);
    container.appendChild(card);
  }
}

function field(text, control) {
  const label = element("label", "field");
  label.append(element("span", "", text), control);
  return label;
}

function selectControl(name, value, choices) {
  const select = element("select");
  select.name = name;
  for (const [id, label] of choices) {
    const option = element("option", "", label);
    option.value = id;
    select.appendChild(option);
  }
  select.value = value;
  return select;
}

function rolePreferences() {
  const roles = {};
  for (const card of byId("roles").querySelectorAll(".role")) {
    const values = {};
    for (const name of ["label", "model", "responsibility", "effort"]) {
      values[name] = card.querySelector(`[name="${name}"]`).value.trim();
    }
    roles[card.dataset.role] = values;
  }
  return { version: 1, roles };
}

function rolesEdited(draft) {
  return Object.entries(draft.roles).some(([key, role]) =>
    Object.entries(role).some(([field, value]) => value !== state.roles.roles[key][field]));
}

byId("roles").addEventListener("input", () => {
  if (state && !byId("refresh").disabled) byId("save-roles").disabled = !rolesEdited(rolePreferences());
});

async function saveRoles() {
  const result = await callTool("save_roles", { preferences: rolePreferences() });
  state.roles = result.preferences;
  for (const card of byId("roles").querySelectorAll(".role")) {
    card.querySelector(".role-purpose").textContent = state.roles.roles[card.dataset.role].responsibility;
  }
  return result;
}

async function refresh() {
  const updated = await callTool("read_settings");
  const draft = state ? rolePreferences() : null;
  const edited = draft && rolesEdited(draft);
  state = updated;
  renderRoles(edited ? draft : state.roles);
  renderProviders();
  renderNativeStatus();
  resize();
}

async function runSettingsAction(action) {
  const refreshButton = byId("refresh");
  const saveButton = byId("save-roles");
  const configureButton = byId("configure");
  refreshButton.disabled = saveButton.disabled = configureButton.disabled = byId("rewrite").disabled = true;
  try {
    await action();
  } catch (error) {
    report(error.message, true);
  } finally {
    refreshButton.disabled = false;
    configureButton.disabled = byId("rewrite").disabled = !state;
    saveButton.disabled = !state || !rolesEdited(rolePreferences());
  }
}

byId("refresh").addEventListener("click", () => runSettingsAction(async () => {
  await refresh();
  report("状态已刷新。");
}));
byId("save-roles").addEventListener("click", () => runSettingsAction(async () => {
  await saveRoles();
  report(hasPendingModels(state.roles) ? "分工预设已保存。请在原生子代理区同步所选型号。" : "分工预设已保存。");
}));
function writeNative() {
  return runSettingsAction(async () => {
    report("正在写入模型目录和原生子代理配置…");
    if (rolesEdited(rolePreferences())) await saveRoles();
    const result = await callTool("configure_native");
    restartPending = result.restart_required === true;
    const backup = result.backup ? `\n备份目录 ${result.backup}` : "";
    report(`配置完成。请重启 Codex 以加载模型目录。${backup}`);
    await refresh();
  });
}
byId("configure").addEventListener("click", writeNative);
byId("rewrite").addEventListener("click", writeNative);

bridgeReady = rpc("ui/initialize", {
  appInfo: { name: "mygo-settings", version: "0.3.1" },
  appCapabilities: {},
  protocolVersion: "2026-01-26",
}).then((result) => {
  updateTheme(result?.hostContext?.theme);
  notify("ui/notifications/initialized", {});
  return result;
});

bridgeReady.then(() => runSettingsAction(refresh)).catch((error) => report(error.message, true));
new ResizeObserver(resize).observe(document.body);
window.addEventListener("pagehide", () => {
  for (const request of pending.values()) clearTimeout(request.timer);
  pending.clear();
  notify("ui/notifications/teardown", {});
}, { once: true });
