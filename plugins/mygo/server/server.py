"""MYGO settings MCP App. The tool schema never accepts an API key."""

from base64 import b64decode
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
from urllib.request import Request, urlopen

from mygo_setup import (
    DEFAULT_ROLES, EFFORTS, Magpie, MAGPIE_PRESETS, MINIMUM_MAGPIE, PROVIDERS,
    configure, credential_status, find_codex, provider_state,
    install_magpie, managed_magpie_path, load_roles, role_model_choices, save_roles, status, sync_model_picker,
)

PLUGIN_FOLDER = Path(__file__).absolute().parents[1]
ROOT = PLUGIN_FOLDER.resolve()
VERSION = json.loads((ROOT / "plugin.json").read_text(encoding="utf-8"))["version"]
CACHE_PATH = Path("plugins/cache/mygo/mygo")
PLUGIN_ID = "mygo@mygo"
URI = f"ui://mygo/settings-{VERSION}.html"
UPDATE_MANIFEST = "https://api.github.com/repos/EliotOK/Multiagent-Yield-optimized-General-Orchestrator/contents/plugins/mygo/plugin.json?ref=main"
# Desktop may reopen a panel using the resource URI saved before an upgrade.
SETTINGS_URI_PATTERN = re.compile(r"ui://mygo/settings(?:-[0-9]{1,8}\.[0-9]{1,8}\.[0-9]{1,8})?\.html")
MIME = "text/html;profile=mcp-app"


def definition(name, description, properties=None, required=(), app=False, panel=False, mutating=False, title=None, network=False):
    result = {
        "name": name,
        "title": title or description.split(".")[0],
        "description": description,
        "inputSchema": {"type": "object", "properties": properties or {}, "required": list(required), "additionalProperties": False},
        "annotations": {"readOnlyHint": not mutating, "destructiveHint": False, "idempotentHint": True, "openWorldHint": network},
    }
    if app:
        result["_meta"] = {"ui": {"visibility": ["app"]}}
    if panel:
        result["_meta"] = {
            "ui": {"resourceUri": URI},
            "openai/ui": {"entrypoints": [{"type": "global"}, {"type": "thread"}]},
        }
    return result


ROLE_PROPS = {
    "label": {"type": "string", "minLength": 1, "maxLength": 60},
    "model": {"type": "string", "minLength": 1, "maxLength": 200},
    "responsibility": {"type": "string", "minLength": 1, "maxLength": 1000},
    "effort": {"type": "string", "enum": sorted(EFFORTS)},
}
ROLES_PROPS = {key: {"type": "object", "properties": ROLE_PROPS, "required": list(ROLE_PROPS), "additionalProperties": False} for key in DEFAULT_ROLES["roles"]}
PREFERENCES_PROPS = {
    "preferences": {"type": "object", "properties": {"version": {"type": "integer", "const": 1}, "roles": {"type": "object", "properties": ROLES_PROPS, "required": list(ROLES_PROPS), "additionalProperties": False}}, "required": ["version", "roles"], "additionalProperties": False},
}
PROVIDER_PROPS = {
    "provider": {"type": "string", "pattern": "^[a-z0-9][a-z0-9-]{0,79}$"},
    "source": {"type": "string", "enum": ["environment", "prompt"]},
    "glm_plan": {"type": "string", "enum": ["coding", "api"]},
}
TOOLS = [
    definition("show_settings", "Open MYGO settings", panel=True, title="打开 MYGO 设置"),
    definition("check_update", "Check the official MYGO marketplace for a newer version", app=True, network=True),
    definition("update_plugin", "Upgrade MYGO using the configured Codex plugin marketplace", app=True, mutating=True, network=True),
    definition("read_settings", "Read secret-free MYGO provider readiness and role preferences", app=True),
    definition("refresh_provider_models", "Fetch the model list for one configured Magpie provider",
               {"provider_id": {"type": "string", "minLength": 1}}, ["provider_id"],
               app=True, mutating=True, network=True),
    definition("import_credential", "Import a provider credential in a local password window. No secret is passed to this tool", PROVIDER_PROPS, ["provider", "source"], app=True, mutating=True),
    definition("sync_model_picker", "Show synced MYGO models in the Codex model picker", app=True, mutating=True),
    definition("configure_native", "Enable native V2 subagents or synchronize their model catalog",
               {"repair": {"type": "boolean"}}, app=True, mutating=True),
    definition("save_roles", "Save model, responsibility, and reasoning preferences", PREFERENCES_PROPS, ["preferences"], app=True, mutating=True),
    definition("settings.read", "Read MYGO settings", app=True),
    definition("settings.update", "Update MYGO role preferences", {"set": {"type": "object", "minProperties": 1, "additionalProperties": {"type": "string"}}}, ["set"], app=True, mutating=True),
]
for tool in TOOLS:
    if tool["name"] == "settings.read":
        tool["outputSchema"] = {"type": "object", "properties": {"schema": {"type": "object"}, "values": {"type": "object"}, "layout": {"type": "array", "items": {"type": "object"}}}, "required": ["schema", "values"]}
    if tool["name"] == "settings.update":
        tool["outputSchema"] = {"type": "object", "properties": {"values": {"type": "object"}}, "required": ["values"]}


