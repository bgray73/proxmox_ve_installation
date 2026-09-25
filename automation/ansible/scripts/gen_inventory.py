#!/usr/bin/env python3
"""Generate an Ansible inventory (JSON) from the deploy-kit's inventory.json.

Ansible reads JSON inventories natively, so this emits JSON and needs no
extra dependencies.

Usage:
    python3 scripts/gen_inventory.py > inventory.json
    ansible-playbook -i inventory.json playbooks/harden.yml
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[3]
    src = root / "inventory.json"
    try:
        data = json.loads(src.read_text())
    except OSError as exc:
        print(f"cannot read {src}: {exc}", file=sys.stderr)
        print("copy inventory.example.json to inventory.json first", file=sys.stderr)
        return 1
    except json.JSONDecodeError as exc:
        print(f"invalid JSON in {src}: {exc}", file=sys.stderr)
        return 1

    groups: dict[str, dict] = {}
    for host in data.get("hosts", []):
        product = str(host.get("product", "")).lower()
        if product == "pve":
            group = "proxmox_ve"
        elif product == "pbs":
            group = "proxmox_bs"
        else:
            print(f"warning: skipping host with unknown product: {host.get('name')}", file=sys.stderr)
            continue
        ip = str(host.get("cidr", "")).split("/")[0]
        if not ip:
            print(f"warning: host {host.get('name')} has no usable cidr; skipped", file=sys.stderr)
            continue
        groups.setdefault(group, {"hosts": {}})["hosts"][host["name"]] = {
            "ansible_host": ip,
            "inventory_fqdn": host.get("fqdn", ""),
        }

    inventory = {"all": {"children": groups}}
    print(json.dumps(inventory, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
