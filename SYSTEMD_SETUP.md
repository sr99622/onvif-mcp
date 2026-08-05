# SystemD Service Setup

This document describes the systemd user services configured for automatic startup.

## Services

### 1. MediaMTX Streaming Server

**Service File:** `~/.config/systemd/user/mediamtx.service`

**Executable:** `/home/stephen/.local/bin/mediamtx /home/stephen/.local/bin/mediamtx.yml`

**Config File:** `/home/stephen/.local/bin/mediamtx.yml`

**Status:** Running (PID 3428)

**Configuration:**
- Automatically starts on user login/boot
- Restarts on failure with 5-second delay
- Logs available via: `journalctl --user -u mediamtx -f`

**Note:** The config file path is explicitly specified in the service file because MediaMTX doesn't automatically find config files outside its working directory. The config contains RTSP URLs with camera credentials.

**Commands:**
```bash
# Check status
systemctl --user status mediamtx

# Restart
systemctl --user restart mediamtx

# Disable auto-start
systemctl --user disable mediamtx

# Enable auto-start
systemctl --user enable mediamtx
```

---

### 2. ONVIF MCP HTTP Server

**Service File:** `~/.config/systemd/user/onvif-mcp.service`

**Executable:** `/home/stephen/.local/bin/uv run /home/stephen/Projects/onvif-mcp/packages/http/src/onvif_mcp_http/main.py`

**Working Directory:** `/home/stephen/Projects/onvif-mcp`

**Status:** Running (PID 2532)

**Environment Variables:**
- `CAMERA_USERNAME=admin`
- `CAMERA_PASSWORD=***`
- `STREAM_SERVER_URL=https://camera.home.arpa/webrtc`
- `UV_PROJECT_ENVIRONMENT=/home/stephen/Projects/onvif-mcp/.venv`

**URL:** http://10.1.1.3:8000

**Dependencies:** Mediamtx (starts after mediamtx.service)

**Configuration:**
- Automatically starts on user login/boot
- Waits for MediaMTX to start first (`Wants=mediamtx.service`)
- Restarts on failure with 5-second delay
- Logs available via: `journalctl --user -u onvif-mcp -f`

**Commands:**
```bash
# Check status
systemctl --user status onvif-mcp

# Restart
systemctl --user restart onvif-mcp

# Disable auto-start
systemctl --user disable onvif-mcp

# Enable auto-start
systemctl --user enable onvif-mcp
```

---

## Restarting Services After Config Changes

If you modify the service file (e.g., to add environment variables):

```bash
systemctl --user daemon-reload
systemctl --user restart mediamtx
systemctl --user restart onvif-mcp
```

To check service logs in real-time:

```bash
# MediaMTX logs
journalctl --user -u mediamtx -f

# ONVIF MCP logs
journalctl --user -u onvif-mcp -f
```

## Configuration File Locations

**MediaMTX config:** `/home/stephen/.local/bin/mediamtx.yml`

This file contains:
- Path definitions for each camera with full RTSP URLs including credentials
- Server settings (ports, protocols, etc.)

Example paths:
```yaml
paths:
  4B0013BPAABE264/MediaProfile000:
    source: rtsp://admin:***@10.2.2.100:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif
  # ... more cameras
```

## Environment Variables

Systemd user services don't source `~/.bashrc`, so environment variables needed by the application must be explicitly defined in the service file using `Environment=` directives.

For the ONVIF MCP server, the following variables are required:
- `CAMERA_USERNAME` - Camera login username
- `CAMERA_PASSWORD` - Camera login password  
- `STREAM_SERVER_URL` - Base URL of the camera web player

## Notes

- User systemd services require the user session to be active
- Services are stored in `~/.config/systemd/user/`
- After editing service files, run `systemctl --user daemon-reload`
- Service files are located at the workspace root for easy reference
