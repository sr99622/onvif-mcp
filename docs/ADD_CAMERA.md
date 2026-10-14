# Camera Addition Runbook

## Purpose

Integrate one newly discovered ONVIF camera into the running system without
disturbing existing configuration. Addition is incremental: the runbook adds
only the new camera's registry entry, MediaMTX paths, and snapshot routes.
Existing cameras' entries are never modified, so any site-specific features
baked into the current configuration stay intact.

Browser authorization (Keycloak + oauth2-proxy) is route-family based, not
per-camera, so the new camera inherits `auth_request` protection on
`/webrtc/`, `/snapshot/`, and `/playback/` automatically. This runbook
verifies that inheritance; it does not re-apply Keycloak or nginx protection.

Target state after a successful run:

- One entry for the camera in `/etc/onvif-mcp/camera_registry.json`
  (`644 root:root`), using the camera's live ONVIF name as-is. A timestamped
  backup of the registry is written before the update.
- One MediaMTX path per camera profile in `/etc/mediamtx/mediamtx.yml`
  (`640 mediamtx:mediamtx`), with `record: true` on the main (first) profile
  only, consistent with existing configuration.
- One snapshot route per profile that has a snapshot URI in
  `/etc/onvif-mcp/snapshot_routes.json` (`644 root:root`), with a timestamped
  backup written before the update.
- `mediamtx.service` and `snapshot-proxy.service` restarted and active; the
  new camera's stream reported online in MediaMTX logs.
- Unauthenticated requests to the new camera's `/snapshot/` and `/webrtc/`
  routes redirect to `/oauth2/start` (auth inheritance verified).
- An nginx checkpoint under `{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/` with
  `ADD_CAMERA.md` as the trigger, capturing both `/etc/onvif-mcp` JSON files.
  No Keycloak checkpoint is created: the runbook changes no Keycloak state.

The camera must already be on the isolated camera network with a DHCP lease;
DHCP.md and FIREWALL.md subnet rules already cover any address in the pool, so
no firewall or DHCP changes are required.

## Required Values

| Value | Description |
|---|---|
| `{{SERVER_FQDN}}` | Server fully qualified domain name |
| `{{CAMERA_IP}}` | IP address of the new camera on the isolated camera network |
| `{{CAMERA_USERNAME}}` | Camera username, normally `admin` |
| `pass show camera` | Camera password from the local password store |
| `{{REPO_PATH}}` | Full path to this repository |
| `{{BACKUP_PATH}}` | Backup folder for the shared checkpoint scripts |
| `{{TOKEN_FILE}}` | Agent OAuth token store for the camera MCP server, default `~/.hermes/mcp-tokens/camera.json` |

Stop and ask the user if any required value is missing. The camera is required
to use the shared `pass show camera` credential. If `pass show camera` fails
because GPG needs the passphrase, stop and ask the user to prime the cache by
running this in their own terminal:

```bash
cd {{REPO_PATH}}
pass show camera >/dev/null
```

After the user confirms that command succeeded, rerun the `apply` command. Do
not ask the user to paste the GPG passphrase or camera password into chat. The
agent is already authenticated to the MCP server; the script uses the stored
token from `{{TOKEN_FILE}}` (refreshing it through Keycloak only when expired).
Do not mint a separate Keycloak token or print token values.

## Agent Presentation Rules

This document is a script for the agent. The executable source of truth is:

```text
{{REPO_PATH}}/scripts/ADD_CAMERA/add_camera_runbook.sh
```

Before executing any AGENT-run command or presenting any USER-run command,
replace every double-curly placeholder with the real site value. Do not ask the
user to type placeholders literally.

For this runbook, the agent normally runs the commands directly. If a command
must be shown to the user, include `cd {{REPO_PATH}}` as the first line of the
copy-paste block after resolving `{{REPO_PATH}}`.

Do not replace the scripted workflow with ad hoc shell fragments. If behavior
must change, update `scripts/ADD_CAMERA/add_camera_runbook.sh` and keep this
runbook as orchestration guidance.

