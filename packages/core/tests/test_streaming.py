import os
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch

from onvif_mcp_core.streaming import (
    build_web_player_url,
    build_web_snapshot_url,
    get_web_player_url,
)


class BuildWebPlayerUrlTests(IsolatedAsyncioTestCase):
    async def test_builds_url_from_stream_server_url(self):
        with patch.dict(
            os.environ,
            {"STREAM_SERVER_URL": "https://camera.home.arpa"},
            clear=True,
        ):
            result = build_web_player_url("AMC014641NE6L35AT8", "MediaProfile000")

        self.assertEqual(
            "https://camera.home.arpa/webrtc/AMC014641NE6L35AT8/MediaProfile000/",
            result,
        )

    async def test_strips_trailing_slash_from_stream_server_url(self):
        with patch.dict(
            os.environ,
            {"STREAM_SERVER_URL": "https://camera.home.arpa/"},
            clear=True,
        ):
            result = build_web_player_url("AMC014641NE6L35AT8", "MediaProfile000")

        self.assertEqual(
            "https://camera.home.arpa/webrtc/AMC014641NE6L35AT8/MediaProfile000/",
            result,
        )

    async def test_missing_stream_server_url_returns_empty_string(self):
        with patch.dict(os.environ, {}, clear=True):
            result = build_web_player_url("SERIAL123", "MediaProfile001")

        self.assertEqual("", result)

    async def test_missing_serial_number_returns_empty_string(self):
        with patch.dict(
            os.environ,
            {"STREAM_SERVER_URL": "https://camera.home.arpa"},
            clear=True,
        ):
            self.assertEqual(build_web_player_url("", "MediaProfile000"), "")
            self.assertEqual(build_web_player_url(None, "MediaProfile000"), "")

    async def test_missing_profile_token_returns_empty_string(self):
        with patch.dict(
            os.environ,
            {"STREAM_SERVER_URL": "https://camera.home.arpa"},
            clear=True,
        ):
            self.assertEqual(build_web_player_url("SERIAL123", ""), "")
            self.assertEqual(build_web_player_url("SERIAL123", None), "")


class BuildWebSnapshotUrlTests(IsolatedAsyncioTestCase):
    async def test_builds_url_from_stream_server_url(self):
        with patch.dict(
            os.environ,
            {"STREAM_SERVER_URL": "https://camera.home.arpa"},
            clear=True,
        ):
            result = build_web_snapshot_url("AMC014641NE6L35AT8", "MediaProfile000")

        self.assertEqual(
            "https://camera.home.arpa/snapshot/AMC014641NE6L35AT8/MediaProfile000/",
            result,
        )

    async def test_strips_trailing_slash_from_stream_server_url(self):
        with patch.dict(
            os.environ,
            {"STREAM_SERVER_URL": "https://camera.home.arpa/"},
            clear=True,
        ):
            result = build_web_snapshot_url("AMC014641NE6L35AT8", "MediaProfile000")

        self.assertEqual(
            "https://camera.home.arpa/snapshot/AMC014641NE6L35AT8/MediaProfile000/",
            result,
        )

    async def test_missing_stream_server_url_returns_empty_string(self):
        with patch.dict(os.environ, {}, clear=True):
            result = build_web_snapshot_url("SERIAL123", "MediaProfile001")

        self.assertEqual("", result)

    async def test_missing_serial_number_returns_empty_string(self):
        with patch.dict(
            os.environ,
            {"STREAM_SERVER_URL": "https://camera.home.arpa"},
            clear=True,
        ):
            self.assertEqual(build_web_snapshot_url("", "MediaProfile000"), "")
            self.assertEqual(build_web_snapshot_url(None, "MediaProfile000"), "")

    async def test_missing_profile_token_returns_empty_string(self):
        with patch.dict(
            os.environ,
            {"STREAM_SERVER_URL": "https://camera.home.arpa"},
            clear=True,
        ):
            self.assertEqual(build_web_snapshot_url("SERIAL123", ""), "")
            self.assertEqual(build_web_snapshot_url("SERIAL123", None), "")


class StreamingTests(IsolatedAsyncioTestCase):
    async def test_builds_url_from_stream_server_url(self):
        with patch.dict(
            os.environ,
            {"STREAM_SERVER_URL": "https://camera.home.arpa"},
            clear=True,
        ):
            result = await get_web_player_url("AMC014641NE6L35AT8", "MediaProfile000")

        self.assertEqual(
            "https://camera.home.arpa/webrtc/AMC014641NE6L35AT8/MediaProfile000/",
            result,
        )

    async def test_missing_stream_server_url_raises_error(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(
                RuntimeError,
                "STREAM_SERVER_URL is not configured",
            ):
                await get_web_player_url("SERIAL123", "MediaProfile001")
