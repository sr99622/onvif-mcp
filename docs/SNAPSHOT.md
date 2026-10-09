# Camera Snapshot Service

## Purpose

Configure the loopback-only snapshot proxy that lets clients retrieve a live JPEG from any camera through a uniform URL:

```text
http://{{SERVER_FQDN}}/snapshot/<serial_number>/<profile_token>/
```

Target state:

- Source: `{{REPO_PATH}}/services/snapshot_proxy.py`
- Routes: `/etc/onvif-mcp/snapshot_routes.json`
- Shared environment file: `/etc/onvif-mcp-http.env`, mode `600 root:root`
- Service: `snapshot-proxy.service`, enabled and active
- Local listener: `127.0.0.1:8891`
- Nginx endpoint: `http://{{SERVER_FQDN}}/snapshot/`
- One route for every camera profile that has a snapshot URI from `get_cameras`

## Required Values

| Value | Description |
|---|---|
| `{{SERVER_FQDN}}` | Server fully qualified domain name |
| `{{REPO_PATH}}` | Full path to this repository |
| `{{SERVER_USER}}` | System user the proxy runs as |
| `{{CAMERA_USERNAME}}` | Camera username |
| `pass show camera` | Camera password from the local password store |

Stop and ask the user if any required value is missing. Do not hard-code the camera password in the systemd unit, shell history, this runbook, or agent chat. The executable script reads the first line from `pass show camera` when updating `/etc/onvif-mcp-http.env`.

## Agent Presentation Rules

This document is a script for the agent. The executable source of truth is:

```text
{{REPO_PATH}}/scripts/SNAPSHOT/snapshot_runbook.sh
```

Before executing any AGENT-run command or presenting any USER-run command, replace every double-curly placeholder with the real site value. Do not ask the user to type placeholders literally.

For this runbook, the agent normally runs the commands directly. If a command must be shown to the user, include `cd {{REPO_PATH}}` as the first line of the copy-paste block after resolving `{{REPO_PATH}}`.

Do not replace the scripted workflow with ad hoc shell fragments. If behavior must change, update `scripts/SNAPSHOT/snapshot_runbook.sh` and keep this runbook as orchestration guidance.

## 1. Apply Snapshot Proxy Configuration (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}
scripts/SNAPSHOT/snapshot_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-username {{CAMERA_USERNAME}} \
  --repo-path {{REPO_PATH}} \
  --server-user {{SERVER_USER}}
```

The script performs the full snapshot runbook:

- Installs missing Debian/Ubuntu packages when `apt-get` is available.
- Reads the camera password from `pass show camera`.
- Updates `/etc/onvif-mcp-http.env` with the snapshot proxy variables while keeping mode `600 root:root`.
- Calls the camera MCP HTTP server `get_cameras` tool through `http://{{SERVER_FQDN}}/mcp`.
- Generates `/etc/onvif-mcp/snapshot_routes.json` from each profile's ONVIF `snapshot_uri`.
- Writes `/etc/systemd/system/snapshot-proxy.service` without embedding the camera password.
- Adds the nginx `/snapshot/` location to the existing camera site.
- Enables and restarts `snapshot-proxy.service`.
- Prints non-secret status output.

If `pass show camera` fails because GPG needs the passphrase, stop and ask the user to run this in their own terminal:

```bash
cd {{REPO_PATH}}
pass show camera >/dev/null
```

After the user confirms that command succeeded, rerun the `apply` command. Do not ask the user to paste the GPG passphrase or camera password into chat.

## 2. Verify Snapshot Proxy (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/SNAPSHOT/snapshot_runbook.sh status --server-fqdn {{SERVER_FQDN}}
```

Acceptance checks:

- `snapshot-proxy.service` is enabled and active.
- `/etc/systemd/system/snapshot-proxy.service` is `644 root:root`.
- `/etc/onvif-mcp-http.env` is `600 root:root`.
- `/etc/onvif-mcp/snapshot_routes.json` exists and contains routes.
- A listener exists on `127.0.0.1:8891` only.
- Recent logs show the proxy listening with the expected route count.

## 3. Test Snapshot Endpoints (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/SNAPSHOT/snapshot_runbook.sh test --server-fqdn {{SERVER_FQDN}}
```

The script requests every generated route through nginx at `http://{{SERVER_FQDN}}/snapshot/<serial>/<profile>/`, verifies HTTP `200 image/jpeg`, and verifies the returned file is real JPEG image data.

## Operational Notes

The snapshot proxy binds to loopback only. Clients reach it only through nginx.

At this stage `/snapshot/` is plain HTTP and has the same open posture as `/webrtc/`. TLS and Keycloak are added by later runbooks.

Camera credentials live in `/etc/onvif-mcp-http.env`, not in the proxy source, systemd unit, client-facing responses, or logs.
