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
from onvif_mcp_core.camera_queries import (
    get_camera as get_camera_query,
    get_cameras as get_cameras_query,
)
from onvif_mcp_core.guidance import TOOL_GUIDANCE
from onvif_mcp_core.tools import (
    register_audio_configuration_tools,
    register_device_management_tools,
    register_ptz_tools,
    register_video_configuration_tools,
)


LOG_FILE = Path(__file__).parent / "camera_events.log"

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.WARNING,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

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
# DNS-rebinding protection stays enabled, but we explicitly allow the
# llama.cpp web UI's origin (10.1.1.2) alongside the usual localhost
# entries FastMCP would otherwise add automatically. Supplying our own
# transport_security here means FastMCP's auto-default (localhost-only)
# is skipped in favor of this one.
mcp = FastMCP(
    "sse-example",
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=["127.0.0.1:*", "localhost:*", "[::1]:*", "10.1.1.2:*", "10.1.1.1:*"],
        allowed_origins=[
            "http://127.0.0.1:*",
            "http://localhost:*",
            "http://[::1]:*",
            "http://10.1.1.2:*",
            "http://10.1.1.1:*",
        ],
    ),
)
register_video_configuration_tools(mcp)
register_audio_configuration_tools(mcp)
register_ptz_tools(mcp)
register_device_management_tools(mcp)

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


@mcp.tool(description=TOOL_GUIDANCE["get_camera"])
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
    return await get_camera_query(ip_address)

@mcp.tool(description=TOOL_GUIDANCE["get_cameras"])
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

    return await get_cameras_query()

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
    uvicorn.run(app, host="0.0.0.0", port=8000)

if __name__ == "__main__":
    main()
