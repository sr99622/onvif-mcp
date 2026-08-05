# Camera MCP HTTPS Proxy and OpenClaw Client Runbook

## Purpose

This runbook documents how the camera MCP HTTP server on `camera.home.arpa` was placed behind Nginx with:

- HTTPS using the Camera System private CA
- HTTP Basic Authentication
- A loopback-only MCP backend
- An authenticated OpenClaw Streamable HTTP client

The final request path is:

```text
OpenClaw
  -> HTTPS + Basic Authentication
  -> https://camera.home.arpa/mcp
  -> Nginx on 10.1.1.3:443
  -> unencrypted loopback HTTP
  -> http://127.0.0.1:8001/mcp
  -> Camera MCP server
```

The backend HTTP connection is acceptable because it never leaves trigkey.

## Final configuration summary

### Trigkey

- Hostname: `camera.home.arpa`
- LAN address: `10.1.1.3`
- Nginx HTTPS listener: `10.1.1.3:443`
- MCP backend: `127.0.0.1:8001`
- MCP service: `onvif-mcp.service` (systemd user service)
- Nginx password file: `/etc/nginx/auth/camera-users.htpasswd`
- Nginx site: `/etc/nginx/sites-available/camera-apps`

### OpenClaw Mac

- OpenClaw config: `~/.openclaw/openclaw.json`
- OpenClaw protected environment file: `~/.openclaw/.env`
- LaunchAgent: `~/Library/LaunchAgents/ai.openclaw.gateway.plist`
- Private root certificate:
  `~/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem`

## Prerequisites

This procedure assumes:

1. `camera.home.arpa` resolves to `10.1.1.3`.
2. Nginx already serves `camera.home.arpa` over HTTPS.
3. Client machines trust the Camera System Root CA.
4. Nginx Basic Authentication is already configured at HTTPS server scope:

```nginx
auth_basic "Camera System";
auth_basic_user_file /etc/nginx/auth/camera-users.htpasswd;
```

5. The MCP server is managed by this user service:

```text
~/.config/systemd/user/onvif-mcp.service
```

## Part 1: Back up the Nginx configuration

On trigkey:

```bash
sudo cp --update=none \
  /etc/nginx/sites-available/camera-apps \
  /etc/nginx/sites-available/camera-apps.before-mcp-proxy-2026-08-05
```

Confirm the backup:

```bash
sudo ls -l \
  /etc/nginx/sites-available/camera-apps.before-mcp-proxy-2026-08-05
```

## Part 2: Add the MCP reverse proxy to Nginx

Inside the HTTPS `server` block in `/etc/nginx/sites-available/camera-apps`, add:

```nginx
location = /mcp {
    proxy_pass http://127.0.0.1:8001;
    proxy_http_version 1.1;

    # Do not pass the Nginx Basic credential to the MCP application.
    proxy_set_header Authorization "";
    proxy_set_header Connection "";

    # Streamable HTTP can keep connections open and stream responses.
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_cache off;

    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
```

Because `auth_basic` is defined at server scope, `/mcp` automatically inherits it.

Validate the configuration before reloading:

```bash
sudo nginx -t
```

Reload Nginx only after validation succeeds:

```bash
sudo systemctl reload nginx.service
```

## Part 3: Bind the MCP backend to loopback

The MCP server must not remain bound to the LAN address. Otherwise, a client could bypass Nginx and its authentication by connecting directly to the MCP port.

In:

```text
/home/stephen/Projects/onvif-mcp/packages/http/src/onvif_mcp_http/main.py
```

use:

```python
# Bind only to loopback; Nginx provides HTTPS and authentication.
# Internal endpoint: http://127.0.0.1:8001/mcp
uvicorn.run(app, host="127.0.0.1", port=8001)
```

Validate the Python file:

```bash
/home/stephen/Projects/onvif-mcp/.venv/bin/python3 -m py_compile \
  /home/stephen/Projects/onvif-mcp/packages/http/src/onvif_mcp_http/main.py
```

Restart the user service:

```bash
systemctl --user restart onvif-mcp.service
```

Reload Nginx after its upstream has been set to the same address and port:

```bash
sudo systemctl reload nginx.service
```

### Important port conflict discovered during implementation

Do not use `127.0.0.1:8000` for MCP on this host. Kea Control Agent already owns it:

```text
127.0.0.1:8000  kea-ctrl-agent
```

The MCP backend therefore uses `127.0.0.1:8001`.

Check both listeners:

