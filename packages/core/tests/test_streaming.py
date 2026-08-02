import os
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch

from onvif_mcp_core.streaming import get_web_player_url


class StreamingTests(IsolatedAsyncioTestCase):
    async def test_builds_url_from_stream_server_ip(self):
        with patch.dict(os.environ, {"STREAM_SERVER_IP": "10.1.1.13"}, clear=False):
            result = await get_web_player_url("AMC014641NE6L35AT8", "MediaProfile000")

        self.assertEqual(
            "http://10.1.1.13:8889/AMC014641NE6L35AT8/MediaProfile000",
            result,
        )

    async def test_missing_stream_server_ip_embeds_none(self):
        with patch.dict(os.environ, {}, clear=True):
            result = await get_web_player_url("SERIAL123", "MediaProfile001")

        self.assertEqual(
            "http://None:8889/SERIAL123/MediaProfile001",
            result,
        )
