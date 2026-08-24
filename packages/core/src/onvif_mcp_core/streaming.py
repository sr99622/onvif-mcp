"""Shared streaming and web-player URL construction."""

from __future__ import annotations

import os


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


async def get_web_player_url(
    serial_number: str,
    profile_token: str,
) -> str:
    """Get the web-player URL for a camera live stream without opening a browser."""
    url = build_web_player_url(serial_number, profile_token)
    if not url:
        raise RuntimeError("STREAM_SERVER_URL is not configured")
    return url
