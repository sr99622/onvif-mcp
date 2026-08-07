"""Shared streaming and web-player URL construction."""

from __future__ import annotations

import os


async def get_web_player_url(
    serial_number: str,
    profile_token: str,
) -> str:
    """Get the web-player URL for a camera live stream without opening a browser."""
    stream_server_url = os.environ.get("STREAM_SERVER_URL")
    if not stream_server_url:
        raise RuntimeError("STREAM_SERVER_URL is not configured")
    stream_server_url = stream_server_url.rstrip("/")
    return (
        f"{stream_server_url}/"
        f"{serial_number}/{profile_token}/"
    )
