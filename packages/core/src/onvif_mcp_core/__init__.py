"""Shared functionality for the ONVIF MCP server transports."""

from .audio import set_camera_audio_encoding, set_camera_audio_sample_rate
from .camera_queries import get_camera, get_cameras
from .device import change_camera_hostname, reboot_camera, sync_camera_time
from .tools import (
    register_audio_configuration_tools,
    register_device_management_tools,
    register_ptz_tools,
    register_video_configuration_tools,
)
from .video import (
    set_camera_video_bitrate,
    set_camera_video_frame_rate,
    set_camera_video_gov_length,
    set_camera_video_resolution,
)

__all__ = [
    "get_camera",
    "get_cameras",
    "change_camera_hostname",
    "reboot_camera",
    "sync_camera_time",
    "register_audio_configuration_tools",
    "register_device_management_tools",
    "register_ptz_tools",
    "register_video_configuration_tools",
    "set_camera_audio_encoding",
    "set_camera_audio_sample_rate",
    "set_camera_video_bitrate",
    "set_camera_video_frame_rate",
    "set_camera_video_gov_length",
    "set_camera_video_resolution",
]
