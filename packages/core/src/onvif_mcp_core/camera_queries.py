"""Transport-independent camera retrieval and discovery."""

from __future__ import annotations

import json
import logging
import os
import sys
from collections.abc import Mapping, Sequence
from typing import Any

from libonvif.devices.camera import Camera, discover, get_camera_by_ip
from libonvif.utils.adapters import find_adapters
from libonvif.utils.serialization import to_dict

logger = logging.getLogger(__name__)


def _get_camera_credentials(camera: Camera) -> None:
    camera.username = os.environ.get("CAMERA_USERNAME", "")
    camera.password = os.environ.get("CAMERA_PASSWORD", "")


def _on_error(xaddr: str, ex: Exception) -> None:
    logger.debug("Camera discovery error at %s: %s", xaddr, ex)


def _camera_filled(camera: Camera) -> None:
    logger.debug(
        "Camera filled: %s : %s",
        camera.hostname,
        camera.device_information.serial_number,
    )


async def get_camera(ip_address: str) -> str:
    """Get the full state of a camera at the specified IP address."""
    camera = get_camera_by_ip(
        ip_address,
        os.environ.get("CAMERA_USERNAME", ""),
        os.environ.get("CAMERA_PASSWORD", ""),
    )
    return camera.to_json()


def _camera_summary(
    camera: Camera,
) -> dict[str, Any]:
    data = to_dict(camera)
    dev = data.get("device_information") or {}
    hostname_obj = data.get("hostname") or {}
    xaddr = data.get("xaddr") or ""
    ip_addr = xaddr.split("://", 1)[1].split("/", 1)[0] if "://" in xaddr else ""

    profiles = []
    for profile in data.get("profiles") or []:
        video_encoder = profile.get("video_encoder") or {}
        rate_control = video_encoder.get("rate_control") or {}
        audio_encoder = profile.get("audio_encoder") or {}
        profiles.append(
            {
                "token": profile.get("token") or "",
                "name": profile.get("name") or "",
                "video_encoder": {
                    "encoding": video_encoder.get("encoding") or "",
                    "resolution": video_encoder.get("resolution") or "",
                    "frame_rate_limit": rate_control.get("frame_rate_limit") or 0,
                    "bitrate_limit": rate_control.get("bitrate_limit") or 0,
                    "gov_length": video_encoder.get("gov_length") or 0,
                },
                "audio_encoder": {
                    "encoding": audio_encoder.get("encoding") or "",
                    "sample_rate": audio_encoder.get("sample_rate") or 0,
                },
                "stream_uri": profile.get("stream_uri") or "",
                "snapshot_uri": profile.get("snapshot_uri") or "",
            }
        )

    ptz = data.get("ptz") or {}
    presets = [
        {"token": preset.get("token") or "", "name": preset.get("name") or ""}
        for preset in ptz.get("presets") or []
    ]

    tours = []
    for tour in ptz.get("tours") or []:
        tour_status = tour.get("status") or {}
        tours.append(
            {
                "token": tour.get("token") or "",
                "name": tour.get("name") or "",
                "status": tour_status.get("state") or "",
                "spot_count": len(tour.get("spots") or []),
            }
        )

    ptz_status = ptz.get("status") or {}
    capabilities = data.get("capabilities") or {}
    ptz_capabilities = capabilities.get("ptz") or {}
    event_properties = data.get("event_properties") or {}

    return {
        "hostname": hostname_obj.get("name") or data.get("name") or "",
        "ip_address": ip_addr,
        "manufacturer": dev.get("manufacturer") or "",
        "model": dev.get("model") or "",
        "firmware_version": dev.get("firmware_version") or "",
        "serial_number": dev.get("serial_number") or "",
        "profiles": profiles,
        "ptz_presets": presets,
        "ptz_tours": tours,
        "ptz_status": {
            "pan_tilt": ptz_status.get("pan_tilt_status") or "",
            "zoom": ptz_status.get("zoom_status") or "",
        },
        "ptz_xaddr": ptz_capabilities.get("xaddr") or "",
        "event_topics": event_properties.get("topic_set") or [],
        "time_offset": int(data.get("time_offset") or 0),
    }


async def get_adapters() -> str:
    """Return a list of available active network adapters.

    Returns:
        A delimited string containing the IP address of each active adapter,
        one per line, separated by "\n--\n".
    """
    adapter_ips = find_adapters()
    if not adapter_ips:
        return ""

    return "\n--\n".join(adapter_ips)


async def get_cameras() -> str:
    """Discover cameras and return lightweight, delimited JSON summaries."""
    # Get all adapter IPs
    adapter_ips = find_adapters()
    if adapter_ips:
        logger.debug("Host IP addresses: %s", adapter_ips)

    # Discover cameras on each adapter and merge results
    all_cameras = []
    seen_ips = set()

    for adapter_ip in adapter_ips:
        logger.debug("Discovering cameras on adapter %s", adapter_ip)
        cameras = discover(
            adapter_ip,
            _get_camera_credentials,
            on_error=_on_error,
            camera_filled=_camera_filled,
            use_threads=True,
        )

        for camera in cameras:
            # Get camera IP for deduplication
            xaddr = getattr(camera, "xaddr", None) or ""
            ip_addr = xaddr.split("://", 1)[1].split("/", 1)[0] if "://" in xaddr else ""

            # Skip if we've already seen this camera
            if ip_addr in seen_ips:
                logger.debug("Skipping duplicate camera %s (already discovered)", ip_addr)
                continue

            seen_ips.add(ip_addr)
            all_cameras.append(camera)

    logger.debug("Discovered %d camera(s) total", len(all_cameras))

    summaries = []
    for camera in all_cameras:
        try:
            summaries.append(json.dumps(_camera_summary(camera)))
        except Exception as ex:
            logger.error(
                "Failed to serialize camera at %s: %s",
                getattr(camera, "xaddr", "?"),
                ex,
            )

    return "\n--\n".join(summaries)
