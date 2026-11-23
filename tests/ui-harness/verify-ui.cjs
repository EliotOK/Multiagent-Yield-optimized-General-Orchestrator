const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
let browser;

(async () => {
  const root = path.resolve(__dirname, '../..');
  const plugin = path.join(root, 'plugins/mygo');
  const version = JSON.parse(fs.readFileSync(path.join(plugin, 'plugin.json'), 'utf8')).version;
  const nextVersion = version.replace(/\d+$/, patch => String(Number(patch) + 1));
  const roles = JSON.parse(fs.readFileSync(path.join(plugin, 'assets/default-roles.json'), 'utf8'));
  const html = fs.readFileSync(path.join(plugin, 'ui/settings.html'), 'utf8')
    .replace('__MYGO_VERSION__', version)
    .replace('/* SETTINGS_CSS */', fs.readFileSync(path.join(plugin, 'ui/settings.css'), 'utf8'))
    .replace('/* SETTINGS_JS */', fs.readFileSync(path.join(plugin, 'ui/settings.js'), 'utf8'));
  const providers = {
    deepseek: { label: 'DeepSeek', provider_id: 'deepseek', configured: false, environment: true },
    kimi: { label: 'Kimi', provider_id: 'moonshot-cn', configured: false, environment: false },
    glm: { label: 'GLM', provider_id: 'zhipu', configured: false, environment: true },
    gemini: { label: 'Gemini', provider_id: 'google', configured: false, environment: false },
  };
  const alternatives = {
    researcher: ['DeepSeek', 'deepseek/deepseek-v4-pro'],
    builder: ['GLM', 'zhipu/glm-5.3'],
    reviewer: ['Kimi', 'moonshot-cn/kimi-k3'],
    writer: ['Gemini', 'google/gemini-3.5-flash'],
    executor: ['OpenAI', 'gpt-6.2-sol'],
  };
  const pendingGemini = 'google/gemini-pro-latest';
  const modelGroups = Object.entries(alternatives).map(([role, [label, model]]) => ({
    label, options: role === 'writer' ? [roles.roles[role].model, model, pendingGemini] : [roles.roles[role].model, model],
  }));
  const connectedChoices = (groups) => Object.fromEntries(Object.keys(roles.roles).map(role => [role, {
    groups, options: groups.flatMap(group => group.options),
    retained_model: null,
    needs_sync: groups.flatMap(group => group.options).filter(model =>
      model.startsWith('qwen-cn/') || model === alternatives.researcher[1] || model === pendingGemini),
  }]));
  const modelChoices = connectedChoices(modelGroups);
  const state = {
    credentials: providers, model_catalog: true, magpie_installed: true, magpie_version: "0.1.4656",
    magpie_compatible: true, v2_configured: true, missing_models: [],
    roles, model_choices: connectedChoices([modelGroups.at(-1)]), provider_presets: { "qwen-cn": "Qwen（中国区）" },
    picker_models: [modelGroups.at(-1), ...modelGroups.slice(0, -1)].flatMap(group =>
      [...group.options].reverse().filter(model => !modelChoices.executor.needs_sync.includes(model))),
  };
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1100, height: 960 } });
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.setContent(`<body style="margin:0"><iframe id="app" style="width:100%;height:900px;border:0"></iframe><script>
    window.calls = [];
    window.availableUpdate = false;
    window.installedVersion = '${version}';
    window.mockState = ${JSON.stringify(state)};
    window.addEventListener('message', (event) => {
      const m = event.data;
      if (!m || m.jsonrpc !== '2.0' || typeof m.id !== 'number') return;
      window.calls.push(m);
      let result = {};
      if (m.method === 'ui/initialize') result = { hostContext: { theme: 'dark' } };
      if (m.params?.name === 'update_plugin') window.installedVersion = '${nextVersion}';
      if (m.params?.name === 'check_update' || m.params?.name === 'update_plugin') {
        const needsReload = window.installedVersion !== '${version}';
        result = { structuredContent: {
          current: '${version}', installed: window.installedVersion,
          latest: window.availableUpdate ? '${nextVersion}' : '${version}',
          reload_required: needsReload, update_available: window.availableUpdate && !needsReload,
        } };
      }
      if (m.method === 'tools/call' && m.params.name === 'read_settings') result = { structuredContent: window.mockState };
      if (m.params?.name === 'refresh_provider_models' && m.params.arguments.provider_id === 'zhipu') {
        const model = 'zhipu/glm-5.4';
        for (const choice of Object.values(window.mockState.model_choices)) {
          choice.groups = choice.groups.map(group => group.label === 'GLM'
            ? {...group, options: [...group.options, model]} : group);
          choice.options.push(model);
          choice.needs_sync.push(model);
        }
        result = { structuredContent: { model_count: 3, added: 1, removed: 0 } };
      }
      if (m.method === 'tools/call' && m.params.name === 'save_roles') {
        window.mockState.roles = m.params.arguments.preferences;
        result = { structuredContent: { saved: true, preferences: window.mockState.roles } };
      }
      if (m.method === 'tools/call' && m.params.name === 'import_credential') result = { structuredContent: { window_opened: true, message: '模拟密码窗口已打开' } };
      if (m.params?.name === 'sync_model_picker') {
        result = { structuredContent: { visible: 39, restart_required: true } };
      }
      if (m.method === 'tools/call' && m.params.name === 'configure_native') {
        const model = window.mockState.roles.roles.researcher.model;
        window.mockState.model_choices.researcher.needs_sync =
          window.mockState.model_choices.researcher.needs_sync.filter(pending => pending !== model);
        window.mockState.picker_models.push(model);
        result = { structuredContent: { backup: 'isolated-test/backup', visible: 39, restart_required: true } };
      }
      event.source.postMessage({ jsonrpc: '2.0', id: m.id, result }, '*');
    });
  </script></body>`);
  await page.locator('#app').evaluate((frame, content) => { frame.srcdoc = content; }, html);
  const frame = page.frames().find((item) => item !== page.mainFrame());
  await frame.waitForSelector('.role[data-role="executor"]');
  await frame.getByRole('button', {name: '检查更新'}).click();
  await frame.locator('#update-status').filter({hasText: '已是最新版'}).waitFor();
  assert.equal(await frame.locator('#apply-update').isVisible(), false);
  await page.evaluate(() => { window.availableUpdate = true; });
  await frame.getByRole('button', {name: '检查更新'}).click();
  await frame.locator('#update-status').filter({hasText: `可更新到 ${nextVersion}`}).waitFor();
  assert.equal(await page.evaluate(() => window.calls.some(call => call.params?.name === 'update_plugin')), false);
  await frame.getByRole('button', {name: '更新 MYGO'}).click();
  await frame.locator('#update-status').filter({hasText: `已安装 MYGO ${nextVersion}`}).waitFor();
  await frame.getByRole('button', {name: '检查更新'}).click();
  await frame.locator('#update-status').filter({hasText: '当前面板仍在运行'}).waitFor();
  assert.equal(await frame.locator('#apply-update').isVisible(), false);
  assert.equal(await page.evaluate(() => window.calls.filter(call => call.params?.name === 'update_plugin').length), 1);
  assert.equal(await frame.locator('#plugin-version').textContent(), version);
  await frame.locator('#update').evaluate(el => { el.hidden = true; });

  assert.equal(await frame.locator('#roles select[name="model"]').count(), 1);
  assert.equal(await frame.locator('#roles input[name="model"]').count(), 0);
  assert.equal(await frame.locator('.role[data-role="builder"]').count(), 0);
  assert.equal(await frame.locator('#providers .provider-refresh').count(), 0);
  await frame.getByText('添加供应商', { exact: true }).click();
  await frame.locator('#provider-preset').selectOption('qwen-cn');
  await frame.locator('#add-provider-key').click();
  await frame.getByText('添加供应商', { exact: true }).click();
  const controlContrast = async () => frame.locator('input, select, select option, textarea').evaluateAll((controls) => {
    function luminance(color) {
      const channels = color.match(/\d+/g).slice(0, 3).map((value) => Number(value) / 255);
      const linear = channels.map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
      return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
    }
    return Math.min(...controls.map((control) => {
      const style = getComputedStyle(control);
      const [low, high] = [luminance(style.color), luminance(style.backgroundColor)].sort((a, b) => a - b);
      return (high + 0.05) / (low + 0.05);
    }));
  });
  const darkContrast = await controlContrast();
  assert.ok(darkContrast >= 4.5, `Dark form contrast was ${darkContrast}`);
  await page.screenshot({ path: path.join(__dirname, 'settings-dark.png'), fullPage: true });
  await frame.locator('section[aria-labelledby="roles-heading"]').screenshot({ path: path.join(__dirname, 'settings-models.png') });
  await page.locator('#app').evaluate((iframe) => {
    iframe.contentWindow.postMessage({
      jsonrpc: '2.0', method: 'ui/notifications/host-context-changed', params: { theme: 'light' },
    }, '*');
  });
  await frame.waitForSelector('html[data-theme="light"]');
  const lightContrast = await controlContrast();
  assert.ok(lightContrast >= 4.5, `Light form contrast was ${lightContrast}`);
  await page.screenshot({ path: path.join(__dirname, 'settings-desktop.png'), fullPage: true });

  await frame.locator('#providers .provider').filter({ hasText: 'DeepSeek' })
    .getByRole('button', { name: '从环境变量导入' }).click();
  await frame.locator('#providers .provider').filter({ hasText: 'Kimi' })
    .getByRole('button', { name: '打开密码窗口' }).click();
  const glm = frame.locator('#providers .provider').filter({ hasText: 'GLM' });
  await glm.getByRole('combobox').selectOption('api');
  await glm.getByRole('button', { name: '从环境变量导入' }).click();
  assert.equal(await frame.locator('#configure').isVisible(), false);
  const qwen = {label: 'Qwen', options: ['qwen-cn/qwen-model']};
  await page.evaluate((choices) => {
    window.mockState.credentials['magpie:qwen-cn'] = {label: 'Qwen', provider_id: 'qwen-cn', configured: true};
    window.mockState.provider_presets = {};
    window.mockState.model_choices = choices;
  }, connectedChoices([qwen, modelGroups.at(-1)]));
  await frame.locator('#refresh').click();
  await frame.getByText('给已接入模型分配职责', {exact: true}).click();
  await frame.locator('#role-slot').selectOption('builder');
  await frame.locator('#role-model').selectOption(qwen.options[0]);
  await frame.locator('#assign-role').click();
  assert.equal(await frame.locator('.role[data-role="builder"] select[name="model"]').inputValue(), qwen.options[0]);
  await frame.locator('#save-roles').click();
  await frame.locator('#notice').filter({ hasText: '分工预设已保存' }).waitFor();
  await page.evaluate(({choices, previousRoles}) => {
    window.mockState.model_choices = choices;
    window.mockState.roles = previousRoles;
  }, {choices: modelChoices, previousRoles: roles});
  await page.evaluate(() => {
    for (const p of Object.values(window.mockState.credentials)) p.configured = true;
    window.mockState.v2_configured = false;
  });
  await frame.locator('#refresh').click();
  await frame.locator('#configure').filter({ hasText: '启用原生子代理' }).waitFor();
  await page.evaluate(() => { window.mockState.v2_configured = true; });
  await frame.locator('#refresh').click();
  await frame.locator('#v2-status').filter({ hasText: '原生配置已就绪' }).waitFor();
  assert.equal(await frame.locator('#configure').isVisible(), false);
  assert.equal(await frame.locator('#rewrite').isVisible(), false);
  await frame.getByText('配置详情', {exact: true}).click();
  await frame.locator('#cli-detail').filter({hasText: '0.1.4656'}).waitFor();
  assert.equal(await frame.locator('#rewrite').isVisible(), true);
  await frame.getByText('配置详情', {exact: true}).click();
  await frame.locator('#notice').evaluate(el => { el.hidden = true; });
  assert.equal(await frame.locator('#save-roles').isDisabled(), true);
  await page.locator('#app').evaluate(iframe => { iframe.style.height = iframe.contentDocument.body.scrollHeight + 'px'; });
  await frame.locator('body').screenshot({ path: path.join(__dirname, 'settings-ready.png') });
  await page.locator('#app').evaluate(iframe => {
    iframe.contentWindow.postMessage({ jsonrpc: '2.0', method: 'ui/notifications/host-context-changed', params: { theme: 'dark' } }, '*');
  });
  await frame.waitForSelector('html[data-theme="dark"]');
  await frame.locator('body').screenshot({ path: path.join(__dirname, 'settings-ready-dark.png') });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('#app').evaluate(iframe => { iframe.style.height = iframe.contentDocument.body.scrollHeight + 'px'; });
  await frame.locator('body').screenshot({ path: path.join(__dirname, 'settings-ready-mobile.png') });
  await page.setViewportSize({ width: 1100, height: 960 });
  const researcher = frame.locator('.role[data-role="researcher"]');
  const modelSelect = researcher.locator('select[name="model"]');
  const selectedModel = alternatives.researcher[1];
  const writerModel = frame.getByRole('combobox', { name: '写作与视觉型号' });
  const geminiOption = writerModel.locator('option[value="' + pendingGemini + '"]');
  assert.deepEqual(await writerModel.locator('optgroup').evaluateAll(groups => groups.map(group => group.label)),
    ['OpenAI', 'DeepSeek', 'GLM', 'Kimi', 'Gemini']);
  assert.deepEqual(await writerModel.locator('optgroup[label="Gemini"] option').evaluateAll(options => options.map(option => option.value)),
    [alternatives.writer[1], roles.roles.writer.model]);
  assert.equal(await geminiOption.count(), 0);
  assert.equal(await modelSelect.locator('option[value="' + selectedModel + '"]').count(), 0);
  await frame.getByRole('button', {name: '显示更多型号'}).click();
  assert.match(await geminiOption.textContent(), /待同步/);
  await modelSelect.selectOption(selectedModel);
  await frame.getByRole('button', {name: '仅显示已同步'}).click();
  assert.equal(await geminiOption.count(), 0);
  assert.equal(await modelSelect.inputValue(), selectedModel);
  await researcher.getByRole('link', { name: '此型号需要同步到原生 V2' }).waitFor();
  await frame.locator('#configure').filter({ hasText: '同步所选模型' }).waitFor();
  assert.equal(await researcher.locator('[name="responsibility"]').isVisible(), false);
  await researcher.getByText('分工设置', { exact: true }).click();
  await researcher.locator('[name="responsibility"]').fill('验收自定义分工');
  const builderModel = frame.getByRole('combobox', {name: '代码构建型号'});
  assert.equal(await builderModel.locator('option[value="zhipu/glm-5.4"]').count(), 0);
  await glm.getByRole('button', {name: '刷新模型列表（GLM）'}).click();
  await frame.locator('#notice').filter({hasText: '新增 1 个'}).waitFor();
  assert.equal(await builderModel.locator('option[value="zhipu/glm-5.4"]').count(), 0);
  await frame.getByRole('button', {name: '显示更多型号'}).click();
  await builderModel.locator('option[value="zhipu/glm-5.4"]').waitFor({state: 'attached'});
  assert.equal(await builderModel.inputValue(), roles.roles.builder.model);
  await builderModel.selectOption('zhipu/glm-5.4');
  await frame.locator('.role[data-role="builder"]').getByRole('link', {name: '此型号需要同步到原生 V2'}).waitFor();
  await builderModel.selectOption(roles.roles.builder.model);
  assert.equal(await modelSelect.inputValue(), selectedModel);
  assert.equal(await researcher.locator('[name="responsibility"]').inputValue(), '验收自定义分工');
  await frame.locator('#refresh').click();
  await frame.locator('#notice').filter({ hasText: '状态已刷新' }).waitFor();
  assert.equal(await modelSelect.inputValue(), selectedModel);
  assert.equal(await researcher.locator('[name="responsibility"]').isVisible(), true);
  assert.equal(await researcher.locator('[name="responsibility"]').inputValue(), '验收自定义分工');
  await frame.locator('#save-roles').click();
  await frame.locator('#notice').filter({ hasText: '分工预设已保存' }).waitFor();
  await frame.locator('#configure').click();
  await frame.locator('#notice').filter({ hasText: '已同步模型' }).waitFor();
  await frame.locator('#v2-status').filter({ hasText: '配置已更新，请重启 Codex' }).waitFor();
  assert.equal(await modelSelect.inputValue(), selectedModel);
  await frame.getByRole('button', { name: '同步 Codex 模型菜单' }).click();
  await frame.locator('#notice').filter({ hasText: '本地模型菜单已写入 39 个型号' }).waitFor();
  assert.equal(await geminiOption.count(), 0);
  const calls = await page.evaluate(() => window.calls);
  const refreshes = calls.filter(call => call.params?.name === 'refresh_provider_models');
  assert.deepEqual(refreshes.map(call => call.params.arguments), [{provider_id: 'zhipu'}]);
  const imports = calls.filter((call) => call.params?.name === 'import_credential').map((call) => call.params.arguments);
  assert.deepEqual(imports, [
    { provider: 'qwen-cn', source: 'prompt' },
    { provider: 'deepseek', source: 'environment' },
    { provider: 'kimi', source: 'prompt' },
    { provider: 'glm', source: 'environment', glm_plan: 'api' },
  ]);
  const saves = calls.filter((call) => call.params?.name === 'save_roles');
  if (!saves.some((call) => call.params.arguments.preferences.roles.researcher.responsibility === '验收自定义分工')) throw new Error('Edited role was not saved');
  assert.ok(saves.some((call) => call.params.arguments.preferences.roles.researcher.model === selectedModel));
  if (!calls.some((call) => call.params?.name === 'configure_native')) throw new Error('Configure was not called');
  await frame.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: path.join(__dirname, 'settings-top.png'), fullPage: false });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('#app').evaluate((frame) => { frame.style.height = '1900px'; });
  await page.screenshot({ path: path.join(__dirname, 'settings-mobile.png'), fullPage: true });
  const overflow = await frame.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
  if (overflow) throw new Error('Mobile layout has horizontal overflow');
  await page.evaluate(() => {
    for (const provider of Object.values(window.mockState.credentials)) provider.configured = true;
  });
  await frame.locator('#refresh').click();
  await frame.getByText('5 家已接入 Magpie', { exact: true }).waitFor();
  assert.equal(await frame.locator('#glm-plan').count(), 0);
  assert.equal(await frame.locator('#providers button').count(), 5);
  assert.equal(await frame.locator('#providers .provider-refresh').count(), 5);
  assert.equal(await frame.getByText('添加供应商', {exact: true}).isVisible(), true);
  await page.close();
  await browser.close();
  if (errors.length) throw new Error(errors.join('\n'));
  console.log(JSON.stringify({ result: 'PASS', dark_contrast: darkContrast, light_contrast: lightContrast, import_arguments: imports, model_selected: selectedModel, role_edit_saved: true, configure_called: true, mobile_overflow: overflow, page_errors: errors }));
})().catch(async (error) => {
  console.error(error);
  await browser?.close();
  process.exitCode = 1;
});
