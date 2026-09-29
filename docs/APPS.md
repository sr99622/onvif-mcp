# Camera Applications — Installation Guide

## Purpose

Configure the two static camera web applications in `apps/` and serve them through nginx.

Target state:

- Camera Switchboard: `http://{{SERVER_FQDN}}/cameras/`
- Four-Camera View: `http://{{SERVER_FQDN}}/multiview/`
- Runtime registry: `/etc/onvif-mcp/camera_registry.json`
- Registry URL: `http://{{SERVER_FQDN}}/outputs/camera_registry.json`
- nginx worker user: `webcam`, with group access to the repository owner's group
- App files are served in place from `{{REPO_PATH}}/onvif-mcp/apps/`; they are not copied into `/usr/share/nginx/html`

## Required Values

| Value | Description |
|---|---|
| `{{SERVER_FQDN}}` | Server fully qualified domain name |
| `{{REPO_PATH}}` | Parent directory containing this repository |
| `{{SERVER_USER}}` | Repository owner / server user |

Stop and ask the user if any required value is missing.

## Agent Presentation Rules

This document is a script for the agent. The executable source of truth is:

```text
{{REPO_PATH}}/onvif-mcp/scripts/APPS/apps_runbook.sh
```

Before executing any AGENT-run command or presenting any USER-run command, replace every double-curly placeholder with the real site value. Do not ask the user to type placeholders literally.

For this runbook, the agent normally runs the commands directly. If a command must be shown to the user, include `cd {{REPO_PATH}}/onvif-mcp` as the first line of the copy-paste block after resolving `{{REPO_PATH}}`.

Do not replace the scripted workflow with ad hoc shell fragments. If behavior must change, update `scripts/APPS/apps_runbook.sh` and keep this runbook as orchestration guidance.

## 1. Apply App Configuration (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/APPS/apps_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --repo-path {{REPO_PATH}} \
  --server-user {{SERVER_USER}}
```

The script performs the full apps runbook:

- Installs missing Debian/Ubuntu packages when `apt-get` is available.
- Calls the camera MCP HTTP server `get_cameras` tool through `http://{{SERVER_FQDN}}/mcp`.
- Generates `/etc/onvif-mcp/camera_registry.json` from the discovered cameras.
- Uses each camera's first profile as `media_player_url` for the switchboard.
- Uses each camera's second profile as `substream_player_url` for multiview when present; otherwise it reuses the first profile.
- Creates the system user `webcam` if missing.
- Adds `webcam` to the `{{SERVER_USER}}` group so nginx can traverse and read the repository app files.
- Sets nginx to run as `webcam`.
- Adds nginx locations for `/cameras/`, `/multiview/`, and `/outputs/camera_registry.json` to the existing camera site.
- Validates and restarts nginx.
- Prints non-secret status output.

## 2. Verify App Configuration (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/APPS/apps_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --repo-path {{REPO_PATH}}
```

Acceptance checks:

- nginx is enabled and active.
- `/etc/nginx/nginx.conf` runs workers as `webcam`.
- `/etc/onvif-mcp/camera_registry.json` is present and readable.
- The registry contains at least one camera.
- These endpoints return HTTP 200:
  - `/cameras/`
  - `/multiview/`
  - `/outputs/camera_registry.json`
  - `/cameras/styles.css`
  - `/cameras/app.js`
  - `/multiview/app.js`

## 3. Test App Endpoints (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/APPS/apps_runbook.sh test --server-fqdn {{SERVER_FQDN}}
```

The script verifies the app endpoints through `http://{{SERVER_FQDN}}`, verifies slashless `/cameras` and `/multiview` redirect to trailing-slash URLs, and validates that every registry camera has a plain-HTTP player URL ending in `/`.

## Operational Notes

Changing camera inventory requires regenerating `/etc/onvif-mcp/camera_registry.json` by rerunning the `apply` command. The static app files do not need a build step.

At this stage the web apps are plain HTTP and open to anyone who can reach port 80 on this host. TLS and Keycloak are added by later runbooks.
