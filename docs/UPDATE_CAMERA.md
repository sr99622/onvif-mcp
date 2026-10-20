# Camera Address Update Runbook

## Purpose

Correct one camera's recorded address when its address on the isolated camera
network changes (DHCP reassignment, a manual static assignment, or a camera that
was moved to a different address). The camera itself is not re-added: identity is
the serial number, so every key in the system — registry entry, snapshot route
key, MediaMTX path key, and the browser URL — stays the same. Only the host those
keys point at changes.

The address is embedded in three generated artifacts, and all three must be
corrected together. Fixing only the registry leaves the camera visible in the web
apps but still broken, because the player URLs are keyed by serial number: the
visible symptom of a stale address is a failed stream and a failed snapshot, not
a missing camera.

Symptom signatures of a stale address:

- MediaMTX logs: `ERR [path <serial>/<profile>] [RTSP source] dial tcp <old-ip>:554: connect: no route to host`
- Snapshot proxy: HTTP 502 for that camera's route, while other cameras return
  HTTP 200 `image/jpeg`
- The web app shows the camera with its old address in the details line

Target state after a successful run:

- The camera's entry in `/etc/onvif-mcp/camera_registry.json` (`644 root:root`)
  records `{{NEW_IP}}`. A timestamped backup of the registry is written before
  the update.
- Every snapshot route in `/etc/onvif-mcp/snapshot_routes.json` (`644 root:root`)
  whose key starts with the camera's serial points at `{{NEW_IP}}`. The key set
  is unchanged. A timestamped backup is written before the update.
- Every MediaMTX path in `/etc/mediamtx/mediamtx.yml` (`640 mediamtx:mediamtx`)
  whose key starts with the camera's serial has `{{NEW_IP}}` in its source URL.
  The path key set and the `# generated_path_count:` line are unchanged. A
  timestamped backup is written before the update.
- `mediamtx.service` and `snapshot-proxy.service` restarted and active; the
  camera's paths reported online in MediaMTX logs, and its snapshot routes
  return HTTP 200 `image/jpeg` with real JPEG magic bytes through the loopback
  proxy.
- No reference to `{{OLD_IP}}` remains in any live file (timestamped backups
  legitimately still contain it).
- An nginx checkpoint under `{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/` with
  `UPDATE_CAMERA.md` as the trigger, capturing both `/etc/onvif-mcp` JSON files.
  No Keycloak checkpoint is created: the runbook changes no Keycloak state.

No firewall or DHCP changes are required: the subnet rules in FIREWALL.md and
DHCP.md already cover the whole pool. If the address must stop moving, add a DHCP
reservation through DHCP.md separately.

## Required Values

| Value | Description |
|---|---|
| `{{SERVER_FQDN}}` | Server fully qualified domain name |
| `{{CAMERA_SERIAL}}` | Camera serial number (the stable identity) |
| `{{NEW_IP}}` | Address the camera now has on the isolated camera network |
| `{{OLD_IP}}` | Address recorded before the change; optional, defaults to the value currently in the registry |
| `{{REPO_PATH}}` | Full path to this repository |
| `{{BACKUP_PATH}}` | Backup folder for the shared checkpoint scripts |
| `{{TOKEN_FILE}}` | Agent OAuth token store for the camera MCP server, default `~/.hermes/mcp-tokens/camera.json` |

Stop and ask the user if any required value is missing. No camera password is
needed: the runbook rewrites only the host portion of existing values, so it
reads no secrets and there is no USER-run password-store step. The agent is
already authenticated to the MCP server; the script uses the stored token from
`{{TOKEN_FILE}}` (refreshing it through Keycloak only when expired). Do not mint
a separate Keycloak token or print token values.

Keep an audit log in the folder that holds the script
(`{{REPO_PATH}}/scripts/UPDATE_CAMERA/update_camera_runbook.log`), suppressing
echo to terminal, and copy it to `{{BACKUP_PATH}}/log/`. Record the serial
resolved, the recorded and target addresses, the live-discovery result, the exact
counts changed in each file, the backups written, and any errors encountered.

## Agent Presentation Rules

This document is a script for the agent. The executable source of truth is:

```text
{{REPO_PATH}}/scripts/UPDATE_CAMERA/update_camera_runbook.sh
```

Before executing any AGENT-run command or presenting any USER-run command,
replace every double-curly placeholder with the real site value. Do not ask the
user to type placeholders literally.

For this runbook, the agent normally runs the commands directly. If a command
must be shown to the user, include `cd {{REPO_PATH}}` as the first line of the
copy-paste block after resolving `{{REPO_PATH}}`.

Do not replace the scripted workflow with ad hoc shell fragments. If behavior
must change, update `scripts/UPDATE_CAMERA/update_camera_runbook.sh` and keep
this runbook as orchestration guidance.

## Guards (hard rules)

1. Identity is the serial number. Keys are never rewritten: the registry entry
   set, the snapshot route key set, and the MediaMTX path key set must be
   identical before and after the run. Only values change, and only values
   belonging to `{{CAMERA_SERIAL}}`. Any key outside the camera's serial touched
   is a hard failure naming the artifact.
2. The supplied `{{NEW_IP}}` is executed exactly. If live discovery reports a
   different address, flag the discrepancy in the handback report; do not
   silently substitute the observed value or widen to a subnet. Re-run only with
   a newly observed address if the camera's next attempt fails.
3. Re-runs are idempotent: each phase reports already-correct artifacts as such
   and skips them, so a partial run interrupted by an error can be completed by
   re-running `apply`. A run that changes nothing at all across all three files
   is a hard failure naming the artifacts — a completed correction is re-verified
   with `status` and `test`, not by a no-op `apply`.
