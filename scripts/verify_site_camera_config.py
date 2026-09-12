#!/usr/bin/env python3
"""Verify generated site-specific camera config."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server-fqdn", required=True)
    parser.add_argument("--site-dir", type=Path, default=Path("/etc/onvif-mcp"))
    parser.add_argument("--mediamtx-file", type=Path, default=Path("/etc/mediamtx/mediamtx.yml"))
    args = parser.parse_args()

    errors: list[str] = []
    registry_file = args.site_dir / "camera_registry.json"
    routes_file = args.site_dir / "snapshot_routes.json"

    try:
        registry = json.loads(registry_file.read_text())
    except Exception as exc:
        raise SystemExit(f"cannot read {registry_file}: {exc}") from exc
    try:
        routes_doc = json.loads(routes_file.read_text())
    except Exception as exc:
        raise SystemExit(f"cannot read {routes_file}: {exc}") from exc
    routes = routes_doc.get("routes", routes_doc)
    if not isinstance(routes, dict):
        errors.append("snapshot routes must be a JSON object or contain a routes object")
        routes = {}

    mediamtx = args.mediamtx_file.read_text()
    mediamtx_paths = set(re.findall(r"^  ([^\s][^:]+):$", mediamtx, re.M))
    registry_paths: list[str] = []
    prefix = f"https://{args.server_fqdn}/webrtc/"

    for camera in registry.get("cameras", []):
        name = camera.get("hostname", "?")
        for key in ("hostname", "ip_address", "manufacturer", "model", "media_player_url", "substream_player_url"):
            if not camera.get(key):
                errors.append(f"{name} missing {key}")
        for key in ("media_player_url", "substream_player_url"):
            url = camera.get(key, "")
            if not url.startswith(prefix) or not url.endswith("/"):
                errors.append(f"{name} bad {key}: {url}")
                continue
            path = url[len(prefix):].rstrip("/")
            registry_paths.append(path)
            if path not in mediamtx_paths:
                errors.append(f"{name} registry path missing from MediaMTX: {path}")

    for path in mediamtx_paths:
        if path not in routes:
            errors.append(f"MediaMTX path missing from snapshot routes: {path}")

    print(f"registry_cameras {len(registry.get('cameras', []))}")
    print(f"registry_stream_urls {len(registry_paths)}")
    print(f"mediamtx_paths {len(mediamtx_paths)}")
    print(f"snapshot_routes {len(routes)}")

    if errors:
        for error in errors:
            print(f"FAIL {error}", file=sys.stderr)
        raise SystemExit(1)
    print("site camera config OK")


if __name__ == "__main__":
    main()
