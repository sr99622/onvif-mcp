# Camera Snapshot Service (Option 1: Direct Camera Endpoints)

This document describes how to build and test the snapshot service that lets
remote clients retrieve a live JPEG from any camera in the fleet through one
uniform, authenticated URL.

## Why this service exists

Two facts drove the design — verify both before changing anything:

1. **MediaMTX v1.20.x has no still-image endpoint.** Its `hls: true` HTTP
   server (port 8888) only serves HLS playlists, video segments, and its
   embedded player page. Confirmed by reading the v1.20.1 source
   (`internal/servers/hls/http_server.go`) — there is no `/snapshot/...jpg`
   route, and no release through v1.20.1 adds one. Do not attempt to proxy
   snapshot requests to MediaMTX; they will never return an image.

2. **Nginx cannot do the camera-side authentication.** A majority of cameras
   in this fleet (Dahua, LoReX/Amcrest, AXIS, Reolink) require **HTTP Digest**
   on their snapshot endpoints. They reject plain `Authorization: Basic` with
   401, and the digest handshake is per-request (the camera issues a fresh
   nonce in each `WWW-Authenticate` challenge). Nginx can only inject static
   headers; it cannot perform the client side of a digest exchange, and this
   stock nginx build has no Lua module.

So an intermediate service sits between nginx and the cameras:

```
browser/agent
    |
    v
http://{{SERVER_FQDN}}/snapshot/<serial_number>/<profile_token>/
    |  (plain HTTP, port 80 — same open posture as /webrtc/ at this stage)
    v
127.0.0.1:8891   services/snapshot_proxy.py   (loopback-only, systemd unit)
    |  (per-request Basic OR Digest auth to the camera)
    v
camera's own ONVIF snapshot_uri  (native JPEG)
```

The URL scheme matches what the MCP tools emit: `build_web_player_url` produces
`http://{{SERVER_FQDN}}/webrtc/<serial>/<token>/`, and
`build_web_snapshot_url` (`packages/core/src/onvif_mcp_core/streaming.py`)
produces `http://{{SERVER_FQDN}}/snapshot/<serial>/<token>/`. Both derive from
`STREAM_SERVER_URL` on `onvif-mcp-http`, which is currently plain HTTP — this
host has no TLS certificate and no Keycloak gate at this stage of the
configuration. (TLS + keycloak will be added later; when they are, the scheme
switches to `https://` and the Step 6 auth lines reappear.) The nginx
location, the proxy's route table keys, and that scheme must all agree.

## Values supplied by Agent

| Value           | Description                                    |
|-----------------|------------------------------------------------|
| {{SERVER_FQDN}} | Server Fully Qualified Domain Name             |
| {{REPO_PATH}}   | Parent directory containing the onvif-mcp repository (repo lives at `{{REPO_PATH}}/onvif-mcp`) |
| {{USERNAME}}    | Camera username                                |
| {{PASSWORD}}    | Camera password                                |

## Step 1 — Confirm the Service Files Exist in the Repository

The service source and unit file are version-controlled in the repo:

```bash
{{REPO_PATH}}/onvif-mcp/services/snapshot_proxy.py
{{REPO_PATH}}/onvif-mcp/configs/systemd/snapshot-proxy.service
```

`snapshot_proxy.py` is a standard-library-only HTTP server (no pip
dependencies). Bind and credentials come from environment:

| Variable          | Default      | Purpose                           |
|-------------------|--------------|-----------------------------------|
| SNAPSHOT_PROXY_HOST | 127.0.0.1  | Bind address — keep loopback only |
| SNAPSHOT_PROXY_PORT | 8891       | Bind port                         |
| CAMERA_USERNAME   | {{USERNAME}} | Camera login                      |
| CAMERA_PASSWORD   | {{PASSWORD}} | Camera login                      |

Do not edit credentials into the source file; the unit file passes them via
`Environment=`.

## Step 2 — Collect Each Camera's Real Snapshot URI

The snapshot endpoint is vendor-specific and may differ from any URL pattern
you expect, so **never guess it** — read it from ONVIF. For every camera
returned by `get_cameras`, a list of profiles is returned, such that each 
profile includes the token and the snapshot_uri.

**Test every URI live** before trusting it. `curl --digest` handles both
Basic and Digest automatically, so one test command covers all vendors:

```bash
curl -s --digest -u {{USERNAME}}:{{PASSWORD}} --max-time 20 \
  -o /tmp/snap.jpg -w '%{http_code} %{content_type}\n' '<snapshot_uri>'
file /tmp/snap.jpg        # must say "JPEG image data"
```

Expectations and known fleet quirks (verified):

- A correct answer is `200 image/jpeg` with a real JPEG body.
- Some cameras require Digest (Dahua, LoReX, Amcrest, AXIS, Reolink — they
  return 401 to plain Basic). The proxy handles this transparently; you only
  need `curl --digest` for your own testing.
- A camera may report one snapshot_uri shared by multiple profiles (e.g.
  Speco maps all profile tokens to `/snapshot.JPG`; Reolink snapshots
  channel=0 only regardless of token). In that case several route entries
  legitimately point at the same upstream URI.
- Some cameras are simply buggy about their snapshot parameters (notably AXIS):
  certain resolution values may 503 persistently or work once and then fail.
  Map each profile token to whichever endpoint reliably returns a JPEG, and do
  not chase dead endpoints on a flaky camera — the proxy validates that the
  upstream answer is actually a JPEG before serving it, so an occasional bad
  response surfaces as a 502 rather than a corrupted image.

## Step 3 — Build the Route Table

In `{{REPO_PATH}}/onvif-mcp/services/snapshot_proxy.py`, the `ROUTES` dict is
the single source of mapping from external URL to upstream camera URI:

```python
ROUTES: dict[str, str] = {
    "<serial_number>/<profile_token>": "http://<camera_ip>/vendor-specific/path?params",
    # one entry per profile token used by the fleet (main stream AND every substream)
}
```

Coverage requirement: every `<serial>/<token>` pair referenced by the MediaMTX
paths in `/etc/mediamtx/mediamtx.yml` (equivalently, every URL component in
`apps/outputs/camera_registry.json`) must have a route entry. A camera that
reports N profiles gets up to N entries; cameras with a single shared snapshot
endpoint may reuse one upstream URI across their tokens. Keep the
serial/token spelling **identical** to the registry and MediaMTX path names —
the proxy does exact string lookup, no normalization.

Add explanatory comments for any non-obvious entry (shared-URI cameras,
quirky endpoints).

## Step 4 — Install and Start the Service

```bash
sudo cp {{REPO_PATH}}/onvif-mcp/configs/systemd/snapshot-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable snapshot-proxy --now
systemctl is-active snapshot-proxy          # expect: active
systemctl is-enabled snapshot-proxy         # expect: enabled (survives reboot)
```

The unit binds **127.0.0.1 only** — verify nothing else can reach it:

```bash
sudo ss -lntpe | grep ':8891'    # expect a single listener on 127.0.0.1:8891
```

## Step 5 — Standalone Test (no nginx involved)

Every route must return a valid JPEG directly from the loopback port:

```bash
for r in <serial>/<token> ... ; do        # one per ROUTES entry
  out=$(curl -s --max-time 30 -o /tmp/s.jpg -w '%{http_code} %{content_type}' \
    "http://127.0.0.1:8891/snapshot/$r/")
  printf '%-52s %-14s sz=%-8s %s\n' "$r" "$out" "$(stat -c%s /tmp/s.jpg)" \
    "$(file -b /tmp/s.jpg | cut -c1-16)"
done
```

Expected: every route shows `200 image/jpeg` and `JPEG image data`. Negatives:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:8891/snapshot/NOSUCH/Profile_1/"   # 404
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:8891/garbage"                       # 400
```

If a route fails, read the service log — it distinguishes auth/transport
failure from a non-JPEG camera response (and shows its retry):

```bash
sudo journalctl -u snapshot-proxy --no-pager -n 30
```

The proxy also validates the JPEG SOI marker (`\xff\xd8`) and retries once, so
an HTML error page can never be served as an image; repeated failure returns
502 with `snapshot unavailable from camera`.

## Step 6 — Add the Nginx Endpoint

Back up the site config first:

```bash
sudo cp --update=none /etc/nginx/sites-available/mediamtx \
  "/etc/nginx/sites-available/mediamtx.backup-$(date +%F)"
