"""Exercise UPS policy with fake commands; never invoke real host shutdown."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class NutPolicyTests(unittest.TestCase):
    def run_case(self, a, b, expected, dry=False, delay=0, comm=0, stagger=0):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "policy.conf"
            config.write_text(f"UPS_A=a\nUPS_B=b\nDELAY={delay}\nCOMM_DELAY={comm}\nPOLL=1\nSTAGGER={stagger}\n")
            script = (ROOT / "power/nut/nut-policy.sh").read_text()
            script = script.replace("CONFIG=/etc/nut/policy.conf", f'CONFIG="{config}"')
            script = script.replace("/sbin/shutdown", str(root / "shutdown"))
            (root / "policy.sh").write_text(script)
            for name, text in {
                "upsc": '#!/bin/bash\nif [[ "$1" == a ]]; then printf "%s" "$STATUS_A"; else printf "%s" "$STATUS_B"; fi\n',
                "logger": "#!/bin/bash\nexit 0\n",
                "shutdown": '#!/bin/bash\nprintf "%s" called > "$MARKER"\n',
            }.items():
                path = root / name
                path.write_text(text)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + ":" + os.environ["PATH"],
                       STATUS_A=a, STATUS_B=b, MARKER=str(root / "called"))
            proc = subprocess.Popen(["bash", str(root / "policy.sh")] +
                                    (["--dry-run"] if dry else []),
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                out, err = proc.communicate(timeout=0.5 if not expected and not dry else 3)
                self.assertEqual(proc.returncode, 0, err.decode())
            except subprocess.TimeoutExpired:
                proc.kill()
                out, err = proc.communicate()
                self.assertFalse(expected)
            self.assertEqual((root / "called").exists(), expected)
            if dry:
                self.assertIn(b"dry-run: no shutdown", out)

    def test_mains_and_single_feed_loss(self):
        for a, b in [("OL", "OL"), ("OB", "OL"), ("OL", "OB LB"), ("UNKNOWN", "OL")]:
            with self.subTest(a=a, b=b):
                self.run_case(a, b, False)

    def test_outage_and_critical(self):
        for a, b in [("OB", "OB"), ("OB LB", "OB"), ("FSD", "FSD"),
                     ("UNKNOWN", "UNKNOWN"), ("OFF", "OB")]:
            with self.subTest(a=a, b=b):
                self.run_case(a, b, True)

    def test_low_battery_bypasses_delay_and_stagger(self):
        self.run_case("OB", "OB LB", True, delay=240, stagger=60)

    def test_grace_windows(self):
        self.run_case("OB", "OB", False, delay=240)
        self.run_case("UNKNOWN", "OB", False, comm=60)

    def test_dry_run_never_shuts_down(self):
        self.run_case("OB LB", "OB", False, dry=True)

if __name__ == "__main__":
    unittest.main()
