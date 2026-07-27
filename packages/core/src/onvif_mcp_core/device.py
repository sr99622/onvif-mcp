"""Shared camera device-management operations."""

from __future__ import annotations

import logging
import os

from libonvif.devices.camera import (
    get_camera_by_ip,
    get_local_date_and_time,
    get_time_offset,
    reboot,
    set_hostname,
    set_system_date_and_time,
)

logger = logging.getLogger(__name__)


def _query_camera(ip_address: str):
    return get_camera_by_ip(
        ip_address,
        os.environ.get("CAMERA_USERNAME", ""),
        os.environ.get("CAMERA_PASSWORD", ""),
    )


def _raise_camera_errors(camera) -> None:
    if camera.errors:
        raise Exception(f"Camera returned errors: {camera.errors}")


async def change_camera_hostname(ip_address: str, new_hostname: str) -> str:
    """Change a camera's hostname by IP address."""
    try:
        camera = _query_camera(ip_address)
    except Exception as ex:
        logger.error("Failed to query camera at %s: %s", ip_address, ex)
        return f"Failed to query camera at {ip_address}: {ex}"

    try:
        camera.hostname.name = new_hostname
        camera.errors = None
        set_hostname(camera)
        _raise_camera_errors(camera)
        return (
            f"Successfully changed hostname of camera at {camera.xaddr} "
            f"to {new_hostname}."
        )
    except Exception as ex:
        logger.error(
            "Failed to change hostname for camera at %s: %s",
            camera.xaddr,
            ex,
        )
        return f"Failed to change hostname for camera at {camera.xaddr}: {ex}"


async def sync_camera_time(ip_address: str) -> str:
    """Synchronize a camera's clock with this machine's local time."""
    try:
        camera = _query_camera(ip_address)
    except Exception as ex:
        logger.error("Failed to query camera at %s: %s", ip_address, ex)
        return f"Failed to query camera at {ip_address}: {ex}"

    try:
        camera.errors = None
        set_system_date_and_time(camera, get_local_date_and_time())
        _raise_camera_errors(camera)
        get_time_offset(camera)
        return (
            f"Successfully synchronized time for camera at {camera.xaddr}. "
            f"time_offset is now {camera.time_offset} seconds."
        )
    except Exception as ex:
        logger.error("Failed to sync time for camera at %s: %s", camera.xaddr, ex)
        return f"Failed to sync time for camera at {camera.xaddr}: {ex}"


async def reboot_camera(ip_address: str) -> str:
    """Request that a camera reboot through ONVIF SystemReboot."""
    try:
        camera = _query_camera(ip_address)
    except Exception as ex:
        logger.error("Failed to query camera at %s: %s", ip_address, ex)
        return f"Failed to query camera at {ip_address}: {ex}"

    try:
        camera.errors = None
        reboot(camera)
        _raise_camera_errors(camera)
        return f"Successfully requested reboot for camera at {camera.xaddr}."
    except Exception as ex:
        logger.error("Failed to reboot camera at %s: %s", camera.xaddr, ex)
        return f"Failed to reboot camera at {camera.xaddr}: {ex}"
