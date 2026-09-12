#!/usr/bin/env python3
"""Generate site-specific camera config outside the git checkout.

Input is a saved camera MCP get_cameras result. The file may contain either the
raw '--'-delimited summaries returned by the tool, or a JSON object with a
"result" field containing that text.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit


def parse_discovery(text: str) -> list[dict]:
    text = text.strip()
    if not text:
        return []
    try:
        data = json.loads(text)
        if isinstance(data, dict) and isinstance(data.get("result"), str):
            text = data["result"].strip()
        elif isinstance(data, list):
            return data
        elif isinstance(data, dict) and "hostname" in data:
            return [data]
    except json.JSONDecodeError:
        pass
    cameras = []
    for chunk in text.split("\n--\n"):
        chunk = chunk.strip()
        if chunk:
            cameras.append(json.loads(chunk))
    return cameras


def resolution_area(profile: dict) -> int:
    resolution = ((profile.get("video_encoder") or {}).get("resolution") or "0 x 0")
    try:
        width, height = [int(part.strip()) for part in resolution.lower().split("x", 1)]
    except ValueError:
        return 0
    return width * height


def choose_registry_profiles(camera: dict) -> tuple[dict, dict]:
    profiles = camera.get("profiles") or []
    h264 = [p for p in profiles if ((p.get("video_encoder") or {}).get("encoding") or "").upper() == "H264"]
    candidates = h264 or profiles
    if not candidates:
        raise ValueError(f"camera {camera.get('hostname', '?')} has no profiles")
    main = max(candidates, key=resolution_area)
    alternatives = [p for p in candidates if p is not main]
    sub = min(alternatives, key=resolution_area) if alternatives else main
    return main, sub


def add_rtsp_credentials(uri: str, username: str, password: str) -> str:
    parsed = urlsplit(uri)
    if parsed.scheme != "rtsp":
        raise ValueError(f"stream_uri is not rtsp: {uri}")
    return urlunsplit((parsed.scheme, f"{username}:{password}@{parsed.netloc}", parsed.path, parsed.query, parsed.fragment))


def load_overrides(path: Path | None) -> dict:
    if not path or not path.exists():
        return {}
    with path.open() as f:
        return json.load(f)


def snapshot_uri_for(camera: dict, profile: dict, overrides: dict) -> str:
    key = f"{camera['serial_number']}/{profile['token']}"
    route_overrides = overrides.get("snapshot_routes", {})
    if key in route_overrides:
        return route_overrides[key]
    return profile.get("snapshot_uri") or ""


def generate(cameras: list[dict], fqdn: str, username: str, password: str, overrides: dict) -> tuple[dict, dict, str]:
    registry = {
        "description": "Camera registry - one entry per physical camera, main stream (switchboard) and substream (multiview)",
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cameras": [],
    }
    routes: dict[str, str] = {}
    mediamtx_lines = [
        "logLevel: info",
        "logDestinations: [stdout]",
        "",
        "rtsp: true",
        "rtspTransports: [tcp]",
        "rtspAddress: 127.0.0.1:8554",
        "",
        "webrtc: true",
        "webrtcAddress: 127.0.0.1:8889",
        "webrtcLocalUDPAddress: :8189",
        "",
        "rtmp: false",
        "hls: false",
        "srt: false",
        "moq: false",
        "api: false",
        "",
        "authMethod: internal",
        "authInternalUsers:",
        "  - user: any",
        "    pass: \"\"",
        "    ips: []",
        "    permissions:",
        "      - action: publish",
        "        path: \"\"",
        "      - action: read",
        "        path: \"\"",
        "      - action: playback",
        "        path: \"\"",
        "",
        "paths:",
    ]

    for camera in cameras:
        serial = camera["serial_number"]
        main, sub = choose_registry_profiles(camera)
        registry["cameras"].append({
            "hostname": camera.get("hostname", ""),
            "ip_address": camera.get("ip_address", ""),
            "manufacturer": camera.get("manufacturer", ""),
            "model": camera.get("model", ""),
            "media_player_url": f"https://{fqdn}/webrtc/{serial}/{main['token']}/",
            "substream_player_url": f"https://{fqdn}/webrtc/{serial}/{sub['token']}/",
        })
        for profile in camera.get("profiles") or []:
            path_name = f"{serial}/{profile['token']}"
            mediamtx_lines.append(f"  {path_name}:")
            mediamtx_lines.append(f"    source: {add_rtsp_credentials(profile['stream_uri'], username, password)}")
            snapshot_uri = snapshot_uri_for(camera, profile, overrides)
            if snapshot_uri:
                routes[path_name] = snapshot_uri

    return registry, {"routes": routes}, "\n".join(mediamtx_lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--discovery-file", required=True, type=Path)
    parser.add_argument("--server-fqdn", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--site-dir", type=Path, default=Path("/etc/onvif-mcp"))
    parser.add_argument("--mediamtx-file", type=Path, default=Path("/etc/mediamtx/mediamtx.yml"))
    parser.add_argument("--overrides-file", type=Path, default=Path("/etc/onvif-mcp/camera_site_overrides.json"))
    args = parser.parse_args()

    cameras = parse_discovery(args.discovery_file.read_text())
    overrides = load_overrides(args.overrides_file)
    registry, routes, mediamtx = generate(cameras, args.server_fqdn, args.username, args.password, overrides)

    args.site_dir.mkdir(parents=True, exist_ok=True)
    (args.site_dir / "camera_registry.json").write_text(json.dumps(registry, indent=2) + "\n")
    (args.site_dir / "snapshot_routes.json").write_text(json.dumps(routes, indent=2) + "\n")
    args.mediamtx_file.write_text(mediamtx)
    print(f"wrote {len(registry['cameras'])} cameras, {len(routes['routes'])} snapshot routes")


if __name__ == "__main__":
    main()