def setting_schema(home, preferences):
    choices = role_model_choices(home, preferences)
    properties, values = {}, {}
    groups = [{
        "kind": "group",
        "title": "本机配置",
        "items": [{"kind": "tool", "tool": "show_settings"}],
    }]
    for key, role in preferences["roles"].items():
        prefix = f"{key}."
        if not choices[key]["active"]:
            continue
        for field, title in (("label", "Display name"), ("model", "Model"), ("responsibility", "Default responsibility"), ("effort", "Reasoning effort")):
            properties[prefix + field] = {"type": "string", "title": title}
            if field == "effort":
                properties[prefix + field]["enum"] = sorted(EFFORTS)
            if field == "model":
                properties[prefix + field]["enum"] = choices[key]["options"]
            values[prefix + field] = choices[key]["model"] if field == "model" else role[field]
        groups.append({"kind": "group", "title": f"{key} · {role['label']}", "items": [{"kind": "property", "property": prefix + field} for field in ("label", "model", "responsibility", "effort")]})
    return {"schema": {"type": "object", "properties": properties, "required": list(properties)}, "values": values, "layout": groups}


def release_version(manifest):
    if isinstance(manifest, dict) and manifest.get("name") == "mygo":
        version = manifest.get("version")
        if isinstance(version, str) and re.fullmatch(r"[0-9]{1,8}(\.[0-9]{1,8}){2}", version):
            return version
    raise ValueError("无法识别 MYGO 的版本信息。")


def published_version():
    request = Request(UPDATE_MANIFEST, headers={"User-Agent": "MYGO-Setup", "Cache-Control": "no-cache"})
    try:
        with urlopen(request, timeout=12) as response:
            entry = json.loads(response.read(65536))
            if entry["encoding"] != "base64":
                raise ValueError("Unrecognized GitHub file encoding")
            content = b64decode("".join(entry["content"].split()), validate=True)
            return release_version(json.loads(content))
    except (OSError, ValueError, KeyError, AttributeError, TypeError) as error:
        raise RuntimeError("暂时无法检查 MYGO 更新。请稍后再试。") from error


def profile_home(root):
    configured = os.environ.get("CODEX_HOME")
    explicit_home = Path(configured).expanduser() if configured else None
    default_home = Path.home() / ".codex"
    # Match the physical package through each profile's logical cache path.
    # Windows may place that cache on a different drive through a junction.
    physical_package = root.resolve()
    for candidate in (explicit_home, default_home):
        if candidate is not None and (candidate / CACHE_PATH / root.name).resolve() == physical_package:
            return candidate
    if root.parent.parts[-len(CACHE_PATH.parts):] == CACHE_PATH.parts:
        cached_home = root.parents[len(CACHE_PATH.parts)]
        if (cached_home / "config.toml").is_file():
            return cached_home
    return explicit_home if explicit_home is not None else default_home


def version_key(version):
    return tuple(map(int, version.split(".")))


def update_environment(home):
    environment = dict(os.environ, CODEX_HOME=str(home), GIT_TERMINAL_PROMPT="0")
    if os.name == "nt" and not shutil.which("git.exe", path=environment.get("PATH", "")):
        profile = Path.home()
        directories = [
            Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git/cmd",
            profile / "AppData/Local/Programs/Git/cmd",
            profile / ".cache/codex-runtimes/codex-primary-runtime/dependencies/native/git/cmd",
        ]
        for directory in directories:
            if (directory / "git.exe").is_file():
                environment["PATH"] = str(directory) + os.pathsep + environment.get("PATH", "")
                break
    return environment


