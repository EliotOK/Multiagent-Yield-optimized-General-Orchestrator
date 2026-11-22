"""MYGO settings MCP App. The tool schema never accepts an API key."""

import json
import os
from pathlib import Path
import subprocess
import sys
import threading

from mygo_setup import (
    DEFAULT_ROLES, EFFORTS, Magpie, MINIMUM_MAGPIE, PROVIDERS,
    configure, credential_status, find_codex,
    install_magpie, managed_magpie_path, load_roles, role_model_choices, save_roles, status,
)

ROOT = Path(__file__).resolve().parents[1]
URI = "ui://mygo/settings.html"
MIME = "text/html;profile=mcp-app"


def definition(name, description, properties=None, required=(), app=False, panel=False, mutating=False, title=None):
    result = {
        "name": name,
        "title": title or description.split(".")[0],
        "description": description,
        "inputSchema": {"type": "object", "properties": properties or {}, "required": list(required), "additionalProperties": False},
        "annotations": {"readOnlyHint": not mutating, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False},
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
    "provider": {"type": "string", "enum": list(PROVIDERS)},
    "source": {"type": "string", "enum": ["environment", "prompt"]},
    "glm_plan": {"type": "string", "enum": ["coding", "api"]},
}
TOOLS = [
    definition("show_settings", "Open MYGO settings", panel=True, title="打开 MYGO 设置"),
    definition("read_settings", "Read secret-free MYGO provider readiness and role preferences", app=True),
    definition("import_credential", "Import a provider credential in a local password window. No secret is passed to this tool", PROVIDER_PROPS, ["provider", "source"], app=True, mutating=True),
    definition("configure_native", "Install a compatible Magpie CLI if needed and enable native V2 subagents", app=True, mutating=True),
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
        for field, title in (("label", "Display name"), ("model", "Model"), ("responsibility", "Default responsibility"), ("effort", "Reasoning effort")):
            properties[prefix + field] = {"type": "string", "title": title}
            if field == "effort":
                properties[prefix + field]["enum"] = sorted(EFFORTS)
            if field == "model":
                properties[prefix + field]["enum"] = choices[key]["options"]
            values[prefix + field] = role[field]
        groups.append({"kind": "group", "title": f"{key} · {role['label']}", "items": [{"kind": "property", "property": prefix + field} for field in ("label", "model", "responsibility", "effort")]})
    return {"schema": {"type": "object", "properties": properties, "required": list(properties)}, "values": values, "layout": groups}


class Server:
    def __init__(self, home):
        self.home = home.expanduser().resolve()
        self.magpie = Magpie()
        self.setup_lock = threading.Lock()
        self.credential_lock = threading.Lock()

    def read(self):
        result = status(self.home, self.magpie)
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
        if provider not in PROVIDERS or args["source"] not in {"environment", "prompt"}:
            raise ValueError("Unknown provider or credential source.")
        with self.credential_lock:
            if credential_status()[provider]["configured"]:
                return {"provider": provider, "saved": False, "reason": "already_configured"}
            self.ensure_magpie()
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
            subprocess.Popen(command, env=environment)
            return {"provider": provider, "window_opened": True, "message": "Complete the local password window, then refresh this panel."}

    def call(self, name, args):
        if name == "show_settings":
            return {"opened": True}
        if name == "read_settings":
            return self.read()
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
        if name == "configure_native":
            with self.setup_lock:
                self.ensure_magpie()
                self.magpie.ensure_gateway()
                result = configure(self.home, self.magpie, apply=True)
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
                    "serverInfo": {"name": "mygo", "version": "0.3.1"},
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
                    result["_meta"] = {"ui": {"resourceUri": URI}}
            elif method == "resources/list":
                result = {"resources": [{"uri": URI, "mimeType": MIME, "name": "mygo-settings"}]}
            elif method == "resources/templates/list":
                result = {"resourceTemplates": []}
            elif method == "resources/read" and params.get("uri") == URI:
                html = (ROOT / "ui/settings.html").read_text(encoding="utf-8")
                html = html.replace("/* SETTINGS_CSS */", (ROOT / "ui/settings.css").read_text(encoding="utf-8"))
                html = html.replace("/* SETTINGS_JS */", (ROOT / "ui/settings.js").read_text(encoding="utf-8"))
                result = {"contents": [{"uri": URI, "mimeType": MIME, "text": html, "_meta": {"ui": {"prefersBorder": True, "csp": {"connectDomains": [], "resourceDomains": []}}, "openai/ui": {"availableDisplayModes": ["inline", "fullscreen"], "preferredDisplayMode": "fullscreen"}}}]}
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
    home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    server = Server(home)
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
