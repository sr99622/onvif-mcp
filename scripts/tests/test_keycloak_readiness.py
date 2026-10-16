"""Exercise the real shell workflow with simulated service startup responses."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "KEYCLOAK/keycloak_runbook.sh"


class ReadinessTest(unittest.TestCase):
    def run_workflow(self, always_fail=False):
        text = SCRIPT.read_text()
        functions = "\n".join(re.findall(r"^\w+\(\) \{\n.*?^\}", text, re.M | re.S))
        harness = r'''
set -euo pipefail
server_fqdn=example.invalid
realm=mcp
issuer() { printf 'https://example.invalid/auth/realms/mcp'; }
resource_url() { printf 'https://example.invalid/mcp'; }
sudo() { if [[ "$1" == tee ]]; then cat >/dev/null; fi; }
systemctl() { printf 'active\n'; }
sleep() { :; }
curl() {
  local args="$*" count=0
  if [[ "$args" == *http://127.0.0.1:8001/mcp* ]]; then
    [[ ! -e "$TEST_STATE/count" ]] || read -r count < "$TEST_STATE/count"
    count=$((count + 1))
    printf '%s\n' "$count" > "$TEST_STATE/count"
    if [[ "$ALWAYS_FAIL" == 1 || "$count" == 1 ]]; then
      printf '000'
      printf 'curl: (7) Connection refused\n' >&2
      return 7
    fi
    printf '401'
  elif [[ "$args" == *oauth-protected-resource* ]]; then
    printf '{}'
  else
    [[ -e "$TEST_STATE/count" ]] || { printf 'PUBLIC_BEFORE_LOCAL\n' >&2; return 90; }
    printf 'HTTP/1.1 401 Unauthorized\r\nwww-authenticate: Bearer resource_metadata="https://example.invalid/.well-known/oauth-protected-resource/mcp"\r\n\r\n'
  fi
}
configure_mcp_oauth
'''
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
            return subprocess.run(["bash", "-c", functions + "\n" + harness],
                                  env=dict(os.environ, TEST_STATE=tmp,
                                           ALWAYS_FAIL=str(int(always_fail))),
                                  capture_output=True, text=True, timeout=10)

    def test_transient_refusal_is_quiet_and_public_probe_waits(self):
        result = self.run_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Connection refused", result.stderr)
        self.assertIn("mcp-ready HTTP 401", result.stdout)

    def test_timeout_reports_last_error_without_public_probe(self):
        result = self.run_workflow(always_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MCP did not become ready", result.stderr)
        self.assertIn("Connection refused", result.stderr)
        self.assertNotIn("PUBLIC_BEFORE_LOCAL", result.stderr)
        self.assertNotIn("HTTP/1.1 401", result.stdout)


if __name__ == "__main__":
    unittest.main()