```bash
sudo ss -lntp \
  '( sport = :8000 or sport = :8001 )'
```

Expected result:

```text
127.0.0.1:8000  kea-ctrl-agent
127.0.0.1:8001  python3
```

There should be no MCP listener on `10.1.1.3:8001` or `0.0.0.0:8001`.

## Part 4: Test Nginx authentication and proxying

### Unauthenticated test

On trigkey:

```bash
sudo curl \
  --resolve camera.home.arpa:443:10.1.1.3 \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  --head \
  https://camera.home.arpa/mcp
```

Expected response:

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Basic realm="Camera System"
```

### Authenticated proxy test

```bash
sudo curl \
  --user stephen \
  --resolve camera.home.arpa:443:10.1.1.3 \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  --header 'Accept: text/event-stream' \
  --include \
  --max-time 5 \
  https://camera.home.arpa/mcp
```

Enter the Basic Authentication password when prompted. Do not place it directly in the command.

A response similar to this is expected:

```text
HTTP/1.1 400 Bad Request
{"jsonrpc":"2.0",...,"message":"Bad Request: Missing session ID"}
```

This is a successful proxy test. A raw `curl` request has not completed the MCP initialization handshake, so it has no session ID.

## Part 5: Make Node.js trust the private CA

Browsers and macOS trusted the private root, but Node.js initially returned:

```text
UNABLE_TO_VERIFY_LEAF_SIGNATURE
```

Confirm that the root certificate fixes a one-off Node request:

```bash
NODE_EXTRA_CA_CERTS="$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
node -e '
fetch("https://camera.home.arpa/mcp")
  .then(response => console.log("HTTP status:", response.status))
  .catch(error => console.error(
    "TLS/fetch error:",
    error.cause?.code ?? error.message
  ))
'
```

Expected response:

```text
HTTP status: 401
```

The `401` proves TLS verification succeeded; authentication was intentionally omitted.

## Part 6: Add the private CA to the OpenClaw LaunchAgent

OpenClaw runs as a macOS LaunchAgent:

```text
~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

Back it up:

```bash
test ! -e "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist.before-camera-ca-2026-08-05" &&
cp -p \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist.before-camera-ca-2026-08-05"
```

Add the CA path:

```bash
/usr/libexec/PlistBuddy \
  -c "Add :EnvironmentVariables:NODE_EXTRA_CA_CERTS string $HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
```

Validate the plist:

```bash
plutil -lint \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
```

Reload the user LaunchAgent so launchd rereads the environment:

```bash
launchctl bootout \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" &&
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
```

Verify the setting without displaying unrelated environment values:

```bash
launchctl print "gui/$(id -u)/ai.openclaw.gateway" |
grep 'NODE_EXTRA_CA_CERTS'
```

### LaunchAgent recovery

During implementation, `openclaw gateway restart` unloaded the LaunchAgent but failed to bootstrap it with error 5. It was recovered without `sudo` by running:

```bash
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
```

Then confirm:

```bash
openclaw gateway status
```

Do not load a per-user LaunchAgent with `sudo`, since that can target the wrong launchd domain.

## Part 7: Store the OpenClaw Basic credential safely

OpenClaw supports custom MCP HTTP headers and environment-variable substitution. The authorization header is stored indirectly so the encoded credential does not appear in `openclaw.json`.

The global OpenClaw environment file is:

```text
~/.openclaw/.env
```

Create it while prompting securely for the Nginx password:

```bash
read -r -s "camera_mcp_password?Nginx password for user stephen: "
printf '\n'
camera_mcp_b64="$(
  printf 'stephen:%s' "$camera_mcp_password" |
  openssl base64 -A
)"
umask 077
printf 'CAMERA_MCP_AUTHORIZATION="Basic %s"\n' \
  "$camera_mcp_b64" \
  > "$HOME/.openclaw/.env"
unset camera_mcp_password camera_mcp_b64
ls -l "$HOME/.openclaw/.env"
```

Expected permissions:

```text
-rw-------
```

The Base64 value is reversible and must be protected like the original password.

Do not display, commit, or copy the `.env` contents into documentation.

## Part 8: Configure the OpenClaw MCP client

Back up:

```text
~/.openclaw/openclaw.json
```

The final camera MCP entry is:

```json
{
  "mcp": {
    "sessionIdleTtlMs": 0,
    "servers": {
      "camera": {
        "url": "https://camera.home.arpa/mcp",
        "transport": "streamable-http",
        "headers": {
          "Authorization": "${CAMERA_MCP_AUTHORIZATION}"
        }
      }
    }
  }
}
```

