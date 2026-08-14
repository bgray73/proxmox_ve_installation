#!/usr/bin/env python3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
from answer_server import InventoryError, load_inventory


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "inventory.json")
    try:
        data = load_inventory(path)
    except InventoryError as exc:
        print(f"INVALID: {exc}", file=sys.stderr)
        return 1
    pve = sum(h["product"] == "pve" for h in data["hosts"])
    pbs = sum(h["product"] == "pbs" for h in data["hosts"])
    print(f"VALID: {len(data['hosts'])} hosts ({pve} PVE, {pbs} PBS)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
