import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ValidateInventoryCliTests(unittest.TestCase):
    def test_example_inventory_fails_safe_until_customized(self):
        result = subprocess.run(
            ["python3", str(ROOT / "scripts" / "validate_inventory.py"), str(ROOT / "inventory.example.json")],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CHANGE_ME", result.stderr)


if __name__ == "__main__":
    unittest.main()
