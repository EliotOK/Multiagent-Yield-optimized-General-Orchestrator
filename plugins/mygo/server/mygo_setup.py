"""MYGO local setup. Secret values are confined to the credential helper."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import tomllib
from datetime import datetime, timezone
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROLES = json.loads((ROOT / "assets/default-roles.json").read_text(encoding="utf-8"))
PROVIDERS = {
    "deepseek": {"label": "DeepSeek", "env": "DEEPSEEK_API_KEY", "models": ["deepseek-flash"]},
    "kimi": {"label": "Kimi", "env": "MOONSHOT_API_KEY", "models": ["kimi-k3.1-pro"]},
    "glm": {"label": "GLM", "env": "ZAI_API_KEY", "models": ["glm-5.3-flash"]},
    "gemini": {"label": "Gemini", "env": "GEMINI_API_KEY", "models": ["gemini-3.1-flash-lite"]},
}
MAGPIE_PRESETS = {"deepseek": "deepseek", "kimi": "moonshot-cn", "glm": "zhipu", "gemini": "google"}
MAGPIE_VERSION = "v0.1.4656"
MINIMUM_MAGPIE = (0, 1, 4656)
MODEL_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,199}$")
EFFORTS = {"low", "medium", "high", "xhigh", "max"}
PENDING_KEY = "mygo-pending-not-a-key"


def clean_text(value, limit=500):
    if not isinstance(value, str):
        raise ValueError("Text values are required.")
    value = value.strip()
    if not value or len(value) > limit or "\x00" in value:
        raise ValueError("Text length or content is invalid.")
    return value


def load_roles(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return json.loads(json.dumps(DEFAULT_ROLES))
    if data.get("version") != 1 or not isinstance(data.get("roles"), dict):
        raise ValueError("MYGO preferences have an unsupported format.")
    roles = {}
    for key in DEFAULT_ROLES["roles"]:
        item = data["roles"].get(key)
        if not isinstance(item, dict) or set(item) != {"label", "model", "responsibility", "effort"}:
            raise ValueError(f"MYGO role {key} is incomplete.")
        model = clean_text(item["model"], 200)
        if not MODEL_PATTERN.fullmatch(model):
            raise ValueError(f"Invalid model ID for {key}.")
        if item["effort"] not in EFFORTS:
            raise ValueError(f"Invalid reasoning effort for {key}.")
        roles[key] = {
            "label": clean_text(item["label"], 60),
            "model": model,
            "responsibility": clean_text(item["responsibility"], 1000),
            "effort": item["effort"],
        }
    return {"version": 1, "roles": roles}


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".mygo-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if os.name != "nt":
            os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def save_roles(path, roles):
    if not isinstance(roles, dict) or set(roles) != {"version", "roles"}:
        raise ValueError("MYGO preferences have an unsupported format.")
    encoded = json.dumps(roles, ensure_ascii=False)
    with tempfile.TemporaryDirectory(prefix="mygo-validate-") as directory:
        candidate = Path(directory) / "preferences.json"
        candidate.write_text(encoded, encoding="utf-8")
        data = load_roles(candidate)
    atomic_write(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return data


def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    raise ValueError("Unsupported TOML value.")


def set_toml_key(text, section, key, value):
    """Replace one scalar TOML key while retaining unrelated configuration."""
    header = re.compile(r"^\s*\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?$")
    key_pattern = re.compile(rf"^(\s*{re.escape(key)}\s*=).*$")
    lines = text.splitlines(keepends=True)
    ranges = []
    for index, line in enumerate(lines):
        match = header.match(line.rstrip("\r\n"))
        if match:
            ranges.append((match.group(1), index))
    ranges.append((None, len(lines)))
    found = [index for index in range(len(ranges) - 1) if ranges[index][0] == section]
    if len(found) > 1:
        raise ValueError(f"Duplicate TOML section [{section}].")
    if section == "":
        end = ranges[0][1] if ranges else len(lines)
        matches = [index for index, line in enumerate(lines[:end]) if key_pattern.match(line.rstrip("\r\n"))]
        if len(matches) > 1:
            raise ValueError(f"Duplicate TOML key {key}.")
        if matches:
            index = matches[0]
            newline = "\r\n" if lines[index].endswith("\r\n") else "\n"
            lines[index] = f"{key} = {toml_value(value)}{newline}"
        else:
            lines.insert(0, f"{key} = {toml_value(value)}\n")
        return "".join(lines)
    if not found:
        suffix = "" if not text or text.endswith("\n") else "\n"
        return text + suffix + ("" if not text.strip() else "\n") + f"[{section}]\n{key} = {toml_value(value)}\n"
    start = ranges[found[0]][1] + 1
    end = ranges[found[0] + 1][1]
    matches = [index for index in range(start, end) if key_pattern.match(lines[index].rstrip("\r\n"))]
    if len(matches) > 1:
        raise ValueError(f"Duplicate TOML key {section}.{key}.")
    if matches:
        index = matches[0]
        newline = "\r\n" if lines[index].endswith("\r\n") else "\n"
        lines[index] = f"{key} = {toml_value(value)}{newline}"
    else:
        lines.insert(start, f"{key} = {toml_value(value)}\n")
    return "".join(lines)


def magpie_home():
    config = magpie_environment().get("XDG_CONFIG_HOME", os.environ.get("XDG_CONFIG_HOME"))
    if config and Path(config).is_absolute():
        return Path(config) / "magpie"
    return Path.home() / ".config" / "magpie"


def magpie_environment():
    """Keep a redirected CLI and Magpie Desktop on the same configuration."""
    if os.name != "nt" or not os.environ.get("XDG_CONFIG_HOME") or os.environ.get("MYGO_MAGPIE_EXECUTABLE"):
        return {}
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            value, _ = winreg.QueryValueEx(key, "XDG_CONFIG_HOME")
        if value and Path(value).is_absolute():
            return {"XDG_CONFIG_HOME": value}
    except (FileNotFoundError, OSError):
        pass
    return {}


def managed_magpie_path():
    override = os.environ.get("MYGO_MAGPIE_EXECUTABLE")
    if override:
        return Path(override)
    local = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local")
    return local / "MYGO/bin/magpie.exe"


def find_magpie():
    candidates = [shutil.which("magpie")]
    if os.name == "nt" or os.environ.get("MYGO_MAGPIE_EXECUTABLE"):
        candidates.insert(0, managed_magpie_path())
    if os.name == "nt":
        local = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local")
        # Desktop hosts can redirect LOCALAPPDATA while the CLI lives in the user profile.
        profile_local = Path.home() / "AppData/Local"
        candidates.extend([profile_local / "MYGO/bin/magpie.exe", local / "Programs/Magpie/magpie.exe",
                           profile_local / "Programs/Magpie/magpie.exe", Path.home() / ".local/bin/magpie.exe"])
    else:
        candidates.extend([Path.home() / ".local/bin/magpie", Path("/usr/local/bin/magpie")])
    existing = list(dict.fromkeys(Path(item) for item in candidates if item and Path(item).is_file()))
    for executable in existing:
        try:
            if Magpie(str(executable), timeout=5).version() >= MINIMUM_MAGPIE:
                return str(executable)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            continue
    return str(existing[0]) if existing else None


def environment_key(name):
    value = os.environ.get(name)
    if value or os.name != "nt":
        return value
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            value, _ = winreg.QueryValueEx(key, name)
            return value
    except (FileNotFoundError, OSError):
        return None


def environment_presence(name):
    return bool(environment_key(name))


def read_config(home):
    path = home / "config.toml"
    return path.read_text(encoding="utf-8-sig") if path.exists() else ""


def model_ids(values):
    if not isinstance(values, list):
        return []
    return [value for value in values if isinstance(value, str) and MODEL_PATTERN.fullmatch(value)]


def cached_magpie_models(path, preset):
    """Read Magpie's fetched list, which can be newer than its saved picks."""
    try:
        entry = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    models = entry.get("models") if isinstance(entry, dict) else None
    if not isinstance(models, list):
        return []
    ids = model_ids([
        model.get("ID") or model.get("id") for model in models
        if isinstance(model, dict) and not (model.get("Draws") or model.get("Serves"))
    ])
    if preset == "google":
        return [model.removeprefix("models/") for model in ids]
    return ids