def run_codex(executable, arguments, environment, timeout):
    return subprocess.run([executable, *arguments], env=environment, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, encoding="utf-8", errors="replace",
                          timeout=timeout, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def installed_version(executable, environment):
    if not executable:
        return VERSION
    try:
        result = run_codex(executable, ["plugin", "list", "--marketplace", "mygo", "--json"], environment, 8)
        result.check_returncode()
        entries = json.loads(result.stdout)["installed"]
        for item in entries:
            if item.get("pluginId") == PLUGIN_ID:
                return release_version({"name": "mygo", "version": item["version"]})
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        pass
    return VERSION


def update_result(latest, installed):
    return {
        "current": VERSION, "installed": installed, "latest": latest,
        "reload_required": version_key(installed) > version_key(VERSION),
        "update_available": bool(latest and version_key(latest) > version_key(installed)),
    }


def update_error(result):
    # Match known failures without presenting potentially sensitive CLI output.
    details = (result.stderr + result.stdout).casefold()
    if "git" in details and any(marker in details for marker in ("program not found", "could not find git", "git not found")):
        return "Codex 无法启动 Git。安装 Git 后，退出并重新打开 Codex，再试一次。"
    if any(marker in details for marker in ("access is denied", "permission denied", "access denied", "拒绝访问", "os error 5")):
        return "Codex 无权写入插件目录。请在 Codex 的插件目录里刷新 MYGO 市场源后重试。"
    if any(marker in details for marker in ("could not resolve host", "failed to connect", "failed to fetch", "connection reset")):
        return "Codex 无法连接 GitHub。请检查网络后重试。"
    if "marketplace" in details and any(marker in details for marker in ("not configured", "unknown marketplace", "unrecognized subcommand")):
        return "当前 Codex 配置无法升级 MYGO 市场源。请核对插件目录中的 MYGO 来源。"
    return f"Codex 的插件更新命令失败（退出码 {result.returncode}）。请在插件目录中刷新 MYGO 市场源后重试。"

class Server:
    def __init__(self, home):
        self.home = home.expanduser().resolve()
        self.magpie = Magpie()
        self.setup_lock = threading.Lock()
        self.credential_process = None

    def read(self):
        result = status(self.home, self.magpie)
        presets = {"qwen": "Qwen", "qwen-cn": "Qwen（中国区）",
                   "qwen-token-plan": "Qwen Token Plan", "bailian-token-plan": "百炼 Token Plan"}
        if self.magpie.executable:
            try:
                presets.update(self.magpie.key_presets())
            except (RuntimeError, OSError, subprocess.SubprocessError):
                pass
        existing = provider_state()
        in_use = {item["preset"] for item in existing.values() if item["configured"]}
        excluded = in_use | set(MAGPIE_PRESETS.values()) | set(PROVIDERS)
        result["provider_presets"] = {key: label for key, label in presets.items() if key not in excluded}
        result["platform"] = os.name
        result["preferences_path"] = str(self.home / "mygo" / "preferences.json")
        result["codex_available"] = bool(find_codex())
        return result

    def ensure_magpie(self):
        try:
            if self.magpie.executable and self.magpie.version() >= MINIMUM_MAGPIE:
                return
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass
        self.magpie.executable = install_magpie(managed_magpie_path())

    def import_credential(self, args):
        if os.name != "nt":
            raise RuntimeError("Interactive credential import currently supports Windows. Add the provider in Magpie's own interface on this platform.")
        provider = args["provider"]
        if not isinstance(provider, str) or not re.fullmatch(PROVIDER_PROPS["provider"]["pattern"], provider):
            raise ValueError("Invalid provider preset ID.")
        if args["source"] not in {"environment", "prompt"} or (args["source"] == "environment" and provider not in PROVIDERS):
            raise ValueError("Unknown credential source for this provider.")
        with self.setup_lock:
            self.check_credential_window()
            preset = MAGPIE_PRESETS.get(provider, provider)
            if any(item["configured"] and item["preset"] == preset for item in provider_state().values()):
                return {"provider": provider, "saved": False, "reason": "already_configured"}
            self.ensure_magpie()
            if provider not in PROVIDERS and provider not in self.magpie.key_presets():
                raise ValueError("This preset needs to be configured in Magpie directly.")
            self.magpie.ensure_gateway()
            command = [
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                str(ROOT / "server" / "credential-window.ps1"),
                "-Provider", provider, "-Source", args["source"], "-Plan", args.get("glm_plan", "coding"),
                "-Python", sys.executable, "-Helper", str(ROOT / "server" / "credential_import.py"),
                "-Magpie", self.magpie.executable,
            ]
            environment = os.environ.copy()
            environment["CODEX_HOME"] = str(self.home)
            self.credential_process = subprocess.Popen(command, env=environment, creationflags=getattr(subprocess, "CREATE_NEW_CONSOLE", 0))
            return {"provider": provider, "window_opened": True, "message": "Complete the local password window, then refresh this panel."}

    def check_credential_window(self):
        if self.credential_process is not None and self.credential_process.poll() is None:
            raise RuntimeError("请先完成或关闭已打开的密钥窗口。")

    def refresh_provider_models(self, provider_id):
        with self.setup_lock:
            self.check_credential_window()
            provider = provider_state().get(provider_id) if isinstance(provider_id, str) else None
            if not provider or not provider["configured"]:
                raise ValueError("请先在 Magpie 中配置这家供应商。")
            if not self.magpie.executable:
                raise RuntimeError("未找到 Magpie CLI。请在 Magpie 中刷新模型列表，再回到 MYGO 刷新状态。")
            before = set(provider["models"])
            try:
                self.magpie.run(["provider", "refresh", provider_id], timeout=45)
            except subprocess.TimeoutExpired:
                raise RuntimeError("刷新模型列表超时，请稍后重试。") from None
            except (OSError, RuntimeError, subprocess.SubprocessError):
                raise RuntimeError("Magpie 未能获取模型列表。请在 Magpie 中检查此供应商的连接后重试。") from None
            updated = provider_state().get(provider_id)
            if not updated or not updated["configured"]:
                raise RuntimeError("供应商配置已变化，请刷新状态后重试。")
            after = set(updated["models"])
            return {"model_count": len(after), "added": len(after - before), "removed": len(before - after)}

    def check_update(self):
        environment = update_environment(self.home)
        installed = installed_version(find_codex(), environment)
        try:
            latest = published_version()
        except RuntimeError:
            if version_key(installed) > version_key(VERSION):
                return update_result(None, installed)
            raise
        return update_result(latest, installed)

    def update_plugin(self):
        with self.setup_lock:
            self.check_credential_window()
            release = self.check_update()
            if not release["update_available"]:
                return release
            executable = find_codex()
            if not executable:
                raise RuntimeError("未找到 Codex CLI。请更新 Codex 后重试。")
            environment = update_environment(self.home)
            latest = release["latest"]
            try:
                result = run_codex(executable, ["plugin", "marketplace", "upgrade", "mygo", "--json"], environment, 75)
                state = update_result(latest, installed_version(executable, environment))
                if not state["update_available"]:
                    return state
                if result.returncode:
                    raise RuntimeError(update_error(result))
                snapshot = self.home / ".tmp/marketplaces/mygo/plugins/mygo/plugin.json"
                marketplace_version = release_version(json.loads(snapshot.read_text(encoding="utf-8")))
                if version_key(marketplace_version) < version_key(latest):
                    raise RuntimeError("已刷新市场，但你的 MYGO 市场源还未提供新版。请在插件目录核对市场源。")
                # An already-current checkout can coexist with an older installed package.
                result = run_codex(executable, ["plugin", "add", PLUGIN_ID, "--json"], environment, 25)
                state = update_result(latest, installed_version(executable, environment))
                if not state["update_available"]:
                    return state
                if result.returncode:
                    raise RuntimeError(update_error(result))
            except subprocess.TimeoutExpired:
                raise RuntimeError("MYGO 更新超时。请检查网络，然后重新检查更新。") from None
            except OSError:
                raise RuntimeError("Codex 无法启动或读取插件更新。请在插件目录刷新 MYGO 市场源后重试。") from None
            except ValueError:
                raise RuntimeError("Codex 未能读取 MYGO 市场的版本信息。请刷新市场源后重试。") from None
            raise RuntimeError("市场已刷新，Codex 的安装列表仍未显示新版。请在插件目录重新检查 MYGO。")

    def call(self, name, args):
        if name == "show_settings":
            return {"opened": True, "version": VERSION}
        if name == "check_update":
            return self.check_update()
        if name == "update_plugin":
            return self.update_plugin()
        if name == "read_settings":
            return self.read()
        if name == "refresh_provider_models":
            return self.refresh_provider_models(args["provider_id"])
        if name == "settings.read":
            return setting_schema(self.home, load_roles(self.home / "mygo" / "preferences.json"))
        if name == "settings.update":
            preferences = load_roles(self.home / "mygo" / "preferences.json")
            changes = args["set"]
            if not isinstance(changes, dict) or not changes:
                raise ValueError("At least one MYGO setting is required.")
            for field, value in changes.items():
                role, separator, attribute = field.partition(".")
                if not separator or role not in preferences["roles"] or attribute not in ROLE_PROPS:
                    raise ValueError("Unknown MYGO setting.")
                if not isinstance(value, str):
                    raise ValueError("MYGO settings must be text values.")
                preferences["roles"][role][attribute] = value
            return setting_schema(self.home, save_roles(self.home / "mygo" / "preferences.json", preferences))
        if name == "save_roles":
            with self.setup_lock:
                return {"saved": True, "preferences": save_roles(self.home / "mygo" / "preferences.json", args["preferences"])}
        if name == "import_credential":
            return self.import_credential(args)
        if name == "sync_model_picker":
            with self.setup_lock:
                self.check_credential_window()
                return sync_model_picker(self.home)
        if name == "configure_native":
            with self.setup_lock:
                self.check_credential_window()
                self.ensure_magpie()
                self.magpie.ensure_gateway()
                result = configure(self.home, self.magpie, apply=True, repair=args.get("repair") is True)
                result["credentials"] = credential_status()
                return result
        raise ValueError("Unknown MYGO tool.")

    def handle(self, message):
        ident = message.get("id") if isinstance(message, dict) else None
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" or not isinstance(message.get("method"), str):
            return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32600, "message": "Invalid request"}}
        if "id" not in message:
            return None
        method, params = message["method"], message.get("params", {})
        try:
            if not isinstance(params, dict):
                raise ValueError("Invalid parameters")
            if method == "initialize":
                version = params.get("protocolVersion")
                result = {
                    "protocolVersion": version if version in ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25") else "2025-06-18",
                    "capabilities": {"tools": {}, "resources": {}, "experimental": {"openai/settings": {"readTool": "settings.read", "updateTool": "settings.update"}}},
                    "serverInfo": {"name": "mygo", "version": VERSION},
                    "instructions": "Use show_settings for local setup. Never request, accept, or return API keys. Provider import tools accept only a provider name and source. Role preferences contain no credentials.",
                }
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                name = params.get("name")
                definition_item = next((tool for tool in TOOLS if tool["name"] == name), None)
                args = params.get("arguments", {})
                if not definition_item or not isinstance(args, dict):
                    raise ValueError("Unknown tool or arguments")
                if set(args) - set(definition_item["inputSchema"]["properties"]):
                    raise ValueError("Unexpected arguments")
                data = self.call(name, args)
                text = "MYGO settings are ready." if name in {"show_settings", "read_settings", "settings.read"} else "MYGO settings were updated."
                result = {"structuredContent": data, "content": [{"type": "text", "text": text}]}
                if name == "show_settings":
                    result["content"][0]["text"] = f"MYGO {VERSION} settings are ready."
                    result["_meta"] = {"ui": {"resourceUri": URI}}
            elif method == "resources/list":
                result = {"resources": [{"uri": URI, "mimeType": MIME, "name": "mygo-settings"}]}
            elif method == "resources/templates/list":
                result = {"resourceTemplates": []}
            elif method == "resources/read":
                uri = params.get("uri")
                if not isinstance(uri, str) or (uri != URI and not SETTINGS_URI_PATTERN.fullmatch(uri)):
                    return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32002, "message": "Resource not found"}}
                html = (ROOT / "ui/settings.html").read_text(encoding="utf-8")
                html = html.replace("/* SETTINGS_CSS */", (ROOT / "ui/settings.css").read_text(encoding="utf-8"))
                html = html.replace("/* SETTINGS_JS */", (ROOT / "ui/settings.js").read_text(encoding="utf-8"))
                html = html.replace("__MYGO_VERSION__", VERSION)
                result = {"contents": [{"uri": uri, "mimeType": MIME, "text": html, "_meta": {"ui": {"prefersBorder": True, "csp": {"connectDomains": [], "resourceDomains": []}}, "openai/ui": {"availableDisplayModes": ["inline", "fullscreen"], "preferredDisplayMode": "fullscreen"}}}]}
            else:
                return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "Unknown method"}}
            return {"jsonrpc": "2.0", "id": ident, "result": result}
        except Exception as error:
            message = str(error)
            for provider in PROVIDERS.values():
                secret = os.environ.get(provider["env"])
                if secret:
                    message = message.replace(secret, "[redacted]")
            return {"jsonrpc": "2.0", "id": ident, "result": {"isError": True, "content": [{"type": "text", "text": message[-1000:]}]}}


def main():
    server = Server(profile_home(PLUGIN_FOLDER))
    sys.stdout.reconfigure(encoding="utf-8")
    for line in sys.stdin.buffer:
        try:
            message = json.loads(line)
        except ValueError:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Invalid JSON"}}
        else:
            response = server.handle(message)
        if response is not None:
            print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
