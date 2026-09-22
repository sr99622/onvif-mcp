# ONVIF Camera MCP HTTP Server

## Values Supplied by the Agent

| Config Variable | Description |
| --- | --- |
| `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the Server       |
| `{{USERNAME}}`    | Camera Username                                 |
| `pass camera`     | Camera password from the local password store   |
| `{{REPO_PATH}}`   | Full Pathname of Repository Location            |
| `{{SERVER_USER}}` | System user the service runs as (project owner) |

These values are required for operation. Do not hard-code the camera password in
the systemd unit, shell history, this runbook, or agent chat. Read the first line
from `pass camera` when generating the service environment file. If GPG prompts
for the passphrase, enter it interactively in the terminal; after that,
`gpg-agent` normally caches the key for subsequent reads during the same build
session.

## Overview

The `onvif-mcp-http` package provides an HTTP-based MCP (Model Context Protocol) server for discovering and controlling ONVIF cameras on the local network. It exposes tools through a Streamable HTTP transport (SSE + POST), accessible both locally on port 8001 and externally through nginx at `http://{{SERVER_FQDN}}/mcp/`.

- **Service**: `onvif-mcp-http.service` — running, enabled for auto-start on boot
- **Local endpoint**: `http://127.0.0.1:8001/mcp`
- **Nginx proxy**: `http://{{SERVER_FQDN}}/mcp/` (forwarded to port 8001)
- **Python venv**: `{{REPO_PATH}}/onvif-mcp/.venv`
- **Executable**: `{{REPO_PATH}}/onvif-mcp/.venv/bin/onvif-mcp-http`
- **Source**: `packages/http/src/onvif_mcp_http/main.py`

## 1. Nginx Proxy Configuration

All of this lives in one server block alongside the MediaMTX proxy and Camera App, at `/etc/nginx/sites-available/camera` (already present from the MEDIAMTX.md and APPS.md installs — extend it; do not create a second vhost):

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

  After installing the MCP locations, verify with:

  ```bash
  # must print exactly 1 per port — a second occurrence means a conflict
  sudo nginx -T | grep -c 'server_name {{SERVER_FQDN}}'
  # re-test every pre-existing endpoint (apps, web player, registry), not just /mcp
  ```

## 2. Configure systemd Service and Start

The camera password is a runtime secret. Store it in a protected systemd
environment file generated from `pass camera`; keep the unit file itself free of
secrets.

Create `/etc/onvif-mcp-http.env` from the password store:

```bash
set -e
umask 077
tmp_env="$(mktemp "$HOME/.onvif-mcp-http.env.XXXXXX")"
IFS= read -r CAMERA_PASSWORD < <(pass camera)
test -n "$CAMERA_PASSWORD"
{
  printf 'MCP_HTTP_HOST=127.0.0.1\n'
  printf 'MCP_HTTP_PORT=8001\n'
  printf 'CAMERA_USERNAME=%s\n' '{{USERNAME}}'
  printf 'CAMERA_PASSWORD=%s\n' "$CAMERA_PASSWORD"
  printf 'STREAM_SERVER_URL=http://%s\n' '{{SERVER_FQDN}}'
} > "$tmp_env"
sudo install -o root -g root -m 0600 "$tmp_env" /etc/onvif-mcp-http.env
shred -u "$tmp_env"
sudo test -s /etc/onvif-mcp-http.env
sudo stat -c '%a %U:%G %n' /etc/onvif-mcp-http.env
```

Required environment-file permissions:

```text
600 root:root /etc/onvif-mcp-http.env
```

Do not make `/etc/onvif-mcp-http.env` world-readable. `systemd` reads the file as
root before starting the service as `{{SERVER_USER}}`.

**File**: `/etc/systemd/system/onvif-mcp-http.service`

```ini
[Unit]
Description=ONVIF Camera MCP HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{SERVER_USER}}
WorkingDirectory={{REPO_PATH}}/onvif-mcp
EnvironmentFile=/etc/onvif-mcp-http.env
ExecStart={{REPO_PATH}}/onvif-mcp/.venv/bin/onvif-mcp-http
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Protect the unit file and verify that it does not contain the camera password:

```bash
sudo chown root:root /etc/systemd/system/onvif-mcp-http.service
sudo chmod 0644 /etc/systemd/system/onvif-mcp-http.service
sudo grep -n 'CAMERA_PASSWORD=' /etc/systemd/system/onvif-mcp-http.service && exit 1 || true
sudo grep -n '^EnvironmentFile=/etc/onvif-mcp-http.env$' /etc/systemd/system/onvif-mcp-http.service
sudo stat -c '%a %U:%G %n' /etc/systemd/system/onvif-mcp-http.service /etc/onvif-mcp-http.env
```

Start the service and make it persistent

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now onvif-mcp-http
```

### Management commands:
```bash
systemctl status onvif-mcp-http          # Check status
journalctl -u onvif-mcp-http -f           # Follow logs
systemctl restart onvif-mcp-http          # Restart after code changes
sudo systemctl disable onvif-mcp-http     # Disable auto-start
```

## 3. Test MCP Protocol Usage (curl examples)

The MCP Streamable HTTP transport uses a session-based handshake. All requests must carry the session ID from the initialize response.

> **Testing note:** the upstream enforces host/origin validation — a POST to
> `http://127.0.0.1/mcp` through nginx (or directly to `127.0.0.1:8001/mcp` with a
> loopback Host) returns `421 Misdirected Request` / `406`. Use the real FQDN
> (`http://{{SERVER_FQDN}}/mcp`) in these tests, or add `-H "Host: {{SERVER_FQDN}}"`
> when targeting `127.0.0.1`. This is correct security behavior, not a broken proxy.

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
│    CAMERA_PASSWORD=(from /etc/onvif-mcp-http.env │
│                    generated by pass camera)     │
│    STREAM_SERVER_URL=http://{{SERVER_FQDN}}      │
│    MCP_HTTP_HOST=127.0.0.1                       │
│    MCP_HTTP_PORT=8001                            │
└──────────────┬───────────────────────────────────┘
               │ libonvif.discover()
               ▼
          ┌─────────────┐
          │ ONVIF       │
          │ Cameras     │
          │             │
          └─────────────┘
```