Important changes from the old entry:

- URL changed from `http://10.1.1.3:8000/mcp` to `https://camera.home.arpa/mcp`.
- The `Authorization` header references the protected environment value.
- The old remote-server `env.STREAM_SERVER_IP` entry was removed. OpenClaw documents the per-server `env` field as stdio-only; it is not how headers are supplied to a remote HTTP MCP server.

Validate JSON syntax:

```bash
jq empty "$HOME/.openclaw/openclaw.json"
```

Restart or reload OpenClaw after adding `~/.openclaw/.env` so the process receives the new variable.

## Part 9: Test the actual OpenClaw MCP client

For a standalone CLI probe, provide the private CA at Node process startup:

```bash
NODE_EXTRA_CA_CERTS="$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
openclaw mcp probe camera
```

Successful result from this installation:

```text
camera: 29 tools, resources, prompts
```

The running gateway does not need the command prefix because its LaunchAgent already supplies `NODE_EXTRA_CA_CERTS`.

## Part 10: Source control and machine-specific files

The loopback bind change in `main.py` is source-controlled. It was committed and pushed as:

```text
375fc24 Bind MCP HTTP server to loopback
```

The repository was then synchronized to the Mac with:

```bash
git -C /Users/stephen/Projects/onvif-mcp pull --ff-only
```

The following are machine-specific and should not be committed to the application repository:

- `/etc/nginx/sites-available/camera-apps`
- `/etc/nginx/auth/camera-users.htpasswd`
- `~/.openclaw/openclaw.json`
- `~/.openclaw/.env`
- `~/Library/LaunchAgents/ai.openclaw.gateway.plist`

Never commit:

- The Nginx password file
- The Basic Authorization value
- The OpenClaw `.env` file
- Private CA keys

## Routine service commands

### MCP service on trigkey

```bash
systemctl --user restart onvif-mcp.service
systemctl --user --no-pager --full status onvif-mcp.service
```

### Nginx on trigkey

```bash
sudo nginx -t
sudo systemctl reload nginx.service
systemctl --no-pager --full status nginx.service
```

### OpenClaw on the Mac

```bash
openclaw gateway status
```

If the restart helper leaves the LaunchAgent unloaded:

```bash
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
```

## Troubleshooting checklist

### Nginx returns `401 Unauthorized`

This is expected without credentials. Confirm the OpenClaw server entry includes:

```json
"headers": {
  "Authorization": "${CAMERA_MCP_AUTHORIZATION}"
}
```

Also confirm `~/.openclaw/.env` exists with mode `600` and restart OpenClaw after changing it.

### Node reports `UNABLE_TO_VERIFY_LEAF_SIGNATURE`

Confirm:

```bash
launchctl print "gui/$(id -u)/ai.openclaw.gateway" |
grep 'NODE_EXTRA_CA_CERTS'
```

For a standalone CLI invocation, prefix the command with `NODE_EXTRA_CA_CERTS=...` because the LaunchAgent environment applies only to the gateway process.

### Nginx returns `502 Bad Gateway`

Check the MCP service:

```bash
systemctl --user --no-pager --full status onvif-mcp.service
sudo ss -lntp 'sport = :8001'
```

Confirm both sides use `127.0.0.1:8001`:

- Uvicorn in `main.py`
- `proxy_pass` in the Nginx site

### MCP fails to start with bind error

Ensure it is not configured for `127.0.0.1:8000`; that port belongs to Kea Control Agent. Use `127.0.0.1:8001`.

### Raw authenticated curl returns `Missing session ID`

That response confirms the endpoint is reachable. A raw request lacks the MCP initialization handshake and session state. Use `openclaw mcp probe camera` for an actual protocol test.

### OpenClaw gateway is unloaded

Check:

```bash
openclaw gateway status
```

Reload the user LaunchAgent without `sudo`:

```bash
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
```

## Rollback overview

If the proxy must be rolled back:

1. Restore the backed-up Nginx site.
2. Validate with `sudo nginx -t`.
3. Reload Nginx.
4. Restore the previous `main.py` revision through Git.
5. Restart `onvif-mcp.service`.
6. Restore the backed-up `openclaw.json` and LaunchAgent plist if required.

Rollback will re-expose the earlier direct HTTP design if the MCP server is rebound to the LAN address. Use it only temporarily while troubleshooting.
