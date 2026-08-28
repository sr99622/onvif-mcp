"""Shared streaming, web-player URL construction, and snapshot retrieval."""

from __future__ import annotations

import os
import urllib.error
import urllib.request

import anyio.to_thread
from mcp.server.fastmcp.utilities.types import Image as _Image


# Default bind of the loopback-only snapshot proxy (services/snapshot_proxy.py).
# The MCP server runs on the same host, so it reaches the proxy directly over
# 127.0.0.1 — no nginx and no keycloak gate involved. Override with
# SNAPSHOT_PROXY_URL if the proxy is bound elsewhere.
_SNAPSHOT_PROXY_DEFAULT = "http://127.0.0.1:8891"

# Worst-case proxy response time (~20s upstream + one retry after a pause), plus
# headroom so we never cut off a slow camera mid-fetch.
_SNAPSHOT_TIMEOUT_S = 60

# JPEG start-of-image marker; the proxy also validates this, but we re-check
# defense in depth so an HTML error page can never be surfaced as an image.
_JPEG_SOI = b"\xff\xd8"


def build_web_player_url(serial_number: str | None, profile_token: str | None) -> str:
    """Build the web-player URL for a camera live stream.

    Returns an empty string when STREAM_SERVER_URL is not configured or either
    value is missing, so callers embedding the URL in larger payloads can do
    so unconditionally without raising.
    """
    stream_server_url = os.environ.get("STREAM_SERVER_URL")
    if not stream_server_url or not serial_number or not profile_token:
        return ""
    stream_server_url = stream_server_url.rstrip("/")
    return (
        f"{stream_server_url}/webrtc/"
        f"{serial_number}/{profile_token}/"
    )


def build_web_snapshot_url(serial_number: str | None, profile_token: str | None) -> str:
    """Build the snapshot URL for a camera image.

    Returns an empty string when STREAM_SERVER_URL is not configured or either
    value is missing, so callers embedding the URL in larger payloads can do
    so unconditionally without raising.
    """
    stream_server_url = os.environ.get("STREAM_SERVER_URL")
    if not stream_server_url or not serial_number or not profile_token:
        return ""
    stream_server_url = stream_server_url.rstrip("/")
    return (
        f"{stream_server_url}/snapshot/"
        f"{serial_number}/{profile_token}/"
    )


def build_snapshot_proxy_url(serial_number: str | None, profile_token: str | None) -> str:
    """Build the loopback snapshot-proxy URL for a camera image.

    Unlike ``build_web_snapshot_url`` (the browser-facing, keycloak-gated URL),
    this points directly at the local proxy that performs the per-vendor camera
    authentication. Returns an empty string when either value is missing.
    """
    proxy_url = os.environ.get("SNAPSHOT_PROXY_URL") or _SNAPSHOT_PROXY_DEFAULT
    if not serial_number or not profile_token:
        return ""
    return f"{proxy_url.rstrip('/')}/snapshot/{serial_number}/{profile_token}/"


async def get_web_player_url(
    serial_number: str,
    profile_token: str,
) -> str:
    """Get the web-player URL for a camera live stream without opening a browser."""
    url = build_web_player_url(serial_number, profile_token)
    if not url:
        raise RuntimeError("STREAM_SERVER_URL is not configured")
    return url


def _fetch_snapshot(url: str, serial_number: str, profile_token: str) -> bytes:
    """Blocking fetch of one JPEG from the snapshot proxy.

    Raises ``RuntimeError`` with a descriptive message on any failure so the MCP
    layer can surface it as a tool error (matching the other tools' behaviour).
    """
    try:
        with urllib.request.urlopen(url, timeout=_SNAPSHOT_TIMEOUT_S) as response:
            return response.read()
    except urllib.error.HTTPError as ex:
        raise RuntimeError(
            f"Snapshot for {serial_number}/{profile_token} failed: "
            f"snapshot proxy returned HTTP {ex.code}"
        ) from ex
    except OSError as ex:
        raise RuntimeError(
            f"Could not reach the snapshot proxy at {url}: {ex}"
        ) from ex


async def get_snapshot(serial_number: str, profile_token: str) -> _Image:
    """Fetch a live JPEG snapshot of a camera and return it as an image.

    Goes directly through the loopback-only snapshot proxy (which performs the
    per-vendor Basic/Digest authentication to the camera), so no browser session
    or keycloak credential is needed from the client side. The returned value is
    the MCP Image helper, which FastMCP converts into an image content block the
    calling model can inspect directly.

    Raises ``RuntimeError`` when the proxy is unreachable, the camera/profile is
    unknown, the camera fails to return a frame, or the response is not a JPEG.
    """
    url = build_snapshot_proxy_url(serial_number, profile_token)
    if not url:
        raise RuntimeError("Serial number and profile token are both required")

    # Keep the event loop responsive; the proxy can block for up to ~60s.
    image_bytes = await anyio.to_thread.run_sync(_fetch_snapshot, url, serial_number, profile_token)
    if not image_bytes.startswith(_JPEG_SOI):
        raise RuntimeError(
            f"Snapshot for {serial_number}/{profile_token} did not return a valid JPEG image"
        )
    return _Image(data=image_bytes, format="jpeg")
