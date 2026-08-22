# ONVIF Camera MCP HTTP Server

## Variables Supplied by the Agent

| Config Variable | Description |
| --- | --- |
| {{SERVER_FQDN}} | Fully Qualified Domain Name of the Server |
| {{USERNAME}}    | Camera Username                           |
| {{PASSWORD}}    | Camera Password                           |
| {{REPO_PATH}}   | Full Pathname of Repository Location      |

## Overview

The `onvif-mcp-http` package provides an HTTP-based MCP (Model Context Protocol) server for discovering and controlling ONVIF cameras on the local network. It exposes 28 tools through a Streamable HTTP transport (SSE + POST), accessible both locally on port 8001 and externally through nginx at `http://{{SERVER_FQDN}}/mcp/`.

## Current State

- **Service**: `onvif-mcp-http.service` — running, enabled for auto-start on boot
- **Local endpoint**: `http://127.0.0.1:8001/mcp`
- **Nginx proxy**: `http://{{SERVER_FQDN}}/mcp/` (forwarded to port 8001)
- **Python venv**: `{{REPO_PATH}}/onvif-mcp/.venv`
- **Executable**: `{{REPO_PATH}}/onvif-mcp/.venv/bin/onvif-mcp-http`
- **Source**: `packages/http/src/onvif_mcp_http/main.py`

## Nginx Proxy Configuration

**File**: `/etc/nginx/sites-available/camera-mcp` (symlinked to `sites-enabled/`)

```nginx
server {
    listen 80;
    server_name {{SERVER_FQDN}};

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
WorkingDirectory={{REPO_PATH}}/onvif-mcp
Environment=MCP_HTTP_HOST=127.0.0.1
Environment=MCP_HTTP_PORT=8001
Environment=CAMERA_USERNAME=admin
Environment=CAMERA_PASSWORD=admin123
Environment=STREAM_SERVER_URL=https://{{SERVER_FQDN}}
ExecStart={{REPO_PATH}}/onvif-mcp/.venv/bin/onvif-mcp-http
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

## MCP Protocol Usage (curl examples)

The MCP Streamable HTTP transport uses a session-based handshake. All requests must carry the session ID from the initialize response.

### Step 1: Initialize

```bash
INIT=$(curl -sD- \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl-test","version":"1.0"}}}' \
  http://{{SERVER_FQDN}}/mcp)

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
  http://{{SERVER_FQDN}}/mcp
```

### Step 3: List Available Tools

```bash
curl -s \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -H "mcp-session-id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  http://{{SERVER_FQDN}}/mcp
```

### Step 4: Call a Tool (get_cameras)

```bash
curl -s \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -H "mcp-session-id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_cameras","arguments":{}}}' \
  http://{{SERVER_FQDN}}/mcp
```

### Step 5: Call a Tool (get_adapters)

```bash
curl -s \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -H "mcp-session-id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_adapters","arguments":{}}}' \
  http://{{SERVER_FQDN}}/mcp
```

## Architecture Diagram

```
                  ┌─────────────────────┐
External clients  │                     │   natively uses MCP protocol.
    ─────────────►│  Nginx (:80)        │
                  │{{SERVER_FQDN}}/mcp/ │
                  └──────────┬──────────┘
                             │ reverse proxy
                             ▼
┌─────────────────────────────────────────────────┐
│              systemd: onvif-mcp-http.service     │
│                                                  │
│  {{REPO_PATH}}/onvif-mcp/.venv/bin/              │
│  python3 -m onvif_mcp_http.main                  │
│                                                  │
│  Listens on http://127.0.0.1:8001/mcp            │
│  Uses uvicorn (ASGI server) for Streamable HTTP  │
│  transport (SSE + POST).                         │
│                                                  │
│  Environment:                                    │
│    CAMERA_USERNAME={{USERNAME}}                  │
│    CAMERA_PASSWORD={{PASSWORD}}                  │
│    STREAM_SERVER_URL=https://{{SERVER_FQDN}}     │
│    MCP_HTTP_HOST=127.0.0.1                       │
│    MCP_HTTP_PORT=8001                            │
└──────────────┬───────────────────────────────────┘
               │ libonvif.discover()
               ▼
          ┌─────────────┐
          │ ONVIF       │
          │ Cameras on  │
          │ 10.1.1.x    │
          └─────────────┘
```

