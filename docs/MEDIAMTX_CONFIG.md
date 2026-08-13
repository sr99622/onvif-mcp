# MediaMTX Server Configuration

This document describes the MediaMTX RTSP-to-WebRTC/HLS streaming server deployed on `gmktec.home.arpa`. It pulls live video from IP cameras and makes them available via WebRTC for browser playback.

## Deployment Details

| Item | Value |
|------|-------|
| Server URL | https://gmktec.home.arpa/webrtc/ |
| Binary | `/usr/local/bin/mediamtx` |
| Config | `/etc/mediamtx/mediamtx.yml` |
| Service | `sudo systemctl status mediamtx` (system service, multi-user.target) |
| User | `mediamtx:mediamtx` (dedicated system user) |

## Protocols & Ports

| Protocol | Port(s) | Status | Use |
|----------|---------|--------|-----|
| RTSP | **127.0.0.1:8554** (TCP only) | **Enabled** | Camera pulls (loopback only — not accessible from LAN) |
| WebRTC | :8889 (TCP HTTP), :8189 (UDP ICE) | **Enabled** | Browser live streams |
| HLS | :8888 | Disabled | Low-latency HLS segments |
| RTMP | :1935 | Disabled | RTMP ingest |
| SRT | :8890 | Disabled | Secure Reliable Transport |

Note: UDP RTP (ports 8000, 8001) and multicast ports (8002, 8003) are **disabled**. Camera streams are pulled over TCP interleaved within the RTSP connection. This reduces exposed attack surface while WebRTC clients continue working normally through port 8889.

## Camera Streams

MediaMTX pulls from 7 physical cameras across multiple profiles. Each camera exposes two (or more) named paths in the YAML config:

### Summary Table

| Camera Name / Serial | IP Address | Profile/Path | Description |
|----------------------|------------|--------------|-------------|
| DS-2CD2142FWD-IS (`DS-2CD2142022579764`) | 10.1.1.70 | `Profile_1` (Channel 101) | Main stream - H264 |
| DS-2CD2142FWD-IS (`DS-2CD2142022579764`) | 10.1.1.70 | `Profile_2` (Channel 102) | Sub stream - occasional auth failures |
| ND021810001394 (Dahua) | 10.1.1.72 | `MediaProfile000` | Main stream - H264 + Audio |
| ND021810001394 (Dahua) | 10.1.1.72 | `MediaProfile001` | Sub stream - H264 + Audio |
| AMC015906KDB241289 (Amcrest) | 10.1.1.68 | `MediaProfile000` | Main stream - H264 + G711 + Generic |
| AMC015906KDB241289 (Amcrest) | 10.1.1.68 | `MediaProfile001` | Sub stream - H264 + G711 + Generic |
| AMC014641NE6L35AT8 (Amcrest) | 10.1.1.71 | `MediaProfile000` | Main stream - H264 + MPEG-4 Audio + Generic |
| AMC014641NE6L35AT8 (Amcrest) | 10.1.1.71 | `MediaProfile001` | Sub stream - H264 + MPEG-4 Audio + Generic |
| ACCC8E99C915 (HIKVISION) | 10.1.1.67 | `profile_1_h264` | Main profile 1 H264 |
| ACCC8E99C915 (HIKVISION) | 10.1.1.67 | `profile_1_jpeg` | MJPEG substream |
| ACCC8E99C915 (HIKVISION) | 10.1.1.67 | `profile0` | Alternate profile 0 |
| ACCC8E99C915 (HIKVISION) | 10.1.1.67 | `profile1` | Alternate profile 1 |

Note: There are 7 physical cameras but 12 named paths in the config, since some cameras have multiple profile streams configured.

### RTSP Source URLs (credentials redacted)

All cameras use the same credentials (`admin` / `<redacted>`). Source URIs follow these patterns:

- **HIKVISION DS-2CD:** `rtsp://admin:***@10.1.1.70:554/Streaming/Channels/101?transportmode=unicast&profile=Profile_1`
- **Dahua:** `rtsp://admin:***@10.1.1.72:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif`
- **Amcrest:** `rtsp://admin:***@10.1.1.68:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif`
- **HIKVISION ONVIF:** `rtsp://admin:***@10.1.1.67/onvif-media/media.amp?profile=profile_1_h264&sessiontimeout=60&streamtype=unicast`

## Authentication

MediaMTX uses **internal database mode** with permissive access rules — no password is required for any user (`pass:` is empty). The config grants full permissions (publish, read, playback) to all cameras:

```yaml
authMethod: internal
authInternalUsers:
  - user: any         # anonymous/unauthenticated users
    pass:             # no password required
    ips: []           # allow from any IP
    permissions:
      - action: publish
      - action: read
      - action: playback
```

The localhost address (`127.0.0.1`, `::1`) also gets API, metrics, and PPROF access for local tooling.

## Nginx Integration

MediaMTX is accessed through Nginx at `/webrtc/` with these key settings:

- **Proxy target:** `http://127.0.0.1:8889/` (MediaMTX WebRTC listener)
- **Protocol rewrite:** `proxy_redirect / /webrtc/` so relative URLs get the correct path prefix
- **WebSocket upgrade:** Required for WebRTC data channels and ICE candidates
- **Auth protection:** `/webrtc/` is protected by oauth2-proxy (Keycloak) via Nginx `auth_request`

The proxy also forwards `X-Forwarded-*` headers so MediaMTX can log the real client IP.

## Operations

### Check status and logs
```bash
sudo systemctl status mediamtx --no-pager
sudo journalctl -u mediamtx -f                    # live logs
sudo tail -n 50 /var/log/mediamtx/mediamtx.log     # file log
```

### Restart
```bash
sudo systemctl restart mediamtx
```

### View running cameras (from status output)
MediaMTX prints a startup line showing which paths have online streams. Look for:
- `INF [path <name>] stream is available and online, N track(s)` = healthy
- `ERR [path <name>] bad status code: 401` = camera auth failure (occurs on HIKVISION Profile_2)

### Adding a new camera
1. Add a new path entry in `/etc/mediamtx/mediamtx.yml`:
```yaml
paths:
  NewCameraName/Profile_1:
    source: rtsp://admin:<password>@<camera_ip>:554/path_to_stream
```
2. Reload and restart:
```bash
sudo systemctl daemon-reload   # not needed for config changes, only service file changes
sudo systemctl restart mediamtx
```

### Removing a camera
Delete the path entry from `/etc/mediamtx/mediamtx.yml` and restart.

## Security Notes

- Camera credentials are embedded in RTSP URLs in the config file (`/etc/mediamtx/mediamtx.yml`). Keep this file protected.
- MediaMTX listens on `0.0.0.0` (all interfaces) for its native ports, but these should never be reached directly from the LAN — access flows through Nginx at `/webrtc/`.
- The oauth2-proxy + Keycloak authentication at the Nginx layer is what actually protects the streams in production. Without it, anyone on the network who can reach port 8889 would get a live stream.
- All cameras use default credentials (`admin` / `admin123`). Changing them should be scheduled for a maintenance window if possible.

## Related Documents

- **SYSTEMD_SETUP.md** — service startup and management
- **STREAM_AUTH.md** — browser authentication (Keycloak/oauth2-proxy)
- **HTTPS.md** — TLS certificate setup for gmktec.home.arpa
- **DESIGN.md** — overall ONVIF MCP architecture
- **KEYCLOAK.md** — Keycloak realm and client configuration