## 1. Apply Camera Addition (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}
scripts/ADD_CAMERA/add_camera_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-ip {{CAMERA_IP}} \
  --camera-username {{CAMERA_USERNAME}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

The script performs the full addition protocol:

- Preflight: confirms the token file is present, the nginx, MediaMTX,
  snapshot-proxy, and MCP HTTP services are active, and the password store
  cache is primed. A failed `pass show camera` is a hard failure that gates on
  the USER-run cache-priming step above.
- Phase 1: calls `get_cameras` through the MCP HTTP server and selects the
  summary for `{{CAMERA_IP}}`. A camera that is not discovered is a hard
  failure — check the camera's network connection and DHCP lease before
  retrying.
- Phase 2: adds the camera's entry to the registry after writing a timestamped
  backup. Existing entries are untouched. Re-running is idempotent.
- Phase 3: appends one MediaMTX path per profile (main profile only with
  `record: true`), preserving all existing paths and the generated path count.
  The password is read from `pass show camera`, URL-encoded, and never printed.
  MediaMTX is restarted.
- Phase 4: adds one snapshot route per profile with a snapshot URI, after a
  timestamped backup. The snapshot proxy loads routes at startup, so it is
  restarted.
- Phase 5: calls `sync_camera_time` for the new camera. A rejected sync is
  printed as `NOTED (non-blocking)` and does not stop the runbook.
- Phase 6: runs the status checks below.
- Phase 7: publishes an nginx checkpoint through the shared backup script, as
  in STREAM_AUTH.md, under `{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/` triggered
  by `ADD_CAMERA.md`. The checkpoint captures
  `/etc/onvif-mcp/camera_registry.json` and
  `/etc/onvif-mcp/snapshot_routes.json`.

A stream not yet reported online shortly after the restart is a noted,
non-blocking outcome — cameras can take a few minutes to come up. Only missing
discovery, missing token file, failed password read, or write failures are hard
failures.

## 2. Verify Addition (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/ADD_CAMERA/add_camera_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-ip {{CAMERA_IP}}
```

Acceptance checks:

- nginx, MediaMTX, snapshot-proxy, and MCP HTTP services are active.
- File modes match the target state (`644 root:root` JSON files,
  `640 mediamtx:mediamtx` config, `600 root:root` env file).
- The registry shows an entry for the camera's serial number.
- Snapshot routes exist for every profile that reported a snapshot URI.
- MediaMTX paths exist for every profile that reported a stream URI, with
  `record: true` on the main profile.
- Unauthenticated `/snapshot/<serial>/` and `/webrtc/<serial>/` return HTTP
  302 to `/oauth2/start?rd=...` — proving the new camera inherits browser auth
  without any Keycloak or nginx change.
- Recent MediaMTX logs show the new camera's paths becoming
  `stream is online`.

## 3. Test New Camera Endpoints (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/ADD_CAMERA/add_camera_runbook.sh test \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-ip {{CAMERA_IP}}
```

The script verifies each new snapshot route through the loopback proxy at
`http://127.0.0.1:8891/snapshot/<route>/` (HTTP 200 `image/jpeg` with real
JPEG magic bytes — this proves the route and that the shared camera password
works on the new camera), then re-checks the unauthenticated public redirects.
The `test` command exits with the number of failed checks (snapshot routes plus
auth-inheritance redirects).

Live video rendering remains a human visual confirmation; HTTP checks prove the
authentication and signaling paths.

## Operational Notes

- Multiview is out of scope: it is a fixed four-tile view, and the new camera
  simply appears as an additional selection in the tile dropdowns once the
  registry entry exists. No app changes are required.
- The camera name is taken from the live ONVIF name as-is. If the user wants a
  different name later, use RENAME_CAMERA.md.
- Re-running `scripts/APPS/apps_runbook.sh` regenerates the whole registry from
  live ONVIF names. Because this runbook records the live ONVIF name, that
  regeneration is consistent; it will still rewrite the file, so publish a new
  nginx checkpoint after any APPS regeneration.
- `/etc/mediamtx/mediamtx.yml` contains embedded camera credentials and is not
  captured by any backup script. This is an accepted gap: restore it by
  re-running the MEDIAMTX.md runbook. The nginx checkpoint covers only the
  `/etc/onvif-mcp` JSON files and nginx configuration.
- No Keycloak checkpoint is published: no Keycloak state changes. All
  authenticated browser users already receive access to all protected route
  families, including the new camera's routes.
- Do not grind on a camera that rejects time sync after a couple of attempts;
  treat it as nonconformant, note it, and continue.
