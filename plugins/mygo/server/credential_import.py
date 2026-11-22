"""Run inside a user-launched local password window, never as an MCP tool."""

import argparse
from getpass import getpass
import sys

from mygo_setup import Magpie, PROVIDERS, environment_key


def main():
    parser = argparse.ArgumentParser(description="MYGO local Magpie credential import")
    parser.add_argument("--provider", required=True)
    parser.add_argument("--source", choices=("environment", "prompt"), required=True)
    parser.add_argument("--plan", choices=("coding", "api"), default="coding")
    parser.add_argument("--magpie", required=True)
    args = parser.parse_args()
    provider = PROVIDERS.get(args.provider)
    label = provider["label"] if provider else args.provider
    try:
        if args.source == "environment":
            if provider is None:
                raise ValueError("Use the password window to enter a key for this preset.")
            secret = environment_key(provider["env"])
            if not secret:
                raise RuntimeError(f"{provider['env']} is unavailable in this user's environment.")
        else:
            print(f"MYGO credential import for {label}", flush=True)
            print("Input is hidden. The value goes directly to local Magpie through stdin.", flush=True)
            secret = getpass("API key: ")
            if secret != getpass("Confirm API key: "):
                raise RuntimeError("The two entries did not match. No key was saved.")
        result = Magpie(args.magpie).save_credential(args.provider, secret, args.plan)
        if result.get("saved"):
            print(f"{label} was added to Magpie. You can close this window.", flush=True)
            if result.get("refresh_failed"):
                print("Refresh this provider's model list in Magpie, then refresh MYGO.", flush=True)
        else:
            print(f"{label} is already configured in Magpie.", flush=True)
    except Exception as error:
        print("Import failed. " + str(error)[:800], flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
