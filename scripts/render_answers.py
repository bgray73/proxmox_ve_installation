#!/usr/bin/env python3
"""Render every inventory host's answer for offline Proxmox validation."""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
from answer_server import InventoryError, build_answer, load_inventory


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} INVENTORY OUTPUT_DIR", file=sys.stderr)
        return 2
    try:
        inventory = load_inventory(sys.argv[1])
        password_hash = os.environ["ROOT_PASSWORD_HASH"]
        output = Path(sys.argv[2])
        output.mkdir(parents=True, exist_ok=True)
        for host in inventory["hosts"]:
            path = output / f"{host['name']}.toml"
            path.write_text(build_answer(inventory, host, password_hash))
            path.chmod(0o600)
            print(path)
    except (InventoryError, KeyError, OSError) as exc:
        print(f"fatal: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
