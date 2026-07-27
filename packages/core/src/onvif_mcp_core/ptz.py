"""Shared PTZ movement, preset, and preset-tour operations."""

from __future__ import annotations

import logging
import os

from libonvif.datastructures.capabilities import Capabilities, PTZCapabilities
from libonvif.datastructures.ptz import PTZPreset, PresetTour, TourSpot
from libonvif.devices.camera import (
    Camera,
    continuous_move,
    create_preset_tour,
    get_camera_by_ip,
    get_presets,
    get_preset_tours,
    goto_preset,
    modify_preset_tour,
    move_stop,
    operate_preset_tour,
    remove_preset,
    remove_preset_tour,
    set_preset,
)

logger = logging.getLogger(__name__)

MISSING_PTZ_XADDR = (
    "camera_ptz_xaddr is required - call get_cameras again to get "
    "an up to date summary before retrying."
)


def _command_camera(ptz_xaddr: str, time_offset: int) -> Camera:
    camera = Camera()
    camera.capabilities = Capabilities(ptz=PTZCapabilities(xaddr=ptz_xaddr))
    camera.username = os.environ.get("CAMERA_USERNAME", "")
    camera.password = os.environ.get("CAMERA_PASSWORD", "")
    camera.time_offset = time_offset
    camera.errors = None
    return camera


def _query_camera(ip_address: str):
    return get_camera_by_ip(
        ip_address,
        os.environ.get("CAMERA_USERNAME", ""),
        os.environ.get("CAMERA_PASSWORD", ""),
    )


def _raise_camera_errors(camera: Camera, prefix: str = "Camera returned errors") -> None:
    if camera.errors:
        raise Exception(f"{prefix}: {camera.errors}")


async def goto_camera_preset(
    camera_ptz_xaddr: str,
    camera_profile_token: str,
    camera_preset_token: str,
    camera_time_offset: int,
) -> str:
    """Move a PTZ camera to a stored preset."""
    if not camera_ptz_xaddr:
        return MISSING_PTZ_XADDR
    camera = _command_camera(camera_ptz_xaddr, camera_time_offset)
    try:
        goto_preset(
            camera,
            camera_profile_token,
            PTZPreset(token=camera_preset_token),
        )
        _raise_camera_errors(camera)
        return (
            f"Successfully moved camera at {camera_ptz_xaddr} "
            f"to preset {camera_preset_token}."
        )
    except Exception as ex:
        logger.error("Failed to move camera to preset: %s", ex)
        return (
            f"Failed to move camera at {camera_ptz_xaddr} "
            f"to preset {camera_preset_token}: {ex}"
        )


async def set_camera_preset(
    ip_address: str,
    profile_token: str,
    preset_token: str = None,
    preset_name: str = None,
) -> str:
    """Create a preset or overwrite one with the camera's current position."""
    try:
        camera = _query_camera(ip_address)
    except Exception as ex:
        return f"Failed to query camera at {ip_address}: {ex}"

    try:
        camera.errors = None
        presets = camera.ptz.presets if camera.ptz else []
        if preset_token:
            preset = next(
                (item for item in presets if item.token == preset_token),
                None,
            )
            if not preset:
                return (
                    f"Preset {preset_token} not found on camera "
                    f"at {camera.xaddr}."
                )
            if preset_name is not None:
                preset.name = preset_name
            set_preset(camera, profile_token, preset)
            _raise_camera_errors(camera)
            return (
                f"Successfully overwrote preset {preset_token} on camera at "
                f"{camera.xaddr} with its current position."
            )

        existing_tokens = {preset.token for preset in presets}
        set_preset(camera, profile_token)
        _raise_camera_errors(camera)
        get_presets(camera, profile_token)
        _raise_camera_errors(
            camera,
            "Camera returned errors while refreshing presets",
        )
        new_tokens = [
            preset.token
            for preset in camera.ptz.presets
            if preset.token not in existing_tokens
        ]
        if not new_tokens:
            return (
                f"Preset created on camera at {camera.xaddr}, but could not "
                "determine its new token from the refreshed preset list."
            )
        new_token = new_tokens[0]
        if preset_name is not None:
            new_preset = next(
                item for item in camera.ptz.presets if item.token == new_token
            )
            new_preset.name = preset_name
            set_preset(camera, profile_token, new_preset)
            if camera.errors:
                raise Exception(
                    f"Preset {new_token} created, but failed to set its name: "
                    f"{camera.errors}"
                )
        name_note = f" named '{preset_name}'" if preset_name else ""
        return (
            f"Successfully created new preset {new_token}{name_note} "
            f"on camera at {camera.xaddr}."
        )
    except Exception as ex:
        logger.error("Failed to set preset for camera at %s: %s", camera.xaddr, ex)
        return f"Failed to set preset for camera at {camera.xaddr}: {ex}"


