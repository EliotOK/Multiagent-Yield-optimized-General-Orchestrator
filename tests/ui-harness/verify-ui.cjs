const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
let browser;

(async () => {
  const root = path.resolve(__dirname, '../..');
  const plugin = path.join(root, 'plugins/mygo');
  const roles = JSON.parse(fs.readFileSync(path.join(plugin, 'assets/default-roles.json'), 'utf8'));
  const html = fs.readFileSync(path.join(plugin, 'ui/settings.html'), 'utf8')
    .replace('__MYGO_VERSION__', JSON.parse(fs.readFileSync(path.join(plugin, 'plugin.json'), 'utf8')).version)
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
  const modelChoices = Object.fromEntries(Object.entries(alternatives).map(([role, [provider, model]]) => [role, {
    provider,
    options: [roles.roles[role].model, model],
    retained_model: null,
    needs_sync: role === 'researcher' ? [model] : [],
  }]));
  const state = {
    credentials: providers, model_catalog: true, magpie_installed: true, magpie_version: "0.1.4656",
    magpie_compatible: true, v2_configured: true, missing_models: [],
    roles, model_choices: modelChoices,
  };
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1100, height: 960 } });
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.setContent(`<body style="margin:0"><iframe id="app" style="width:100%;height:900px;border:0"></iframe><script>
    window.calls = [];
    window.mockState = ${JSON.stringify(state)};
    window.addEventListener('message', (event) => {
      const m = event.data;
      if (!m || m.jsonrpc !== '2.0' || typeof m.id !== 'number') return;
      window.calls.push(m);
      let result = {};
      if (m.method === 'ui/initialize') result = { hostContext: { theme: 'dark' } };
      if (m.method === 'tools/call' && m.params.name === 'read_settings') result = { structuredContent: window.mockState };
      if (m.method === 'tools/call' && m.params.name === 'save_roles') {
        window.mockState.roles = m.params.arguments.preferences;
        result = { structuredContent: { saved: true, preferences: window.mockState.roles } };
      }
      if (m.method === 'tools/call' && m.params.name === 'import_credential') result = { structuredContent: { window_opened: true, message: '模拟密码窗口已打开' } };
      if (m.method === 'tools/call' && m.params.name === 'configure_native') {
        window.mockState.model_choices.researcher.needs_sync = [];
        result = { structuredContent: { backup: 'isolated-test/backup', restart_required: true } };
      }
      event.source.postMessage({ jsonrpc: '2.0', id: m.id, result }, '*');
    });
  </script></body>`);
  await page.locator('#app').evaluate((frame, content) => { frame.srcdoc = content; }, html);
  const frame = page.frames().find((item) => item !== page.mainFrame());
  await frame.waitForSelector('.role[data-role="researcher"]');
  assert.equal(await frame.locator('#roles select[name="model"]').count(), Object.keys(alternatives).length);
  assert.equal(await frame.locator('#roles input[name="model"]').count(), 0);
  for (const [role, choice] of Object.entries(modelChoices)) {
    const options = await frame.locator(`.role[data-role="${role}"] select[name="model"] option`)
      .evaluateAll((items) => items.map((option) => option.value));
    assert.deepEqual(options, choice.options);
  }
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
  assert.equal(await frame.locator('#key-link').isVisible(), true);
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
  await modelSelect.selectOption(selectedModel);
  await researcher.getByRole('link', { name: '此型号需要同步到原生 V2' }).waitFor();
  await frame.locator('#configure').filter({ hasText: '同步所选模型' }).waitFor();
  assert.equal(await researcher.locator('[name="responsibility"]').isVisible(), false);
  await researcher.getByText('分工设置', { exact: true }).click();
  await researcher.locator('[name="responsibility"]').fill('验收自定义分工');
  await frame.locator('#refresh').click();
  await frame.locator('#notice').filter({ hasText: '状态已刷新' }).waitFor();
  assert.equal(await modelSelect.inputValue(), selectedModel);
  assert.equal(await researcher.locator('[name="responsibility"]').isVisible(), true);
  assert.equal(await researcher.locator('[name="responsibility"]').inputValue(), '验收自定义分工');
  await frame.locator('#save-roles').click();
  await frame.locator('#notice').filter({ hasText: '分工预设已保存' }).waitFor();
  await frame.locator('#configure').click();
  await frame.locator('#notice').filter({ hasText: '配置完成' }).waitFor();
  await frame.locator('#v2-status').filter({ hasText: '配置已更新，请重启 Codex' }).waitFor();
  assert.equal(await modelSelect.inputValue(), selectedModel);
  const calls = await page.evaluate(() => window.calls);
  const imports = calls.filter((call) => call.params?.name === 'import_credential').map((call) => call.params.arguments);
  assert.deepEqual(imports, [
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
  await frame.getByText('4 / 4 已接入 Magpie', { exact: true }).waitFor();
  assert.equal(await frame.locator('#glm-plan').count(), 0);
  assert.equal(await frame.locator('#providers button').count(), 0);
  await page.close();
  await browser.close();
  if (errors.length) throw new Error(errors.join('\n'));
  console.log(JSON.stringify({ result: 'PASS', dark_contrast: darkContrast, light_contrast: lightContrast, import_arguments: imports, model_selected: selectedModel, role_edit_saved: true, configure_called: true, mobile_overflow: overflow, page_errors: errors }));
})().catch(async (error) => {
  console.error(error);
  await browser?.close();
  process.exitCode = 1;
});
