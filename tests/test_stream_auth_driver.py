"""Offline safety regressions for the runbook's HTTP login verifier."""
import importlib.util
from pathlib import Path
import ssl
import unittest
from http.cookiejar import CookieJar
from urllib.request import HTTPSHandler

spec = importlib.util.spec_from_file_location(
    'stream_auth_driver', Path(__file__).resolve().parents[1] / 'scripts/stream_auth_step9_driver.py')
assert spec is not None and spec.loader is not None
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class DriverSafetyTests(unittest.TestCase):
    def test_origin_required_before_reading_password(self):
        import contextlib
        import io
        from unittest.mock import patch
        with patch('sys.argv', ['stream_auth_step9_driver.py']), \
                patch.object(driver.subprocess, 'run', side_effect=AssertionError('secret read before origin supplied')), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                driver.main()
        self.assertEqual(caught.exception.code, 2)

    def test_https_verifies_certificate_and_hostname(self):
        opener = driver.make_opener(CookieJar())
        handler = next(h for h in opener.handlers if isinstance(h, HTTPSHandler))
        context = getattr(handler, '_context')
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)


if __name__ == '__main__':
    unittest.main()