async def remove_camera_preset(
    ip_address: str,
    profile_token: str,
    preset_token: str,
) -> str:
    """Permanently remove a PTZ preset."""
    try:
        camera = _query_camera(ip_address)
    except Exception as ex:
        return f"Failed to query camera at {ip_address}: {ex}"
    preset = next(
        (
            item
            for item in (camera.ptz.presets if camera.ptz else [])
            if item.token == preset_token
        ),
        None,
    )
    if not preset:
        return f"Preset {preset_token} not found on camera at {camera.xaddr}."
    try:
        camera.errors = None
        remove_preset(camera, profile_token, preset)
        _raise_camera_errors(camera)
        return (
            f"Successfully removed preset {preset_token} "
            f"from camera at {camera.xaddr}."
        )
    except Exception as ex:
        return (
            f"Failed to remove preset {preset_token} "
            f"from camera at {camera.xaddr}: {ex}"
        )


async def create_camera_preset_tour(
    ip_address: str,
    profile_token: str,
    tour_name: str = None,
) -> str:
    """Create a new empty PTZ preset tour."""
    try:
        camera = _query_camera(ip_address)
    except Exception as ex:
        return f"Failed to query camera at {ip_address}: {ex}"
    try:
        camera.errors = None
        existing_tokens = {
            tour.token for tour in (camera.ptz.tours if camera.ptz else [])
        }
        create_preset_tour(camera, profile_token)
        _raise_camera_errors(camera)
        get_preset_tours(camera, profile_token)
        _raise_camera_errors(
            camera,
            "Camera returned errors while refreshing tours",
        )
        new_tokens = [
            tour.token
            for tour in camera.ptz.tours
            if tour.token not in existing_tokens
        ]
        if not new_tokens:
            return (
                f"Tour created on camera at {camera.xaddr}, but could not "
                "determine its new token from the refreshed tour list."
            )
        new_token = new_tokens[0]
        if tour_name is not None:
            new_tour = next(
                item for item in camera.ptz.tours if item.token == new_token
            )
            new_tour.name = tour_name
            modify_preset_tour(camera, profile_token, new_tour)
            if camera.errors:
                raise Exception(
                    f"Tour {new_token} created, but failed to set its name: "
                    f"{camera.errors}"
                )
        name_note = f" named '{tour_name}'" if tour_name else ""
        return (
            f"Successfully created new preset tour {new_token}{name_note} "
            f"on camera at {camera.xaddr}."
        )
    except Exception as ex:
        return f"Failed to create preset tour for camera at {camera.xaddr}: {ex}"


async def set_camera_preset_tour(
    ip_address: str,
    profile_token: str,
    tour_token: str,
    tour_name: str = None,
    auto_start: bool = None,
    spots: list[dict] = None,
) -> str:
    """Update a preset tour's name, auto-start setting, and/or spots."""
    try:
        camera = _query_camera(ip_address)
    except Exception as ex:
        return f"Failed to query camera at {ip_address}: {ex}"
    tour = next(
        (
            item
            for item in (camera.ptz.tours if camera.ptz else [])
            if item.token == tour_token
        ),
        None,
    )
    if not tour:
        return f"Tour {tour_token} not found on camera at {camera.xaddr}."
    if tour_name is not None:
        tour.name = tour_name
    if auto_start is not None:
        tour.auto_start = auto_start
    if spots is not None:
        tour.spots = [
            TourSpot(
                preset_token=spot.get("preset_token"),
                stay_time=spot.get("stay_time"),
            )
            for spot in spots
        ]
    try:
        camera.errors = None
        modify_preset_tour(camera, profile_token, tour)
        _raise_camera_errors(camera)
        return (
            f"Successfully updated preset tour {tour_token} "
            f"on camera at {camera.xaddr}."
        )
    except Exception as ex:
        return (
            f"Failed to update preset tour {tour_token} "
            f"on camera at {camera.xaddr}: {ex}"
        )


async def remove_camera_preset_tour(
    ip_address: str,
    profile_token: str,
    tour_token: str,
) -> str:
    """Permanently remove a PTZ preset tour."""
    try:
        camera = _query_camera(ip_address)
    except Exception as ex:
        return f"Failed to query camera at {ip_address}: {ex}"
    tour = next(
        (
            item
            for item in (camera.ptz.tours if camera.ptz else [])
            if item.token == tour_token
        ),
        None,
    )
    if not tour:
        return f"Tour {tour_token} not found on camera at {camera.xaddr}."
    try:
        camera.errors = None
        remove_preset_tour(camera, profile_token, tour)
        _raise_camera_errors(camera)
        return (
            f"Successfully removed preset tour {tour_token} "
            f"from camera at {camera.xaddr}."
        )
    except Exception as ex:
        return (
            f"Failed to remove preset tour {tour_token} "
            f"from camera at {camera.xaddr}: {ex}"
        )


