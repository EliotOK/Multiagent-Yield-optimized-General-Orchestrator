import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins" / "mygo"
sys.path.insert(0, str(PLUGIN / "server"))

import credential_import
import mygo_setup
import server as mygo_server


class FakeMagpie(mygo_setup.Magpie):
    def __init__(self):
        super().__init__("fake-magpie")
        self.calls = []
        self.stdin = []

    def version(self):
        return mygo_setup.MINIMUM_MAGPIE

    def run(self, args, secret=None, timeout=None, home=None):
        self.calls.append(list(args))
        if secret is not None:
            self.stdin.append(secret)
        if args[:2] == ["provider", "add"]:
            path = mygo_setup.magpie_home() / "providers.json"
            data = json.loads(path.read_text(encoding="utf-8"))
            data["providers"].append({
                "id": "deepseek-test", "preset": "deepseek",
                "key": mygo_setup.PENDING_KEY, "keys": [],
            })
            path.write_text(json.dumps(data), encoding="utf-8")
            return "Saved DeepSeek (deepseek-test)"
        if args[:3] == ["provider", "keys", "deepseek-test"] and args[3:] == ["add", "-"]:
            path = mygo_setup.magpie_home() / "providers.json"
            data = json.loads(path.read_text(encoding="utf-8"))
            provider = next(item for item in data["providers"] if item["id"] == "deepseek-test")
            provider["keys"].append({"id": "test-key", "key": secret.strip()})
            path.write_text(json.dumps(data), encoding="utf-8")
        return ""


class IsolatedCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mygo-plugin-test-", dir=ROOT / "tests")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.home = self.base / "codex"
        self.home.mkdir()
        self.magpie = self.base / "config" / "magpie"
        self.magpie.mkdir(parents=True)
        self.environment = mock.patch.dict(os.environ, {
            "XDG_CONFIG_HOME": str(self.base / "config"),
            "CODEX_HOME": str(self.home),
            "MYGO_MAGPIE_EXECUTABLE": str(self.base / "fake-magpie"),
        }, clear=False)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        for name in [item["env"] for item in mygo_setup.PROVIDERS.values()]:
            os.environ.pop(name, None)

    def write_providers(self, providers=None):
        if providers is None:
            providers = [{
                "id": item["preset"], "preset": item["preset"], "key": "configured-locally",
                "models": [item["models"][0]], "pickedFrom": [item["models"][0]],
            } for item in ({
                "preset": preset, "models": mygo_setup.PROVIDERS[name]["models"],
            } for name, preset in mygo_setup.MAGPIE_PRESETS.items())]
        path = self.magpie / "providers.json"
        path.write_text(json.dumps({"providers": providers}), encoding="utf-8")
        return path