def provider_state():
    try:
        data = json.loads((magpie_home() / "providers.json").read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    cache_dir = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "magpie/models"
    result = {}
    for item in data.get("providers", []):
        if isinstance(item, dict) and isinstance(item.get("id"), str) and re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", item["id"]):
            provider_id = item["id"]
            preset = item.get("preset", "")
            configured = bool(item.get("key") or item.get("keys") or item.get("account"))
            cached = (cached_magpie_models(cache_dir / f"{provider_id}.json", preset)
                      if configured and not item.get("listOff") else [])
            picked = model_ids(item.get("models"))
            discovered = model_ids(item.get("pickedFrom")) + cached
            delisted = set(model_ids(item.get("delisted")))
            result[provider_id] = {
                "preset": preset,
                "label": str(item.get("name") or provider_id),
                "configured": configured,
                "models": [model for model in dict.fromkeys(discovered + picked) if model not in delisted],
                "delisted": delisted,
            }
    return result


def credential_status(existing=None):
    if existing is None:
        existing = provider_state()
    result = {}
    for name, provider in PROVIDERS.items():
        matches = [key for key, item in existing.items() if item["preset"] == MAGPIE_PRESETS[name] and item["configured"]]
        env = environment_presence(provider["env"])
        result[name] = {
            "label": provider["label"],
            "provider_id": matches[0] if matches else MAGPIE_PRESETS[name],
            "configured": bool(matches),
            "environment": env,
            "ready": bool(matches) or env,
            "source": "magpie" if matches else "environment" if env else "missing",
        }
    shown = {item["provider_id"] for item in result.values() if item["configured"]}
    for provider_id, item in existing.items():
        if item["configured"] and provider_id not in shown:
            result[f"magpie:{provider_id}"] = {
                "label": item["label"], "provider_id": provider_id,
                "configured": True, "environment": False, "ready": True, "source": "magpie",
            }
    return result


def catalog_models(path):
    try:
        catalog = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}
    entries = catalog.get("models") if isinstance(catalog, dict) else None
    if not isinstance(entries, list):
        return {}
    return {
        entry["slug"]: entry for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("slug"), str) and MODEL_PATTERN.fullmatch(entry["slug"])
    }


