const byId = (id) => document.getElementById(id);
const effortOptions = [
  ["low", "低"], ["medium", "中"], ["high", "高"], ["xhigh", "很高"], ["max", "最高"],
];
const roleTitles = {
  researcher: "资料检索", builder: "代码构建", reviewer: "方案与审核",
  writer: "写作与视觉", executor: "执行与验证",
};
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
  byId("ready-count").textContent = ready + " 家已接入 Magpie";
  byId("ready-count").classList.toggle("ready", ready === entries.length);
  byId("credential-help").hidden = ready === entries.length;
  const preset = byId("provider-preset");
  const picked = preset.value;
  const options = Object.entries(state.provider_presets || {}).sort((a, b) => a[1].localeCompare(b[1]));
  preset.replaceChildren(new Option(options.length ? "选择供应商" : "没有可添加的预设", ""),
    ...options.map(([id, label]) => new Option(label, id)));
  if (options.some(([id]) => id === picked)) preset.value = picked;
  preset.disabled = !options.length;
  byId("add-provider-key").disabled = !preset.value;
  for (const [name, provider] of entries) {
    const row = element("div", "provider");
    row.appendChild(element("strong", "provider-name", provider.label));
    const statusText = provider.configured ? "密钥已配置" : provider.environment ? "检测到本机环境变量" : "尚未检测到密钥";
    row.appendChild(element("span", `provider-state${provider.configured ? " ready" : ""}`, statusText));
    const actions = element("div", "provider-actions");
    if (provider.configured) {
      const refreshButton = element("button", "secondary provider-refresh", "刷新模型列表");
      refreshButton.type = "button";
      refreshButton.setAttribute("aria-label", `刷新模型列表（${provider.label}）`);
      refreshButton.addEventListener("click", () => refreshProviderModels(provider));
      actions.appendChild(refreshButton);
    } else {
      if (name === "glm") {
        const planField = byId("glm-plan-field").content.cloneNode(true);
        if (glmPlan) planField.querySelector("select").value = glmPlan;
        row.appendChild(planField);
      }
      if (provider.environment) {
        const envButton = element("button", "secondary", "从环境变量导入");
        envButton.addEventListener("click", () => importCredential(name, "environment", envButton));
        actions.appendChild(envButton);
      }
      const promptButton = element("button", "secondary", "打开密码窗口");
      promptButton.addEventListener("click", () => importCredential(name, "prompt", promptButton));
      actions.appendChild(promptButton);
    }
    row.appendChild(actions);
    container.appendChild(row);
  }
}

function refreshProviderModels(provider) {
  return runSettingsAction(async () => {
    report(`正在刷新 ${provider.label} 的模型列表…`);
    const result = await callTool("refresh_provider_models", { provider_id: provider.provider_id });
    await refresh();
    const changes = [];
    if (result.added) changes.push(`新增 ${result.added} 个`);
    if (result.removed) changes.push(`减少 ${result.removed} 个`);
    const summary = changes.length ? `（${changes.join("，")}）` : "，型号没有变化";
    report(`${provider.label} 已刷新，Magpie 当前有 ${result.model_count} 个型号${summary}。`);
  });
}

function hasPendingModels(preferences) {
  return state.v2_configured && Object.entries(preferences.roles).some(([key, role]) =>
    state.model_choices[key].needs_sync.includes(role.model));
}