class ManifestAndProtocolTests(IsolatedCase):
    def test_plugin_discovery_files_and_secret_free_tool_schemas(self):
        manifest = json.loads((PLUGIN / "plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["name"], "mygo")
        self.assertTrue((PLUGIN / "skills/mygo/SKILL.md").is_file())
        for name in ("mcp.json", ".mcp.json"):
            data = json.loads((PLUGIN / name).read_text(encoding="utf-8"))
            self.assertIn("mygo", data["mcpServers"])
        for tool in mygo_server.TOOLS:
            schema = json.dumps(tool["inputSchema"]).lower()
            self.assertNotIn("api_key", schema)
            self.assertNotIn("apikey", schema)
            self.assertNotIn("secret", schema)
            self.assertNotIn("password", schema)

    def test_mcp_initialize_resources_and_embedded_ui(self):
        instance = mygo_server.Server(self.home)
        instance.magpie = FakeMagpie()
        initialized = instance.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
        self.assertEqual(initialized["result"]["serverInfo"]["name"], "mygo")
        self.assertEqual(initialized["result"]["capabilities"]["experimental"]["openai/settings"]["readTool"], "settings.read")
        listed = instance.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        panel = next(tool for tool in listed["result"]["tools"] if tool["name"] == "show_settings")
        self.assertEqual(panel["_meta"]["ui"]["resourceUri"], mygo_server.URI)
        self.assertIn({"type": "global"}, panel["_meta"]["openai/ui"]["entrypoints"])
        resource = instance.handle({"jsonrpc": "2.0", "id": 3, "method": "resources/read", "params": {"uri": mygo_server.URI}})
        html = resource["result"]["contents"][0]["text"]
        version = json.loads((PLUGIN / "plugin.json").read_text(encoding="utf-8"))["version"]
        uri = f"ui://mygo/settings-{version}.html"
        self.assertEqual(panel["_meta"]["ui"]["resourceUri"], uri)
        resources = instance.handle({"jsonrpc": "2.0", "id": 4, "method": "resources/list"})
        self.assertEqual(resources["result"]["resources"][0]["uri"], uri)
        opened = instance.handle({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "show_settings"}})
        self.assertEqual(opened["result"]["_meta"]["ui"]["resourceUri"], uri)
        self.assertIn(f'id="plugin-version">{version}<', html)
        legacy = "ui://mygo/settings.html"
        old = instance.handle({"jsonrpc": "2.0", "id": 6, "method": "resources/read", "params": {"uri": legacy}})
        self.assertEqual(old["result"]["contents"][0]["uri"], legacy)
        self.assertEqual(old["result"]["contents"][0]["text"], html)
        self.assertIn("ui/initialize", html)
        self.assertIn("import_credential", html)
        self.assertNotIn("/* SETTINGS_JS */", html)
        self.assertNotIn('type="password"', html)
        self.assertNotIn("save-keys", html)

    def test_stdio_server_handles_notifications_without_replies(self):
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process = subprocess.Popen(
            [sys.executable, "-u", str(PLUGIN / "server/server.py")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", env=environment,
        )
        self.addCleanup(process.stderr.close)
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.kill)
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        self.assertEqual(response, {"jsonrpc": "2.0", "id": 1, "result": {}})
        process.stdin.close()
        self.assertEqual(process.wait(timeout=10), 0)
        self.assertEqual(process.stderr.read(), "")

    def test_structured_settings_and_role_preferences(self):
        instance = mygo_server.Server(self.home)
        initial = instance.call("settings.read", {})
        self.assertIn({"kind": "tool", "tool": "show_settings"}, initial["layout"][0]["items"])
        self.assertEqual(initial["values"]["researcher.model"], "deepseek/deepseek-flash")
        updated = instance.call("settings.update", {"set": {
            "researcher.label": "Research",
            "researcher.model": "deepseek/deepseek-flash",
            "researcher.responsibility": "Inspect approved public sources.",
            "researcher.effort": "low",
        }})
        self.assertEqual(updated["values"]["researcher.label"], "Research")
        saved = json.loads((self.home / "mygo/preferences.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["roles"]["researcher"]["label"], "Research")
        result = subprocess.run(
            [sys.executable, str(PLUGIN / "server/roles.py"), "--role", "researcher"],
            capture_output=True, text=True, encoding="utf-8", check=True, env=os.environ.copy(),
        )
        self.assertEqual(json.loads(result.stdout)["responsibility"], "Inspect approved public sources.")
        with self.assertRaises(ValueError):
            instance.call("settings.update", {"set": {"researcher.effort": "extreme"}})

    def test_model_choices_use_the_local_catalog_and_preserve_saved_ids(self):
        provider_path = self.write_providers()
        providers = json.loads(provider_path.read_text(encoding="utf-8"))["providers"]
        deepseek = providers[0]
        deepseek["pickedFrom"] = ["deepseek-flash", "deepseek-v4-pro", "old-model"]
        deepseek["delisted"] = ["old-model"]
        self.write_providers(providers)
        catalog = {"models": [
            {"slug": "deepseek/deepseek-flash", "multi_agent_version": "v2"},
            {"slug": "gpt-6-luna", "multi_agent_version": "v2"},
            {"slug": "gpt-6.2-sol", "multi_agent_version": "v2"},
            {"slug": "gpt-reserve", "multi_agent_version": "v2", "visibility": "hide"},
        ]}
        (self.home / "mygo-magpie-v2-models.json").write_text(json.dumps(catalog), encoding="utf-8")
        instance = mygo_server.Server(self.home)
        result = instance.call("settings.update", {"set": {"researcher.model": "deepseek/saved-preview"}})
        model_choices = instance.call("read_settings", {})["model_choices"]
        deepseek_choices = model_choices["researcher"]
        self.assertEqual(deepseek_choices["options"], [
            "deepseek/saved-preview", "deepseek/deepseek-flash", "deepseek/deepseek-v4-pro",
        ])
        self.assertEqual(deepseek_choices["retained_model"], "deepseek/saved-preview")
        self.assertEqual(deepseek_choices["needs_sync"], ["deepseek/saved-preview", "deepseek/deepseek-v4-pro"])
        self.assertEqual(result["schema"]["properties"]["researcher.model"]["enum"], deepseek_choices["options"])
        self.assertEqual(model_choices["executor"]["options"], ["gpt-6-luna", "gpt-6.2-sol"])
        self.assertNotIn("configured-locally", json.dumps(model_choices))

    def test_credential_window_launch_has_no_secret_or_blocking_wait(self):
        instance = mygo_server.Server(self.home)
        instance.magpie = FakeMagpie()
        instance.ensure_magpie = lambda: None
        instance.magpie.ensure_gateway = lambda: None
        with mock.patch.object(mygo_server.os, "name", "nt"), mock.patch.object(mygo_server.subprocess, "Popen") as popen:
            result = instance.import_credential({"provider": "deepseek", "source": "prompt"})
        self.assertTrue(result["window_opened"])
        command = popen.call_args.args[0]
        self.assertNotIn("--secret", command)
        self.assertNotIn("--api-key", command)
        popen.assert_called_once()


class CredentialTests(IsolatedCase):
    def test_stdin_import_removes_placeholder_and_restores_on_failure(self):
        self.write_providers([])
        fake = FakeMagpie()
        marker = "test-only-credential-value"
        result = fake.save_credential("deepseek", marker)
        self.assertTrue(result["saved"])
        self.assertEqual(fake.stdin, [marker + "\n"])
        self.assertTrue(all(marker not in " ".join(call) for call in fake.calls))
        data = json.loads((self.magpie / "providers.json").read_text(encoding="utf-8"))
        provider = data["providers"][0]
        self.assertEqual(provider["key"], marker)
        self.assertNotIn(mygo_setup.PENDING_KEY, json.dumps(data))

        self.write_providers([])
        original = (self.magpie / "providers.json").read_bytes()
        with mock.patch.object(FakeMagpie, "run", side_effect=RuntimeError("simulated failure")):
            with self.assertRaises(RuntimeError):
                FakeMagpie().save_credential("deepseek", marker)
        self.assertEqual((self.magpie / "providers.json").read_bytes(), original)

    def test_password_helper_never_prints_or_passes_secret_in_arguments(self):
        marker = "test-only-password-entry"
        captured = {}

        class HelperMagpie:
            def __init__(self, executable):
                captured["executable"] = executable

            def save_credential(self, provider, secret, plan):
                captured.update(provider=provider, secret=secret, plan=plan)
                return {"saved": True}

        output = io.StringIO()
        with mock.patch.object(sys, "argv", ["credential_import.py", "--provider", "kimi", "--source", "prompt", "--magpie", "fake"]), \
                mock.patch.object(credential_import, "getpass", side_effect=[marker, marker]), \
                mock.patch.object(credential_import, "Magpie", HelperMagpie), contextlib.redirect_stdout(output):
            self.assertEqual(credential_import.main(), 0)
        self.assertEqual(captured["secret"], marker)
        self.assertNotIn(marker, output.getvalue())
        self.assertNotIn(marker, " ".join(sys.argv))


class ConfigurationTests(IsolatedCase):
    def test_discovery_prefers_a_compatible_cli_and_reuses_it(self):
        managed = mygo_setup.managed_magpie_path()
        managed.touch()
        path_cli = self.base / "path-magpie"
        path_cli.touch()
        with mock.patch.object(mygo_setup.shutil, "which", return_value=str(path_cli)), \
                mock.patch.object(mygo_setup.Magpie, "version", autospec=True) as version, \
                mock.patch.object(mygo_server, "install_magpie") as install:
            version.side_effect = lambda cli: mygo_setup.MINIMUM_MAGPIE if cli.executable == str(managed) else (0, 1, 1)
            instance = mygo_server.Server(self.home)
            self.assertEqual(instance.magpie.executable, str(managed))
            self.assertTrue(instance.read()["magpie_compatible"])
            instance.ensure_magpie()
            install.assert_not_called()
            version.side_effect = lambda cli: mygo_setup.MINIMUM_MAGPIE if cli.executable == str(path_cli) else (0, 1, 1)
            self.assertEqual(mygo_setup.find_magpie(), str(path_cli))

    @unittest.skipUnless(os.name == "nt", "Windows installation paths")
    def test_discovery_with_redirected_localappdata(self):
        profile = self.base / "user"
        managed = profile / "AppData/Local/MYGO/bin/magpie.exe"
        managed.parent.mkdir(parents=True)
        managed.touch()
        with mock.patch.dict(os.environ, {"LOCALAPPDATA": str(self.base / "redirect"), "MYGO_MAGPIE_EXECUTABLE": ""}), \
                mock.patch.object(Path, "home", return_value=profile), \
                mock.patch.object(mygo_setup.shutil, "which", return_value=None), \
                mock.patch.object(mygo_setup.Magpie, "version", return_value=mygo_setup.MINIMUM_MAGPIE):
            self.assertEqual(mygo_setup.find_magpie(), str(managed))

    def test_native_status_reads_active_toml_values(self):
        config = self.home / "config.toml"
        catalog = 'model_catalog_json = "mygo-magpie-v2-models.json"'
        for text, enabled in [(catalog + "\n[features.multi_agent_v2]\nenabled = true", True),
                              (catalog + "\n[features.multi_agent_v2]\nenabled = false", False),
                              ("# " + catalog, False), ("[broken", False)]:
            config.write_text(text, encoding="utf-8")
            self.assertEqual(mygo_setup.status(self.home, FakeMagpie())["v2_configured"], enabled)

    def catalog(self):
        slugs = ["gpt-6.2-sol"] + [role["model"] for role in mygo_setup.DEFAULT_ROLES["roles"].values() if "/" in role["model"]]
        return {"models": [{"slug": slug, "multi_agent_version": "v2"} for slug in slugs]}

    def test_model_selection_uses_actual_provider_id_and_full_list(self):
        provider_path = self.write_providers()
        providers = json.loads(provider_path.read_text(encoding="utf-8"))["providers"]
        providers[0]["pickedFrom"].append("deepseek-v4-pro")
        self.write_providers(providers)
        preferences = copy.deepcopy(mygo_setup.DEFAULT_ROLES)
        preferences["roles"]["researcher"]["model"] = "deepseek/deepseek-v4-pro"
        fake = FakeMagpie()
        fake.select_models(preferences)
        self.assertIn(["provider", "models", "deepseek", "deepseek-v4-pro"], fake.calls)
        self.assertIn(["sync"], fake.calls)
        self.assertFalse(any(call[:2] == ["provider", "refresh"] for call in fake.calls))

    def test_configure_is_repeatable_absolute_and_ignores_native_luna(self):
        self.write_providers()
        (self.home / "config.toml").write_text('model = "gpt-6.2-sol"\n[features]\ncode_mode = true\n', encoding="utf-8")

        class ConfigureMagpie(FakeMagpie):
            def select_models(self, preferences):
                self.calls.append(["select_models"])

            def connect_codex(self, home):
                self.calls.append(["connect_codex"])
                (home / "magpie-models.json").write_text(json.dumps(ConfigurationTests.catalog(self)), encoding="utf-8")
                return "gpt-6.2-sol"

        with mock.patch.object(mygo_setup, "codex_capability_check", return_value="passed") as check:
            result = mygo_setup.configure(self.home, ConfigureMagpie(), apply=True)
            again = mygo_setup.configure(self.home, ConfigureMagpie(), apply=True)
        self.assertTrue(Path(result["catalog"]).is_absolute())
        self.assertEqual(result["lead_model"], again["lead_model"])
        config = (self.home / "config.toml").read_text(encoding="utf-8")
        self.assertEqual(config.count("model_catalog_json"), 1)
        self.assertEqual(config.count("[features.multi_agent_v2]"), 1)
        self.assertEqual(check.call_args.args[0], self.home)
        catalog = json.loads(Path(result["catalog"]).read_text(encoding="utf-8"))
        lead = next(item for item in catalog["models"] if item["slug"] == "gpt-6.2-sol")
        self.assertTrue(lead["multi_agent_tools_in_code_mode"])

    def test_failed_configuration_restores_codex_and_magpie_files(self):
        providers = self.write_providers()
        original_providers = providers.read_bytes()
        config = self.home / "config.toml"
        config.write_text('model = "gpt-6.2-sol"\n', encoding="utf-8")
        original_config = config.read_bytes()

        class FailingMagpie(FakeMagpie):
            def select_models(self, preferences):
                providers.write_text('{"providers":[]}', encoding="utf-8")

            def connect_codex(self, home):
                (home / "magpie-models.json").write_text(json.dumps(ConfigurationTests.catalog(self)), encoding="utf-8")
                return "gpt-6.2-sol"

        with mock.patch.object(mygo_setup, "codex_capability_check", side_effect=RuntimeError("simulated rejection")):
            with self.assertRaisesRegex(RuntimeError, "simulated rejection"):
                mygo_setup.configure(self.home, FailingMagpie(), apply=True)
        self.assertEqual(config.read_bytes(), original_config)
        self.assertEqual(providers.read_bytes(), original_providers)
        self.assertFalse((self.home / "mygo-magpie-v2-models.json").exists())


if __name__ == "__main__":
    unittest.main()
