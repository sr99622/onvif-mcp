# ONVIF Camera MCP HTTP Server

## Overview

The `onvif-mcp-http` package provides an HTTP-based MCP (Model Context Protocol) server for discovering and controlling ONVIF cameras on the local network. It exposes 28 tools through a Streamable HTTP transport (SSE + POST), accessible both locally on port 8001 and externally through nginx at `http://nuc.home.arpa/mcp/`.

## Current State

- **Service**: `onvif-mcp-http.service` — running, enabled for auto-start on boot
- **Local endpoint**: `http://127.0.0.1:8001/mcp`
- **Nginx proxy**: `http://nuc.home.arpa/mcp/` (forwarded to port 8001)
- **Python venv**: `/home/stephen/Projects/onvif-mcp/.venv`
- **Executable**: `/home/stephen/Projects/onvif-mcp/.venv/bin/onvif-mcp-http`
- **Source**: `packages/http/src/onvif_mcp_http/main.py`

## Nginx Proxy Configuration

**File**: `/etc/nginx/sites-available/camera-mcp` (symlinked to `sites-enabled/`)

```nginx
server {
    listen 80;
    server_name nuc.home.arpa;

    # MCP endpoint - exact match to avoid redirect issues with POST
    location = /mcp {
        proxy_pass http://127.0.0.1:8001/mcp;
        proxy_redirect off;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Handle trailing slash variant - redirect to no-slash version
    location = /mcp/ {
        return 301 http://$host/mcp;
    }
}
```

**Key points:**
- Uses `location = /mcp` (exact match) because the MCP server redirects `/mcp/` to `/mcp`, and POST requests don't survive the redirect. Nginx must forward directly to `/mcp` without trailing slash.
- Proxy headers include Upgrade/Connection for SSE, plus standard forwarded headers.

## systemd Service

**File**: `/etc/systemd/system/onvif-mcp-http.service`

```ini
[Unit]
Description=ONVIF Camera MCP HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=stephen
WorkingDirectory=/home/stephen/Projects/onvif-mcp
Environment=MCP_HTTP_HOST=127.0.0.1
Environment=MCP_HTTP_PORT=8001
Environment=CAMERA_USERNAME=admin
Environment=CAMERA_PASSWORD=admin123
Environment=STREAM_SERVER_URL=https://nuc.home.arpa
ExecStart=/home/stephen/Projects/onvif-mcp/.venv/bin/onvif-mcp-http
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**Management commands:**
```bash
systemctl status onvif-mcp-http          # Check status
journalctl -u onvif-mcp-http -f           # Follow logs
systemctl restart onvif-mcp-http          # Restart after code changes
sudo systemctl disable onvif-mcp-http     # Disable auto-start
```

## Bug Fix: Broken Pipe on `get_cameras`

### Problem

Calling `get_cameras()` or `get_cameras_by_adapter()` through the MCP HTTP server returned:
```json
{"error": {"message": "Broken pipe"}, ...}
```

### Root Cause

`libonvif.discover()` contains a hardcoded `print("Discovering cameras on {ip_address}...")` that writes to stdout. When called during an active SSE (Server-Sent Events) stream, this stdout output interferes with the MCP transport layer, causing a "Broken pipe" error. The direct CLI call works fine because it runs in a standalone process; only the HTTP server is affected.

### Fix

Modified `/home/stephen/Projects/onvif-mcp/packages/core/src/onvif_mcp_core/camera_queries.py` to redirect stdout to `/dev/null` during `libonvif.discover()` calls. This was applied in both `get_cameras()` and `get_cameras_by_adapter()`:

```python
for adapter_ip in adapter_ips:
    logger.debug("Discovering cameras on adapter %s", adapter_ip)
    with open(os.devnull, "w") as devnull:
        import sys
        old_stdout = sys.stdout
        try:
            sys.stdout = devnull
            cameras = discover(
                adapter_ip,
                _get_camera_credentials,
                on_error=_on_error,
                camera_filled=_camera_filled,
                use_threads=True,
            )
        finally:
            sys.stdout = old_stdout
