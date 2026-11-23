from base64 import b64encode
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
            "XDG_CACHE_HOME": str(self.base / "cache"),
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


class UpdateTests(IsolatedCase):
    def test_reads_the_published_version(self):
        manifest = json.dumps({"name": "mygo", "version": "0.10.0"}).encode()
        response = io.BytesIO(json.dumps({
            "encoding": "base64", "content": b64encode(manifest).decode(),
        }).encode())
        with mock.patch.object(mygo_server, "urlopen", return_value=response) as fetch:
            self.assertEqual(mygo_server.published_version(), "0.10.0")
        self.assertEqual(fetch.call_args.args[0].full_url, mygo_server.UPDATE_MANIFEST)

    def test_cached_plugin_uses_its_own_codex_profile(self):
        root = self.home / mygo_server.CACHE_PATH / "0.9.0"
        other_profile = self.base / "other-profile"
        with mock.patch.dict(os.environ, {"CODEX_HOME": str(other_profile)}):
            self.assertEqual(mygo_server.profile_home(root), self.home)
            self.assertEqual(mygo_server.profile_home(PLUGIN), other_profile)

    def inventory(self, version):
        return subprocess.CompletedProcess([], 0, json.dumps({"installed": [
            {"pluginId": "mygo@mygo", "version": version},
        ]}), "")

    def test_old_panel_reports_installed_update_without_fetching_again(self):
        with mock.patch.object(mygo_server, "VERSION", "0.9.0"), \
                mock.patch.object(mygo_server, "published_version", return_value="0.10.0"), \
                mock.patch.object(mygo_server, "find_codex", return_value="codex"), \
                mock.patch.object(mygo_server, "run_codex", return_value=self.inventory("0.10.0")) as native:
            result = mygo_server.Server(self.home).update_plugin()
        self.assertEqual(result, {
            "current": "0.9.0", "installed": "0.10.0", "latest": "0.10.0",
            "reload_required": True, "update_available": False,
        })
        native.assert_called_once()
        self.assertEqual(native.call_args.args[1], ["plugin", "list", "--marketplace", "mygo", "--json"])

    def test_verifies_new_install_even_with_no_upgraded_roots(self):
        command_result = subprocess.CompletedProcess([], 0, '{"upgradedRoots":[],"errors":[]}', "")
        results = [self.inventory("0.9.0"), command_result, self.inventory("0.10.0")]
        with mock.patch.object(mygo_server, "VERSION", "0.9.0"), \
                mock.patch.object(mygo_server, "published_version", return_value="0.10.0"), \
                mock.patch.object(mygo_server, "find_codex", return_value="codex"), \
                mock.patch.object(mygo_server, "run_codex", side_effect=results) as native:
            result = mygo_server.Server(self.home).update_plugin()
        self.assertEqual(result["installed"], "0.10.0")
        self.assertTrue(result["reload_required"])
        self.assertEqual(native.call_args_list[1].args[1], ["plugin", "marketplace", "upgrade", "mygo", "--json"])
        self.assertTrue(all(call.args[2]["CODEX_HOME"] == str(self.home) for call in native.call_args_list))

    def test_current_market_repairs_an_older_installed_package(self):
        manifest = self.home / ".tmp/marketplaces/mygo/plugins/mygo/plugin.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text('{"name":"mygo","version":"0.10.0"}', encoding="utf-8")
        done = subprocess.CompletedProcess([], 0, "{}", "")
        results = [self.inventory("0.9.0"), done, self.inventory("0.9.0"), done, self.inventory("0.10.0")]
        with mock.patch.object(mygo_server, "VERSION", "0.9.0"), \
                mock.patch.object(mygo_server, "published_version", return_value="0.10.0"), \
                mock.patch.object(mygo_server, "find_codex", return_value="codex"), \
                mock.patch.object(mygo_server, "run_codex", side_effect=results) as native:
            result = mygo_server.Server(self.home).update_plugin()
        self.assertEqual(result["installed"], "0.10.0")
        self.assertEqual(native.call_args_list[3].args[1], ["plugin", "add", "mygo@mygo", "--json"])

    def test_update_failure_identifies_missing_git_without_showing_raw_output(self):
        failure = subprocess.CompletedProcess([], 1, "", "failed to run git: program not found; private details")
        results = [self.inventory("0.9.0"), failure, self.inventory("0.9.0")]
        with mock.patch.object(mygo_server, "VERSION", "0.9.0"), \
                mock.patch.object(mygo_server, "published_version", return_value="0.10.0"), \
                mock.patch.object(mygo_server, "find_codex", return_value="codex"), \
                mock.patch.object(mygo_server, "run_codex", side_effect=results):
            with self.assertRaisesRegex(RuntimeError, "无法启动 Git") as caught:
                mygo_server.Server(self.home).update_plugin()
        self.assertNotIn("private details", str(caught.exception))


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
        for saved_uri in ("ui://mygo/settings.html", "ui://mygo/settings-0.3.8.html", "ui://mygo/settings-0.3.9.html"):
            with self.subTest(uri=saved_uri):
                response = instance.handle({
                    "jsonrpc": "2.0", "id": 6, "method": "resources/read", "params": {"uri": saved_uri},
                })
                panel = response["result"]["contents"][0]
                self.assertEqual(panel["uri"], saved_uri)
                self.assertEqual(panel["text"], html)
                self.assertEqual(panel["mimeType"], mygo_server.MIME)
        unknown = instance.handle({
            "jsonrpc": "2.0", "id": 7, "method": "resources/read", "params": {"uri": "ui://mygo/other.html"},
        })
        self.assertEqual(unknown["error"]["code"], -32002)
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
        self.assertNotIn("researcher.model", initial["values"])
        self.write_providers()
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
            {"slug": "deepseek/old-model", "multi_agent_version": "v2"},
            {"slug": "gpt-6-luna", "multi_agent_version": "v2"},
            {"slug": "gpt-6.2-sol", "multi_agent_version": "v2"},
            {"slug": "gpt-reserve", "multi_agent_version": "v2", "visibility": "hide"},
        ]}
        (self.home / "mygo-magpie-v2-models.json").write_text(json.dumps(catalog), encoding="utf-8")
        instance = mygo_server.Server(self.home)
        result = instance.call("settings.update", {"set": {"researcher.model": "deepseek/saved-preview"}})
        model_choices = instance.call("read_settings", {})["model_choices"]
        deepseek_choices = model_choices["researcher"]
        self.assertEqual(deepseek_choices["options"][:3], [
            "deepseek/saved-preview", "deepseek/deepseek-flash", "deepseek/deepseek-v4-pro",
        ])
        self.assertEqual(deepseek_choices["retained_model"], "deepseek/saved-preview")
        self.assertNotIn("deepseek/old-model", deepseek_choices["options"])
        self.assertEqual(deepseek_choices["needs_sync"][:2], ["deepseek/saved-preview", "deepseek/deepseek-v4-pro"])
        self.assertEqual(result["schema"]["properties"]["researcher.model"]["enum"], deepseek_choices["options"])
        self.assertEqual(model_choices["executor"]["options"][-2:], ["gpt-6-luna", "gpt-6.2-sol"])
        self.assertNotIn("configured-locally", json.dumps(model_choices))

    def test_connected_qwen_is_selectable_and_unconfigured_roles_stay_saved(self):
        self.write_providers([
            {"id": "qwen-cn-2", "name": "Qwen", "preset": "qwen-cn", "key": "test-key",
             "models": ["qwen-model"]},
            {"id": "deepseek", "name": "DeepSeek", "preset": "deepseek", "models": ["deepseek-flash"]},
        ])
        instance = mygo_server.Server(self.home)
        state = instance.call("read_settings", {})
        self.assertTrue(state["credentials"]["magpie:qwen-cn-2"]["configured"])
        self.assertFalse(state["model_choices"]["researcher"]["active"])
        self.assertIn("qwen-cn-2/qwen-model", state["model_choices"]["researcher"]["options"])
        self.assertNotIn("deepseek/deepseek-flash", state["model_choices"]["researcher"]["options"])
        preferences = state["roles"]
        preferences["roles"]["builder"]["model"] = "qwen-cn-2/qwen-model"
        instance.call("save_roles", {"preferences": preferences})
        state = instance.call("read_settings", {})
        self.assertEqual(state["roles"]["roles"]["researcher"]["model"], "deepseek/deepseek-flash")
        self.assertTrue(state["model_choices"]["builder"]["active"])
        fake = FakeMagpie()
        fake.select_models(state["roles"])
        self.assertEqual(fake.calls, [["provider", "models", "qwen-cn-2", "+qwen-model"], ["sync"]])

    def test_only_key_only_presets_are_offered_for_local_import(self):
        fake = FakeMagpie()
        with mock.patch.object(fake, "run", return_value=(
            "  vendors\n"
            "  Qwen (China)                  qwen-cn         magpie provider add qwen-cn <key>\n"
            "  Vertex AI                     vertex          magpie provider add vertex project=<id>\n"
        )):
            self.assertEqual(fake.key_presets(), {"qwen-cn": "Qwen (China)"})

    def test_refresh_provider_models_reloads_the_target_suppliers_choices(self):
        providers = [
            {"id": "zhipu-2", "preset": "zhipu", "key": "fixture-key",
             "models": ["glm-5.3-flash"], "pickedFrom": ["glm-5.3-flash", "retired-model"],
             "delisted": ["retired-model"]},
            {"id": "qwen-cn", "preset": "qwen-cn", "models": ["unconnected-model"]},
        ]
        self.write_providers(providers)
        catalog = self.home / "mygo-magpie-v2-models.json"
        catalog.write_text(json.dumps({"models": [
            {"slug": "zhipu-2/retired-model", "multi_agent_version": "v2"},
        ]}), encoding="utf-8")
        instance = mygo_server.Server(self.home)
        instance.magpie = FakeMagpie()

        def refresh(args, timeout):
            path = self.base / "cache/magpie/models/zhipu-2.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"models": [{"ID": "glm-5.3-flash"}, {"ID": "glm-5.4"}]}), encoding="utf-8")

        with mock.patch.object(instance.magpie, "run", side_effect=refresh) as cli:
            with self.assertRaisesRegex(ValueError, "请先在 Magpie 中配置"):
                instance.call("refresh_provider_models", {"provider_id": "qwen-cn"})
            cli.assert_not_called()
            result = instance.call("refresh_provider_models", {"provider_id": "zhipu-2"})
            cli.assert_called_once_with(["provider", "refresh", "zhipu-2"], timeout=45)
        self.assertEqual(result, {"model_count": 2, "added": 1, "removed": 0})
        data = instance.call("read_settings", {})
        self.assertIn("zhipu-2/glm-5.4", data["model_choices"]["builder"]["needs_sync"])
        self.assertNotIn("zhipu-2/retired-model", data["model_choices"]["builder"]["options"])
        self.assertEqual(data["roles"], mygo_setup.DEFAULT_ROLES)
        self.assertFalse((self.home / "mygo/preferences.json").exists())

    def test_cached_gemini_chat_models_preserve_selectable_model_ids(self):
        self.write_providers([
            {"id": "google", "preset": "google", "key": "fixture-key", "models": ["gemini-existing"]},
        ])
        cache = self.base / "cache/magpie/models/google.json"
        cache.parent.mkdir(parents=True)
        cache.write_text(json.dumps({"models": [
            {"ID": "models/gemini-new"},
            {"ID": "models/gemini-existing"},
            {"ID": "models/embedding", "Serves": "embedding"},
            {"ID": "models/image-only", "Draws": True},
        ]}), encoding="utf-8")
        ids = mygo_setup.provider_state()["google"]["models"]
        self.assertEqual(set(ids), {"gemini-existing", "gemini-new"})

    def test_refresh_provider_models_does_not_expose_raw_vendor_errors(self):
        self.write_providers()
        instance = mygo_server.Server(self.home)
        instance.magpie = FakeMagpie()
        with mock.patch.object(instance.magpie, "run", side_effect=RuntimeError("private vendor payload")):
            response = instance.handle({
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": {"name": "refresh_provider_models", "arguments": {"provider_id": "zhipu"}},
            })["result"]
        self.assertTrue(response["isError"])
        self.assertIn("Magpie 未能获取模型列表", response["content"][0]["text"])
        self.assertNotIn("private vendor payload", json.dumps(response))

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

    def test_new_preset_import_keeps_key_out_of_commands(self):
        path = self.write_providers([])
        marker = "test-only-qwen-key"

        class QwenMagpie(FakeMagpie):
            def key_presets(self):
                return {"qwen-cn": "Qwen"}

            def run(self, args, secret=None, **kwargs):
                if args[:2] == ["provider", "add"]:
                    path.write_text(json.dumps({"providers": [{
                        "id": "qwen-cn", "preset": "qwen-cn", "key": mygo_setup.PENDING_KEY,
                        "models": ["test-model"],
                    }]}), encoding="utf-8")
                    return "Saved Qwen (qwen-cn)"
                self.calls.append(args)
                self.stdin.append(secret)
                data = json.loads(path.read_text(encoding="utf-8"))
                data["providers"][0]["keys"] = [{"key": secret.strip()}]
                path.write_text(json.dumps(data), encoding="utf-8")

        fake = QwenMagpie()
        self.assertTrue(fake.save_credential("qwen-cn", marker)["saved"])
        self.assertEqual(fake.calls, [["provider", "keys", "qwen-cn", "add", "-"]])
        self.assertEqual(fake.stdin, [marker + "\n"])
        self.assertTrue(mygo_setup.credential_status()["magpie:qwen-cn"]["configured"])

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
        self.assertIn(["provider", "models", "deepseek", "+deepseek-v4-pro"], fake.calls)
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

    def test_picker_keeps_native_and_synced_choices_and_can_restore_visibility(self):
        self.write_providers([
            {"id": "google", "preset": "google", "key": "test-only",
             "pickedFrom": ["gemini-4-hydrogen", "models/gemini-4-hydrogen", "gemini-future", "gemini-old"]},
        ])
        (self.home / "config.toml").write_text(
            'model = "gpt-6.2-sol"\nmodel_catalog_json = "mygo-magpie-v2-models.json"\n'
            '[features.multi_agent_v2]\nenabled = true\n', encoding="utf-8",
        )
        preferences = copy.deepcopy(mygo_setup.DEFAULT_ROLES)
        preferences["roles"]["writer"]["model"] = "google/gemini-4-hydrogen"
        preferences_path = self.home / "mygo/preferences.json"
        mygo_setup.save_roles(preferences_path, preferences)
        catalog = self.home / mygo_setup.NATIVE_CATALOG
        catalog.write_text(json.dumps({"models": [
            {"slug": "gpt-6.2-sol", "visibility": "list", "multi_agent_version": "v2"},
            {"slug": "gpt-native-v1", "visibility": "list"},
            {"slug": "gpt-hidden", "visibility": "hide"},
            {"slug": "google/models/gemini-4-hydrogen", "visibility": "list", "multi_agent_version": "v2"},
            {"slug": "google/gemini-old", "visibility": "list"},
            {"slug": "qwen/qwen3", "visibility": "list", "multi_agent_version": "v2"},
            {"slug": "qwen/internal", "visibility": "hide", "multi_agent_version": "v2"},
        ]}), encoding="utf-8")

        instance = mygo_server.Server(self.home)
        status = instance.call("read_settings", {})
        writer = status["model_choices"]["writer"]
        self.assertIn("google/models/gemini-4-hydrogen", status["picker_models"])
        self.assertNotIn("gpt-hidden", status["picker_models"])
        self.assertNotIn("google/gemini-future", status["picker_models"])
        self.assertIn("google/models/gemini-4-hydrogen", writer["options"])
        self.assertNotIn("google/gemini-4-hydrogen", writer["options"])
        self.assertEqual(writer["needs_sync"], ["google/gemini-future", "google/gemini-old"])

        result = instance.call("sync_model_picker", {})
        self.assertEqual(result, {"restart_required": True, "visible": 3})
        self.assertEqual(mygo_setup.load_roles(preferences_path)["roles"]["writer"]["model"],
                         "google/models/gemini-4-hydrogen")
        models = mygo_setup.catalog_models(catalog)
        self.assertEqual(len(models), 7)
        self.assertEqual(models["qwen/qwen3"]["visibility"], "hide")
        self.assertEqual(models["google/gemini-old"]["visibility"], "hide")
        self.assertEqual(instance.call("sync_model_picker", {}), {"restart_required": False, "visible": 3})

        self.write_providers([
            {"id": "google", "preset": "google", "key": "test-only", "models": ["gemini-4-hydrogen"]},
            {"id": "qwen", "preset": "qwen", "key": "test-only", "models": ["qwen3", "internal"]},
        ])
        self.assertEqual(instance.call("sync_model_picker", {}), {"restart_required": True, "visible": 4})
        models = mygo_setup.catalog_models(catalog)
        self.assertEqual(models["qwen/qwen3"]["visibility"], "list")
        self.assertEqual(models["qwen/internal"]["visibility"], "hide")

    def test_picker_applies_local_provider_choices_and_orders_visible_models(self):
        google = ["gemini-3.1-flash-lite", "gemini-3.7-flash", "gemini-3.8-flash",
                  "gemini-4-argon", "gemini-4-carbon", "gemini-4-hydrogen", "gemini-4-neon"]
        self.write_providers([
            {"id": "google", "preset": "google", "key": "test-only", "models": google},
            {"id": "moonshot-cn", "preset": "moonshot-cn", "key": "test-only",
             "models": ["kimi-k3", "kimi-k3.1-pro"]},
            {"id": "zhipu", "preset": "zhipu", "key": "test-only",
             "models": ["glm-5.3-flash", "glm-5.4"]},
            {"id": "deepseek", "preset": "deepseek", "key": "test-only", "models": ["deepseek-flash"]},
        ])
        (self.home / "config.toml").write_text(
            'model = "gpt-6.2-sol"\nmodel_catalog_json = "mygo-magpie-v2-models.json"\n'
            '[features.multi_agent_v2]\nenabled = true\n', encoding="utf-8",
        )
        picks = ["gemini-4-neon", "gemini-4-hydrogen", "gemini-4-carbon", "gemini-3.8-flash"]
        mygo_setup.atomic_write(self.home / mygo_setup.PICKER_PREFERENCES, json.dumps({"google": picks}))
        catalog = self.home / mygo_setup.NATIVE_CATALOG
        shuffled = ["google/models/" + model for model in google] + [
            "gpt-6.2-sol", "moonshot-cn/kimi-k3", "deepseek/deepseek-flash",
            "zhipu/glm-5.3-flash", "gpt-6-luna", "moonshot-cn/kimi-k3.1-pro", "zhipu/glm-5.4",
        ]
        catalog.write_text(json.dumps({"models": [
            {"slug": slug, "priority": i, "visibility": "list", "multi_agent_version": "v2"}
            for i, slug in enumerate(shuffled)
        ]}), encoding="utf-8")

        instance = mygo_server.Server(self.home)
        expected = ["gpt-6.2-sol", "gpt-6-luna", "deepseek/deepseek-flash",
                    "moonshot-cn/kimi-k3.1-pro", "moonshot-cn/kimi-k3",
                    "zhipu/glm-5.4", "zhipu/glm-5.3-flash",
                    *("google/models/" + model for model in picks)]
        result = instance.call("sync_model_picker", {})
        self.assertEqual(result, {"visible": len(expected), "restart_required": True})
        state = instance.call("read_settings", {})
        self.assertEqual(state["picker_models"], expected)
        self.assertEqual(set(state["available_models"]), set(shuffled))
        self.assertEqual(instance.call("sync_model_picker", {}),
                         {"visible": len(expected), "restart_required": False})

    def test_signed_in_sync_loads_gateway_catalog_without_legacy_files(self):
        self.write_providers()
        (self.home / "config.toml").write_text(
            'model = "gpt-6.2-sol"\nmodel_catalog_json = "mygo-magpie-v2-models.json"\n'
            'openai_base_url = "http://127.0.0.1:3425/backend-api/codex"\n'
            '[features.multi_agent_v2]\nenabled = true\n', encoding="utf-8",
        )
        catalog = self.catalog()
        lead = catalog["models"].pop(0)
        (self.home / "models_cache.json").write_text(json.dumps({"models": [lead]}), encoding="utf-8")
        fake = FakeMagpie()
        with mock.patch.object(mygo_setup, "HTTPConnection") as connection, \
                mock.patch.object(mygo_setup, "codex_capability_check", return_value="passed"):
            conn = connection.return_value
            conn.getresponse.return_value.status = 200
            conn.getresponse.return_value.read.return_value = json.dumps(catalog).encode("utf-8")
            result = mygo_setup.configure(self.home, fake, apply=True)
        self.assertEqual(fake.calls, [])
        conn.request.assert_called_once_with("GET", "/v1/codex/models?client_version=0.166.0")
        self.assertEqual(result["visible"], 5)
        self.assertEqual(set(mygo_setup.catalog_models(Path(result["catalog"]))),
                         {lead["slug"], *(entry["slug"] for entry in catalog["models"])})
        self.assertFalse(any((self.home / name).exists() for name in mygo_setup.MAGPIE_CATALOGS))

    def test_existing_configuration_syncs_a_newly_selected_model(self):
        self.write_providers([{"id": "deepseek", "preset": "deepseek", "key": "test-only",
                               "pickedFrom": ["deepseek-flash", "deepseek-v4-pro"]}])
        (self.home / "config.toml").write_text(
            'model_catalog_json = "mygo-magpie-v2-models.json"\n[features.multi_agent_v2]\nenabled = true\n',
            encoding="utf-8",
        )
        preferences = copy.deepcopy(mygo_setup.DEFAULT_ROLES)
        preferences["roles"]["researcher"]["model"] = "deepseek/deepseek-v4-pro"
        mygo_setup.save_roles(self.home / "mygo/preferences.json", preferences)
        initial = self.catalog()
        synced = copy.deepcopy(initial)
        synced["models"].append({"slug": "deepseek/deepseek-v4-pro", "multi_agent_version": "v2"})
        fake = FakeMagpie()
        with mock.patch.object(fake, "codex_catalog", side_effect=[initial, synced]), \
                mock.patch.object(mygo_setup, "codex_capability_check", return_value="passed"):
            result = mygo_setup.configure(self.home, fake, apply=True)
        self.assertEqual(fake.calls, [["provider", "models", "deepseek", "+deepseek-v4-pro"], ["sync"]])
        models = mygo_setup.catalog_models(Path(result["catalog"]))
        self.assertEqual(models["deepseek/deepseek-v4-pro"].get("visibility", "list"), "list")

    def test_desktop_catalog_is_valid_fallback_when_gateway_is_unavailable(self):
        desktop = self.home / "magpie-desktop-models.json"
        desktop.write_text(json.dumps(self.catalog()), encoding="utf-8")
        legacy = self.home / "magpie-models.json"
        legacy.write_text('{"models":[]}', encoding="utf-8")
        result = mygo_setup.magpie_codex_catalog(self.home, FakeMagpie(), {})
        self.assertEqual(result, self.catalog())
        desktop.unlink()
        with self.assertRaisesRegex(RuntimeError, "无法读取 Magpie"):
            mygo_setup.magpie_codex_catalog(self.home, FakeMagpie(), {})

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
