"""Shared streaming and web-player URL construction."""

from __future__ import annotations

import os


async def get_web_player_url(
    camera_device_information_serial_number: str,
    camera_media_profile_token: str,
) -> str:
    """Get the web-player URL for a camera live stream without opening a browser."""
    stream_server_ip = os.environ.get("STREAM_SERVER_IP")
    return (
        f"https://{stream_server_ip}:8889/"
        f"{camera_device_information_serial_number}/{camera_media_profile_token}"
    )
