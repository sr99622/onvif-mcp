# Adding a New Camera

## Prerequisites

1. Camera must be connected to one of the server's network interfaces.
2. Camera credentials are known (RTSP username and password, used for MediaMTX source URL construction).

Values supplied by Agent

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

## Step 4 — Verify

Run this verification script:

```bash
python3 -c '
import json, sys

errors = []

# camera_registry.json — main stream AND substream URLs must be present
with open("{{REPO_PATH}}/onvif-mcp/apps/outputs/camera_registry.json") as f:
    data = json.load(f)

required_keys = ("hostname", "ip_address", "media_player_url", "substream_player_url")
for cam in data["cameras"]:
    for key in required_keys:
        if key not in cam:
            name = cam.get("hostname", "?")
            errors.append(name + " missing " + key)
print("registry OK: %d cameras, all fields present" % len(data["cameras"]))

# MediaMTX paths — every registry URL (main and substream) must map to a path
with open("/etc/mediamtx/mediamtx.yml") as f:
    config = f.read()

for cam in data["cameras"]:
    name = cam.get("hostname", "?")
    for key in ("media_player_url", "substream_player_url"):
        url = cam.get(key)
        if not url:
            continue  # already reported as missing above
        url_parts = url.replace("https://{{SERVER_FQDN}}/webrtc/", "").rstrip("/").split("/")
        path_name = "/".join(url_parts[:2]) if len(url_parts) >= 2 else url_parts[0]
        if path_name in config:
            print("mediamtx OK: %s (%s)" % (name, path_name))
        else:
            errors.append("Missing MediaMTX path for %s: %s" % (name, path_name))
    if cam.get("media_player_url") == cam.get("substream_player_url"):
        print("WARN: %s substream_player_url is identical to media_player_url" % name)

if errors:
    for e in errors:
        print("FAIL: " + e, file=sys.stderr)
    sys.exit(1)

print("\nAll checks passed.")
'
```

Expected output should show every camera passing both registry and MediaMTX checks.

## Notes

- **Single source of truth**: `{{REPO_PATH}}/onvif-mcp/apps/outputs/camera_registry.json` feeds both the cameras app (`apps/cameras/app.js`) and multiview app (`apps/multiview/app.js`). Adding entries here automatically updates all UIs.
- **MediaMTX hot-reload**: `/etc/mediamtx/mediamtx.yml` is re-read on new client connections — no service restart needed after adding path entries.
- **Credentials in config**: RTSP passwords are stored in plaintext in the MediaMTX config (`source: rtsp://user:pass@...`). Keep this file protected (permissions 600) and avoid committing it to version control.
