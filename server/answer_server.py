#!/usr/bin/env python3
"""Dependency-free HTTPS answer server for Proxmox automated installs."""
from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

PLACEHOLDERS = ("CHANGE_ME", "example.com", "192.0.2.", "AAAATEST")


class InventoryError(ValueError):
    pass


def validate_auth_token(token: str) -> str:
    if not isinstance(token, str) or token.count(":") != 1:
        raise InventoryError("ANSWER_TOKEN must use the name:secret format")
    name, secret = token.split(":", 1)
    if (
        not re.fullmatch(r"[A-Za-z0-9_.-]+", name)
        or len(secret) < 24
        or len(set(secret)) < 10
        or "CHANGE_ME" in secret
    ):
        raise InventoryError("ANSWER_TOKEN requires a valid name and a high-entropy secret of at least 24 characters")
    return token


def _toml_string(value: str) -> str:
    return json.dumps(value)


def _required(obj: dict[str, Any], key: str) -> Any:
    value = obj.get(key)
    if value in (None, "", []):
        raise InventoryError(f"missing required field: {key}")
    return value


def _validate_storage(host: dict[str, Any]) -> None:
    name = host["name"]
    disks = host["disks"]
    if not isinstance(disks, list) or not disks or not all(isinstance(d, str) for d in disks):
        raise InventoryError(f"{name}: disks must be a non-empty list of device names")
    if len(set(disks)) != len(disks):
        raise InventoryError(f"{name}: disks must not contain duplicates")
    device_pattern = re.compile(r"(?:sd|vd|xvd)[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+")
    if not all(device_pattern.fullmatch(d) for d in disks):
        raise InventoryError(f"{name}: invalid disk name; use installer-visible names such as sda or nvme0n1")

    filesystem = host["filesystem"]
    if filesystem not in ("ext4", "xfs", "zfs", "btrfs"):
        raise InventoryError(f"{name}: unsupported filesystem {filesystem!r}")
    if filesystem == "btrfs" and host["product"] != "pve":
        raise InventoryError(f"{name}: btrfs is supported only for PVE")
    if filesystem in ("ext4", "xfs"):
        if len(disks) != 1 or host.get("raid") is not None:
            raise InventoryError(f"{name}: {filesystem} requires exactly one installer disk and no raid key")
        lvm = host.get("lvm")
        if lvm is not None:
            allowed = {"hdsize", "swapsize", "maxroot", "maxvz", "minfree"}
            if not isinstance(lvm, dict) or not set(lvm).issubset(allowed):
                raise InventoryError(f"{name}: invalid lvm options")
            if not all(isinstance(v, (int, float)) and v >= 0 for v in lvm.values()):
                raise InventoryError(f"{name}: lvm values must be non-negative numbers")
        return

    raid = host.get("raid")
    allowed_raids = {
        "zfs": {"raid0", "raid1", "raid10", "raidz-1", "raidz-2", "raidz-3"},
        "btrfs": {"raid0", "raid1", "raid10"},
    }[filesystem]
    if raid not in allowed_raids:
        raise InventoryError(f"{name}: invalid {filesystem} raid level {raid!r}")
    count = len(disks)
    minimum = {"raid0": 1, "raid1": 2, "raid10": 4, "raidz-1": 3, "raidz-2": 4, "raidz-3": 5}[raid]
    if count < minimum or (raid == "raid10" and count % 2):
        raise InventoryError(f"{name}: raid level {raid} is incompatible with {count} disks")


def load_inventory(path: str | Path) -> dict[str, Any]:
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise InventoryError(f"cannot read inventory: {exc}") from exc
    defaults = _required(data, "defaults")
    hosts = _required(data, "hosts")
    if not isinstance(hosts, list) or not hosts:
        raise InventoryError("hosts must be a non-empty list")
    serials: set[str] = set()
    names: set[str] = set()
    management_macs: set[str] = set()
    for host in hosts:
        for key in ("name", "product", "serial", "fqdn", "management_mac", "cidr", "disks", "filesystem"):
            _required(host, key)
        if host["product"] not in ("pve", "pbs"):
            raise InventoryError(f"{host['name']}: product must be pve or pbs")
        flattened = json.dumps(host)
        bad = next((marker for marker in PLACEHOLDERS if marker in flattened), None)
        if bad:
            raise InventoryError(f"{host['name']}: unresolved placeholder {bad}")
        serial = host["serial"].strip().lower()
        name = host["name"].strip().lower()
        management_mac = host["management_mac"].strip().lower()
        if serial in serials or name in names or management_mac in management_macs:
            raise InventoryError(f"duplicate host name, serial, or management MAC: {host['name']}")
        serials.add(serial)
        names.add(name)
        management_macs.add(management_mac)
        if not re.fullmatch(r"[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}", host["management_mac"]):
            raise InventoryError(f"{host['name']}: invalid management_mac")
        _validate_storage(host)
    for key in ("keyboard", "country", "timezone", "mailto", "dns", "gateway", "ssh_keys"):
        _required(defaults, key)
    defaults_flattened = json.dumps(defaults)
    bad = next((marker for marker in PLACEHOLDERS if marker in defaults_flattened), None)
    if bad:
        raise InventoryError(f"defaults: unresolved placeholder {bad}")
    return data


