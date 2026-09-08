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
# Important Notes:
# Many cameras do not have proper interfaces on some api calls and may display 
# erroneous data. Some cameras may only support Basic Authentication, but also 
# have a faulty Digest Algorithm that returns garbage. In fact, any call a camera 
# has may behave erratically or out of spec. These are exceptions to Match
# out for. Most cameras will work most of the time, so try to optimaize 
# for utility without obsessing over making absolutely everything conform.
#
ROUTES: dict[str, str] = {
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
