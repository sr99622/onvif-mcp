"""Registration of camera query tools shared by all MCP transports."""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP

from .audio import set_camera_audio_encoding, set_camera_audio_sample_rate
from .camera_queries import get_camera as query_camera
from .camera_queries import get_cameras as query_cameras
from .camera_queries import get_cameras_by_adapter
from .device import change_camera_hostname, reboot_camera, sync_camera_time
from .guidance import TOOL_GUIDANCE
from .streaming import get_snapshot, get_web_player_url
from .video import (
    set_camera_video_bitrate,
    set_camera_video_frame_rate,
    set_camera_video_gov_length,
    set_camera_video_resolution,
)
from .ptz import (
    create_camera_preset_tour,
    goto_camera_preset,
    pan_tilt_camera,
    remove_camera_preset,
    remove_camera_preset_tour,
    set_camera_preset,
    set_camera_preset_tour,
    start_camera_preset_tour,
    stop_camera_pan_tilt,
    stop_camera_preset_tour,
    stop_camera_zoom,
    zoom_camera,
)


def _register_tool(mcp: FastMCP, tool) -> None:
    """Register a shared function with its canonical MCP description."""
    mcp.tool(description=TOOL_GUIDANCE[tool.__name__])(tool)


def register_video_configuration_tools(mcp: FastMCP) -> None:
    """Register video configuration tools shared by all MCP transports."""
    _register_tool(mcp, set_camera_video_resolution)
    _register_tool(mcp, set_camera_video_frame_rate)
    _register_tool(mcp, set_camera_video_bitrate)
    _register_tool(mcp, set_camera_video_gov_length)


def register_audio_configuration_tools(mcp: FastMCP) -> None:
    """Register audio configuration tools shared by all MCP transports."""
    _register_tool(mcp, set_camera_audio_encoding)
    _register_tool(mcp, set_camera_audio_sample_rate)


def register_ptz_tools(mcp: FastMCP) -> None:
    """Register PTZ tools shared by all MCP transports."""
    for tool in (
        goto_camera_preset,
        set_camera_preset,
        remove_camera_preset,
        create_camera_preset_tour,
        set_camera_preset_tour,
        remove_camera_preset_tour,
        start_camera_preset_tour,
        stop_camera_preset_tour,
        pan_tilt_camera,
        zoom_camera,
        stop_camera_pan_tilt,
        stop_camera_zoom,
    ):
        _register_tool(mcp, tool)


def register_device_management_tools(mcp: FastMCP) -> None:
    """Register device-management tools shared by all MCP transports."""
    _register_tool(mcp, change_camera_hostname)
    _register_tool(mcp, sync_camera_time)
    _register_tool(mcp, reboot_camera)


def register_camera_query_tools(mcp: FastMCP) -> None:
    """Register camera query tools shared by all MCP transports."""
    _register_tool(mcp, query_camera)
    _register_tool(mcp, query_cameras)
    _register_tool(mcp, get_cameras_by_adapter)


def register_streaming_tools(mcp: FastMCP) -> None:
    """Register streaming tools shared by all MCP transports."""
    _register_tool(mcp, get_web_player_url)
    _register_tool(mcp, get_snapshot)
