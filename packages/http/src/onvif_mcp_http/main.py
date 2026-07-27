from __future__ import annotations

import asyncio
import os
import sys
import json
from datetime import datetime
import logging
from pathlib import Path
import uvicorn
from importlib.metadata import version as get_installed_version
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import StreamingResponse
from starlette.types import ASGIApp, Receive, Scope, Send
from pydantic import BaseModel
from mcp.server.fastmcp import FastMCP, Context
from mcp.server.elicitation import AcceptedElicitation, DeclinedElicitation, CancelledElicitation
from mcp.server.transport_security import TransportSecuritySettings
from libonvif.utils.adapters import find_adapters
from libonvif.utils.server import EventServer
from libonvif.utils.subscriber import SubscriptionManager
from libonvif.devices.camera import Camera, discover, get_camera_by_ip, set_hostname, \
        set_video_encoder_configuration, set_audio_encoder_configuration, camera_from_json, refresh_camera, \
        goto_preset, continuous_move, move_stop, get_local_date_and_time, set_system_date_and_time, \
        get_time_offset, set_preset, get_presets, remove_preset, create_preset_tour, modify_preset_tour, \
        remove_preset_tour, operate_preset_tour, get_preset_tours, reboot
from libonvif.datastructures.capabilities import Capabilities, PTZCapabilities
from libonvif.datastructures.ptz import PTZPreset, PresetTour, TourSpot
from libonvif.utils.serialization import to_dict


LOG_FILE = Path(__file__).parent / "camera_events.log"

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.WARNING,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

def get_camera_credentials(camera: Camera) -> None:
    camera.username = os.environ.get("CAMERA_USERNAME", "")
    camera.password = os.environ.get("CAMERA_PASSWORD", "")

def on_error(xaddr: str, ex: Exception) -> None:
    logger.debug(f"error: {xaddr} - {ex}")

def camera_filled(camera: Camera) -> None:
    logger.debug(f"Camera Filled: {camera.hostname} : {camera.device_information.serial_number}")

# --- Event listener integration ---
# Bridges the standalone motion_watcher.py prototype (packages/sse) into
# this server, generalized to "event listener" since future work will
# subscribe to event topics beyond just motion. All cameras share ONE
# EventServer (ONVIF push events are just an HTTP POST to whatever URL a
# camera was told during Subscribe - nothing about the protocol requires
# a separate listener per camera), created on first use by whichever
# camera adds its first subscribed event. Each camera gets its own
# SubscriptionManager, since subscriptions (and their resubscribe
# timers) are inherently per-camera.

EVENT_SERVER_PORT = int(os.environ.get("EVENT_SERVER_PORT", "8856"))
SNAPSHOT_DIR = Path(__file__).parent / "snapshots"
OPENCLAW_HOOK_URL = os.environ.get("OPENCLAW_HOOK_URL", "http://127.0.0.1:18789/hooks/camera-motion")
OPENCLAW_HOOK_TOKEN = os.environ.get("OPENCLAW_HOOK_TOKEN", "")
# Home-relative subdirectory OpenClaw uses as its own workspace folder for
# camera snapshots/descriptions. Motion-event snapshots are now written
# directly here by _on_event_listener_event (see CAMERA_EVENTS_DIR below)
# instead of camera.py's own SNAPSHOT_DIR, so there is exactly one capture
# per event, taken at alarm time, and OpenClaw's `read` tool loads those
# same bytes rather than re-querying the camera itself several seconds
# later once its own reasoning gets around to a download step. OpenClaw's
# own tools already resolve "~" against this same machine's home
# directory (confirmed via trajectory review), so using "~" in both the
# path we write to and the path we tell OpenClaw to read needs no
# $WORKSPACE_DIR substitution or other coordination.
OPENCLAW_SNAPSHOT_SUBDIR = "onvif-events"
CAMERA_EVENTS_DIR = Path(os.path.expanduser(f"~/{OPENCLAW_SNAPSHOT_SUBDIR}"))

# The one shared EventServer instance, or None until the first camera
# adds a subscribed event. Created by _ensure_camera_subscription_entry.
_event_server = None

# Per-camera state, keyed by IP address: {"camera": Camera, "subscription_manager": SubscriptionManager}.
# Populated lazily, the first time a given camera's subscriptions are
# touched. The Camera object here is queried once and then reused
# across resyncs (its subscription_references list is what actually
# tracks live ONVIF subscriptions) - it is NOT refreshed automatically,
# so if a camera's IP/credentials/xaddr genuinely change, its entry here
# would need to be rebuilt (not handled yet - a later concern).
_camera_subscriptions: dict[str, dict] = {}

# In-memory store, keyed by camera IP address, for the set of event
# topics the user wants that camera marked for observation on. Kept
# deliberately separate from _event_server/_camera_subscriptions above:
# those track live ONVIF subscription state (built lazily, in memory
# only), while this needs to hold user preferences for potentially many
# cameras (nothing stored on the Camera object itself persists across
# get_cameras() calls, which rediscovers cameras fresh every time).
#
# This does not survive a server restart - it is reset to empty on
# every process start.
_subscribed_events_by_camera: dict[str, list[str]] = {}