```

Inside the existing `server` block (the one serving `/webrtc/`) add this
location. This host currently serves **plain HTTP on port 80** — it has no TLS
certificate and no Keycloak gate, so at this stage there is no
`auth_request`/`@oauth2_signin` wiring to reuse. Access control is the same
open posture as `/webrtc/` (see the security notes at the bottom). When TLS +
Keycloak are added later, insert the keycloak lines from that section's final
form inside `location /snapshot/`:

```nginx
    auth_request /oauth2/auth;
    error_page 401 = @oauth2_signin;
    auth_request_set $auth_cookie $upstream_http_set_cookie;
    add_header Set-Cookie $auth_cookie always;
```

The location as it is installed today (no client-side gate):

```nginx
    # --- Snapshot proxy (services/snapshot_proxy.py, loopback-only on 8891) ---
    # Cameras authenticate with per-request HTTP Digest which nginx cannot do
    # natively, so the local snapshot service performs that handshake.
    location /snapshot/ {
        # Pass through unchanged: the proxy expects /snapshot/<serial>/<profile>/
        proxy_pass http://127.0.0.1:8891/snapshot/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Snapshots are one-shot, but a hung camera upstream must not hold a worker.
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;

        # Never cache live images at any layer.
        proxy_no_cache on;
        proxy_cache_bypass on;
    }
```

Note the trailing `/snapshot/` in `proxy_pass`: it keeps the external path
intact, which is what the proxy's route lookup expects. The short timeouts are
deliberate — a snapshot is one image, not a long-lived session like WebRTC.

Validate **before** touching the running server:

```bash
sudo nginx -t                    # must say "test is successful"
sudo systemctl reload nginx.service
systemctl --no-pager status nginx.service
```

If `nginx -t` fails, restore the backup (`sudo cp <backup> /etc/nginx/sites-available/mediamtx`)
and re-test before reloading.

## Step 7 — End-to-End Verification

1. **Unauthenticated requests get a plain image** (there is no Keycloak gate
   yet on this host, so there is nothing to bounce — same open posture as
   `/webrtc/`). Verify the proxy path through nginx returns a real JPEG:

   ```bash
   curl -s -o /tmp/e2e.jpg \
     -w '%{http_code} %{content_type}\n' \
     "http://{{SERVER_FQDN}}/snapshot/<serial>/<token>/"
   file /tmp/e2e.jpg        # must say "JPEG image data"
   ```

   Expected: `200 image/jpeg` with a real JPEG body and
   `Cache-Control: no-store` in the response headers.

2. **Fetch returns the image.** Open
   `http://{{SERVER_FQDN}}/snapshot/<serial>/<token>/` in a browser and
   confirm a photo of that camera appears.

3. **MCP tools emit the same URL.** With `STREAM_SERVER_URL=http://{{SERVER_FQDN}}`
   set on `onvif-mcp-http`, call `get_cameras` and confirm each profile's
   `web_snapshot_url` equals the URL verified in step 1.

> **When TLS + Keycloak are added later:** re-insert the keycloak lines from
> Step 6 into the `/snapshot/` location, switch every client-facing URL above
> to `https://{{SERVER_FQDN}}/...` (with a CA cert), and replace step 1 with
> the gate check:
>
> ```bash
> curl --head -s --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
>   "https://{{SERVER_FQDN}}/snapshot/<serial>/<token>/" | head -8
> # expect: HTTP/1.1 302 with Location: .../oauth2/start?rd=/snapshot/<serial>/<token>/
> ```

## Adding a Camera Later

The service needs no nginx changes — only:

1. A new entry (or entries) in `ROUTES` in `services/snapshot_proxy.py`,
   keyed exactly like the registry/MediaMTX path name (Step 3).
2. Restart the unit: `sudo systemctl restart snapshot-proxy`.
3. Re-run the Step 5 standalone test for the new route(s), plus one browser
   check from Step 7.

## Security Notes

- The proxy binds to loopback only; the cameras are reached solely through it,
  and clients reach it solely through nginx. **At this stage there is no client
  authentication gate** — `/snapshot/` is open on port 80 with the same posture
  as `/webrtc/`. When TLS + Keycloak are added later, insert the keycloak
  `auth_request` lines from Step 6 to put it behind the same gate.
- Camera credentials live in environment (systemd unit) and in the upstream
  URLs' authentication, never in client-facing responses or logs. The proxy
  logs request paths only.
- Responses carry `Cache-Control: no-store` and nginx sets `proxy_no_cache`,
  so a stale frame cannot be cached by any layer.
- Camera credentials are also embedded in plaintext in `/etc/mediamtx/mediamtx.yml`
  (pre-existing condition, see docs/MEDIAMTX.md) — keep that file protected.