def connected_provider(slug, providers):
    prefix, separator, model = slug.partition("/")
    if not separator or not model:
        return None
    if prefix in providers:
        return prefix if providers[prefix]["configured"] else None
    # Older role files use the preset as the prefix.
    return next((key for key, item in providers.items()
                 if item["configured"] and item["preset"] == prefix), None)


def role_model_choices(home, preferences, providers=None, catalog=None):
    if providers is None:
        providers = provider_state()
    if catalog is None:
        catalog = catalog_models(home / "mygo-magpie-v2-models.json")

    model_groups = {}
    for provider_id, provider in providers.items():
        if not provider["configured"]:
            continue
        options = [f"{provider_id}/{model}" for model in provider["models"]]
        options.extend(slug for slug, model in catalog.items()
                       if connected_provider(slug, providers) == provider_id
                       and slug.partition("/")[2] not in provider["delisted"]
                       and model.get("multi_agent_version") == "v2"
                       and model.get("visibility") != "hide")
        model_groups[provider_id] = {"label": provider["label"], "options": list(dict.fromkeys(options))}

    codex_models = catalog_models(home / "models_cache.json") | catalog
    native = [
        slug for slug, model in codex_models.items()
        if slug.startswith("gpt-") and "/" not in slug
        and model.get("multi_agent_version") == "v2" and model.get("visibility") != "hide"
    ]
    model_groups["@codex"] = {"label": "OpenAI · Codex", "options": native or [DEFAULT_ROLES["roles"]["executor"]["model"]]}

    result = {}
    for key, role in preferences["roles"].items():
        current = role["model"]
        group_id = "@codex" if current.startswith("gpt-") and "/" not in current else connected_provider(current, providers)
        group = model_groups.get(group_id)
        groups = {name: {"label": item["label"], "options": list(item["options"])}
                  for name, item in model_groups.items()}
        retained = group is not None and current not in group["options"]
        if retained:
            groups[group_id]["options"].insert(0, current)
        options = [slug for item in groups.values() for slug in item["options"]]
        result[key] = {
            "provider": group["label"] if group else None,
            "active": group is not None,
            "groups": [item for item in groups.values() if item["options"]],
            "options": options,
            "retained_model": current if retained else None,
            "needs_sync": [slug for slug in options if "/" in slug and catalog.get(slug, {}).get("multi_agent_version") != "v2"],
        }
    return result


