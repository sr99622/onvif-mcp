import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("snapshot_proxy.py")


def load_snapshot_proxy(routes_file: Path):
    with patch.dict(os.environ, {"SNAPSHOT_ROUTES_FILE": str(routes_file)}):
        spec = importlib.util.spec_from_file_location("snapshot_proxy_under_test", MODULE_PATH)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module


class SnapshotProxyRouteLoadingTests(unittest.TestCase):
    def test_loads_routes_from_json_file(self):
        with self.subTest("route dict"):
            tmp_dir = Path(os.environ.get("TMPDIR", "/tmp"))
            routes_file = tmp_dir / "snapshot_routes_test_dict.json"
            routes_file.write_text(json.dumps({"SERIAL/Profile_1": "http://camera/snapshot.jpg"}))
            try:
                module = load_snapshot_proxy(routes_file)
                self.assertEqual(module.ROUTES, {"SERIAL/Profile_1": "http://camera/snapshot.jpg"})
                self.assertEqual(module._lookup("SERIAL", "Profile_1"), "http://camera/snapshot.jpg")
            finally:
                routes_file.unlink(missing_ok=True)

    def test_loads_routes_from_json_object_with_routes_key(self):
        tmp_dir = Path(os.environ.get("TMPDIR", "/tmp"))
        routes_file = tmp_dir / "snapshot_routes_test_wrapped.json"
        routes_file.write_text(json.dumps({"routes": {"SERIAL/Profile_2": "http://camera/two.jpg"}}))
        try:
            module = load_snapshot_proxy(routes_file)
            self.assertEqual(module.ROUTES, {"SERIAL/Profile_2": "http://camera/two.jpg"})
        finally:
            routes_file.unlink(missing_ok=True)

    def test_missing_routes_file_uses_empty_routes_without_crashing(self):
        module = load_snapshot_proxy(Path("/tmp/no-such-snapshot-routes-file.json"))
        self.assertEqual(module.ROUTES, {})
        self.assertIsNone(module._lookup("SERIAL", "Profile_1"))


if __name__ == "__main__":
    unittest.main()
