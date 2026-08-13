# Adding a New Camera

## Prerequisites

1. Camera must be connected to one of the server's network interfaces (either `enp171s0` / 10.1.1.x or `enp170s0` / 10.2.2.x).
2. Camera IP address is assigned via dnsmasq DHCP or set statically.
3. Camera credentials are known (RTSP username and password, used for MediaMTX source URL construction).

## Step 1 — Discover the Camera on the Network

Run ONVIF discovery to get all camera details:

```bash
# Returns structured data with hostname, IP, profiles, stream URIs, serial number
mcp__cameras__get_cameras
```

From the output, identify your new camera and note:
- **hostname** — used as a human-readable identifier
- **ip_address** — for both MediaMTX source URL and registry entry
- **serial_number** — used to construct MediaMTX path names (e.g. `AMC014641NE6L35AT8/Profile_1`)
- **stream URIs** — RTSP stream paths needed for the MediaMTX `source` field

## Step 2 — Add Entry to Camera Registry

Edit `/home/stephen/Projects/onvif-mcp/apps/outputs/camera_registry.json`.

Add a new object inside the `"cameras"` array. Each entry requires:
- `hostname`, `ip_address`, `manufacturer`, `model` — descriptive metadata
- `media_player_url` — **required**: HTTPS URL to the MediaMTX WebRTC player for the main stream, using serial_number as path component
- `substream_player_url` — optional but recommended: same format for substream

Format:

```json
{
  "hostname": "CameraName",
  "ip_address": "10.x.x.x",
  "manufacturer": "Maker",
  "model": "Model",
  "media_player_url": "https://gmktec.home.arpa/webrtc/<serial_number>/<stream_token>/",
  "substream_player_url": "https://gmktec.home.arpa/webrtc/<serial_number>/<substream_token>/"
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
    source: rtsp://<username>:<password>@<ip_address>:554/<rtsp_stream_path>
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

# camera_registry.json
with open("/home/stephen/Projects/onvif-mcp/apps/outputs/camera_registry.json") as f:
    data = json.load(f)

for cam in data["cameras"]:
    for key in ("hostname", "ip_address", "media_player_url"):
        if key not in cam:
            errors.append(f"{cam.get(\"hostname\",\"?\")} missing \"{key}\"")
print(f"registry OK: {len(data[\"cameras\"])} cameras, all fields present")

# MediaMTX paths — check every camera registry entry maps to a path
with open("/etc/mediamtx/mediamtx.yml") as f:
    config = f.read()

for cam in data["cameras"]:
    url_parts = cam["media_player_url"].replace("https://gmktec.home.arpa/webrtc/", "").rstrip("/").split("/")
    path_name = url_parts[0] + "/" + url_parts[1] if len(url_parts) >= 2 else url_parts[0]
    if path_name in config:
        print(f"mediamtx OK: {cam[\"hostname\"]} ({path_name})")
    else:
        errors.append(f"Missing MediaMTX path for {cam[\"hostname\"]}: {path_name}")

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)

print("\nAll checks passed.")
'
```

Expected output should show every camera passing both registry and MediaMTX checks.

## Troubleshooting

### Camera appears in discovery but doesn't load in the web UI

- Check that the MediaMTX path name in `/etc/mediamtx/mediamtx.yml` exactly matches the URL components used in `camera_registry.json`. The match is: `<serial>/<profile_token>` from the registry URL must exist as a key under `paths:` in the MediaMTX config.
- Check `/var/log/mediamtx/mediamtx.log` for connection errors on the RTSP source URL. A common issue is incorrect username/password or camera rejecting the connection from this server's IP.

### Camera shows in discovery but MediaMTX can't connect to it

- Verify the camera's IP is reachable: `ping 10.x.x.x` or `ping 192.168.x.x`
- Test the RTSP URL manually: `ffplay rtsp://admin:password@IP:554/path`
- Confirm credentials are correct — this is the #1 cause of "no stream" issues. The system-wide default credential is `admin:admin123` (configured in `/etc/systemd/system/onvif-mcp-http.service`). Many cameras use this as their actual password, but some set a custom one. If the camera has a different password, update the `source` line in `/etc/mediamtx/mediamtx.yml` accordingly.
- MediaMTX hot-reloads config on new client connections — no restart needed after editing. Check journalctl for errors: `journalctl -u mediamtx --no-pager -n 30`

### Camera appears on 10.2.2.x but no WebRTC stream

- The camera may need to be assigned a static IP reservation in dnsmasq or set statically on the device itself.
- Ensure `interface=enp170s0` and `dhcp-range=10.2.2.50,10.2.2.200,255.255.255.0,12h` are present in `/etc/dnsmasq.conf` (see `DNSMASQ_DNS_DHCP.md`).
- Check that the MediaMTX config is not blocking traffic from that subnet — review `readIPAllow` / `publishIPAllow` settings if present.

## Notes

- **Single source of truth**: `/home/stephen/Projects/onvif-mcp/apps/outputs/camera_registry.json` feeds both the cameras app (`apps/cameras/app.js`) and multiview app (`apps/multiview/app.js`). Adding entries here automatically updates all UIs.
- **MediaMTX hot-reload**: `/etc/mediamtx/mediamtx.yml` is re-read on new client connections — no service restart needed after adding path entries.
- **Credentials in config**: RTSP passwords are stored in plaintext in the MediaMTX config (`source: rtsp://user:pass@...`). Keep this file protected (permissions 600) and avoid committing it to version control.
- **No `substream_player_url` required**: The Office (AXIS M1065-LW) camera does not have a substream entry — it is optional but recommended for lower-bandwidth viewing.