async def _operate_tour(
    camera_ptz_xaddr: str,
    camera_profile_token: str,
    camera_ptz_tour_token: str,
    camera_time_offset: int,
    operation: str,
) -> str:
    if not camera_ptz_xaddr:
        return MISSING_PTZ_XADDR
    camera = _command_camera(camera_ptz_xaddr, camera_time_offset)
    try:
        operate_preset_tour(
            camera,
            camera_profile_token,
            PresetTour(token=camera_ptz_tour_token),
            operation,
        )
        _raise_camera_errors(camera)
        action = "started" if operation == "Start" else "stopped"
        return (
            f"Successfully {action} preset tour {camera_ptz_tour_token} "
            f"on camera at {camera_ptz_xaddr}."
        )
    except Exception as ex:
        return (
            f"Failed to {operation.lower()} preset tour "
            f"{camera_ptz_tour_token} on camera at {camera_ptz_xaddr}: {ex}"
        )


async def start_camera_preset_tour(
    camera_ptz_xaddr: str,
    camera_profile_token: str,
    camera_ptz_tour_token: str,
    camera_time_offset: int,
) -> str:
    """Start a PTZ preset tour."""
    result = await _operate_tour(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_ptz_tour_token,
        camera_time_offset,
        "Start",
    )
    if result.startswith("Successfully"):
        return (
            result
            + " To stop it later, call stop_camera_preset_tour with these "
            f"exact values: camera_ptz_xaddr='{camera_ptz_xaddr}', "
            f"camera_profile_token='{camera_profile_token}', "
            f"camera_ptz_tour_token='{camera_ptz_tour_token}', "
            f"camera_time_offset={camera_time_offset}."
        )
    return result


async def stop_camera_preset_tour(
    camera_ptz_xaddr: str,
    camera_profile_token: str,
    camera_ptz_tour_token: str,
    camera_time_offset: int,
) -> str:
    """Stop a running PTZ preset tour."""
    return await _operate_tour(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_ptz_tour_token,
        camera_time_offset,
        "Stop",
    )


async def pan_tilt_camera(
    camera_ptz_xaddr: str,
    camera_profile_token: str,
    camera_time_offset: int,
    x: float,
    y: float,
) -> str:
    """Start continuous pan/tilt movement."""
    if not camera_ptz_xaddr:
        return MISSING_PTZ_XADDR
    camera = _command_camera(camera_ptz_xaddr, camera_time_offset)
    try:
        continuous_move(camera, camera_profile_token, x, y, 0)
        _raise_camera_errors(camera)
        return (
            f"Successfully started pan/tilt move on camera at "
            f"{camera_ptz_xaddr} (x={x}, y={y})."
        )
    except Exception as ex:
        return (
            f"Failed to start pan/tilt move on camera "
            f"at {camera_ptz_xaddr}: {ex}"
        )


async def zoom_camera(
    camera_ptz_xaddr: str,
    camera_profile_token: str,
    camera_time_offset: int,
    z: float,
) -> str:
    """Start continuous zoom movement."""
    if z == 0:
        return (
            "z must not be 0.0 - to stop an in-progress zoom, "
            "call stop_camera_zoom instead."
        )
    if not camera_ptz_xaddr:
        return MISSING_PTZ_XADDR
    camera = _command_camera(camera_ptz_xaddr, camera_time_offset)
    try:
        continuous_move(camera, camera_profile_token, 0, 0, z)
        _raise_camera_errors(camera)
        return (
            f"Successfully started zoom move on camera at "
            f"{camera_ptz_xaddr} (z={z})."
        )
    except Exception as ex:
        return f"Failed to start zoom move on camera at {camera_ptz_xaddr}: {ex}"


async def _stop_move(
    camera_ptz_xaddr: str,
    camera_profile_token: str,
    camera_time_offset: int,
    *,
    is_zoom: bool,
) -> str:
    if not camera_ptz_xaddr:
        return MISSING_PTZ_XADDR
    camera = _command_camera(camera_ptz_xaddr, camera_time_offset)
    movement = "zoom" if is_zoom else "pan/tilt"
    try:
        move_stop(camera, camera_profile_token, is_zoom=is_zoom)
        _raise_camera_errors(camera)
        return (
            f"Successfully stopped {movement} move "
            f"on camera at {camera_ptz_xaddr}."
        )
    except Exception as ex:
        return (
            f"Failed to stop {movement} move "
            f"on camera at {camera_ptz_xaddr}: {ex}"
        )


async def stop_camera_pan_tilt(
    camera_ptz_xaddr: str,
    camera_profile_token: str,
    camera_time_offset: int,
) -> str:
    """Stop continuous pan/tilt movement."""
    return await _stop_move(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_time_offset,
        is_zoom=False,
    )


async def stop_camera_zoom(
    camera_ptz_xaddr: str,
    camera_profile_token: str,
    camera_time_offset: int,
) -> str:
    """Stop continuous zoom movement."""
    return await _stop_move(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_time_offset,
        is_zoom=True,
    )
