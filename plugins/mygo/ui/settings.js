const byId = (id) => document.getElementById(id);
const rolePurposes = {
  researcher: "资料检索",
  builder: "代码构建",
  reviewer: "方案与审核",
  writer: "写作与视觉",
  executor: "执行与验证",
};
const effortOptions = [
  ["low", "低"], ["medium", "中"], ["high", "高"], ["xhigh", "很高"], ["max", "最高"],
];
const pending = new Map();
let requestId = 0;
let state = null;
let bridgeReady;

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
    const statusText = provider.configured ? "Magpie 已配置" : provider.environment ? "检测到本机环境变量" : "尚未检测到密钥";
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
  const needsSync = hasPendingModels(rolePreferences());
  const status = byId("v2-status");
  status.textContent = needsSync ? "有模型待同步" : state.v2_configured ? "已写入配置" : "未配置";
  status.classList.toggle("ready", state.v2_configured && !needsSync);
  status.classList.toggle("pending", needsSync);
  byId("configure").textContent = needsSync ? "同步所选模型" : "写入原生 V2 配置";
  const details = byId("setup-details");
  details.replaceChildren();
  const cliStatus = state.magpie_compatible ? `Magpie ${state.magpie_version}` : "写入配置时会下载并校验兼容的 Magpie CLI。";
  details.appendChild(element("p", "", cliStatus));
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
    title.appendChild(element("span", "role-purpose", rolePurposes[key]));
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

async function saveRoles() {
  const result = await callTool("save_roles", { preferences: rolePreferences() });
  state.roles = result.preferences;
  return result;
}

async function refresh() {
  const updated = await callTool("read_settings");
  const draft = state ? rolePreferences() : null;
  const edited = draft && JSON.stringify(draft) !== JSON.stringify(state.roles);
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
  refreshButton.disabled = saveButton.disabled = configureButton.disabled = true;
  try {
    await action();
  } catch (error) {
    report(error.message, true);
  } finally {
    refreshButton.disabled = false;
    saveButton.disabled = configureButton.disabled = !state;
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
byId("configure").addEventListener("click", () => runSettingsAction(async () => {
  report("正在检查模型目录并写入原生 V2 配置，可能需要下载兼容 CLI。");
  await saveRoles();
  const result = await callTool("configure_native");
  const backup = result.backup ? `\n备份目录 ${result.backup}` : "";
  report(`配置完成。请重启 Codex 以加载模型目录。${backup}`);
  await refresh();
}));

bridgeReady = rpc("ui/initialize", {
  appInfo: { name: "mygo-settings", version: "0.3.0" },
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
