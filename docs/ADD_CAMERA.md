# Adding a New Camera

## Prerequisites

1. Camera must be connected to one of the server's network interfaces.
2. Camera credentials are known (RTSP username and password, used for MediaMTX source URL construction).

## Values supplied by Agent

| Value           | Description                                 |
|-----------------|-----------------------------------------------|
| {{SERVER_FQDN}} | Server Fully Qualified Domain Name          |
| {{REPO_PATH}}   | Parent directory containing the onvif-mcp repository (repo lives at `{{REPO_PATH}}/onvif-mcp`) |
| {{USERNAME}}    | Camera username                             |
| {{PASSWORD}}    | Camera password                             |


## Step 1 — Discover the Camera on the Network

Run ONVIF discovery to get all camera details:

```bash
# Fully-qualified name depends on MCP server configuration; bare tool name is get_cameras
# Returns structured data with hostname, IP, profiles, stream URIs, serial number
get_cameras
```

From the output, identify your new camera and note:
- **hostname** — used as a human-readable identifier
- **ip_address** — for both MediaMTX source URL and registry entry
- **serial_number** — used to construct MediaMTX path names (e.g. `AMC014641NE6L35AT8/Profile_1`)
- **stream URIs** — RTSP stream paths needed for the MediaMTX `source` field

## Step 2 — Add Entry to Camera Registry

Edit `{{REPO_PATH}}/onvif-mcp/apps/outputs/camera_registry.json`.

Add a new object inside the `"cameras"` array. Each entry requires:
- `hostname`, `ip_address`, `manufacturer`, `model` — descriptive metadata
- `media_player_url` — **required**: HTTPS URL to the MediaMTX WebRTC player for the main stream, using serial_number as path component
- `substream_player_url` — **required**: same format as media_player_url, using the substream profile

Format:

```json
{
  "hostname": "CameraName",
  "ip_address": "10.x.x.x",
  "manufacturer": "Maker",
  "model": "Model",
  "media_player_url": "https://{{SERVER_FQDN}}/webrtc/<serial_number>/<stream_token>/",
  "substream_player_url": "https://{{SERVER_FQDN}}/webrtc/<serial_number>/<substream_token>/"
}
```

The `serial_number` and `stream_token` in the URL must match the MediaMTX path name (see Step 3). Examples from existing entries:

| Manufacturer | Serial Number Prefix Used in URL | Stream Token Format |
|-------------|----------------------------------|---------------------|
| HIKVISION   | DS-2CD...BBWR                     | Profile_1 / Profile_2 |
| LOREX       | NDxxxx                            | MediaProfile000 / MediaProfile001 |
| Amcrest     | AMCxxxx                           | MediaProfile000 / MediaProfile001 |
| AXIS        | ACCCxxxx                          | profile_1_h264, profile_1_jpeg, profile0, profile1 |
| TRENDnet    | TV-IP319PI...AAWR                 | Profile_1 / Profile_2 |

Update the `"generated"` timestamp to the current date.

## Step 3 — Add MediaMTX Path Entries

Edit `/etc/mediamtx/mediamtx.yml` in the `paths:` section. Each camera profile gets its own path entry with a unique name and an RTSP `source` URL.

Format:

```yaml
  <serial_number>/<stream_token>:
    source: rtsp://{{USERNAME}}:{{PASSWORD}}@<ip_address>:554/<rtsp_stream_path>
```

Add one entry per profile (main stream + substream). The path name must match the corresponding URL component in `camera_registry.json` so the web UI streams appear correctly.

Example for a Dahua camera:

```yaml
  ND021810001394/MediaProfile000:
    source: rtsp://admin:admin123@10.1.1.72:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif
  ND021810001394/MediaProfile001:
    source: rtsp://admin:admin123@10.1.1.72:554/cam/realmonitor?channel=1&subtype=1&unicast=true&proto=Onvif
```

Note: MediaMTX hot-loads the config — **no restart needed** after editing.

## Step 4 — Add Snapshot Proxy Route Entries

Skip this step only if the camera's `<serial_number>/<token>` pairs already have
entries in `{{REPO_PATH}}/onvif-mcp/services/snapshot_proxy.py` (some cameras are
pre-registered there). Without these entries, the camera's `web_snapshot_url`
links in the apps and MCP silently return 404 — nothing else fails loudly.

Edit the `ROUTES` dict in `{{REPO_PATH}}/onvif-mcp/services/snapshot_proxy.py`.
One entry per profile token used by the fleet (main stream AND every substream):

```python
ROUTES: dict[str, str] = {
    ...
    "<serial_number>/<profile_token>": "http://<camera_ip>/<vendor-specific-snapshot-path>?params",
}
```

- The key must match the registry/MediaMTX path name **exactly** (the proxy does
  exact string lookup, no normalization).
- Use the snapshot path the camera actually serves a JPEG from — not always the
  literal `snapshot_uri` reported by ONVIF. Add explanatory comments for
  non-obvious entries. A camera may share one snapshot endpoint across all its
  profile tokens (several keys pointing at the same URI is correct in that case).
- The proxy performs the camera-side Basic/Digest handshake itself and validates
  the upstream response is a JPEG before serving it; a camera that returns
  non-JPEG surfaces as a 502 rather than a corrupted image.

Example for a REOLINK camera (shared upstream for all tokens):