4. `/etc/mediamtx/mediamtx.yml` contains embedded camera credentials: the working
   copy is created with `umask 077` and shredded at exit, the backup stays `640
   mediamtx:mediamtx` in the same directory, and no file content is printed —
   status prints only the path key and the host.
5. The script never changes nginx, Keycloak, firewall, or DHCP state.

## 1. Apply Address Update (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}
scripts/UPDATE_CAMERA/update_camera_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-serial {{CAMERA_SERIAL}} \
  --new-ip {{NEW_IP}} \
  --old-ip {{OLD_IP}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

The script performs the full update protocol:

- Preflight: confirms the nginx, MediaMTX, snapshot-proxy, and MCP HTTP services
  are active, the registry file exists, the backup path is reachable, and the
  token file is present.
- Phase 1: resolves the camera's registry entry by serial and records the address
  it currently holds (`{{OLD_IP}}` defaults to that value).
- Phase 2: calls `get_cameras` through the MCP HTTP server and reports the live
  address for the serial. This is informational: a disagreement with `{{NEW_IP}}`
  is flagged, not substituted. A camera that is not discovered is noted and the
  run continues, because the supplied value may still be correct while the camera
  is momentarily offline.
- Phase 3: rewrites the camera's registry address after writing a timestamped
  backup, asserting exactly one entry changed and the entry set is unchanged.
- Phase 4 (mirrors add phase 3): rewrites the host in the camera's MediaMTX
  source URLs after writing a timestamped backup, asserting the key set and the
  `# generated_path_count:` line are unchanged, then restarts
  `mediamtx.service`.
- Phase 5 (mirrors add phase 4): rewrites the host in the camera's snapshot
  routes after writing a timestamped backup, asserting the key set is unchanged,
  then restarts `snapshot-proxy.service` (the proxy loads routes at startup).
- Phase 6: runs the status checks below.
- Phase 7: publishes an nginx checkpoint through the shared backup script, as in
  STREAM_AUTH.md, under `{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/` triggered by
  `UPDATE_CAMERA.md`. The checkpoint captures
  `/etc/onvif-mcp/camera_registry.json` and
  `/etc/onvif-mcp/snapshot_routes.json`. The audit log is copied to
  `{{BACKUP_PATH}}/log/`.

A stream not yet reported online shortly after the restart is a noted,
non-blocking outcome — cameras can take a few minutes to come up. Only a missing
registry entry, missing token file, unreachable backup path, key-set assertion
failure, or write failure is a hard failure.

## 2. Verify Update (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/UPDATE_CAMERA/update_camera_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-serial {{CAMERA_SERIAL}}
```

Acceptance checks:

- nginx, MediaMTX, snapshot-proxy, and MCP HTTP services are active.
- File modes match the target state (`644 root:root` JSON files,
  `640 mediamtx:mediamtx` config, `600 root:root` env file).
- The registry entry for the serial records `{{NEW_IP}}`.
- Every route for the serial points at `{{NEW_IP}}`; every MediaMTX path for the
  serial points at `{{NEW_IP}}` (printed as key and host only, credentials
  suppressed).
- The stale-reference count over the live files is zero. Timestamped
  `*.backup-*` files still containing `{{OLD_IP}}` are expected and are not a
  failure.
- A timestamped backup exists for each of the three files for this run.

## 3. Test Camera Endpoints (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/UPDATE_CAMERA/update_camera_runbook.sh test \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-serial {{CAMERA_SERIAL}}
```

The script verifies each of the camera's snapshot routes through the loopback
proxy at `http://127.0.0.1:8891/snapshot/<route>/` (HTTP 200 `image/jpeg` with
real JPEG magic bytes — this proves the route now resolves to the live camera),
that the camera's MediaMTX paths are reported online in recent logs, that no
reference to `{{OLD_IP}}` remains in the live files, and that unauthenticated
requests to the route families still redirect to `/oauth2/start` — proving
route-family authorization is untouched. The `test` command exits with the number
of failed checks.

Live video rendering remains a human visual confirmation; HTTP checks prove the
authentication and signaling paths.

## Operational Notes

- Multiview is out of scope: the tile dropdowns read the registry, so the camera
  simply shows the corrected address once the registry entry is updated. No app
  changes are required.
- Re-running `scripts/APPS/apps_runbook.sh` regenerates the whole registry from
  live discovery, which is consistent with this runbook when the live address is
  the corrected one; it will still rewrite the file, so publish a new nginx
  checkpoint after any APPS regeneration.
- `/etc/mediamtx/mediamtx.yml` contains embedded camera credentials and is not
  captured by any backup script. This is an accepted gap: restore it by
  re-running the MEDIAMTX.md runbook. The timestamped `mediamtx.yml.backup-*`
  written by this runbook stays in `/etc/mediamtx/` with `640
  mediamtx:mediamtx` permissions.
- The nginx checkpoint is the recovery point for the two `/etc/onvif-mcp` JSON
  files. Restore is documented in NGINX_BACKUP.md and is not yet scripted; the
  per-file timestamped backups written by this runbook are the immediate
  rollback for a wrong address.
- No Keycloak checkpoint is published: no Keycloak state changes. Users who could
  reach the camera before the address change can still reach it after, because
  authorization is route-family based on the serial, not the address.
- If the camera's clock is also wrong (a nonsensical `time_offset` in discovery
  output), that is a separate condition; `sync_camera_time` is not part of this
  runbook and is handled by ADD_CAMERA.md's phase 5.
