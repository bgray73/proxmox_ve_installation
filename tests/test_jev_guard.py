import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("jev_guard", ROOT / "automation" / "jev" / "guard.py")
jev_guard = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(jev_guard)


class JevGuardTests(unittest.TestCase):
    def test_redacts_credentials_and_site_identifiers(self):
        source = """TOKEN=super-secret
Authorization: Bearer abc.def.ghi
node=10.20.30.40/24 mac=aa:bb:cc:dd:ee:ff
admin@example.com
serial: ABC1234
-----BEGIN OPENSSH PRIVATE KEY-----
secret material
-----END OPENSSH PRIVATE KEY-----
"""
        result = jev_guard.redact(source)
        for secret in ("super-secret", "abc.def.ghi", "10.20.30.40", "aa:bb:cc:dd:ee:ff", "admin@example.com", "ABC1234", "secret material"):
            self.assertNotIn(secret, result)

    def test_limits_diff_size(self):
        result = jev_guard.redact("x" * (jev_guard.MAX_DIFF_CHARS + 100))
        self.assertTrue(result.endswith("<DIFF_TRUNCATED>"))

    def test_report_recommends_review_at_threshold(self):
        result = {
            "answers": {
                "change_type": {"choice": "infrastructure", "confidence": 0.8},
                "operational_risk": {"score": 2.3, "confidence": 0.7},
                "manual_review": {"noul": 0.8},
                "storage_risk": {"noul": 0.7},
                "network_risk": {"noul": 0.2},
                "secret_exposure": {"noul": 0.1},
            }
        }
        report = jev_guard.build_report(result)
        self.assertIn("Manual review recommended", report)
        self.assertIn("2.30/4", report)
        self.assertIn("storage or backup behavior", report)

    def test_report_is_advisory_when_below_thresholds(self):
        result = {
            "answers": {
                "change_type": {"choice": "documentation_only", "confidence": 1.0},
                "operational_risk": {"score": 0.0, "confidence": 1.0},
                "manual_review": {"noul": 0.1},
                "storage_risk": {"noul": 0.1},
                "network_risk": {"noul": 0.1},
                "secret_exposure": {"noul": 0.0},
            }
        }
        report = jev_guard.build_report(result)
        self.assertIn("No elevated risk detected", report)
        self.assertIn("cannot merge", report)


if __name__ == "__main__":
    unittest.main()
