import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from answer_server import InventoryError, build_answer, find_host, load_inventory, validate_auth_token

TEST_HASH = "$6$testsalt$" + "A" * 86


class AnswerServerTests(unittest.TestCase):
    def setUp(self):
        self.inventory = {
            "defaults": {
                "keyboard": "en-us",
                "country": "us",
                "timezone": "America/New_York",
                "mailto": "admin@lab.local",
                "dns": "10.0.0.53",
                "gateway": "10.0.0.1",
                "ssh_keys": ["ssh-ed25519 AAAAValidTestKey admin@lab.local"],
            },
            "hosts": [
                {
                    "name": "pve01",
                    "product": "pve",
                    "serial": "DELL001",
                    "fqdn": "pve01.lab.local",
                    "management_mac": "AA:BB:CC:DD:EE:01",
                    "cidr": "10.0.0.11/24",
                    "disks": ["sda", "sdb"],
                    "filesystem": "zfs",
                    "raid": "raid1",
                }
            ],
        }

    def test_find_host_matches_serial_case_insensitively(self):
        host = find_host(self.inventory, {"product": "pve", "system": {"serial": "dell001"}})
        self.assertEqual(host["name"], "pve01")

    def test_find_host_matches_current_proxmox_post_schema(self):
        info = {
            "product": {"fullname": "Proxmox VE", "product": "pve", "enable_btrfs": True},
            "dmi": {"system": {"serial": "DELL001"}},
            "network_interfaces": [{"mac": "aa:bb:cc:dd:ee:01", "name": "eno1"}],
        }
        self.assertEqual(find_host(self.inventory, info)["name"], "pve01")

    def test_find_host_falls_back_to_mac(self):
        host = find_host(self.inventory, {"product": "pve", "system": {"serial": "unknown"}, "mac_addresses": ["aa:bb:cc:dd:ee:01"]})
        self.assertEqual(host["name"], "pve01")

    def test_find_host_rejects_serial_mac_conflict(self):
        other = dict(self.inventory["hosts"][0])
        other.update(name="pve02", serial="DELL002", fqdn="pve02.lab.local", management_mac="AA:BB:CC:DD:EE:02", cidr="10.0.0.12/24")
        self.inventory["hosts"].append(other)
        with self.assertRaises(InventoryError):
            find_host(self.inventory, {"product": "pve", "system": {"serial": "DELL001"}, "mac_addresses": ["aa:bb:cc:dd:ee:02"]})

    def test_product_mismatch_is_rejected(self):
        with self.assertRaises(InventoryError):
            find_host(self.inventory, {"product": "pbs", "system": {"serial": "DELL001"}})

    def test_answer_contains_static_network_zfs_and_hash(self):
        answer = build_answer(self.inventory, self.inventory["hosts"][0], TEST_HASH)
        self.assertIn('fqdn = "pve01.lab.local"', answer)
        self.assertIn(f'root-password-hashed = "{TEST_HASH}"', answer)
        self.assertIn('source = "from-answer"', answer)
        self.assertIn('cidr = "10.0.0.11/24"', answer)
        self.assertIn('filter.ID_NET_NAME_MAC = "*aabbccddee01"', answer)
        self.assertIn('filesystem = "zfs"', answer)
        self.assertIn('raid = "raid1"', answer)
        self.assertIn('disk-list = ["sda", "sdb"]', answer)

    def test_answer_enables_iso_first_boot_hook(self):
        answer = build_answer(self.inventory, self.inventory["hosts"][0], TEST_HASH)
        self.assertIn('[first-boot]', answer)
        self.assertIn('source = "from-iso"', answer)
        self.assertIn('ordering = "fully-up"', answer)

    def test_placeholders_are_rejected(self):
        self.inventory["hosts"][0]["serial"] = "CHANGE_ME"
        with self.assertRaises(InventoryError):
            load_inventory_data(self.inventory)

    def test_default_placeholders_are_rejected(self):
        self.inventory["defaults"]["mailto"] = "CHANGE_ME@lab.local"
        with self.assertRaises(InventoryError):
            load_inventory_data(self.inventory)

    def test_duplicate_management_macs_are_rejected(self):
        other = dict(self.inventory["hosts"][0])
        other.update(name="pve02", serial="DELL002", fqdn="pve02.lab.local", cidr="10.0.0.12/24")
        self.inventory["hosts"].append(other)
        with self.assertRaises(InventoryError):
            load_inventory_data(self.inventory)

    def test_disks_must_be_a_unique_list_of_device_names(self):
        for bad in ("sda", ["sda", "sda"], ["../../dev/sda", "sdb"]):
            with self.subTest(disks=bad):
                self.inventory["hosts"][0]["disks"] = bad
                with self.assertRaises(InventoryError):
                    load_inventory_data(self.inventory)

    def test_filesystem_and_raid_are_validated(self):
        host = self.inventory["hosts"][0]
        host["filesystem"] = "made-up"
        with self.assertRaises(InventoryError):
            load_inventory_data(self.inventory)
        host["filesystem"] = "zfs"
        host["raid"] = "raid10"
        with self.assertRaises(InventoryError):
            load_inventory_data(self.inventory)

    def test_btrfs_is_rejected_for_pbs(self):
        host = self.inventory["hosts"][0]
        host.update(product="pbs", filesystem="btrfs", raid="raid1")
        with self.assertRaises(InventoryError):
            load_inventory_data(self.inventory)

    def test_pve_btrfs_answer_contains_btrfs_raid_section(self):
        host = self.inventory["hosts"][0]
        host.update(filesystem="btrfs", raid="raid1")
        answer = build_answer(self.inventory, host, TEST_HASH)
        self.assertIn("[disk-setup.btrfs]", answer)
        self.assertIn('raid = "raid1"', answer)

    def test_auth_token_requires_nonempty_name_and_secret(self):
        for bad in ("", "no-colon", ":secret", "name:", "name:short", "installer:CHANGE_ME_RANDOM_SECRET", "installer:00000000000000000000000000000000"):
            with self.subTest(token=bad):
                with self.assertRaises(InventoryError):
                    validate_auth_token(bad)
        strong = "installer:0123456789abcdefABCDEFxy"
        self.assertEqual(validate_auth_token(strong), strong)

    def test_malformed_password_hash_is_rejected(self):
        for bad in ("$6$hash", "$6$salt$short", "plain-text"):
            with self.assertRaises(InventoryError):
                build_answer(self.inventory, self.inventory["hosts"][0], bad)


def load_inventory_data(data):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as tmp:
        json.dump(data, tmp)
        path = Path(tmp.name)
    try:
        return load_inventory(path)
    finally:
        path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
