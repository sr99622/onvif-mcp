"""Shared audio encoder configuration operations."""

from __future__ import annotations

import logging
import os
from collections.abc import Callable
from typing import Any

from libonvif.devices.camera import (
    get_camera_by_ip,
    set_audio_encoder_configuration,
)

logger = logging.getLogger(__name__)


async def _set_audio_encoder_value(
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
                apply_value(profile.audio_encoder, value)
                set_audio_encoder_configuration(camera, profile.audio_encoder)
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


async def set_camera_audio_encoding(
    ip_address: str,
    profile_token: str,
    encoding: str,
) -> str:
    """
    Set the audio encoding for one media profile on a camera.

    The encoding must be one of the codecs offered by the camera for the
    selected profile, such as ``AAC`` or ``G711``.
    """
    return await _set_audio_encoder_value(
        ip_address,
        profile_token,
        encoding,
        setting_name="audio encoding",
        apply_value=lambda encoder, value: setattr(encoder, "encoding", value),
    )


async def set_camera_audio_sample_rate(
    ip_address: str,
    profile_token: str,
    sample_rate: int,
) -> str:
    """
    Set the audio sample rate for one media profile on a camera.

    Some cameras couple sample rate and bitrate. Re-query the camera after
    changing this value to confirm the settings actually retained.
    """
    return await _set_audio_encoder_value(
        ip_address,
        profile_token,
        sample_rate,
        setting_name="audio sample rate",
        apply_value=lambda encoder, value: setattr(
            encoder,
            "sample_rate",
            value,
        ),
    )
