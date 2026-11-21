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
    .replace('/* SETTINGS_CSS */', fs.readFileSync(path.join(plugin, 'ui/settings.css'), 'utf8'))
    .replace('/* SETTINGS_JS */', fs.readFileSync(path.join(plugin, 'ui/settings.js'), 'utf8'));
  const providers = {
    deepseek: { label: 'DeepSeek', configured: false, environment: true },
    kimi: { label: 'Kimi', configured: false, environment: false },
    glm: { label: 'GLM', configured: false, environment: true },
    gemini: { label: 'Gemini', configured: false, environment: false },
  };
  const state = {
    credentials: providers, magpie_installed: false, magpie_version: null,
    magpie_compatible: false, v2_configured: false, missing_models: [],
    roles, preferences_path: 'isolated-test/preferences.json',
  };
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1100, height: 960 } });
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.setContent(`<body><iframe id="app" style="width:100%;height:900px;border:0"></iframe><script>
    window.calls = [];
    window.mockState = ${JSON.stringify(state)};
    window.addEventListener('message', (event) => {
      const m = event.data;
      if (!m || m.jsonrpc !== '2.0' || typeof m.id !== 'number') return;
      window.calls.push(m);
      let result = {};
      if (m.method === 'ui/initialize') result = { hostContext: { theme: 'dark' } };
      if (m.method === 'tools/call' && m.params.name === 'read_settings') result = { structuredContent: window.mockState };
      if (m.method === 'tools/call' && m.params.name === 'save_roles') result = { structuredContent: { saved: true, preferences: m.params.arguments.preferences } };
      if (m.method === 'tools/call' && m.params.name === 'import_credential') result = { structuredContent: { window_opened: true, message: '模拟密码窗口已打开' } };
      if (m.method === 'tools/call' && m.params.name === 'configure_native') result = { structuredContent: { backup: 'isolated-test/backup', restart_required: true } };
      event.source.postMessage({ jsonrpc: '2.0', id: m.id, result }, '*');
    });
  </script></body>`);
  await page.locator('#app').evaluate((frame, content) => { frame.srcdoc = content; }, html);
  const frame = page.frames().find((item) => item !== page.mainFrame());
  await frame.waitForSelector('.role[data-role="researcher"]');
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
  await page.locator('#app').evaluate((iframe) => {
    iframe.contentWindow.postMessage({
      jsonrpc: '2.0', method: 'ui/notifications/host-context-changed', params: { theme: 'light' },
    }, '*');
  });
  await frame.waitForSelector('html[data-theme="light"]');
  const lightContrast = await controlContrast();
  assert.ok(lightContrast >= 4.5, `Light form contrast was ${lightContrast}`);

  await frame.locator('#providers .provider').filter({ hasText: 'DeepSeek' })
    .getByRole('button', { name: '从环境变量导入' }).click();
  await frame.locator('#providers .provider').filter({ hasText: 'Kimi' })
    .getByRole('button', { name: '打开密码窗口' }).click();
  const glm = frame.locator('#providers .provider').filter({ hasText: 'GLM' });
  await glm.getByRole('combobox').selectOption('api');
  await glm.getByRole('button', { name: '从环境变量导入' }).click();
  const researcher = frame.locator('.role[data-role="researcher"]');
  await researcher.locator('[name="responsibility"]').fill('验收自定义分工');
  await frame.locator('#save-roles').click();
  await frame.locator('#notice').filter({ hasText: '分工预设已保存' }).waitFor();
  await page.screenshot({ path: path.join(__dirname, 'settings-desktop.png'), fullPage: true });
  await frame.locator('#configure').click();
  await frame.locator('#notice').filter({ hasText: '配置完成' }).waitFor();
  const calls = await page.evaluate(() => window.calls);
  const imports = calls.filter((call) => call.params?.name === 'import_credential').map((call) => call.params.arguments);
  assert.deepEqual(imports, [
    { provider: 'deepseek', source: 'environment' },
    { provider: 'kimi', source: 'prompt' },
    { provider: 'glm', source: 'environment', glm_plan: 'api' },
  ]);
  const saves = calls.filter((call) => call.params?.name === 'save_roles');
  if (!saves.some((call) => call.params.arguments.preferences.roles.researcher.responsibility === '验收自定义分工')) throw new Error('Edited role was not saved');
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
  console.log(JSON.stringify({ result: 'PASS', dark_contrast: darkContrast, light_contrast: lightContrast, import_arguments: imports, role_edit_saved: true, configure_called: true, mobile_overflow: overflow, page_errors: errors }));
})().catch(async (error) => {
  console.error(error);
  await browser?.close();
  process.exitCode = 1;
});
