# ONVIF Camera MCP HTTP Server

## Purpose

Configure the HTTP-based ONVIF MCP server and expose it through nginx at `http://{{SERVER_FQDN}}/mcp`.

Target state:

- Service: `onvif-mcp-http.service`, enabled and active
- Local endpoint: `http://127.0.0.1:8001/mcp`
- Nginx endpoint: `http://{{SERVER_FQDN}}/mcp`
- Environment file: `/etc/onvif-mcp-http.env`, mode `600 root:root`
- Unit file: `/etc/systemd/system/onvif-mcp-http.service`, mode `644 root:root`
- Python venv: `{{REPO_PATH}}/onvif-mcp/.venv`
- Executable: `{{REPO_PATH}}/onvif-mcp/.venv/bin/onvif-mcp-http`
- Hermes MCP entry: `camera` pointing to `http://{{SERVER_FQDN}}/mcp`

## Required Values

| Config Variable | Description |
|---|---|
| `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server |
| `{{CAMERA_USERNAME}}` | Camera username |
| `pass show camera` | Camera password from the local password store |
| `{{REPO_PATH}}` | Parent directory containing this repository |
| `{{SERVER_USER}}` | System user the service runs as |

Stop and ask the user if any required value is missing. Do not hard-code the camera password in the systemd unit, shell history, this runbook, or agent chat. The executable script reads the first line from `pass show camera` when generating `/etc/onvif-mcp-http.env`.

## Agent Presentation Rules

This document is a script for the agent. The executable source of truth is:

```text
{{REPO_PATH}}/onvif-mcp/scripts/MCP_HTTP/mcp_http_runbook.sh
```

Before executing any AGENT-run command or presenting any USER-run command, replace every double-curly placeholder with the real site value. Do not ask the user to type placeholders literally.

For this runbook, the agent normally runs the commands directly. If a command must be shown to the user, include `cd {{REPO_PATH}}/onvif-mcp` as the first line of the copy-paste block after resolving `{{REPO_PATH}}`.

Do not replace the scripted workflow with ad hoc shell fragments. If behavior must change, update `scripts/MCP_HTTP/mcp_http_runbook.sh` and keep this runbook as orchestration guidance.

## 1. Apply MCP HTTP Configuration (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/MCP_HTTP/mcp_http_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-username {{CAMERA_USERNAME}} \
  --repo-path {{REPO_PATH}} \
  --server-user {{SERVER_USER}}
```

The script performs the full MCP HTTP runbook:

- Installs missing Debian/Ubuntu packages when `apt-get` is available.
- Runs `uv sync --all-packages` in `{{REPO_PATH}}/onvif-mcp`.
- Verifies `{{REPO_PATH}}/onvif-mcp/.venv/bin/onvif-mcp-http` exists.
- Reads the camera password from `pass show camera`.
- Writes `/etc/onvif-mcp-http.env` with mode `600 root:root`.
- Writes `/etc/systemd/system/onvif-mcp-http.service` with mode `644 root:root`.
- Verifies the unit file does not contain `CAMERA_PASSWORD=`.
- Creates or extends `/etc/nginx/sites-available/camera` with exact `/mcp` proxy locations.
- Enables the nginx site and reloads nginx after `nginx -t` succeeds.
- Enables and restarts `onvif-mcp-http.service`.
- Prints non-secret status output.

If `pass show camera` fails because GPG needs the passphrase, stop and ask the user to run this in their own terminal:

```bash
cd {{REPO_PATH}}/onvif-mcp
pass show camera >/dev/null
```

After the user confirms that command succeeded, rerun the `apply` command. Do not ask the user to paste the GPG passphrase or camera password into chat.

## 2. Verify MCP HTTP Service (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/MCP_HTTP/mcp_http_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --repo-path {{REPO_PATH}}
```

Acceptance checks:

- `onvif-mcp-http.service` is enabled and active.
- `/etc/systemd/system/onvif-mcp-http.service` is `644 root:root`.
- `/etc/onvif-mcp-http.env` is `600 root:root`.
- nginx has exactly one `server_name {{SERVER_FQDN}}` entry for this site.
- A listener exists on `127.0.0.1:8001`.
- Recent service logs show Uvicorn running on `http://127.0.0.1:8001`.

## 3. Test MCP Protocol (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/MCP_HTTP/mcp_http_runbook.sh test --server-fqdn {{SERVER_FQDN}}
```

The script performs the MCP Streamable HTTP initialize handshake, sends the initialized notification, calls `tools/list`, verifies the `get_cameras` and `get_adapters` tools are present, then calls `get_adapters` and requires the private adapter address `10.2.2.1` in the response.

The MCP server enforces host/origin validation. Use the real FQDN endpoint in tests; loopback requests with a loopback Host can return `421 Misdirected Request` or `406` and do not indicate a broken nginx proxy.

## 4. Add Camera MCP Server Configuration to Hermes (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/MCP_HTTP/mcp_http_runbook.sh configure-hermes --server-fqdn {{SERVER_FQDN}}
```

Then verify `~/.hermes/config.yaml` contains:

```yaml
mcp_servers:
  camera:
    url: http://{{SERVER_FQDN}}/mcp
    connect_timeout: 60
    timeout: 180
```

Tell the user to reload MCP in Hermes with `/reload-mcp` or restart Hermes before relying on the new camera MCP server in the current session.
