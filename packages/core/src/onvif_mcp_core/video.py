"""Shared video encoder configuration operations."""

from __future__ import annotations

import logging
import os
from collections.abc import Callable
from typing import Any

from libonvif.devices.camera import (
    get_camera_by_ip,
    set_video_encoder_configuration,
)

logger = logging.getLogger(__name__)


async def _set_video_encoder_value(
    ip_address: str,
    profile_token: str,
    value: Any,
    *,
    setting_name: str,
    apply_value: Callable[[Any, Any], None],
) -> str:
    try:
        camera = get_camera_by_ip(
            ip_address,
            os.environ.get("CAMERA_USERNAME", ""),
            os.environ.get("CAMERA_PASSWORD", ""),
        )
    except Exception as ex:
        logger.error("Failed to query camera at %s: %s", ip_address, ex)
        return f"Failed to query camera at {ip_address}: {ex}"

    try:
        camera.errors = None
        for profile in camera.profiles:
            if profile.token == profile_token:
                apply_value(profile.video_encoder, value)
                set_video_encoder_configuration(camera, profile.video_encoder)
                if camera.errors:
                    raise Exception(f"Camera returned errors: {camera.errors}")
                return (
                    f"Successfully set {setting_name} to {value} for camera "
                    f"at {camera.xaddr}, profile {profile_token}."
                )

        return f"Profile {profile_token} not found on camera at {camera.xaddr}."
    except Exception as ex:
        logger.error(
            "Failed to set %s for camera at %s: %s",
            setting_name,
            camera.xaddr,
            ex,
        )
        return f"Failed to set {setting_name} for camera at {camera.xaddr}: {ex}"


async def set_camera_video_resolution(
    ip_address: str,
    profile_token: str,
    resolution: str,
) -> str:
    """Set the resolution for a camera media profile."""
    return await _set_video_encoder_value(
        ip_address,
        profile_token,
        resolution,
        setting_name="resolution",
        apply_value=lambda encoder, value: setattr(encoder, "resolution", value),
    )


async def set_camera_video_frame_rate(
    ip_address: str,
    profile_token: str,
    frame_rate_limit: int,
) -> str:
    """Set the frame-rate limit for a camera media profile."""
    return await _set_video_encoder_value(
        ip_address,
        profile_token,
        frame_rate_limit,
        setting_name="frame rate limit",
        apply_value=lambda encoder, value: setattr(
            encoder.rate_control,
            "frame_rate_limit",
            value,
        ),
    )


async def set_camera_video_bitrate(
    ip_address: str,
    profile_token: str,
    bitrate_limit: int,
) -> str:
    """Set the bitrate limit for a camera media profile."""
    return await _set_video_encoder_value(
        ip_address,
        profile_token,
        bitrate_limit,
        setting_name="bitrate limit",
        apply_value=lambda encoder, value: setattr(
            encoder.rate_control,
            "bitrate_limit",
            value,
        ),
    )


async def set_camera_video_gov_length(
    ip_address: str,
    profile_token: str,
    gov_length: int,
) -> str:
    """Set the GOV/GOP length for a camera media profile."""
    return await _set_video_encoder_value(
        ip_address,
        profile_token,
        gov_length,
        setting_name="gov_length",
        apply_value=lambda encoder, value: setattr(encoder, "gov_length", value),
    )
