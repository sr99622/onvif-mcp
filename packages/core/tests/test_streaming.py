import os
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch

from onvif_mcp_core.streaming import get_web_player_url


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