function renderNativeStatus() {
  const preferences = rolePreferences();
  const needsSync = hasPendingModels(preferences);
  const status = byId("v2-status");
  const configured = state.v2_configured;
  const hasExternalRole = Object.entries(preferences.roles).some(([key, role]) =>
    role.model.includes("/") && state.model_choices[key].options.includes(role.model));
  const ready = configured && !needsSync;
  status.textContent = !configured && !hasExternalRole ? "请先接入供应商并分配模型"
    : !configured ? "尚未启用原生子代理" : needsSync ? "所选模型待同步"
    : restartPending ? "配置已更新，请重启 Codex" : "原生配置已就绪";
  const symbol = byId("native-symbol");
  symbol.textContent = ready ? "✓" : "·";
  symbol.classList.toggle("ready", ready);
  byId("native-details").classList.toggle("compact", ready);
  const action = byId("configure");
  action.hidden = ready || !hasExternalRole;
  action.textContent = needsSync ? "同步所选模型" : "启用原生子代理";
  byId("rewrite").hidden = !ready || !hasExternalRole;
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
    report(result.window_opened ? "请在本机密码窗口完成导入，然后点击「刷新状态」。" : "这家供应商已在 Magpie 中配置。请刷新状态。");
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
  const hiddenRoles = [];
  for (const [key, role] of Object.entries(preferences.roles)) {
    const group = state.model_choices[key];
    if (!group.options.includes(role.model)) {
      hiddenRoles.push([key, roleTitles[key]]);
      continue;
    }
    const card = element("article", "role");
    card.dataset.role = key;
    const title = element("div", "role-title");
    title.appendChild(element("h3", "", roleTitles[key]));
    title.appendChild(element("span", "role-purpose", role.responsibility));
    card.appendChild(title);

    const model = element("select");
    model.name = "model";
    fillModelChoices(model, group, role.model);
    model.setAttribute("aria-label", roleTitles[key] + "型号");
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
  const slot = byId("role-slot");
  const selectedSlot = slot.value;
  slot.replaceChildren(...hiddenRoles.map(([id, label]) => new Option(label, id)));
  if (hiddenRoles.some(([id]) => id === selectedSlot)) slot.value = selectedSlot;
  const hasConnectedModels = Object.values(state.model_choices).some(group =>
    group.options.some(model => model.includes("/")));
  byId("role-add").hidden = !hiddenRoles.length || !hasConnectedModels;
  if (!byId("role-add").hidden) updateRoleAssignment();
}

function fillModelChoices(select, group, value = "") {
  select.replaceChildren();
  for (const provider of group.groups) {
    const choices = element("optgroup");
    choices.label = provider.label;
    for (const id of provider.options) {
      const name = id.includes("/") ? id.slice(id.indexOf("/") + 1) : id;
      const label = provider.label + " · " + name;
      choices.appendChild(new Option(id === group.retained_model ? label + "（已保存）" : label, id));
    }
    select.appendChild(choices);
  }
  if (value) select.value = value;
}

function updateRoleAssignment() {
  fillModelChoices(byId("role-model"), state.model_choices[byId("role-slot").value]);
}

byId("role-slot").addEventListener("change", updateRoleAssignment);
byId("assign-role").addEventListener("click", () => {
  const draft = rolePreferences();
  const key = byId("role-slot").value;
  draft.roles[key] = { ...draft.roles[key], model: byId("role-model").value };
  renderRoles(draft);
  renderNativeStatus();
  byId("save-roles").disabled = !rolesEdited(draft);
  byId("roles").querySelector('[data-role="' + key + '"] select').focus();
});

byId("provider-preset").addEventListener("change", () => {
  byId("add-provider-key").disabled = !byId("provider-preset").value;
});
byId("add-provider-key").addEventListener("click", (event) => {
  importCredential(byId("provider-preset").value, "prompt", event.currentTarget);
});

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
  const roles = { ...state.roles.roles };
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
  const providerButtons = byId("providers").querySelectorAll(".provider-refresh");
  refreshButton.disabled = saveButton.disabled = configureButton.disabled = byId("rewrite").disabled = true;
  for (const button of providerButtons) button.disabled = true;
  try {
    await action();
  } catch (error) {
    report(error.message, true);
  } finally {
    refreshButton.disabled = false;
    for (const button of providerButtons) button.disabled = false;
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

async function updateAction(apply) {
  const check = byId("check-update");
  const install = byId("apply-update");
  const status = byId("update-status");
  byId("update").hidden = false;
  check.disabled = install.disabled = true;
  install.hidden = true;
  status.textContent = apply ? "正在下载并安装 MYGO 更新…" : "正在检查 MYGO 版本…";
  try {
    const result = await callTool(apply ? "update_plugin" : "check_update");
    if (result.installed) {
      status.textContent = "已安装 MYGO " + result.installed + "。请关闭并重新打开设置页。如果仍显示旧版，请重新打开 Codex。";
    } else if (result.update_available) {
      status.textContent = "当前 " + result.current + "，可更新到 " + result.latest + "。";
      install.hidden = false;
    } else {
      status.textContent = "MYGO " + result.current + " 已是最新版。";
    }
  } catch (error) {
    status.textContent = error.message;
  } finally {
    check.disabled = install.disabled = false;
  }
}

byId("check-update").addEventListener("click", () => updateAction(false));
byId("apply-update").addEventListener("click", () => updateAction(true));

bridgeReady = rpc("ui/initialize", {
  appInfo: { name: "mygo-settings", version: byId("plugin-version").textContent },
  appCapabilities: {},
  protocolVersion: "2026-01-26",
}).then((result) => {
  updateTheme(result?.hostContext?.theme);
  byId("check-update").disabled = false;
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
