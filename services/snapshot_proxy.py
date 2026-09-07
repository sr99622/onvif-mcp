#!/usr/bin/env python3

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

CAMERA_USERNAME = "admin"
CAMERA_PASSWORD = "admin123"
HOST = "127.0.0.1"
PORT = 8891
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
    # --- Hikvision DS-2CD2142FWD-IS (10.1.1.70) ---
    "DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1":
        "http://10.1.1.70/onvif-http/snapshot?Profile_1",
    "DS-2CD2142FWD-IS20171118BBWR129028868/Profile_2":
        "http://10.1.1.70/onvif-http/snapshot?Profile_2",
    # --- LOREX LNB8973B / Kitchen (10.1.1.72) --- HTTP Digest required
    "ND021810001394/MediaProfile000":
        "http://10.1.1.72/onvifsnapshot/media_service/snapshot?channel=1&subtype=0",
    "ND021810001394/MediaProfile001":
        "http://10.1.1.72/onvifsnapshot/media_service/snapshot?channel=1&subtype=1",
    # --- Amcrest IP3M-HX2W / Driveway (10.1.1.68) --- HTTP Digest required
    "AMC015906KDB241289/MediaProfile000":
        "http://10.1.1.68/onvifsnapshot/media_service/snapshot?channel=1&subtype=0",
    "AMC015906KDB241289/MediaProfile001":
        "http://10.1.1.68/onvifsnapshot/media_service/snapshot?channel=1&subtype=1",
    # --- Amcrest IP2M-841EB / Monopoly (10.1.1.71) --- HTTP Digest required
    "AMC014641NE6L35AT8/MediaProfile000":
        "http://10.1.1.71/onvifsnapshot/media_service/snapshot?channel=1&subtype=0",
    "AMC014641NE6L35AT8/MediaProfile001":
        "http://10.1.1.71/onvifsnapshot/media_service/snapshot?channel=1&subtype=1",
    # --- AXIS M1065-LW / Office (10.1.1.67) --- image.cgi resolution quirk:
    # 1280x720 and 640x360 return 503 persistently; only the default endpoint
    # and resolution=1920x1080 reliably return a JPEG (verified live).
    "ACCC8E99C915/profile_1_h264":
        "http://10.1.1.67/onvif-cgi/jpg/image.cgi?resolution=1920x1080&compression=30",
    "ACCC8E99C915/profile_1_jpeg":
        "http://10.1.1.67/onvif-cgi/jpg/image.cgi?resolution=1920x1080&compression=30",
    "ACCC8E99C915/profile0":
        "http://10.1.1.67/onvif-cgi/jpg/image.cgi",
    "ACCC8E99C915/profile1":
        "http://10.1.1.67/onvif-cgi/jpg/image.cgi?resolution=1920x1080&compression=30",
    # --- Dahua IPC-HDW4631C-A / Tester (10.2.2.98, isolated) --- HTTP Digest required
    "4B0013BPAABE264/MediaProfile000":
        "http://10.2.2.98/onvifsnapshot/media_service/snapshot?channel=1&subtype=0",
    "4B0013BPAABE264/MediaProfile001":
        "http://10.2.2.98/onvifsnapshot/media_service/snapshot?channel=1&subtype=1",
    # --- Speco O4VD2 (10.2.2.101, isolated) --- all three tokens share one /snapshot.JPG
    "5CF2075C9F49/profile1":
        "http://10.2.2.101:80/snapshot.JPG",
    "5CF2075C9F49/profile2":
        "http://10.2.2.101:80/snapshot.JPG",
    "5CF2075C9F49/profile3":
        "http://10.2.2.101:80/snapshot.JPG",
}

# Match the external shape: optionally-prefixed /snapshot/<serial>/<profile>/
_ROUTE_RE = re.compile(r"^/?(?:snapshot/)?(?P<serial>[^/]+)/(?P<profile>[^/]+)/?$")


def _lookup(serial: str, profile: str) -> str | None:
    return ROUTES.get(f"{serial}/{profile}")


def _curl(url: str, digest: bool) -> bytes:
    """One curl attempt. `digest=False` sends HTTP Basic; `digest=True` lets curl
    do the Digest handshake. Returns the response body (possibly an error page)."""
    args = ["curl", "-s"]
    if digest:
        args.append("--digest")
    args += [
        "-u",
        f"{CAMERA_USERNAME}:{CAMERA_PASSWORD}",
        "--max-time",
        str(UPSTREAM_TIMEOUT_S),
        url,
    ]
    try:
        proc = subprocess.run(args, check=False, capture_output=True, timeout=UPSTREAM_TIMEOUT_S + 5)
    except (subprocess.SubprocessError, OSError) as ex:
        log.warning("upstream fetch error for %s: %s", url, ex)
        return b""
    if proc.returncode != 0 and not proc.stdout:
        log.warning(
            "curl failed (code %d) for %s: %s", proc.returncode, url, proc.stderr[:200]
        )
    return proc.stdout


def _fetch_once(url: str) -> bytes:
    for digest in (True, False):
        for attempt in (1, 2):
            body = _curl(url, digest)
            if body[:2] == b"\xff\xd8":  # JPEG SOI marker
                return body
            if attempt == 1:
                log.info(
                    "no JPEG from %s via %s (len=%d), retrying",
                    url, "digest" if digest else "basic", len(body),
                )
                time.sleep(1.0)
    log.warning("no JPEG from %s (tried basic and digest)", url)
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

        image = _fetch_once(upstream_url)
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
