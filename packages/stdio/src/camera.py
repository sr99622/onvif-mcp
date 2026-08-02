from __future__ import annotations

import base64
import json
import logging
import time
from datetime import datetime
from importlib.metadata import version as get_installed_version
from pathlib import Path
from libonvif.utils.server import EventServer
from libonvif.utils.subscriber import SubscriptionManager
from libonvif.devices.camera import Camera, get_camera_by_ip, \
        camera_from_json, refresh_camera
from mcp.server.fastmcp import FastMCP, Context
from mcp.server.elicitation import AcceptedElicitation, DeclinedElicitation, CancelledElicitation
from pydantic import BaseModel
import os
import sys
import webbrowser
import niquests as requests
from niquests.auth import HTTPDigestAuth
import re
import shutil
import subprocess
from typing import Any
from onvif_mcp_core.audio import (
    set_camera_audio_encoding as set_camera_audio_encoding_core,
    set_camera_audio_sample_rate as set_camera_audio_sample_rate_core,
)
from onvif_mcp_core.video import (
    set_camera_video_bitrate as set_camera_video_bitrate_core,
    set_camera_video_frame_rate as set_camera_video_frame_rate_core,
    set_camera_video_gov_length as set_camera_video_gov_length_core,
    set_camera_video_resolution as set_camera_video_resolution_core,
)
from onvif_mcp_core.ptz import (
    create_camera_preset_tour as create_camera_preset_tour_core,
    goto_camera_preset as goto_camera_preset_core,
    pan_tilt_camera as pan_tilt_camera_core,
    remove_camera_preset as remove_camera_preset_core,
    remove_camera_preset_tour as remove_camera_preset_tour_core,
    set_camera_preset as set_camera_preset_core,
    set_camera_preset_tour as set_camera_preset_tour_core,
    start_camera_preset_tour as start_camera_preset_tour_core,
    stop_camera_pan_tilt as stop_camera_pan_tilt_core,
    stop_camera_preset_tour as stop_camera_preset_tour_core,
    stop_camera_zoom as stop_camera_zoom_core,
    zoom_camera as zoom_camera_core,
)
from onvif_mcp_core.device import (
    change_camera_hostname as change_camera_hostname_core,
    reboot_camera as reboot_camera_core,
    sync_camera_time as sync_camera_time_core,
)
from onvif_mcp_core.camera_queries import get_adapters as get_adapters_query
from onvif_mcp_core.guidance import TOOL_GUIDANCE
from onvif_mcp_core.streaming import get_web_player_url as get_web_player_url_core
from onvif_mcp_core.tools import (
    register_audio_configuration_tools,
    register_camera_query_tools,
    register_device_management_tools,
    register_ptz_tools,
    register_streaming_tools,
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

mcp = FastMCP("onvif-mcp")
register_video_configuration_tools(mcp)
register_audio_configuration_tools(mcp)
register_ptz_tools(mcp)
register_device_management_tools(mcp)
register_camera_query_tools(mcp)
register_streaming_tools(mcp)

@mcp.tool(description=TOOL_GUIDANCE["get_adapters"])
async def get_adapters() -> str:
    """Return a list of available active network adapters.

    Returns:
        A delimited string containing the IP address of each active adapter,
        one per line, separated by "\n--\n".
    """
    return await get_adapters_query()

USER_AGENT = "onvif-mcp-app/1.0"

class TripTypeResponse(BaseModel):
    value: str

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
OPENCLAW_CHAT_SESSION_KEY = "agent:main:main"

@mcp.tool()
async def send_message_to_openclaw_chat(
    message: str,
    session_key: str = OPENCLAW_CHAT_SESSION_KEY,
) -> str:
    """
    Inject an assistant message into an OpenClaw WebChat session.

    Args:
        message:
            Text to display in the OpenClaw chat.

        session_key:
            OpenClaw session receiving the message. The normal main-agent
            session is commonly "agent:main:main".

    Returns:
        A status message describing the result.

    Raises:
        ValueError:
            If message or session_key is empty.

        RuntimeError:
            If the OpenClaw CLI cannot be found or the RPC call fails.
    """
    message = message.strip()
    session_key = session_key.strip()

    if not message:
        raise ValueError("message cannot be empty")

    if not session_key:
        raise ValueError("session_key cannot be empty")

    openclaw_executable = shutil.which("openclaw")

    if openclaw_executable is None:
        raise RuntimeError("The openclaw executable was not found in PATH")

    params = json.dumps(
        {
            "sessionKey": session_key,
            "message": message,
        }
    )

    command = [
        openclaw_executable,
        "gateway",
        "call",
        "chat.inject",
        "--params",
        params,
        "--json",
    ]

    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("OpenClaw chat.inject timed out") from exc
    except OSError as exc:
        raise RuntimeError(
            f"Unable to run the OpenClaw CLI: {exc}"
        ) from exc

    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        stdout = completed.stdout.strip()

        details = stderr or stdout or "no diagnostic output"

        raise RuntimeError(
            f"OpenClaw chat.inject failed with exit code "
            f"{completed.returncode}: {details}"
        )

    try:
        response: Any = json.loads(completed.stdout)
    except json.JSONDecodeError:
        response = completed.stdout.strip()

    return (
        f"Message injected into OpenClaw session "
        f"{session_key}: {response}"
    )

def _build_snapshot_filename(camera_ip: str, event_type: str) -> str:
    """
    Shared naming scheme for every snapshot/marker file the event
    listener produces, so files can be found by camera, event type, and
    time without needing to open them:

        {camera_ip with dashes instead of dots}_{event_type}_{timestamp}.jpg

    e.g. "10-1-1-77_motion_true_20260718T215035.jpg"
    """
    safe_ip = camera_ip.replace(".", "-")
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    return f"{safe_ip}_{event_type}_{timestamp}.jpg"


def _fetch_motion_snapshot(camera: Camera, filename: str, directory: Path = SNAPSHOT_DIR):
    """
    Download the given camera's current snapshot as a JPEG file, saved
    under the given filename in the given directory (SNAPSHOT_DIR by
    default). Returns the saved Path, or None on failure.

    Motion-event calls from _on_event_listener_event pass
    directory=CAMERA_EVENTS_DIR instead, so the one fetch this function
    performs lands directly where OpenClaw will read it from - see the
    comment on CAMERA_EVENTS_DIR above for why that matters.
    """
    snapshot_uri = camera.profiles[0].snapshot_uri
    try:
        response = requests.get(
            snapshot_uri,
            auth=HTTPDigestAuth(os.environ.get("CAMERA_USERNAME", ""), os.environ.get("CAMERA_PASSWORD", "")),
            timeout=10,
        )
        response.raise_for_status()
    except Exception as e:
        logger.error(f"Failed to fetch motion snapshot: {e}")
        return None

    directory.mkdir(exist_ok=True, parents=True)
    path = directory / filename
    path.write_bytes(response.content)
    logger.debug(f"Saved motion snapshot to {path}")
    return path


def _save_empty_motion_marker(filename: str):
    """
    Save a 0-byte marker file recording a motion-ended (State: false)
    event without fetching a real image for it.
    """
    SNAPSHOT_DIR.mkdir(exist_ok=True)
    path = SNAPSHOT_DIR / filename
    path.touch()
    logger.debug(f"Recorded empty motion marker at {path}")
    return path


def _notify_openclaw_of_motion(camera_ip: str, filename: str) -> None:
    """
    POST to OpenClaw's /hooks/camera-motion endpoint (a named hook mapping
    configured in openclaw.json, NOT the generic /hooks/agent path),
    telling the agent exactly what to do and where to find the snapshot
    and description - naming the exact tools and paths up front, rather
    than leaving the agent to rediscover a working sequence through
    trial and error on every motion event (get_snapshot_image_base64_encoded
    and the browser tool both proved unusable to it in earlier testing).

    Does NOT ask OpenClaw to fetch the snapshot itself. The caller
    (_on_event_listener_event) already wrote it directly to
    CAMERA_EVENTS_DIR (a real "~/onvif-events" path on this same
    machine) at alarm time, via _fetch_motion_snapshot. Trajectory review
    (2026-07-22, 5 clean runs) showed OpenClaw's own
    camera__download_snapshot_to_file step re-queries the camera's live
    snapshot URL again, ~4.5s+ after the alarm on average once its model
    reasoning gets around to calling it - since that endpoint returns
    whatever the camera sees at request time, not a buffered frame from
    the alarm, that second fetch can be a materially different moment
    than the one that actually triggered the event (confirmed visually:
    consecutive live snapshots 5s apart showed a clearly different pose).
    Telling OpenClaw the file already exists and to just `read` it
    removes that second fetch entirely, so the image it describes is the
    same one captured at alarm time. This also removes one full tool
    round-trip (and its ~4.5s model reasoning step) from every
    notification, on top of the earlier camera__get_camera removal.

    Requires an openclaw.json hooks.mappings entry like:

        {
          "id": "camera-motion",
          "match": { "path": "camera-motion" },
          "action": "agent",
          "wakeMode": "now",
          "name": "Camera Motion",
          "messageTemplate": "{{payload.message}}",
          "allowUnsafeExternalContent": true
        }

    allowUnsafeExternalContent must live in this mapping config, NOT in
    the JSON body we send: normalizeAgentPayload() (the generic
    /hooks/agent request parser) doesn't recognize that field at all, so
    sending it directly in our payload was silently dropped - confirmed
    by trajectory review showing the SECURITY NOTICE wrapper still
    present after we started sending it. Worse, /hooks/agent and
    /hooks/wake are special-cased in the request router and always
    return before hooks.mappings is ever consulted, so no mapping -
    including one matched by source rather than path - can apply to
    those two paths regardless of config. A mapped path is the only way
    to reach allowUnsafeExternalContent at all.

    Without it, OpenClaw wraps this message in a SECURITY NOTICE +
    EXTERNAL_UNTRUSTED_CONTENT boundary (since hook requests default to
    externalContentSource: "webhook"), telling the model not to follow
    instructions embedded in it - directly undermining the explicit
    numbered steps below. We control both the sender (this script) and
    the content (our own instructions), so this isn't actually untrusted
    third-party content; it's just labeled that way by default. Batch
    trajectory review showed the majority of sampled motion-event runs
    called get_snapshot_image_base64_encoded anyway - the exact tool
    step 1 explicitly says not to use - despite that instruction being
    present in every one of those runs, so this is a hypothesis to test
    against fresh, controlled events, not a confirmed fix.
    """
    file_path = f"~/{OPENCLAW_SNAPSHOT_SUBDIR}/{filename}"
    description_path = f"~/{OPENCLAW_SNAPSHOT_SUBDIR}/{Path(filename).stem}.txt"
    payload = {
        "message": (
            f"Motion detected on the camera at {camera_ip}. A snapshot has "
            f"already been saved to exactly \"{file_path}\" - it was captured "
            f"at the moment of the alarm, so use it as-is. Do the following:\n"
            f"1. Call read on \"{file_path}\" to view the image.\n"
            f"2. Write a brief description of what you see using the write "
            f"tool, saving it to exactly \"{description_path}\" as plain "
            f"text (just the description itself, no extra formatting).\n"
            f"3. Call camera__send_message_to_openclaw_chat with message set to "
            f"exactly that same description.\n"
            "Do not call camera__get_camera, camera__download_snapshot_to_file, "
            "or any other camera tool to fetch or look up the snapshot - it is "
            "already saved at the path above. Do not use "
            "get_snapshot_image_base64_encoded or the browser tool for this - "
            "go directly to read."
        ),
    }
    try:
        response = requests.post(
            OPENCLAW_HOOK_URL,
            json=payload,
            headers={"Authorization": f"Bearer {OPENCLAW_HOOK_TOKEN}"},
            timeout=10,
        )
        response.raise_for_status()
        logger.debug(f"Notified OpenClaw: {response.json()}")
    except Exception as e:
        logger.error(f"Failed to notify OpenClaw: {e}")


def _ensure_camera_subscription_entry(ip_address: str) -> dict:
    """
    Ensure the shared EventServer exists (starting it on the very first
    call across any camera) and this camera's own SubscriptionManager
    exists (creating it, and querying the camera fresh, the first time
    this particular camera is touched). Returns the _camera_subscriptions
    entry for this camera.
    """
    global _event_server

    if _event_server is None:
        _event_server = EventServer("0.0.0.0", EVENT_SERVER_PORT, _on_event_listener_event)
        _event_server.start()

    if ip_address not in _camera_subscriptions:
        camera = get_camera_by_ip(
            ip_address,
            os.environ.get("CAMERA_USERNAME", ""),
            os.environ.get("CAMERA_PASSWORD", ""),
        )
        _camera_subscriptions[ip_address] = {
            "camera": camera,
            "subscription_manager": SubscriptionManager(camera),
        }

    return _camera_subscriptions[ip_address]


def _subscribe_camera_event_topic(ip_address: str, event_topic: str) -> None:
    """
    Subscribe a camera to a single ONVIF event topic, mirroring the real
    ONVIF Subscribe operation directly - it does not touch any of the
    camera's other active push subscriptions.
    """
    entry = _ensure_camera_subscription_entry(ip_address)
    camera = entry["camera"]
    subscription_manager = entry["subscription_manager"]

    subscription_manager.subscribe_push_event(camera, "0.0.0.0", EVENT_SERVER_PORT, event_topic)


def _unsubscribe_camera_events(ip_address: str) -> None:
    """
    Unsubscribe a camera from ALL of its ONVIF push subscriptions,
    mirroring the real ONVIF Unsubscribe operation directly - ONVIF has
    no operation to target a single topic while leaving others active,
    so this always clears everything for the camera at once.
    """
    entry = _ensure_camera_subscription_entry(ip_address)
    camera = entry["camera"]
    subscription_manager = entry["subscription_manager"]

    subscription_manager.unsubscribe_events(camera)


def _on_event_listener_event(alarms: list[dict]) -> None:
    """
    Callback invoked by EventServer's background thread on every incoming
    ONVIF event, from any camera - all cameras share this one EventServer,
    so this looks up which camera an event actually came from via its
    ip_address field (present on every parsed alarm) against
    _camera_subscriptions, rather than assuming a single fixed camera.

    Still only ACTS on VideoSource/MotionAlarm for now, even though a
    camera may genuinely be subscribed to other topics too (subscribing
    itself is already fully general via _subscribe_camera_event_topic
    above) - generalizing this handling logic to other topics is a
    separate, later step. Events on any other topic are received here
    but currently just ignored.

    State: "true" (real motion) saves a real local snapshot and notifies
    OpenClaw. State: "false" (motion ended) only records a 0-byte local
    marker file - no OpenClaw notification, since spending an agent run
    on "motion stopped" would reintroduce noise.
    """
    for alarm in alarms:
        logger.debug(f"Event listener event: {alarm}")

        camera_ip = alarm.get("ip_address")
        entry = _camera_subscriptions.get(camera_ip)
        if not entry:
            logger.error(f"Received event for camera at {camera_ip}, which has no tracked subscription; ignoring.")
            continue

        topic = alarm.get("topic")
        state = alarm.get("data", {}).get("State")
        logger.info(f"Alarm received: camera={camera_ip} topic={topic} state={state}")

        if topic != "VideoSource/MotionAlarm":
            continue

        camera = entry["camera"]
        is_motion = str(state).lower() == "true"
        event_type = "motion_true" if is_motion else "motion_false"
        filename = _build_snapshot_filename(camera_ip, event_type)

        if is_motion:
            pull_start = time.perf_counter()
            _fetch_motion_snapshot(camera, filename, directory=CAMERA_EVENTS_DIR)
            pull_elapsed_s = time.perf_counter() - pull_start
            logger.info(
                f"Snapshot pull timing: camera={camera_ip} filename={filename} "
                f"elapsed={pull_elapsed_s:.3f}s"
            )

            notify_start = time.perf_counter()
            _notify_openclaw_of_motion(camera_ip, filename)
            notify_elapsed_s = time.perf_counter() - notify_start
            logger.info(
                f"OpenClaw notify timing: camera={camera_ip} filename={filename} "
                f"elapsed={notify_elapsed_s:.3f}s"
            )
        else:
            _save_empty_motion_marker(filename)

def list_files(directory):
    """Recursively list all files in a directory."""
    for root, _, files in os.walk(directory):
        for file in files:
            yield os.path.join(root, file)

@mcp.tool()
def grep_search(pattern, directory, fileExtension=None):
    """Search for a regex pattern in files under a directory."""
    results = []

    # Validate directory
    if not os.path.isdir(directory):
        return {"error": f"Directory not found: {directory}"}

    try:
        regex = re.compile(pattern, re.IGNORECASE)
    except re.error as e:
        return {"error": f"Invalid regex: {e}"}

    try:
        for file_path in list_files(directory):
            if fileExtension and not file_path.endswith(fileExtension):
                continue

            try:
                with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                    for line_num, line in enumerate(f, start=1):
                        if regex.search(line):
                            results.append({
                                "file": file_path,
                                "lineNum": line_num,
                                "line": line.strip()
                            })
            except (OSError, UnicodeDecodeError):
                # Skip unreadable files
                continue

    except Exception as e:
        return {"error": f"Search failed: {e}"}

    return {"matches": results}

@mcp.tool()
async def example_async_tool(context: Context) -> str:
    """
    Example async tool that asks the user a question via MCP elicitation,
    to experiment with the elicitation flow (server -> client -> user ->
    client -> server) as a building block for eventually responding to
    camera events interactively.
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
    filename = Path(current_file.parent.parent) / "pyproject.toml"
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

@mcp.tool(description=TOOL_GUIDANCE["set_camera_video_resolution"])
async def set_camera_video_resolution(ip_address: str, profile_token: str, resolution: str) -> str:
    return await set_camera_video_resolution_core(
        ip_address,
        profile_token,
        resolution,
    )

@mcp.tool(description=TOOL_GUIDANCE["set_camera_video_frame_rate"])
async def set_camera_video_frame_rate(ip_address: str, profile_token: str, frame_rate_limit: int) -> str:
    return await set_camera_video_frame_rate_core(
        ip_address,
        profile_token,
        frame_rate_limit,
    )

@mcp.tool(description=TOOL_GUIDANCE["set_camera_video_bitrate"])
async def set_camera_video_bitrate(ip_address: str, profile_token: str, bitrate_limit: int) -> str:
    return await set_camera_video_bitrate_core(
        ip_address,
        profile_token,
        bitrate_limit,
    )

@mcp.tool(description=TOOL_GUIDANCE["set_camera_video_gov_length"])
async def set_camera_video_gov_length(ip_address: str, profile_token: str, gov_length: int) -> str:
    return await set_camera_video_gov_length_core(
        ip_address,
        profile_token,
        gov_length,
    )

@mcp.tool(description=TOOL_GUIDANCE["set_camera_audio_encoding"])
async def set_camera_audio_encoding(ip_address: str, profile_token: str, encoding: str) -> str:
    return await set_camera_audio_encoding_core(
        ip_address,
        profile_token,
        encoding,
    )

@mcp.tool(description=TOOL_GUIDANCE["set_camera_audio_sample_rate"])
async def set_camera_audio_sample_rate(ip_address: str, profile_token: str, sample_rate: int) -> str:
    return await set_camera_audio_sample_rate_core(
        ip_address,
        profile_token,
        sample_rate,
    )

@mcp.tool(description=TOOL_GUIDANCE["goto_camera_preset"])
async def goto_camera_preset(camera_ptz_xaddr: str, camera_profile_token: str, camera_preset_token: str, camera_time_offset: int) -> str:
    return await goto_camera_preset_core(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_preset_token,
        camera_time_offset,
    )

@mcp.tool(description=TOOL_GUIDANCE["set_camera_preset"])
async def set_camera_preset(ip_address: str, profile_token: str, preset_token: str = None, preset_name: str = None) -> str:
    return await set_camera_preset_core(
        ip_address,
        profile_token,
        preset_token,
        preset_name,
    )

@mcp.tool(description=TOOL_GUIDANCE["remove_camera_preset"])
async def remove_camera_preset(ip_address: str, profile_token: str, preset_token: str) -> str:
    return await remove_camera_preset_core(
        ip_address,
        profile_token,
        preset_token,
    )

@mcp.tool(description=TOOL_GUIDANCE["create_camera_preset_tour"])
async def create_camera_preset_tour(ip_address: str, profile_token: str, tour_name: str = None) -> str:
    return await create_camera_preset_tour_core(
        ip_address,
        profile_token,
        tour_name,
    )

@mcp.tool(description=TOOL_GUIDANCE["set_camera_preset_tour"])
async def set_camera_preset_tour(ip_address: str, profile_token: str, tour_token: str, tour_name: str = None, auto_start: bool = None, spots: list[dict] = None) -> str:
    return await set_camera_preset_tour_core(
        ip_address,
        profile_token,
        tour_token,
        tour_name,
        auto_start,
        spots,
    )

@mcp.tool(description=TOOL_GUIDANCE["remove_camera_preset_tour"])
async def remove_camera_preset_tour(ip_address: str, profile_token: str, tour_token: str) -> str:
    return await remove_camera_preset_tour_core(
        ip_address,
        profile_token,
        tour_token,
    )

@mcp.tool(description=TOOL_GUIDANCE["start_camera_preset_tour"])
async def start_camera_preset_tour(camera_ptz_xaddr: str, camera_profile_token: str, camera_ptz_tour_token: str, camera_time_offset: int) -> str:
    return await start_camera_preset_tour_core(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_ptz_tour_token,
        camera_time_offset,
    )

@mcp.tool(description=TOOL_GUIDANCE["stop_camera_preset_tour"])
async def stop_camera_preset_tour(camera_ptz_xaddr: str, camera_profile_token: str, camera_ptz_tour_token: str, camera_time_offset: int) -> str:
    return await stop_camera_preset_tour_core(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_ptz_tour_token,
        camera_time_offset,
    )

@mcp.tool(description=TOOL_GUIDANCE["pan_tilt_camera"])
async def pan_tilt_camera(camera_ptz_xaddr: str, camera_profile_token: str, camera_time_offset: int, x: float, y: float) -> str:
    return await pan_tilt_camera_core(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_time_offset,
        x,
        y,
    )

@mcp.tool(description=TOOL_GUIDANCE["zoom_camera"])
async def zoom_camera(camera_ptz_xaddr: str, camera_profile_token: str, camera_time_offset: int, z: float) -> str:
    return await zoom_camera_core(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_time_offset,
        z,
    )

@mcp.tool(description=TOOL_GUIDANCE["stop_camera_pan_tilt"])
async def stop_camera_pan_tilt(camera_ptz_xaddr: str, camera_profile_token: str, camera_time_offset: int) -> str:
    return await stop_camera_pan_tilt_core(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_time_offset,
    )

@mcp.tool(description=TOOL_GUIDANCE["stop_camera_zoom"])
async def stop_camera_zoom(camera_ptz_xaddr: str, camera_profile_token: str, camera_time_offset: int) -> str:
    return await stop_camera_zoom_core(
        camera_ptz_xaddr,
        camera_profile_token,
        camera_time_offset,
    )

@mcp.tool(description=TOOL_GUIDANCE["change_camera_hostname"])
async def change_camera_hostname(ip_address: str, new_hostname: str) -> str:
    return await change_camera_hostname_core(ip_address, new_hostname)

@mcp.tool(description=TOOL_GUIDANCE["sync_camera_time"])
async def sync_camera_time(ip_address: str) -> str:
    return await sync_camera_time_core(ip_address)

@mcp.tool(description=TOOL_GUIDANCE["reboot_camera"])
async def reboot_camera(ip_address: str) -> str:
    return await reboot_camera_core(ip_address)

@mcp.tool()
async def check_camera_mcp_environment() -> str:
    """
    Collect information about the environment under which camera server is running
    
    Args:
        None

    Returns:
        A delimited string containing environment variable settings

    """

    output = []
    output.append(os.environ.get("CAMERA_USERNAME", "Empty $env:CAMERA_USERNAME"))
    output.append(os.environ.get("CAMERA_PASSWORD", "Empty $env:CAMERA_PASSWORD"))
    output.append(os.environ.get("STREAM_SERVER_IP", "Empty $env:STREAM_SERVER_IP"))
    output.append(os.environ.get("PATH", "Empty $env:PATH"))

    return "\n--\n".join(output)

@mcp.tool()
async def stream_camera(camera_device_information_serial_number: str, camera_media_profile_token: str) -> str:
    """
    Open a camera live stream in the user's default web browser.

    Args:
        camera_device_information_serial_number: The camera serial number found in the ONVIF data of the camera
                                                 that is stored in the device_information topic group.

        camera_media_profile_token: The media profile token found the ONVIF data topic profiles. The default choice
                                    should be the first profile.

    Returns:
        A message indicating success or failure
    """
    #http://10.1.1.76:8889/AMC014641NE6L35AT8/MediaProfile000
    stream_server_ip = os.environ.get("STREAM_SERVER_IP")
    url = f"http://{stream_server_ip}:8889/{camera_device_information_serial_number}/{camera_media_profile_token}"
    opened = webbrowser.open(url)
    if opened:
        return f"Opened {url} in default browser."
    else:
        return f"Failed to open {url}."

@mcp.tool(description=TOOL_GUIDANCE["get_web_player_url"])
async def get_web_player_url(camera_device_information_serial_number: str, camera_media_profile_token: str) -> str:
    return await get_web_player_url_core(
        camera_device_information_serial_number,
        camera_media_profile_token,
    )


@mcp.tool()
async def get_snapshot_image_base64_encoded(url: str) -> str:
    """
    Get a snapshot image from a camera as a base64-encoded string.

    Args:
        url: The full URL to the snapshot, e.g. "https://example.com/snapshot.jpg"

    Returns:
        The snapshot image as a base64-encoded string.
    """
    if not (url.startswith("http://") or url.startswith("https://")):
        raise ValueError(f"Refused to get snapshot from '{url}': must start with http:// or https://")

    try:
        response = requests.get(url, auth=HTTPDigestAuth(os.environ.get("CAMERA_USERNAME", ""), os.environ.get("CAMERA_PASSWORD", "")), timeout=5)
        response.raise_for_status()
        return base64.b64encode(response.content).decode('utf-8')
    except Exception as e:
        logger.error(f"Failed to get snapshot from {url}: {e}")
        return None

@mcp.tool()
async def download_snapshot_to_file(url: str, file_path: str) -> str:
    """
    Download a snapshot from a camera to a specified file path.

    Args:
        url: The full URL to the snapshot, e.g. "https://example.com/snapshot.jpg"
        file_path: The local file path where the snapshot will be saved.

    Returns:
        A message indicating success or failure.
    """
    if not (url.startswith("http://") or url.startswith("https://")):
        return f"Refused to download '{url}': must start with http:// or https://"

    try:
        response = requests.get(url, auth=HTTPDigestAuth(os.environ.get("CAMERA_USERNAME", ""), os.environ.get("CAMERA_PASSWORD", "")), timeout=5)
        response.raise_for_status()
        with open(file_path, 'wb') as f:
            f.write(response.content)
        return f"Snapshot downloaded successfully to {file_path}."
    except Exception as e:
        logger.error(f"Failed to download snapshot from {url}: {e}")
        return f"Failed to download snapshot from {url}: {e}"

@mcp.tool()
async def show_snapshot_in_browser(url: str) -> str:
    """
    Open a snapshot URL in the user's default web browser.

    Args:
        url: The full URL to open, e.g. "https://example.com"

    Returns:
        A confirmation message.
    """
    if not (url.startswith("http://") or url.startswith("https://")):
        return f"Refused to open '{url}': must start with http:// or https://"

    camera_username = os.environ.get("CAMERA_USERNAME", "")
    camera_password = os.environ.get("CAMERA_PASSWORD", "")
    curl = f"{url[:7]}{camera_username}:{camera_password}@{url[7:]}"
    opened = webbrowser.open(curl)
    if opened:
        return f"Opened {url} in default browser."
    else:
        return f"Failed to open {url}."
    
@mcp.tool()
async def update_camera_data(json_string: str) -> str:
    """
    Re-query a camera fresh, using the xaddr and credentials currently set
    in the given camera JSON.

    Use this after editing username or password in the JSON returned by
    get_camera/get_cameras - for example, to try different credentials
    against a camera that failed authorization the first time. The edited
    credentials are what get used for the fresh query, not whatever was
    originally used. Any other edits made elsewhere in the JSON are
    ignored, since this re-runs the full query from scratch rather than
    patching the existing data - the returned camera reflects the device's
    actual current state, not your edits (aside from username/password,
    which control how the query is authorized).

    Do not edit xaddr. It is the camera's own self-reported device service
    address, discovered without authorization, and functions as the
    camera's network identity rather than a configurable setting. Changing
    it points this tool at a different device entirely rather than
    re-querying the same camera.

    Args:
        json_string: The JSON string representation of the camera, as
                     returned by get_camera or get_cameras, with the
                     desired username/password already edited.

    Returns:
        The freshly queried camera as a JSON string, or an error message
        if the JSON could not be parsed or the query itself failed (e.g.
        the credentials are still not authorized).
    """
    try:
        camera = camera_from_json(json_string)
    except Exception as e:
        logger.error(f"Failed to parse camera JSON: {e}")
        return f"Failed to parse camera JSON: {e}"

    try:
        refreshed = refresh_camera(camera)
        return refreshed.to_json()
    except Exception as e:
        logger.error(f"Failed to refresh camera at {camera.xaddr}: {e}")
        return f"Failed to refresh camera at {camera.xaddr}: {e}"


async def add_subscribed_event(ip_address: str, event_topic: str) -> str:
    """
    Subscribe a camera to an ONVIF event topic and mark it as observed.

    Updates this server's own bookkeeping (visible afterward as that
    camera's subscribed_events list in get_cameras) AND performs the
    real ONVIF subscription on the camera itself - adding just this one
    topic, without touching any of the camera's other active
    subscriptions (this mirrors ONVIF's own Subscribe operation, which
    is likewise additive/per-topic). All cameras share one underlying
    event listener - the first call to this tool or
    unsubscribe_all_events, for any camera, starts it; every subsequent
    call (for that camera or any other) reuses it.

    If the real subscription fails (e.g. the camera is unreachable), the
    bookkeeping change is rolled back rather than left showing a topic
    as subscribed when it isn't.

    event_topic is not validated against the camera's real topics here -
    it should be one of the strings in that camera's event_topics list
    (from get_cameras), but a typo will be sent to the camera as a
    literal (and likely rejected or silently non-matching) topic filter.

    Args:
        ip_address: The IP address of the camera.
        event_topic: The event topic string to add, e.g.
                     "RuleEngine/CellMotionDetector/Motion" - see that
                     camera's event_topics list in get_cameras for the
                     full set of valid values.

    Returns:
        A message indicating the result, including the resulting list.
    """
    events = _subscribed_events_by_camera.setdefault(ip_address, [])
    if event_topic in events:
        return f"{event_topic} is already in the subscribed_events list for camera at {ip_address}. Current list: {events}"

    events.append(event_topic)

    try:
        _subscribe_camera_event_topic(ip_address, event_topic)
        return f"Added {event_topic} to the subscribed_events list for camera at {ip_address}, and subscribed on the camera. Current list: {events}"
    except Exception as e:
        events.remove(event_topic)
        logger.error(f"Failed to subscribe camera at {ip_address} to {event_topic}: {e}")
        return f"Failed to subscribe camera at {ip_address} to {event_topic}: {e}"

@mcp.tool()
async def unsubscribe_all_events(ip_address: str) -> str:
    """
    Unsubscribe a camera from ALL of its ONVIF event topics and clear it
    from observation.

    Updates this server's own bookkeeping (visible afterward as that
    camera's subscribed_events list in get_cameras) AND performs the
    real ONVIF unsubscription on the camera itself. This mirrors ONVIF's
    own Unsubscribe operation directly: it has no way to target a single
    subscription while leaving others active, so it always removes every
    push subscription for the camera at once. To resume observing any
    topics afterward, call add_subscribed_event again for each one.

    If the real unsubscription fails (e.g. the camera is unreachable),
    the bookkeeping change is rolled back rather than left showing an
    empty subscribed_events list when the camera might still be sending
    events.

    Args:
        ip_address: The IP address of the camera.

    Returns:
        A message indicating the result, including the resulting list.
    """
    events = _subscribed_events_by_camera.get(ip_address, [])
    if not events:
        return f"Camera at {ip_address} has no subscribed events. Current list: {events}"

    previous_events = list(events)
    events.clear()

    try:
        _unsubscribe_camera_events(ip_address)
        return f"Unsubscribed camera at {ip_address} from all events. Current list: {events}"
    except Exception as e:
        events.extend(previous_events)
        logger.error(f"Failed to unsubscribe camera at {ip_address} from all events: {e}")
        return f"Failed to unsubscribe camera at {ip_address} from all events: {e}"


def main():
    logger.debug("Server starting...")
    mcp.run(transport="stdio")

if __name__ == "__main__":
    main()