# DNS-rebinding protection stays enabled, but we explicitly allow the
# llama.cpp web UI's origin (10.1.1.2) alongside the usual localhost
# entries FastMCP would otherwise add automatically. Supplying our own
# transport_security here means FastMCP's auto-default (localhost-only)
# is skipped in favor of this one.
mcp = FastMCP(
    "sse-example",
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=["127.0.0.1:*", "localhost:*", "[::1]:*", "10.1.1.2:*"],
        allowed_origins=[
            "http://127.0.0.1:*",
            "http://localhost:*",
            "http://[::1]:*",
            "http://10.1.1.2:*",
        ],
    ),
)

class TripTypeResponse(BaseModel):
    value: str

@mcp.tool()
async def add(a: int, b: int) -> int:
    """Add two numbers together."""
    return a + b

@mcp.tool()
async def example_elicit_tool(context: Context) -> str:
    """
    Example tool that asks the user a question via MCP elicitation, to
    test whether a given client (e.g. llama.cpp's web UI) implements the
    client side of the elicitation flow - Claude Desktop returned
    "Method not found" when this was tried there.
    """
    result = await context.elicit(
        message="What type of trip are you planning? Options: business, leisure, family, adventure",
        schema=TripTypeResponse,
    )
    if isinstance(result, AcceptedElicitation):
        return result.data.value
    elif isinstance(result, DeclinedElicitation):
        return "DECLINED"
    elif isinstance(result, CancelledElicitation):
        return "CANCELLED"
    return "INVALID RESPONSE"

@mcp.tool()
async def get_camera_mcp_version() -> str:
    """
    Get the version of the camera application, along with the version of the
    installed libonvif package it depends on.

    Returns:
        A JSON string with two fields:
            camera_mcp_version: version derived from the pyproject.toml file.
            libonvif_version: version of the installed libonvif package,
                               read via importlib.metadata.
    """

    camera_mcp_version = None
    current_file = Path(__file__)
    filename = Path(current_file.parent.parent.parent) / "pyproject.toml"
    with open(filename, "r") as f:
        for line in f:
            if line.startswith("version"):
                camera_mcp_version = line.split("=")[1].strip().strip('"')
                logger.debug(f"Found camera_mcp version: {camera_mcp_version}")
                break

    try:
        libonvif_version = get_installed_version("libonvif")
    except Exception as e:
        logger.error(f"Failed to get libonvif version: {e}")
        libonvif_version = None

    return json.dumps({
        "camera_mcp_version": camera_mcp_version,
        "libonvif_version": libonvif_version,
    }, indent=4)


@mcp.tool()
async def get_camera(ip_address: str) -> str:
    """
    Query a camera by IP address and return its full state as a JSON
    string. Credentials come from the CAMERA_USERNAME/CAMERA_PASSWORD
    environment variables - the same pattern used by the camera MCP
    server. Added here as a test of whether real camera data (a large,
    deeply nested JSON payload) flows correctly through the
    streamable-http transport and this server's CORS/session setup, not
    just the trivial add() tool above.

    Args:
        ip_address: The IP address of the camera to query.

    Returns:
        The camera's JSON representation, as produced by Camera.to_json().
    """
    camera = get_camera_by_ip(ip_address, os.environ.get("CAMERA_USERNAME", ""), os.environ.get("CAMERA_PASSWORD", ""))
    return camera.to_json()