```python
    "19216868252/000": "http://192.168.68.252/cgi-bin/api.cgi?cmd=onvifSnapPic&channel=0",
    "19216868252/001": "http://192.168.68.252/cgi-bin/api.cgi?cmd=onvifSnapPic&channel=0",  # shared upstream for all tokens
```

Then restart the service (unlike MediaMTX, it does not hot-reload):

```bash
sudo systemctl restart snapshot-proxy
systemctl is-active snapshot-proxy          # expect: active
```

Test each new route directly on the loopback port before proceeding to Step 5;
SNAPSHOT.md Step 3 covers details and vendor quirks:

```bash
for r in <serial>/<token> ... ; do        # one per new ROUTES entry
  curl -s --max-time 30 -o /tmp/s.jpg -w '%{http_code} %{content_type} ' \
    "http://127.0.0.1:8891/snapshot/$r/"
  file -b /tmp/s.jpg | cut -c1-16; echo " ($r)"
done
```

Every route must show `200 image/jpeg` and `JPEG image data`. If one fails,
read the service log: it distinguishes auth/transport failure from a non-JPEG
camera response.

## Step 5 — Verify

Run this verification script. It needs root (sudo): `/etc/mediamtx/mediamtx.yml`
is owned by `mediamtx` and is not readable by unprivileged users.

```bash
sudo python3 - <<'EOF'
import json, re, sys

repo = "{{REPO_PATH}}"
fqdn = "{{SERVER_FQDN}}"
proxy_py = repo + "/onvif-mcp/services/snapshot_proxy.py"

errors = []
warnings = []

# --- camera_registry.json: main AND substream URLs present --------------------
with open(repo + "/onvif-mcp/apps/outputs/camera_registry.json") as f:
    data = json.load(f)

required_keys = ("hostname", "ip_address", "media_player_url", "substream_player_url")
for cam in data["cameras"]:
    for key in required_keys:
        if key not in cam:
            errors.append(cam.get("hostname", "?") + " missing " + key)
print("registry OK: %d cameras, all fields present" % len(data["cameras"]))

# --- MediaMTX paths: every registry URL maps to a path -------------------------
with open("/etc/mediamtx/mediamtx.yml") as f:
    config = f.read()

pairs = []
for cam in data["cameras"]:
    name = cam.get("hostname", "?")
    for key in ("media_player_url", "substream_player_url"):
        url = cam.get(key)
        if not url:
            continue  # already reported as missing above
        url_parts = url.replace("https://%s/webrtc/" % fqdn, "").rstrip("/").split("/")
        path_name = "/".join(url_parts[:2]) if len(url_parts) >= 2 else url_parts[0]
        pairs.append((name, key, path_name))
        if path_name in config:
            print("mediamtx OK: %s (%s)" % (name, path_name))
        else:
            errors.append("Missing MediaMTX path for %s: %s" % (name, path_name))
    if cam.get("media_player_url") == cam.get("substream_player_url"):
        warnings.append("%s substream_player_url is identical to media_player_url" % name)

# --- snapshot-proxy routes: every serial/token pair must have a ROUTES entry ---
# (missing entries mean the camera's web_snapshot_url silently does not work;
#  see SNAPSHOT.md Step 3 — add them there, then restart snapshot-proxy)
routes = re.findall(r'^\s*"([^"]+)"\s*:', open(proxy_py).read(), re.M)
for name, _key, path_name in pairs:
    if path_name not in routes:
        errors.append("Missing snapshot-proxy ROUTES entry for %s: %s" % (name, path_name))
    else:
        print("snapshot OK: %s (%s)" % (name, path_name))

for w in warnings:
    print("WARN: " + w)
if errors:
    for e in errors:
        print("FAIL: " + e, file=sys.stderr)
    sys.exit(1)
print("\nAll checks passed.")
EOF
```

Then verify the new camera's stream actually passes through MediaMTX (which
hot-reloads `/etc/mediamtx/mediamtx.yml` on new client connections). Replace
`<new path name>` with one of the paths added in Step 3:

```bash
ffprobe -hide_banner -rtsp_transport tcp rtsp://127.0.0.1:8554/<new\ path\ name> | grep -E 'Input|Stream'
```

Expect the camera's video (and audio, if present) streams listed under the
`Input #0` line — that proves both that the new config entry was loaded and
that the RTSP `source` with its credentials actually connects. Skip this check
only if ffprobe is unavailable; it cannot be substituted with the MediaMTX
HTTP API on this deployment (`api: false`).

Expected output should show every camera passing all three checks, followed by
the live stream listing for the new camera.

## Notes

- **Single source of truth**: `{{REPO_PATH}}/onvif-mcp/apps/outputs/camera_registry.json` feeds both the cameras app (`apps/cameras/app.js`) and multiview app (`apps/multiview/app.js`). Adding entries here automatically updates all UIs.
- **MediaMTX hot-reload**: `/etc/mediamtx/mediamtx.yml` is re-read on new client connections — no service restart needed after adding path entries.
- **Credentials in config**: RTSP passwords are stored in plaintext in the MediaMTX
  config (`source: rtsp://user:pass@...`). Avoid committing it to version control.
  Permissions on this deployment are `0640 mediamtx:mediamtx` — readable by the
  mediamtx service group only, which is workable but wider than ideal for a file
  holding credentials; if you (re)install it fresh, `chmod 600` it and keep it
  root- or mediamtx-owned. Note the file is not world-readable: Step 5's
  verification script must run as root.