class Magpie:
    def __init__(self, executable=None, timeout=90):
        self.executable = executable or find_magpie()
        self.timeout = timeout

    def run(self, args, secret=None, timeout=None, home=None):
        if not self.executable:
            raise RuntimeError("Magpie is not installed.")
        environment = os.environ.copy()
        environment.update(magpie_environment())
        if home is not None:
            environment["CODEX_HOME"] = str(home.resolve())
        result = subprocess.run(
            [self.executable, *args], input=secret, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout or self.timeout, env=environment,
        )
        if result.returncode:
            message = (result.stderr or result.stdout).strip()
            if secret:
                message = message.replace(secret.strip(), "[redacted]")
            raise RuntimeError(f"Magpie command failed: {message[-800:]}")
        return result.stdout

    def version(self):
        match = re.search(r"(\d+)\.(\d+)\.(\d+)", self.run(["version"]))
        if not match:
            raise RuntimeError("Could not identify the Magpie version.")
        return tuple(int(value) for value in match.groups())

    def require_supported_version(self):
        version = self.version()
        if version < MINIMUM_MAGPIE:
            raise RuntimeError(
                f"Magpie {'.'.join(map(str, version))} is too old for secure credential import. "
                f"Install {MAGPIE_VERSION} or newer from https://usemagpie.ai/ and retry."
            )

    def key_presets(self):
        """Read the presets that require only an API key."""
        output = self.run(["presets"], timeout=8)
        pattern = re.compile(r"^\s*(.+?)\s{2,}([a-z0-9-]+)\s+magpie provider add \2 <key>\s*$", re.M)
        return dict((preset, label) for label, preset in pattern.findall(output))

    def save_credential(self, name, secret, plan="coding"):
        """Add a secret through stdin, then remove the CLI's creation placeholder."""
        if name not in PROVIDERS and name not in self.key_presets():
            raise ValueError("Unknown Magpie API-key preset.")
        preset = MAGPIE_PRESETS.get(name, name)
        if not isinstance(secret, str) or not 8 <= len(secret) <= 4096 or secret != secret.strip():
            raise ValueError("The API key is empty or invalid.")
        if any(character.isspace() for character in secret) or secret == PENDING_KEY:
            raise ValueError("The API key contains unsupported whitespace.")
        if plan not in {"coding", "api"}:
            raise ValueError("GLM plan must be coding or api.")
        self.require_supported_version()
        providers = provider_state()
        if any(item["preset"] == preset and item["configured"] for item in providers.values()):
            return {"provider": name, "saved": False, "reason": "already_configured"}
        path = magpie_home() / "providers.json"
        original = path.read_bytes() if path.exists() else None
        provider_id = next((key for key, item in providers.items() if item["preset"] == preset), preset)
        created = provider_id not in providers or providers[provider_id]["preset"] != preset
        try:
            if created:
                args = ["provider", "add", preset, PENDING_KEY]
                if name == "glm":
                    args.append("plan=" + plan)
                output = self.run(args)
                match = re.search(r"\(([a-z0-9-]+)\)", output)
                if match:
                    provider_id = match.group(1)
            self.run(["provider", "keys", provider_id, "add", "-"], secret=secret + "\n")
            if created:
                self._remove_pending_key(path, provider_id)
        except Exception:
            if original is None:
                if path.exists():
                    path.unlink()
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                temporary = path.with_suffix(".mygo-rollback")
                temporary.write_bytes(original)
                os.replace(temporary, path)
            raise
        if name not in PROVIDERS and not provider_state().get(provider_id, {}).get("models"):
            try:
                self.run(["provider", "refresh", provider_id], timeout=30)
            except (OSError, RuntimeError, subprocess.SubprocessError):
                return {"provider": name, "saved": True, "provider_id": provider_id, "refresh_failed": True}
        return {"provider": name, "saved": True, "provider_id": provider_id}

    def _remove_pending_key(self, path, provider_id):
        data = json.loads(path.read_text(encoding="utf-8"))
        for provider in data.get("providers", []):
            if provider.get("id") != provider_id:
                continue
            keys = provider.get("keys", [])
            provider["keys"] = [item for item in keys if item.get("key") != PENDING_KEY]
            if provider.get("key") == PENDING_KEY:
                active = next((item for item in provider["keys"] if not item.get("off")), None)
                if active is None:
                    raise RuntimeError("Credential import did not leave an active key.")
                provider["key"] = active["key"]
                provider["keys"].remove(active)
            if not provider.get("key") or provider.get("key") == PENDING_KEY:
                raise RuntimeError("Credential import did not leave a usable key.")
            if not provider["keys"]:
                provider.pop("keys", None)
            atomic_write(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
            return
        raise RuntimeError("Magpie did not create the requested provider.")

    def select_models(self, preferences):
        providers = provider_state()
        choices = {}
        for role in preferences["roles"].values():
            slug = role["model"]
            provider_id = connected_provider(slug, providers)
            if provider_id:
                choices.setdefault(provider_id, set()).add(slug.partition("/")[2])
        for provider_id, models in choices.items():
            available = set(providers[provider_id]["models"])
            if not models.issubset(available):
                self.run(["provider", "refresh", provider_id], timeout=120)
                available = set(provider_state().get(provider_id, {}).get("models", []))
            unknown = sorted(models - available)
            if unknown:
                raise RuntimeError(f"Magpie does not list these models for {provider_id}: {', '.join(unknown)}. Choose available IDs in the role panel or adjust this provider in Magpie.")
            self.run(["provider", "models", provider_id, *["+" + model for model in sorted(models)]], timeout=120)
        self.run(["sync"], timeout=120)

    def ensure_gateway(self):
        self.run(["autostart", "on"])
        if os.name == "nt":
            flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
            subprocess.Popen([self.executable], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, creationflags=flags, close_fds=True,
                             env=os.environ.copy() | magpie_environment())
            time.sleep(1)

    def connect_codex(self, home):
        config = read_config(home)
        try:
            model = tomllib.loads(config).get("model", "gpt-6.2-sol")
        except tomllib.TOMLDecodeError as error:
            raise RuntimeError("Codex config.toml must be valid before MYGO can update it.") from error
        if not isinstance(model, str) or not MODEL_PATTERN.fullmatch(model):
            raise RuntimeError("Codex's current lead model ID is invalid.")
        self.run(["codex", model], timeout=120, home=home)
        self.run(["codex", "subagent", ""], timeout=120, home=home)
        deadline = time.monotonic() + 30
        while not (home / "magpie-models.json").exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("Magpie did not write its Codex model catalog within 30 seconds.")
            time.sleep(0.5)
        return model


def install_magpie(destination, version=MAGPIE_VERSION):
    if os.name != "nt" or os.environ.get("PROCESSOR_ARCHITECTURE", "AMD64").upper() != "AMD64":
        raise RuntimeError("Automatic installation supports Windows x64. Install Magpie from https://usemagpie.ai/.")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        raise ValueError("Invalid Magpie version.")
    base = f"https://github.com/yetone/magpie-releases/releases/download/{version}"
    filename = "magpie-cli-windows-amd64.exe"
    with urlopen(Request(f"{base}/{filename}", headers={"User-Agent": "MYGO-Setup"}), timeout=180) as response:
        executable = response.read()
    with urlopen(Request(f"{base}/SHA256SUMS", headers={"User-Agent": "MYGO-Setup"}), timeout=30) as response:
        checksums = response.read().decode("ascii")
    expected = next((line.split()[0] for line in checksums.splitlines() if line.split()[-1].lstrip("*") == filename), None)
    if not expected or hashlib.sha256(executable).hexdigest() != expected:
        raise RuntimeError("Magpie checksum verification failed. No file was installed.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".download")
    temporary.write_bytes(executable)
    os.replace(temporary, destination)
    return str(destination)


def find_codex():
    if os.environ.get("MYGO_CODEX_EXECUTABLE"):
        return os.environ["MYGO_CODEX_EXECUTABLE"]
    if os.name == "nt":
        desktop_root = Path.home() / "AppData/Local/OpenAI/Codex/bin"
        bundled = list(desktop_root.glob("*/codex.exe"))
        if bundled:
            return str(max(bundled, key=lambda executable: executable.stat().st_mtime))
    return shutil.which("codex.exe") or shutil.which("codex")


def codex_capability_check(home):
    executable = find_codex()
    if not executable:
        raise RuntimeError("Codex CLI was not found. Install a compatible Codex Desktop or CLI release.")
    environment = os.environ.copy()
    environment["CODEX_HOME"] = str(home.resolve())
    result = subprocess.run([executable, "features", "list"], capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=45, env=environment)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()[-500:]
        raise RuntimeError(f"Codex rejected the generated V2 configuration. Use a compatible Desktop or CLI release. {detail}")
    return "codex features list passed"


class ConfigurationBackup:
    def __init__(self, home):
        self.home = home
        self.paths = [home / "config.toml", home / "magpie-models.json", home / "mygo-magpie-v2-models.json"]
        self.original = {path: path.read_bytes() if path.exists() else None for path in self.paths}
        self.directory = home / "backups" / "mygo" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        for path, content in self.original.items():
            if content is not None:
                self.directory.mkdir(parents=True, exist_ok=True)
                (self.directory / path.name).write_bytes(content)

    def restore(self):
        for path, content in self.original.items():
            if content is None:
                if path.exists():
                    path.unlink()
            else:
                temporary = path.with_suffix(".mygo-restore")
                temporary.write_bytes(content)
                os.replace(temporary, path)


def configure(home, magpie, apply=False):
    preferences = load_roles(home / "mygo" / "preferences.json")
    if not apply:
        return {"ready": True, "apply": False, "roles": preferences}
    magpie.require_supported_version()
    backup = ConfigurationBackup(home)
    providers_path = magpie_home() / "providers.json"
    providers_before = providers_path.read_bytes() if providers_path.exists() else None
    providers = provider_state()
    try:
        magpie.select_models(preferences)
        model = magpie.connect_codex(home)
        source_catalog = home / "magpie-models.json"
        catalog = json.loads(source_catalog.read_text(encoding="utf-8"))
        models = catalog.get("models")
        if not isinstance(models, list) or not models:
            raise RuntimeError("Magpie's model catalog is empty or invalid.")
        by_slug = {item.get("slug"): item for item in models if isinstance(item, dict)}
        lead = by_slug.get(model)
        if not lead or lead.get("multi_agent_version") != "v2":
            raise RuntimeError(f"The lead model {model} has no V2 entry. Select a V2-compatible lead in Codex and retry.")
        lead["multi_agent_tools_in_code_mode"] = True
        required = {
            role["model"] for role in preferences["roles"].values()
            if connected_provider(role["model"], providers)
        }
        missing = sorted(required - set(by_slug))
        if missing:
            raise RuntimeError("These role models are not in Magpie's catalog: " + ", ".join(missing))
        for slug in sorted(required):
            if by_slug[slug].get("multi_agent_version") != "v2":
                raise RuntimeError(f"The role model {slug} has no V2 catalog entry.")
        destination = home / "mygo-magpie-v2-models.json"
        catalog_text = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
        updated = read_config(home)
        for section, key, value in [
            ("", "model_catalog_json", str(destination.resolve())),
            ("features", "code_mode", True),
            ("features", "code_mode_host_grpc", True),
            ("features.multi_agent_v2", "enabled", True),
            ("features.multi_agent_v2", "non_code_mode_only", False),
            ("features.multi_agent_v2", "expose_spawn_agent_model_overrides", True),
            ("features.multi_agent_v2", "wait_agent_enabled", True),
        ]:
            updated = set_toml_key(updated, section, key, value)
        tomllib.loads(updated)
        atomic_write(destination, catalog_text)
        atomic_write(home / "config.toml", updated)
        capability = codex_capability_check(home)
    except Exception:
        backup.restore()
        if providers_before is None:
            if providers_path.exists():
                providers_path.unlink()
        else:
            temporary = providers_path.with_suffix(".mygo-restore")
            temporary.write_bytes(providers_before)
            os.replace(temporary, providers_path)
        raise
    return {
        "lead_model": model, "catalog": str(destination), "restart_required": True,
        "apply": True, "backup": str(backup.directory), "capability_check": capability,
    }


def status(home, magpie=None):
    config = read_config(home)
    catalog = home / "mygo-magpie-v2-models.json"
    models = catalog_models(catalog)
    providers = provider_state()
    roles = load_roles(home / "mygo" / "preferences.json")
    try:
        settings = tomllib.loads(config)
    except tomllib.TOMLDecodeError:
        settings = {}
    configured_path = settings.get("model_catalog_json")
    features = settings.get("features")
    v2 = features.get("multi_agent_v2") if isinstance(features, dict) else None
    uses_catalog = isinstance(configured_path, str) and (home / configured_path) == catalog
    v2_enabled = v2 is True or (isinstance(v2, dict) and v2.get("enabled") is True)
    executable = magpie.executable if magpie else find_magpie()
    version = None
    if executable:
        try:
            version = ".".join(map(str, Magpie(executable, timeout=5).version()))
        except (RuntimeError, OSError, subprocess.SubprocessError):
            pass
    return {
        "credentials": credential_status(providers),
        "magpie_installed": bool(executable),
        "magpie_version": version,
        "magpie_compatible": bool(version and tuple(map(int, version.split("."))) >= MINIMUM_MAGPIE),
        "v2_configured": uses_catalog and v2_enabled,
        "code_mode": bool(re.search(r"(?m)^code_mode\s*=\s*true\s*$", config)),
        "model_catalog": catalog.exists(),
        "roles": roles,
        "model_choices": role_model_choices(home, roles, providers, models),
        "available_models": list(models),
        "missing_models": sorted({
            role["model"] for role in roles["roles"].values()
            if connected_provider(role["model"], providers) and role["model"] not in models
        }),
    }
