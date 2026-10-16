"""Regression checks for the Hermes OAuth subprocess's desktop isolation.

Run with: python3 -m unittest discover -s scripts/tests -p 'test_keycloak*.py'
No services, credentials, browser windows, or active Hermes config are touched.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class BrowserIsolationTest(unittest.TestCase):
    def test_login_subprocess_cannot_use_desktop_display(self):
        script = Path(__file__).resolve().parents[1] / "KEYCLOAK/keycloak_runbook.sh"
        launch = next(line.strip().split(" <&9", 1)[0]
                      for line in script.read_text().splitlines()
                      if 'hermes mcp login "$mcp_name" <&9' in line)
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
            fake = Path(tmp) / "hermes"
            fake.write_text(
                f"#!{sys.executable}\n"
                "import json, os\n"
                "print(json.dumps({k: os.environ.get(k) for k in "
                "('DISPLAY', 'WAYLAND_DISPLAY', 'BROWSER', 'HERMES_HOME')}))\n"
            )
            fake.chmod(0o700)
            env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"],
                       DISPLAY=":99", WAYLAND_DISPLAY="wayland-regression")
            result = subprocess.run(
                ["bash", "-c", 'isolated_home="$1"; mcp_name=camera; ' + launch,
                 "test", tmp], env=env, capture_output=True, text=True, check=True,
            )
            actual = json.loads(result.stdout)
            self.assertIsNone(actual["DISPLAY"], "X11 permits desktop browser fallback")
            self.assertIsNone(actual["WAYLAND_DISPLAY"], "Wayland permits desktop browser fallback")
            self.assertEqual(actual["BROWSER"], "/bin/false")
            self.assertEqual(actual["HERMES_HOME"], tmp)


if __name__ == "__main__":
    unittest.main()
