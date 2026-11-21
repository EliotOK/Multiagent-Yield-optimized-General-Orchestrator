"""Read the active role preferences for the MYGO skill."""

import argparse
import json
import os
from pathlib import Path

from mygo_setup import load_roles


def main():
    parser = argparse.ArgumentParser(description="Read MYGO's secret-free role preferences")
    parser.add_argument("--codex-home", default=os.environ.get("CODEX_HOME"))
    parser.add_argument("--role")
    args = parser.parse_args()
    home = Path(args.codex_home).expanduser() if args.codex_home else Path.home() / ".codex"
    roles = load_roles(home / "mygo" / "preferences.json")
    if args.role:
        print(json.dumps(roles["roles"][args.role], ensure_ascii=False))
    else:
        print(json.dumps(roles, ensure_ascii=False))


if __name__ == "__main__":
    main()