def find_host(inventory: dict[str, Any], system_info: dict[str, Any]) -> dict[str, Any]:
    product_data = system_info.get("product", "")
    product = str(product_data.get("product", "") if isinstance(product_data, dict) else product_data).lower()
    dmi = system_info.get("dmi", {})
    system = dmi.get("system", {}) if isinstance(dmi, dict) else {}
    if not system:
        system = system_info.get("system", {})
    serial = str(system.get("serial", "")).strip().lower()
    macs = {str(m).lower() for m in system_info.get("mac_addresses", [])}
    macs.update(str(n.get("mac", "")).lower() for n in system_info.get("network_interfaces", []) if isinstance(n, dict))
    macs.discard("")
    candidates = [h for h in inventory["hosts"] if str(h["product"]).lower() == product]
    serial_host = next((h for h in candidates if serial and str(h["serial"]).strip().lower() == serial), None)
    mac_host = next((h for h in candidates if str(h["management_mac"]).lower() in macs), None)
    if serial_host and mac_host and serial_host is not mac_host:
        raise InventoryError("serial and management MAC identify different inventory hosts")
    if serial_host or mac_host:
        return serial_host or mac_host
    raise InventoryError(f"no {product or 'unknown-product'} host matches serial={serial!r} or supplied MACs")


def build_answer(inventory: dict[str, Any], host: dict[str, Any], password_hash: str) -> str:
    if not re.fullmatch(r"\$6\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}", password_hash):
        raise InventoryError("ROOT_PASSWORD_HASH must be a complete SHA-512 crypt hash from mkpasswd -m sha-512")
    d = inventory["defaults"]
    keys = ", ".join(_toml_string(k) for k in d["ssh_keys"])
    disks = ", ".join(_toml_string(x) for x in host["disks"])
    mac = host["management_mac"].lower()
    mac_filter = "*" + mac.replace(":", "")
    lines = [
        "[global]",
        f"keyboard = {_toml_string(d['keyboard'])}",
        f"country = {_toml_string(d['country'])}",
        f"fqdn = {_toml_string(host['fqdn'])}",
        f"mailto = {_toml_string(d['mailto'])}",
        f"timezone = {_toml_string(d['timezone'])}",
        f"root-password-hashed = {_toml_string(password_hash)}",
        f"root-ssh-keys = [{keys}]",
        'reboot-mode = "reboot"',
        "",
        "[network]",
        'source = "from-answer"',
        f"cidr = {_toml_string(host['cidr'])}",
        f"dns = {_toml_string(host.get('dns', d['dns']))}",
        f"gateway = {_toml_string(host.get('gateway', d['gateway']))}",
        f"filter.ID_NET_NAME_MAC = {_toml_string(mac_filter)}",
        "",
        "[disk-setup]",
        f"filesystem = {_toml_string(host['filesystem'])}",
        f"disk-list = [{disks}]",
    ]
    if host["filesystem"] == "zfs":
        lines.extend(["", "[disk-setup.zfs]", f"raid = {_toml_string(_required(host, 'raid'))}"])
    elif host["filesystem"] == "btrfs":
        lines.extend(["", "[disk-setup.btrfs]", f"raid = {_toml_string(_required(host, 'raid'))}"])
    elif host["filesystem"] in ("ext4", "xfs") and host.get("lvm"):
        lines.append("")
        lines.append("[disk-setup.lvm]")
        for key, value in host["lvm"].items():
            lines.append(f"{key} = {value}")
    lines.extend(["", "[first-boot]", 'source = "from-iso"', 'ordering = "fully-up"'])
    return "\n".join(lines) + "\n"


class AnswerHandler(BaseHTTPRequestHandler):
    inventory: dict[str, Any]
    password_hash: str
    auth_token: str

    def _reply(self, status: int, body: str, content_type: str = "text/plain; charset=utf-8") -> None:
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._reply(200, "ok\n")
        else:
            self._reply(404, "not found\n")

    def do_POST(self) -> None:
        if self.path != "/answer":
            self._reply(404, "not found\n")
            return
        expected = f"Bearer {self.auth_token}"
        if self.auth_token and not hmac.compare_digest(self.headers.get("Authorization", ""), expected):
            self._reply(401, "unauthorized\n")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 1_000_000:
                raise InventoryError("invalid request size")
            info = json.loads(self.rfile.read(length))
            host = find_host(self.inventory, info)
            answer = build_answer(self.inventory, host, self.password_hash)
        except (json.JSONDecodeError, InventoryError, ValueError) as exc:
            print(f"request rejected from {self.client_address[0]}: {exc}", file=sys.stderr)
            self._reply(400, f"request rejected: {exc}\n")
            return
        print(f"served {host['product']} answer for {host['name']} to {self.client_address[0]}")
        self._reply(200, answer, "application/toml; charset=utf-8")

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.client_address[0]} - {fmt % args}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", default="inventory.json")
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--tls-cert", required=True)
    parser.add_argument("--tls-key", required=True)
    args = parser.parse_args()
    try:
        inventory = load_inventory(args.inventory)
        password_hash = os.environ["ROOT_PASSWORD_HASH"]
        auth_token = validate_auth_token(os.environ["ANSWER_TOKEN"])
        build_answer(inventory, inventory["hosts"][0], password_hash)
    except (InventoryError, KeyError) as exc:
        print(f"fatal: {exc}", file=sys.stderr)
        return 2
    AnswerHandler.inventory = inventory
    AnswerHandler.password_hash = password_hash
    AnswerHandler.auth_token = auth_token
    server = ThreadingHTTPServer((args.listen, args.port), AnswerHandler)
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    except (OSError, ssl.SSLError) as exc:
        print(f"fatal: cannot configure TLS: {exc}", file=sys.stderr)
        server.server_close()
        return 2
    print(f"answer server listening on https://{args.listen}:{args.port}/answer")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
