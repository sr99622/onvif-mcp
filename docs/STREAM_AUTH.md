# Keycloak Authentication for Camera Apps, WebRTC Streams, Recorded Playback, and Snapshots

## Values supplied by agent

| Name | Description |
|------|-------------|
| `{{SERVER_FQDN}}` | Public DNS name shared by Nginx, Keycloak, and MCP |
| `{{SERVER_IP}}` | Address on which Nginx accepts public HTTPS |
| `{{BACKUP_PATH}}` | Backup folder |

Executable installation actions are implemented by:

```bash
scripts/STREAM_AUTH/stream_auth_runbook.sh
```

That script is the single source of truth for commands that add browser-session
authorization to the stream/app endpoints. This runbook is the agent guide: it
states intent, required checks, boundaries, and follow-up checkpoints without
repeating executable shell fragments that can drift from the script.

## Purpose

This runbook adds browser-session authorization to camera applications, WebRTC
signaling, recorded playback, static playback cache files, and live JPEG
snapshots while preserving the MCP server's independent OAuth bearer-token flow.

The implementation uses:

- Keycloak as the OpenID Connect provider;
- oauth2-proxy for Authorization Code flow with PKCE and encrypted sessions;
- Nginx `auth_request` for route enforcement;
- the existing MediaMTX service for WebRTC signaling and encrypted media;
- the existing MCP resource-server JWT validation for Hermes;
- the existing snapshot proxy for live JPEG images.

Protected browser routes:

```text
/cameras/
/multiview/
/outputs/
/webrtc/
/playback/
/playback-cache/
/snapshot/
```

Routes that must remain independent and must not receive browser `auth_request`
protection:

```text
/auth/
/oauth2/
/mcp
/.well-known/oauth-protected-resource/mcp
```

## Security rules

Do not display:

- `/opt/keycloak/.env` values;
- Keycloak client secrets;
- oauth2-proxy cookie secrets;
- browser session cookies;
- OAuth codes, state, or PKCE values;
- passwords, JWTs, or refresh tokens;
- private keys.

Use direct live API queries to resolve installation-specific UUIDs. Never copy
UUIDs from another realm or deployment. Keep oauth2-proxy bound to loopback and
do not disable private-CA verification.

## Apply stream authentication (AGENT-run)

Run with resolved values:

```bash
cd {{REPO_PATH}}
scripts/STREAM_AUTH/stream_auth_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

The script performs these executable stages:

1. Preflight verifies Keycloak/PostgreSQL, Nginx, MediaMTX, MCP HTTP, and
   snapshot-proxy are active; verifies loopback listeners; verifies nginx syntax;
   and validates a known loopback snapshot path as a real JPEG.
2. Verifies the `mcp-user` login user is enabled, has a nonempty verified email,
   and has no required actions.
3. Creates or verifies the confidential browser client `camera-web` with exact
   redirect URI `https://{{SERVER_FQDN}}/oauth2/callback`, web origin
   `https://{{SERVER_FQDN}}`, and PKCE `S256`.
4. Stores oauth2-proxy client and cookie secrets once in `/opt/keycloak/.env`,
   preserving root ownership and mode `0600`, without printing secret values.
5. Adds oauth2-proxy to `/opt/keycloak/compose.yaml`, mounts the private CA root,
   binds it to `127.0.0.1:4180`, pulls/starts it, and verifies `/ping` and
   unauthenticated `/oauth2/auth` behavior.
6. Adds `/oauth2/*` support routes to the HTTPS nginx vhost.
7. Adds `auth_request` protection to `/cameras/`, `/multiview/`, `/outputs/`,
   `/webrtc/`, `/playback/`, `/playback-cache/`, and `/snapshot/`, while leaving
   `/auth/`, `/oauth2/`, `/mcp`, and MCP protected-resource metadata unprotected
   by browser auth.
8. Verifies unauthenticated protected routes redirect to `/oauth2/start` with
   the original path in `rd=`; verifies HTTP snapshot access redirects to HTTPS;
   verifies Keycloak discovery and MCP 401 behavior still work.
