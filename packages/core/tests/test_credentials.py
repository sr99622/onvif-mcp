import os
from types import SimpleNamespace
from unittest import IsolatedAsyncioTestCase, TestCase
from unittest.mock import patch

from onvif_mcp_core.credentials import CameraCredentials, get_camera_credentials
from onvif_mcp_core import camera_queries, ptz


class CredentialTests(TestCase):
    def test_missing_values_retain_empty_defaults(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(get_camera_credentials(), CameraCredentials("", ""))

    def test_values_are_preserved_and_changes_are_not_cached(self):
        with patch.dict(os.environ, {"CAMERA_USERNAME": "operator", "CAMERA_PASSWORD": " secret \t"}, clear=True):
            credentials = get_camera_credentials()
            self.assertEqual(credentials.username, "operator")
            self.assertEqual(credentials.password, " secret \t")
            os.environ["CAMERA_PASSWORD"] = "rotated"
            self.assertEqual(get_camera_credentials().password, "rotated")
            os.environ["CAMERA_PASSWORD"] = ""
            self.assertEqual(get_camera_credentials().password, "")

    def test_repr_does_not_include_password(self):
        self.assertNotIn("secret-sentinel", repr(CameraCredentials("operator", "secret-sentinel")))

    def test_discovery_callback_populates_camera_from_shared_accessor(self):
        camera = SimpleNamespace()
        with patch.object(camera_queries, "get_camera_credentials", return_value=CameraCredentials("discovery-user", "discovery-secret")):
            camera_queries._get_camera_credentials(camera)
        self.assertEqual((camera.username, camera.password), ("discovery-user", "discovery-secret"))

    def test_direct_ptz_camera_retains_credentials(self):
        with patch.object(ptz, "get_camera_credentials", return_value=CameraCredentials("ptz-user", "ptz-secret")):
            camera = ptz._command_camera("http://camera/ptz", 3)
        self.assertEqual((camera.username, camera.password), ("ptz-user", "ptz-secret"))
        self.assertEqual(camera.time_offset, 3)


class CredentialQueryTests(IsolatedAsyncioTestCase):
    async def test_camera_query_passes_credentials_and_preserves_json_output(self):
        camera = SimpleNamespace(to_json=lambda: '{"existing": "camera-json"}')
        with (
            patch.object(camera_queries, "get_camera_credentials", return_value=CameraCredentials("query-user", "query-secret")),
            patch.object(camera_queries, "get_camera_by_ip", return_value=camera) as query,
        ):
            result = await camera_queries.get_camera("192.0.2.1")
        query.assert_called_once_with("192.0.2.1", "query-user", "query-secret")
        self.assertEqual(result, '{"existing": "camera-json"}')