@mcp.tool()
async def get_cameras() -> str:
    """
    Discover cameras on the local network and return lightweight summaries.

    Each summary contains only the fields an agent typically needs to reason
    about — hostname, device info, profile tokens, encoder config (from the
    first/primary profile), PTZ presets, tours, snapshot & stream URIs, and
    time offset. All the noisy ONVIF boilerplate (codec resolution lists,
    multicast settings, SOAP addresses, network interface details, imaging
    options, etc.) is stripped away.

    Returns:
        A delimited string containing a summary dict for each camera found on
        the local network. Each camera's summary is separated by "\n--\n".
    """

    ip_address = "0.0.0.0"
    if sys.platform == "win32":
        ips = find_adapters()
        if len(ips):
            ip_address = ips[0]
            logger.debug(f"host ip addresses: {ips}")

    cameras = discover(ip_address,
                       get_camera_credentials,
                       on_error=on_error,
                       camera_filled=camera_filled,
                       use_threads=True)

    logger.debug(f"Discovered {len(cameras)} camera(s)")

    summaries = []
    for camera in cameras:
        # Serialize once via the same codec used by Camera.to_json(), then
        # project down to just the fields this summary needs. Every field
        # below is read with `.get(key) or default` rather than
        # `.get(key, default)`, since to_dict() always includes every
        # dataclass field explicitly (even when its value is None) - the
        # dict.get default only kicks in for a missing key, not a present
        # key holding None, so relying on it here would silently produce
        # None instead of the intended fallback.
        try:
            data = to_dict(camera)
        except Exception as e:
            logger.error(f"Failed to serialize camera at {getattr(camera, 'xaddr', '?')}: {e}")
            continue

        dev = data.get("device_information") or {}
        hostname_obj = data.get("hostname") or {}
        xaddr = data.get("xaddr") or ""
        ip_addr = xaddr.split("://", 1)[1].split("/", 1)[0] if "://" in xaddr else ""

        profiles = []
        for p in data.get("profiles") or []:
            video_encoder = p.get("video_encoder") or {}
            rate_control = video_encoder.get("rate_control") or {}
            audio_encoder = p.get("audio_encoder") or {}
            profiles.append({
                "token": p.get("token") or "",
                "name": p.get("name") or "",
                "video_encoder": {
                    "encoding": video_encoder.get("encoding") or "",
                    "resolution": video_encoder.get("resolution") or "",
                    "frame_rate_limit": rate_control.get("frame_rate_limit") or 0,
                    "bitrate_limit": rate_control.get("bitrate_limit") or 0,
                    "gov_length": video_encoder.get("gov_length") or 0
                },
                "audio_encoder": {
                    "encoding": audio_encoder.get("encoding") or "",
                    "sample_rate": audio_encoder.get("sample_rate") or 0
                },
                "stream_uri": p.get("stream_uri") or "",
                "snapshot_uri": p.get("snapshot_uri") or ""
            })

        ptz = data.get("ptz") or {}

        presets = [
            {"token": pr.get("token") or "", "name": pr.get("name") or ""}
            for pr in ptz.get("presets") or []
        ]

        tours = []
        for t in ptz.get("tours") or []:
            tour_status = t.get("status") or {}
            tours.append({
                "token": t.get("token") or "",
                "name": t.get("name") or "",
                "status": tour_status.get("state") or "",
                "spot_count": len(t.get("spots") or [])
            })

        ptz_status = ptz.get("status") or {}
        ptz_st = {
            "pan_tilt": ptz_status.get("pan_tilt_status") or "",
            "zoom": ptz_status.get("zoom_status") or ""
        }

        caps = data.get("capabilities") or {}
        ptz_caps = caps.get("ptz") or {}
        ptz_xaddr = ptz_caps.get("xaddr") or ""

        event_props = data.get("event_properties") or {}
        event_topics = event_props.get("topic_set") or []

        summary = {
            "hostname": hostname_obj.get("name") or data.get("name") or "",
            "ip_address": ip_addr,
            "manufacturer": dev.get("manufacturer") or "",
            "model": dev.get("model") or "",
            "firmware_version": dev.get("firmware_version") or "",
            "serial_number": dev.get("serial_number") or "",
            "profiles": profiles,
            "ptz_presets": presets,
            "ptz_tours": tours,
            "ptz_status": ptz_st,
            "ptz_xaddr": ptz_xaddr,
            "event_topics": event_topics,
            "subscribed_events": list(_subscribed_events_by_camera.get(ip_addr, [])),
            "time_offset": int(data.get("time_offset") or 0)
        }
        summaries.append(json.dumps(summary))

    return "\n--\n".join(summaries)

class PrivateNetworkAccessMiddleware:
    """
    Adds the Access-Control-Allow-Private-Network header some Chromium
    browsers require (in addition to normal CORS) before allowing a page
    served from a non-loopback origin to fetch a loopback address like
    127.0.0.1. Without this, the browser can reject the request before
    it ever reaches this server, showing up client-side as a generic
    "Failed to fetch" with no server-side log at all.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                headers = message.setdefault("headers", [])
                headers.append((b"access-control-allow-private-network", b"true"))
            await send(message)

        await self.app(scope, receive, send_wrapper)


async def event_stream(request: Request) -> StreamingResponse:
    """
    Plain Server-Sent Events endpoint, independent of the MCP protocol -
    just a raw text/event-stream that emits one tick every 5 seconds.
    Built to test/observe the SSE mechanism itself directly (e.g. via
    curl -N http://127.0.0.1:8000/events, or a browser EventSource),
    separate from anything MCP-specific like tool calls or sessions.
    """

    async def generator():
        count = 0
        try:
            while True:
                await asyncio.sleep(5)
                count += 1
                yield f"data: tick {count} at {datetime.now().isoformat()}\n\n"
        except asyncio.CancelledError:
            pass

    return StreamingResponse(generator(), media_type="text/event-stream")


def main():
    app = mcp.streamable_http_app()
    app.add_route("/events", event_stream, methods=["GET"])
    app.add_middleware(PrivateNetworkAccessMiddleware)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
        # The streamable-http transport returns a session ID in a custom
        # response header on the initialize call, and expects it echoed
        # back on every subsequent request. Browsers hide custom response
        # headers from JS by default unless the server explicitly exposes
        # them via CORS - without this, the client never sees the session
        # ID and every follow-up request gets rejected as missing one.
        expose_headers=["mcp-session-id"],
    )
    # Defaults: host=127.0.0.1, port=8000, path=/mcp
    # -> server listens at http://127.0.0.1:8000/mcp
    uvicorn.run(app, host="127.0.0.1", port=8000)

if __name__ == "__main__":
    main()