9. Runs `scripts/stream_auth_step9_driver.py` for headless browser-flow
   verification: login form, PKCE parameter names, landing on `/cameras/`,
   authenticated `/oauth2/ping`, same-session `/multiview/`, WebRTC pass-through,
   same-session snapshot JPEG, and fresh-session direct snapshot login/JPEG.
10. Runs `hermes mcp test camera` to prove MCP OAuth remains independent.
11. Publishes shared Keycloak and nginx checkpoints with `STREAM_AUTH.md` as the
    trigger.

## Status checks (AGENT-run)

```bash
cd {{REPO_PATH}}
scripts/STREAM_AUTH/stream_auth_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}}
```

Required outcomes:

- nginx, mediamtx, onvif-mcp-http.service, and snapshot-proxy.service are active.
- Keycloak, PostgreSQL, and oauth2-proxy containers are running; PostgreSQL is
  healthy.
- oauth2-proxy `/ping` returns HTTP 200 on loopback.
- Unauthenticated `/cameras/` returns HTTP 302 to `/oauth2/start?rd=/cameras/`.
- Unauthenticated `/mcp` still returns HTTP 401 with protected-resource metadata.

## Browser verification

The browser behavior check is agent-driven; there is no manual browser step.
The script runs:

```bash
python3 scripts/stream_auth_step9_driver.py --origin "https://{{SERVER_FQDN}}"
```

The driver keeps cookies in memory only and reads `/opt/keycloak/mcp-user.pass`
inside the process. It must never print or persist credentials, cookies, OAuth
codes, state values, or token values.

Required browser outcomes:

- unauthenticated `/cameras/` redirects to `/oauth2/start?rd=/cameras/`;
- one hop from `/oauth2/start` reaches Keycloak authorization with parameter
  names for client ID, redirect URI, response type, scope, state, PKCE challenge,
  and `code_challenge_method=S256`;
- login lands exactly on `/cameras/` with HTTP 200 HTML;
- authenticated `/oauth2/ping` returns HTTP 202 with body `Authenticated`;
- same-session `/multiview/` returns HTTP 200 without a second login;
- WebRTC route passes through without a sign-in bounce;
- same-session snapshot returns HTTP 200 `image/jpeg`, JPEG magic bytes, and
  `Cache-Control: no-store`;
- a fresh unauthenticated direct snapshot URL redirects to login and returns to
  the requested JPEG after authentication.

Live video rendering remains a human visual confirmation; HTTP checks prove the
browser authentication and signaling paths.

## Shared checkpoints

After successful verification, the script creates shared checkpoints using the
existing shared backup scripts:

- Keycloak checkpoint under `{{BACKUP_PATH}}/keycloak/YYYYMMDDHHMMSSZ/`, with
  `STREAM_AUTH.md` as trigger. It contains `/opt/keycloak/` including the
  oauth2-proxy Compose service and secrets, plus a fresh PostgreSQL dump
  containing the browser client.
- Nginx checkpoint under `{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/`, with
  `STREAM_AUTH.md` as trigger. It contains nginx configuration including
  `/oauth2/*` and `auth_request` routes.

Do not create procedure-named nginx backups or conf.d-only archives. Restore
through [KEYCLOAK_BACKUP.md](KEYCLOAK_BACKUP.md) and
[NGINX_BACKUP.md](NGINX_BACKUP.md).

## Troubleshooting notes

- If `/outputs/` returns 404 without a login redirect, ensure the protected
  fallback uses `try_files "" =404;`; nginx `return 404` runs before
  `auth_request`.
- If oauth2-proxy reports an unknown CA, mount the public private-CA root and
  pass `--provider-ca-file`; do not disable verification.
- If nginx returns 502 after successful login, inspect for `upstream sent too big
  header` and require the 32 KiB/64 KiB `/oauth2/` proxy buffer settings.
- If login returns to the site root, require `return 302 /oauth2/start?rd=$request_uri;`.
- Browser cookies and Hermes MCP tokens are independent credentials.
- All authenticated browser users currently receive access to all protected route
  families. Add Keycloak roles/groups and policy if per-user or per-route access
  is required.
