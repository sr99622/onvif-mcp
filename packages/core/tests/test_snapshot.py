import os
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch

from onvif_mcp_core.streaming import (
    build_snapshot_proxy_url,
    get_snapshot,
)


class BuildSnapshotProxyUrlTests(IsolatedAsyncioTestCase):
    async def test_builds_loopback_url_by_default(self):
        with patch.dict(os.environ, {}, clear=True):
            result = build_snapshot_proxy_url("AMC014641NE6L35AT8", "MediaProfile000")

        self.assertEqual(
            "http://127.0.0.1:8891/snapshot/AMC014641NE6L35AT8/MediaProfile000/",
            result,
        )

    async def test_respects_snapshot_proxy_url_override(self):
        with patch.dict(
            os.environ,
            {"SNAPSHOT_PROXY_URL": "http://10.9.8.7:8891"},
            clear=True,
        ):
            result = build_snapshot_proxy_url("AMC014641NE6L35AT8", "MediaProfile000")

        self.assertEqual(
            "http://10.9.8.7:8891/snapshot/AMC014641NE6L35AT8/MediaProfile000/",
            result,
        )

    async def test_strips_trailing_slash_from_override(self):
        with patch.dict(
            os.environ,
            {"SNAPSHOT_PROXY_URL": "http://127.0.0.1:9999/"},
            clear=True,
        ):
            result = build_snapshot_proxy_url("SERIAL", "Profile_1")

        self.assertEqual("http://127.0.0.1:9999/snapshot/SERIAL/Profile_1/", result)

    async def test_missing_serial_number_returns_empty_string(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(build_snapshot_proxy_url("", "MediaProfile000"), "")
            self.assertEqual(build_snapshot_proxy_url(None, "MediaProfile000"), "")

    async def test_missing_profile_token_returns_empty_string(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(build_snapshot_proxy_url("SERIAL", ""), "")
            self.assertEqual(build_snapshot_proxy_url("SERIAL", None), "")


def _jpeg_bytes() -> bytes:
    # SOI marker + minimal filler; only the SOI prefix matters to the code under test.
    return b"\xff\xd8\xff\xe0" + b"imagedata" * 20


class GetSnapshotTests(IsolatedAsyncioTestCase):
    async def test_returns_image_with_jpeg_mime_and_bytes(self):
        # anyio runs the blocking fetch in a worker thread, so patch the
        # underlying _fetch_snapshot directly.
        with patch(
            "onvif_mcp_core.streaming._fetch_snapshot",
            return_value=_jpeg_bytes(),
        ):
            result = await get_snapshot("SERIAL123", "MediaProfile000")

        self.assertEqual(result.data, _jpeg_bytes())
        self.assertEqual(result._mime_type, "image/jpeg")

    async def test_rejects_non_jpeg_response(self):
        with patch(
            "onvif_mcp_core.streaming._fetch_snapshot",
            return_value=b"<html>302 Found</html>",
        ):
            with self.assertRaisesRegex(RuntimeError, "did not return a valid JPEG"):
                await get_snapshot("SERIAL123", "MediaProfile000")

    async def test_missing_values_raise(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "both required"):
                await get_snapshot("", "MediaProfile000")
            with self.assertRaisesRegex(RuntimeError, "both required"):
                await get_snapshot("SERIAL123", "")


class _FakeResponse:
    def __init__(self, body: bytes):
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FetchSnapshotTests(IsolatedAsyncioTestCase):
    async def test_returns_body_on_success(self):
        fake = _FakeResponse(_jpeg_bytes())
        with patch("onvif_mcp_core.streaming.urllib.request.urlopen", return_value=fake):
            body = await get_snapshot("SERIAL123", "MediaProfile000")

        self.assertEqual(body.data, _jpeg_bytes())

    async def test_http_error_surfaces_status_code(self):
        import urllib.error

        # Only ex.code is read by the code under test, so a minimal subclass of the
        # real HTTPError (with a permissive constructor) keeps it catchable while
        # dodging HTTPError.__init__'s required params.
        class _FakeHTTPError(urllib.error.HTTPError):
            def __init__(self, code: int) -> None:
                self.code = code

        with patch(
            "onvif_mcp_core.streaming.urllib.request.urlopen",
            side_effect=_FakeHTTPError(code=502),
        ):
            with self.assertRaisesRegex(RuntimeError, "HTTP 502"):
                await get_snapshot("SERIAL123", "MediaProfile000")

    async def test_connection_error_surfaces_url(self):
        import urllib.error

        with patch(
            "onvif_mcp_core.streaming.urllib.request.urlopen",
            side_effect=urllib.error.URLError("Connection refused"),
        ):
            with self.assertRaisesRegex(RuntimeError, "Could not reach"):
                await get_snapshot("SERIAL123", "MediaProfile000")
