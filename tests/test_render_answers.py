import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class RenderAnswersTests(unittest.TestCase):
    def test_renders_one_valid_answer_per_host(self):
        inventory = {
            "defaults": {
                "keyboard": "en-us", "country": "us", "timezone": "America/New_York",
                "mailto": "admin@lab.local", "dns": "10.0.0.53", "gateway": "10.0.0.1",
                "ssh_keys": ["ssh-ed25519 AAAAValidTestKey admin@lab.local"]
            },
            "hosts": [{
                "name": "pve01", "product": "pve", "serial": "DELL001",
                "fqdn": "pve01.lab.local", "management_mac": "aa:bb:cc:dd:ee:01",
                "cidr": "10.0.0.11/24", "filesystem": "zfs", "raid": "raid1",
                "disks": ["sda", "sdb"]
            }]
        }
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            inv = td_path / "inventory.json"
            out = td_path / "answers"
            inv.write_text(json.dumps(inventory))
            env = dict(os.environ, ROOT_PASSWORD_HASH="$6$testsalt$" + "A" * 86)
            result = subprocess.run(
                ["python3", str(ROOT / "scripts" / "render_answers.py"), str(inv), str(out)],
                text=True, capture_output=True, env=env
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            answer = (out / "pve01.toml").read_text()
            self.assertIn('fqdn = "pve01.lab.local"', answer)
            self.assertIn('[first-boot]', answer)


if __name__ == "__main__":
    unittest.main()
