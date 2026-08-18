# Systemd Service Setup

This document describes the systemd services configured on `gmktec.home.arpa` for automatic startup of ONVIF MCP infrastructure components.

## Services

### 1. MediaMTX RTSP Streaming Server

**Service File:** `/etc/systemd/system/mediamtx.service`

**Executable:** `/usr/local/bin/mediamtx`

**Config File:** `/etc/mediamtx/mediamtx.yml`

**Working Directory:** `/var/log/mediamtx`

**User/Group:** `mediamtx:mediamtx` (dedicated system user)

**Status:** Running as a **system service** (not user service). Runs under `multi-user.target` so it starts at boot before any user login — essential for headless operation.

**Configuration:**
- Automatically starts at boot via `multi-user.target`
- Restarts on failure with 5-second delay
- Logs available via: `sudo journalctl -u mediamtx -f`
- Log file: `/var/log/mediamtx/mediamtx.log` (written by the process itself)

**Commands:**
```bash
# Check status
systemctl status mediamtx --no-pager

# Restart
sudo systemctl restart mediamtx

# Disable auto-start
sudo systemctl disable mediamtx

# Enable auto-start
sudo systemctl enable mediamtx

# View logs in real time
sudo journalctl -u mediamtx -f
```

---

### 2. ONVIF MCP HTTP Server

**Service File:** `/etc/systemd/user/onvif-mcp.service` (user service)

**Executable:** `/home/stephen/.local/bin/uv run /home/stephen/Projects/onvif-mcp/packages/http/src/onvif_mcp_http/main.py`

**Working Directory:** `/home/stephen/Projects/onvif-mcp`

**Status:** Running as a user service.

**Environment Variables:**
- `CAMERA_USERNAME=admin`
- `CAMERA_PASSWORD=***`
- `STREAM_SERVER_URL=https://camera.home.arpa/webrtc`
- `UV_PROJECT_ENVIRONMENT=/home/stephen/Projects/onvif-mcp/.venv`

**URL:** http://10.1.1.3:8000 (or the gmktec IP on port 8000)

**Dependencies:** MediaMTX (starts after mediamtx.service via `After=`)

**Configuration:**
- Automatically starts on user login/boot
- Waits for MediaMTX to start first
- Restarts on failure with 5-second delay
- Logs available via: `journalctl --user -u onvif-mcp-http -f` (note the full service name — check `systemctl --user list-units` for the exact name)

**Commands:**
```bash
# Check status
systemctl --user status onvif-mcp-http  # or whatever the unit name is

# Restart
systemctl --user restart onvif-mcp-http

# Disable auto-start
systemctl --user disable onvif-mcp-http

# Enable auto-start
systemctl --user enable onvif-mcp-http
```

---

## Restarting Services After Config Changes

### MediaMTX (system service)
```bash
sudo systemctl daemon-reload
sudo systemctl restart mediamtx
```

### ONVIF MCP HTTP Server (user service)
```bash
systemctl --user daemon-reload
systemctl --user restart onvif-mcp-http  # or whatever the unit name is
```

---

## Configuration File Locations

| Component | Config Path | Description |
|-----------|-------------|-------------|
| MediaMTX | `/etc/mediamtx/mediamtx.yml` | Camera RTSP source URLs, server settings (ports, protocols), path definitions |
| Nginx | `/etc/nginx/sites-enabled/camera-apps-https` | Reverse proxy config for camera web apps and MediaMTX WebRTC proxy |

### Key details in `/etc/mediamtx/mediamtx.yml`:
- **paths:** Maps each camera + profile combination to an RTSP pull source URL (with embedded credentials)
- **rtsp:** Enabled on port 8554 (TCP), with UDP RTP ports at 8000/8001
- **webrtc:** Enabled on port 8889 (TCP) and ICE listener on 8189 (UDP)
- **hls, rtmp, srt, moq:** Disabled

### Key details in `/etc/nginx/sites-enabled/camera-apps-https`:
- Proxies `/webrtc/` to MediaMTX port 8889 with WebSocket upgrade headers
- Protects `/cameras/`, `/multiview/`, `/outputs/`, `/webrtc/` with oauth2-proxy auth
- Serves static camera app content from document root

---

## Troubleshooting

### Service won't start after config change
```bash
# Verify systemd can parse the service file
systemd-analyze verify /etc/systemd/system/mediamtx.service 2>&1 | head -20

# Check what's going on
sudo journalctl -u mediamtx --since "5 minutes ago"
```

### MediaMTX logs show authentication errors on camera
```bash
# Watch live logs
sudo journalctl -u mediamtx -f
```

Common issue: an HIKVISION camera (e.g., DS-2CD2142FWD-IS) returns 401 Unauthorized on one profile while the other works. This is a known intermittent auth failure with some camera firmware — restart MediaMTX or reconnect the camera.

### Nginx config validation
```bash
sudo nginx -t
```

### Service not at boot
Verify it's enabled:
```bash
systemctl is-enabled mediamtx       # should say "enabled"
systemctl list-unit-files | grep mediamtx
```
