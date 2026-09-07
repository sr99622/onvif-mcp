#!/usr/bin/env python3
"""Loopback-only snapshot proxy for the camera fleet.

Nginx (see configs/nginx/sites-available/mediamtx, location /snapshot/) is the
only network-facing front end: it authenticates the client against Keycloak via
auth_request and then proxies to this helper on 127.0.0.1:8891. This process
binds to loopback only, so the camera credentials it uses never leave the host.

It maps a uniform external URL of the form

    /snapshot/<serial_number>/<profile_token>/

to each camera's own ONVIF snapshot URI (which is vendor-specific and may
require HTTP Digest), fetches the JPEG per-request with `curl --digest`
(handles Basic and Digest automatically), and streams the bytes back.

Bind/credentials come from environment so the unit file need not embed secrets:
    SNAPSHOT_PROXY_HOST      default 127.0.0.1
    SNAPSHOT_PROXY_PORT      default 8891
    CAMERA_USERNAME          default admin
    CAMERA_PASSWORD          default admin123
"""

from __future__ import annotations

import logging
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("snapshot-proxy")

CAMERA_USERNAME = os.environ.get("CAMERA_USERNAME", "admin")
CAMERA_PASSWORD = os.environ.get("CAMERA_PASSWORD", "admin123")
HOST = os.environ.get("SNAPSHOT_PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("SNAPSHOT_PROXY_PORT", "8891"))
UPSTREAM_TIMEOUT_S = 20

# Route table: "<serial>/<profile>" -> upstream snapshot URI (no credentials).
# Sourced from each camera's ONVIF GetProfiles snapshot_uri, verified live.
# Notes on the non-obvious entries:
#   * Dahua 4B0013BPAABE264 (IPC-HDW4631C-A) — snapshot endpoint requires
#     HTTP Digest; handled transparently by `curl --digest` below.
#   * Speco 5CF2075C9F49 (O4VD2) — all three profile tokens share one
#     /snapshot.JPG endpoint, so every token maps to the same URI.
#   * AXIS ACCC8E99C915 (M1065-LW) — buggy about image.cgi resolution
#     parameters: 1280x720 and 640x360 return 503 persistently; only the
#     default endpoint and resolution=1920x1080 reliably return a JPEG, so
#     all four AXIS tokens map to one of those two.
ROUTES: dict[str, str] = {
    # --- Isolated camera network (10.2.2.x) ---
    # Dahua IPC-HDW4631C-A @ 10.2.2.98 — main stream + substream (digest auth)
    "4B0013BPAABE264/MediaProfile000": "http://10.2.2.98/onvifsnapshot/media_service/snapshot?channel=1&subtype=0",
    "4B0013BPAABE264/MediaProfile001": "http://10.2.2.98/onvifsnapshot/media_service/snapshot?channel=1&subtype=1",
    # Speco O4VD2 @ 10.2.2.101 — all three profiles share one snapshot endpoint
    "5CF2075C9F49/profile1": "http://10.2.2.101:80/snapshot.JPG",
    "5CF2075C9F49/profile2": "http://10.2.2.101:80/snapshot.JPG",
    "5CF2075C9F49/profile3": "http://10.2.2.101:80/snapshot.JPG",
    # --- Main LAN (10.1.1.x) ---
    # HIKVISION DS-2CD2142FWD-IS @ 10.1.1.70 — main + substream (digest auth)
    "DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1": "http://10.1.1.70/onvif-http/snapshot?Profile_1",
    "DS-2CD2142FWD-IS20171118BBWR129028868/Profile_2": "http://10.1.1.70/onvif-http/snapshot?Profile_2",
    # LOREX LNB8973B (Dahua) @ 10.1.1.72 — main + substream
    "ND021810001394/MediaProfile000": "http://10.1.1.72/onvifsnapshot/media_service/snapshot?channel=1&subtype=0",
    "ND021810001394/MediaProfile001": "http://10.1.1.72/onvifsnapshot/media_service/snapshot?channel=1&subtype=1",
    # Amcrest IP3M-HX2W (Dahua) @ 10.1.1.68 — main + substream
    "AMC015906KDB241289/MediaProfile000": "http://10.1.1.68/onvifsnapshot/media_service/snapshot?channel=1&subtype=0",
    "AMC015906KDB241289/MediaProfile001": "http://10.1.1.68/onvifsnapshot/media_service/snapshot?channel=1&subtype=1",
    # Amcrest IP2M-841EB (Dahua) @ 10.1.1.71 — main + substream only; the other
    # ONVIF tokens on this camera are PTZ presets/tours with no media source.
    "AMC014641NE6L35AT8/MediaProfile000": "http://10.1.1.71/onvifsnapshot/media_service/snapshot?channel=1&subtype=0",
    "AMC014641NE6L35AT8/MediaProfile001": "http://10.1.1.71/onvifsnapshot/media_service/snapshot?channel=1&subtype=1",
    # AXIS M1065-LW @ 10.1.1.67 — all tokens map to the two reliable endpoints:
    # default (no params) or resolution=1920x1080; the 1280x720 / 640x360
    # variants return 503 persistently on this unit.
    "ACCC8E99C915/profile_1_h264": "http://10.1.1.67/onvif-cgi/jpg/image.cgi",
    "ACCC8E99C915/profile_1_jpeg": "http://10.1.1.67/onvif-cgi/jpg/image.cgi?resolution=1920x1080&compression=30",
    "ACCC8E99C915/profile0": "http://10.1.1.67/onvif-cgi/jpg/image.cgi",
    "ACCC8E99C915/profile1": "http://10.1.1.67/onvif-cgi/jpg/image.cgi?resolution=1920x1080&compression=30",
}

# Match the external shape: optionally-prefixed /snapshot/<serial>/<profile>/
_ROUTE_RE = re.compile(r"^/?(?:snapshot/)?(?P<serial>[^/]+)/(?P<profile>[^/]+)/?$")


def _lookup(serial: str, profile: str) -> str | None:
    return ROUTES.get(f"{serial}/{profile}")


def _fetch_once(upstream_url: str) -> tuple[bool, bytes]:
    """One attempt to fetch the JPEG. Returns (ok, body)."""
    try:
        proc = subprocess.run(
            [
                "curl",
                "-s",
                "--digest",
                "-u",
                f"{CAMERA_USERNAME}:{CAMERA_PASSWORD}",
                "--max-time",
                str(UPSTREAM_TIMEOUT_S),
                upstream_url,
            ],
            check=False,
            capture_output=True,
            timeout=UPSTREAM_TIMEOUT_S + 5,
        )
    except (subprocess.SubprocessError, OSError) as ex:
        log.warning("upstream fetch error for %s: %s", upstream_url, ex)
        return False, b""
    if proc.returncode != 0 and not proc.stdout:
        log.warning(
            "curl failed (code %d) for %s: %s", proc.returncode, upstream_url, proc.stderr[:200]
        )
        return False, b""
    return True, proc.stdout


def _fetch(upstream_url: str) -> bytes:
    """Fetch the JPEG. Retries once after a short pause when the body is not a
    valid image — some cameras (e.g. the AXIS M1065-LW) cap concurrent HTTP
    clients and answer with a small HTML error page, occasionally over a 200."""
    for attempt in (1, 2):
        ok, body = _fetch_once(upstream_url)
        if ok and body[:2] == b"\xff\xd8":  # JPEG SOI marker
            return body
        if attempt == 1:
            log.info("retrying %s after non-JPEG response (len=%d)", upstream_url, len(body))
            time.sleep(1.5)
    log.warning("no JPEG from %s", upstream_url)
    return b""


class Handler(BaseHTTPRequestHandler):
    server_version = "snapshot-proxy/1.0"

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        m = _ROUTE_RE.match(self.path)
        if not m:
            self._send(400, b"malformed path", content_type="text/plain; charset=utf-8")
            return

        upstream_url = _lookup(m.group("serial"), m.group("profile"))
        if upstream_url is None:
            log.info("no route for %s", self.path)
            self._send(404, b"unknown camera/profile\n", content_type="text/plain; charset=utf-8")
            return

        image = _fetch(upstream_url)
        if not image:
            log.warning("empty/failed snapshot for %s", self.path)
            self._send(502, b"snapshot unavailable from camera\n", content_type="text/plain; charset=utf-8")
            return

        self._send(200, image, content_type="image/jpeg")

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # Snapshots are live; never let intermediaries cache a stale frame.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:  # route access logs through logging
        log.info("%s %s", self.address_string(), format % args)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    log.info("snapshot proxy listening on http://%s:%d (%d routes)", HOST, PORT, len(ROUTES))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