```

## MCP Protocol Usage (curl examples)

The MCP Streamable HTTP transport uses a session-based handshake. All requests must carry the session ID from the initialize response.

### Step 1: Initialize

```bash
INIT=$(curl -sD- \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl-test","version":"1.0"}}}' \
  http://nuc.home.arpa/mcp)

SESSION_ID=$(echo "$INIT" | grep -i "^mcp-session-id:" | awk '{print $2}' | tr -d '\r')
```

### Step 2: Send Initialized Notification

```bash
curl -s \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -H "mcp-session-id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  http://nuc.home.arpa/mcp
```

### Step 3: List Available Tools

```bash
curl -s \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -H "mcp-session-id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  http://nuc.home.arpa/mcp
```

### Step 4: Call a Tool (get_cameras)

```bash
curl -s \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -H "mcp-session-id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_cameras","arguments":{}}}' \
  http://nuc.home.arpa/mcp
```

### Step 5: Call a Tool (get_adapters)

```bash
curl -s \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -H "mcp-session-id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_adapters","arguments":{}}}' \
  http://nuc.home.arpa/mcp
```

## Discovered Cameras

| IP Address | Hostname |
|------------|----------|
| 10.1.1.70 | Hikvision |
| 10.1.1.72 | Kitchen |
| 10.1.1.68 | Driveway |
| 10.1.1.71 | Monopoly |
| 10.1.1.67 | Office |

## Available MCP Tools (28 total)

Video configuration: `set_camera_video_resolution`, `set_camera_video_frame_rate`, `set_camera_video_bitrate`, `set_camera_video_gov_length`
Audio configuration: `set_camera_audio_encoding`, `set_camera_audio_sample_rate`
PTZ controls: `goto_camera_preset`, `set_camera_preset`, `remove_camera_preset`, `create_camera_preset_tour`, `set_camera_preset_tour`, `remove_camera_preset_tour`, `start_camera_preset_tour`, `stop_camera_preset_tour`, `pan_tilt_camera`, `zoom_camera`, `stop_camera_pan_tilt`, `stop_camera_zoom`
Device management: `change_camera_hostname`, `sync_camera_time`, `reboot_camera`
Queries: `get_cameras`, `get_cameras_by_adapter`, `get_camera`, `get_web_player_url`, `get_adapters`, `get_camera_mcp_version`, `example_elicit_tool`

## Architecture Diagram

```
                    ┌─────────────────────┐
External clients  │                     │   natively uses MCP protocol.
    ─────────────►│  Nginx (:80)        │
                  │  nuc.home.arpa/mcp/ │
                  └──────────┬──────────┘
                             │ reverse proxy
                             ▼
┌─────────────────────────────────────────────────┐
│              systemd: onvif-mcp-http.service     │
│                                                  │
│  /home/stephen/Projects/onvif-mcp/.venv/bin/     │
│  python3 -m onvif_mcp_http.main                  │
│                                                  │
│  Listens on http://127.0.0.1:8001/mcp            │
│  Uses uvicorn (ASGI server) for Streamable HTTP  │
│  transport (SSE + POST).                         │
│                                                  │
│  Environment:                                    │
│    CAMERA_USERNAME=admin                         │
│    CAMERA_PASSWORD=admin123                      │
│    STREAM_SERVER_URL=https://nuc.home.arpa       │
│    MCP_HTTP_HOST=127.0.0.1                       │
│    MCP_HTTP_PORT=8001                            │
└──────────────┬───────────────────────────────────┘
               │ libonvif.discover() (stdout suppressed)
               ▼
          ┌─────────────┐
          │ ONVIF       │
          │ Cameras on  │
          │ 10.1.1.x    │
          └─────────────┘
```

## Troubleshooting

### Service fails to start

Check logs: `journalctl -u onvif-mcp-http -n 50 --no-pager`
Verify port is free: `ss -tlnp | grep 8001`
Check environment variables are set in the service file.

### MCP calls return "Broken pipe"

This was caused by `libonvif.discover()` printing to stdout which conflicted with SSE streams. The fix redirects stdout to `/dev/null` during discovery. If this bug recurs in a future libonvif version, look for similar `print()` statements in the `discover()` function and suppress them via stdout redirection.

### Nginx returns 421 Misdirected Request

The MCP server validates the Host header for DNS rebinding protection. Ensure nginx proxies with `proxy_set_header Host $host;` so the backend receives the correct hostname. Direct curl to `http://127.0.0.1:80/mcp` will fail — always access via the hostname (`nuc.home.arpa`) or add the server IP to the allowed hosts list in `main.py`.

### Camera discovery returns empty results

Check that cameras are on the same subnet as the server's network adapters. Use `get_adapters` first, then verify camera IPs are reachable from those subnets. The `get_cameras_by_adapter("10.1.1.6")` tool can test a specific adapter.
