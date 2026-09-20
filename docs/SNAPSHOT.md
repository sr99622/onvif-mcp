# Camera Snapshot Service

This document describes how to build and test the snapshot service that lets
remote clients retrieve a live JPEG from any camera in the fleet through one
uniform, authenticated URL.

## Why this service exists

Set up an intermediate service that sits between nginx and the cameras:

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

| Value             | Description                                    |
|-------------------|------------------------------------------------|
| `{{SERVER_FQDN}}`   | Server Fully Qualified Domain Name            |
| `{{REPO_PATH}}`     | Parent directory containing the onvif-mcp repository (repo lives at `{{REPO_PATH}}/onvif-mcp`) |
| `{{SERVER_USER}}`   | System user the proxy runs as (owner of `{{REPO_PATH}}`, so it can read the repo source and its venv) |
| `{{USERNAME}}`      | Camera username                                |
| `{{PASSWORD}}`      | Camera password                                |

These values are required for operation. Stop and prompt the user if any of them are not provided.

## 1. Confirm the Service Source Exists in the Repository

The service source is version-controlled in the repo:

```bash
{{REPO_PATH}}/onvif-mcp/services/snapshot_proxy.py
```

The systemd unit file is **not** committed; it is generated on the fly in
Step 4 (the deployment details vary per host — service user, repo path, and
venv location).

`snapshot_proxy.py` is a standard-library-only HTTP server (no pip
dependencies). Bind and credentials come from environment:

| Variable          | Default      | Purpose                           |
|-------------------|--------------|-----------------------------------|
| SNAPSHOT_PROXY_HOST | 127.0.0.1  | Bind address — keep loopback only |
| SNAPSHOT_PROXY_PORT | 8891       | Bind port                         |
| SNAPSHOT_ROUTES_FILE | /etc/onvif-mcp/snapshot_routes.json | Generated site route table |
| CAMERA_USERNAME   | {{USERNAME}} | Camera login                      |
| CAMERA_PASSWORD   | {{PASSWORD}} | Camera login                      |

Do not edit credentials into the source file; the unit file passes them via
`Environment=`.

## 2. Collect Each Camera's Real Snapshot URI

NOTE: Not all cameras will support Digest Authentication. Some cameras will
only support Basic Authentication. Digest is preferred, use Basic as the
fallback. Also, some cameras do not implement either protocol correctly and
may produce garbage output. If a curl to a camera snapshot does not respond
properly to repeated attempts, abandon the url and move on. It is possible 
that the camera has some endpoints that work and others that do not, so
don't give up entirely on the camera, give up on an individual endpoint.

The snapshot endpoint is vendor-specific and may differ from any URL pattern
you expect, so **never guess it** — read it from ONVIF. For every camera
returned by `get_cameras`, a list of profiles is returned, such that each 
profile includes the token and the snapshot_uri.

**Test every URI live** before trusting it. `curl --digest` handles Digest 
authentication and `curl --basic` does Basic authentication. If --digest is
unsuccessful, wait a few seconds then try --basic. Do not repeatedly hit the
camera with requests in succession, you might crash it:

* Digest Version of the Command

  ```bash
  curl -s --digest -u {{USERNAME}}:{{PASSWORD}} --max-time 20 \
    -o /tmp/snap.jpg -w '%{http_code} %{content_type}\n' '<snapshot_uri>'
  file /tmp/snap.jpg        # must say "JPEG image data"
  ```

* Basic Version of the Command

  ```bash
  curl -s --basic -u {{USERNAME}}:{{PASSWORD}} --max-time 20 \
    -o /tmp/snap.jpg -w '%{http_code} %{content_type}\n' '<snapshot_uri>'
  file /tmp/snap.jpg        # must say "JPEG image data"
  ```

Expectations and known fleet quirks (verified):

- A correct answer is `200 image/jpeg` with a real JPEG body.
- Some cameras require Digest (Dahua, LoReX, Amcrest, AXIS, Reolink — they
  return 401 to plain Basic). The proxy handles this transparently.
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

## 3. Build the Route Table

In `/etc/onvif-mcp/snapshot_routes.json`, the `routes` object is the single
source of mapping from external URL to upstream camera URI. It is generated
outside the git checkout so repository updates cannot erase site camera data:

```json
{
  "routes": {
    "<serial_number>/<profile_token>": "http://<camera_ip>/vendor-specific/path?params"
  }
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

## 4. Generate, Install, and Start the Service

Generate the unit file on the fly from the template below (deployment details
vary per host). Substitute `{{SERVER_USER}}` with the user who owns `{{REPO_PATH}}`, 
and the other braces with the values supplied by the Agent:

```bash
sudo tee /etc/systemd/system/snapshot-proxy.service >/dev/null <<'EOF'
[Unit]
Description=Loopback-only camera snapshot proxy (services/snapshot_proxy.py)
Documentation=file:{{REPO_PATH}}/onvif-mcp/services/snapshot_proxy.py
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{SERVER_USER}}
WorkingDirectory={{REPO_PATH}}/onvif-mcp
# Loopback-only bind: the proxy is reached only through nginx, which handles
# client authentication (keycloak). Credentials for the cameras are supplied
# via environment so they are not embedded in the unit file on disk.
Environment=SNAPSHOT_PROXY_HOST=127.0.0.1
Environment=SNAPSHOT_PROXY_PORT=8891
Environment=SNAPSHOT_ROUTES_FILE=/etc/onvif-mcp/snapshot_routes.json
Environment=CAMERA_USERNAME={{USERNAME}}
Environment=CAMERA_PASSWORD={{PASSWORD}}
ExecStart={{REPO_PATH}}/onvif-mcp/.venv/bin/python {{REPO_PATH}}/onvif-mcp/services/snapshot_proxy.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Installation steps:
```bash
sudo systemctl daemon-reload
sudo systemctl enable snapshot-proxy --now
systemctl is-active snapshot-proxy          # expect: active
systemctl is-enabled snapshot-proxy         # expect: enabled (survives reboot)
```

The unit binds **127.0.0.1 only** — verify nothing else can reach it:

```bash
sudo ss -lntpe | grep ':8891'    # expect a single listener on 127.0.0.1:8891
```

## 5. Standalone Test (no nginx involved)

Every route must return a valid JPEG directly from the loopback port:

```bash
python3 - <<'PY'
import json
import os
import subprocess

routes = json.load(open('/etc/onvif-mcp/snapshot_routes.json'))['routes']
failed = 0

for route in routes:
    out = '/tmp/s.jpg'
    url = f'http://127.0.0.1:8891/snapshot/{route}/'
    curl = subprocess.run(
        ['curl', '-s', '--max-time', '30', '-o', out, '-w', '%{http_code} %{content_type}', url],
        capture_output=True,
        text=True,
        timeout=35,
    )
    size = os.path.getsize(out) if os.path.exists(out) else 0
    kind = subprocess.run(['file', '-b', out], capture_output=True, text=True).stdout.strip()
    ok = curl.stdout.startswith('200 image/jpeg') and kind.startswith('JPEG image data')
    failed += 0 if ok else 1
    print(f'{route:60} {curl.stdout:18} sz={size:<8} {kind[:70]}')

raise SystemExit(failed)
PY
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

## 6. Add the Nginx Endpoint

Back up the site config first:

```bash
sudo cp --update=none /etc/nginx/sites-available/camera \
  "/etc/nginx/sites-available/camera.backup-$(date +%F)"
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

If `nginx -t` fails, restore the backup (`sudo cp <backup> /etc/nginx/sites-available/camera`)
and re-test before reloading.

## 7. End-to-End Verification

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

