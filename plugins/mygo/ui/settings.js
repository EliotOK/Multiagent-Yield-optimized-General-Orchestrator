const byId = (id) => document.getElementById(id);
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
  for (const [name, provider] of entries) {
    const row = element("div", "provider");
    row.appendChild(element("span", "provider-name", provider.label));
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
  byId("v2-status").textContent = state.v2_configured ? "已写入配置" : "未配置";
  const details = byId("setup-details");
  details.replaceChildren();
  details.appendChild(element("div", "", state.magpie_installed ? `Magpie ${state.magpie_version || "版本未知"}${state.magpie_compatible ? "，支持安全导入" : "，配置时将安装兼容 CLI"}` : "配置时将下载并校验兼容的 Magpie CLI"));
  if (state.v2_configured && state.missing_models?.length) {
    details.appendChild(element("div", "warning", `当前目录缺少：${state.missing_models.join("、")}`));
  }
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

function renderRoles() {
  const container = byId("roles");
  container.replaceChildren();
  for (const [key, role] of Object.entries(state.roles.roles)) {
    const card = element("div", "role");
    card.dataset.role = key;
    const title = element("div", "role-title");
    title.appendChild(element("strong", "", role.label));
    title.appendChild(element("span", "role-key", key));
    card.appendChild(title);
    const modelRow = element("div", "role-model");
    modelRow.appendChild(field("模型 ID", "model", role.model));
    const effort = field("推理强度", "effort", role.effort, "select");
    const select = effort.querySelector("select");
    for (const value of ["low", "medium", "high", "xhigh", "max"]) {
      const option = element("option", "", value);
      option.value = value;
      option.selected = value === role.effort;
      select.appendChild(option);
    }
    modelRow.appendChild(effort);
    card.appendChild(modelRow);
    card.appendChild(field("显示名称", "label", role.label));
    card.appendChild(field("默认职责", "responsibility", role.responsibility, "textarea"));
    container.appendChild(card);
  }
  byId("preferences-path").textContent = state.preferences_path;
}

function field(labelText, name, value, type = "input") {
  const wrapper = element("div", "field");
  const label = element("label", "", labelText);
  const input = document.createElement(type === "input" ? "input" : type);
  input.name = name;
  input.value = value;
  if (type === "input") input.type = "text";
  label.appendChild(input);
  wrapper.appendChild(label);
  return wrapper;
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
  state = await callTool("read_settings");
  renderProviders();
  renderRoles();
  resize();
}

byId("refresh").addEventListener("click", () => refresh().then(() => report("状态已刷新。")).catch((error) => report(error.message, true)));
byId("save-roles").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    await saveRoles();
    report("分工预设已保存，之后每次派发都会读取。");
  } catch (error) {
    report(error.message, true);
  } finally {
    button.disabled = false;
  }
});
byId("configure").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  button.disabled = true;
  report("正在检查模型目录并写入原生 V2 配置，可能需要下载兼容 CLI。");
  try {
    await saveRoles();
    const result = await callTool("configure_native");
    report(`配置完成。请彻底重启 Codex，再重开原聊天验收子代理。\n备份：${result.backup || "无需备份"}`);
    await refresh();
  } catch (error) {
    report(error.message, true);
  } finally {
    button.disabled = false;
  }
});

bridgeReady = rpc("ui/initialize", {
  appInfo: { name: "mygo-settings", version: "0.2.1" },
  appCapabilities: {},
  protocolVersion: "2026-01-26",
}).then((result) => {
  updateTheme(result?.hostContext?.theme);
  notify("ui/notifications/initialized", {});
  return result;
});

bridgeReady.then(refresh).catch((error) => report(error.message, true));
new ResizeObserver(resize).observe(document.body);
window.addEventListener("pagehide", () => {
  for (const request of pending.values()) clearTimeout(request.timer);
  pending.clear();
  notify("ui/notifications/teardown", {});
}, { once: true });
