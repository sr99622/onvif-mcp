# Camera Removal Runbook

## Purpose

Remove one camera from the running system — the reverse of
[ADD_CAMERA.md](ADD_CAMERA.md) — without disturbing existing configuration.
Removal is incremental: only the camera's own registry entry, MediaMTX paths,
and snapshot routes are deleted; every other camera's entries stay intact.

The camera is typically already physically disconnected, so live ONVIF
discovery is not required: the registry entry (or its timestamped backup) is
the source of truth for the camera's serial number. Browser authorization is
route-family based (Keycloak + oauth2-proxy), so removing the camera changes
no Keycloak or nginx state; the runbook verifies that the route family still
protects the surviving cameras and that the removed camera's routes now 404.

Target state after a successful run:

- No entry for the camera in `/etc/onvif-mcp/camera_registry.json`
  (`644 root:root`). A timestamped backup of the registry is written before
  the update.
- No MediaMTX path for the camera in `/etc/mediamtx/mediamtx.yml`
  (`640 mediamtx:mediamtx`), and the `# generated_path_count:` line decremented
  by the number of paths removed. A timestamped backup of the file is written
  before the update.
- No snapshot route for the camera in `/etc/onvif-mcp/snapshot_routes.json`
  (`644 root:root`), with a timestamped backup written before the update.
- `mediamtx.service` and `snapshot-proxy.service` restarted and active; the
  removed camera's paths no longer appear in MediaMTX logs.
- Unauthenticated requests to the surviving cameras' `/snapshot/` and
  `/webrtc/` routes still redirect to `/oauth2/start` (route-family auth
  unaffected), and the removed camera's snapshot routes return 404 through the
  loopback proxy.
- An nginx checkpoint under `{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/` with
  `REMOVE_CAMERA.md` as the trigger, capturing both `/etc/onvif-mcp` JSON
  files. No Keycloak checkpoint is created: the runbook changes no Keycloak
  state.

No firewall or DHCP changes are required: the subnet rules in FIREWALL.md and
DHCP.md already cover the whole pool, and a stale DHCP lease for a
disconnected camera is harmless.

## Required Values

| Value | Description |
|---|---|
| `{{SERVER_FQDN}}` | Server fully qualified domain name |
| `{{CAMERA_IP}}` | IP address the camera had on the isolated camera network |
| `{{REPO_PATH}}` | Full path to this repository |
| `{{BACKUP_PATH}}` | Backup folder for the shared checkpoint scripts |

Stop and ask the user if any required value is missing. No camera password and
no OAuth token are needed: removal reads no secrets and calls no MCP tools, so
there is no USER-run password-store step. Keep an audit log in the folder that
holds the script (`{{REPO_PATH}}/scripts/REMOVE_CAMERA/remove_camera_runbook.log`),
suppressing echo to terminal, and copy it to `{{BACKUP_PATH}}/log/`. Record the
serial resolved, the exact counts removed from each file, the backups written,
and any errors encountered.

## Agent Presentation Rules

This document is a script for the agent. The executable source of truth is:

```text
{{REPO_PATH}}/scripts/REMOVE_CAMERA/remove_camera_runbook.sh
```

Before executing any AGENT-run command or presenting any USER-run command,
replace every double-curly placeholder with the real site value. Do not ask the
user to type placeholders literally.

For this runbook, the agent normally runs the commands directly. If a command
must be shown to the user, include `cd {{REPO_PATH}}` as the first line of the
copy-paste block after resolving `{{REPO_PATH}}`.

Do not replace the scripted workflow with ad hoc shell fragments. If behavior
must change, update `scripts/REMOVE_CAMERA/remove_camera_runbook.sh` and keep
this runbook as orchestration guidance.

## Guards (hard rules)

1. Removal asserts exact counts: exactly one registry entry, the snapshot
   routes whose keys start with the camera's serial, and the MediaMTX paths
   whose keys start with the camera's serial. Any count mismatch, or any key
   outside the camera's serial touched, is a hard failure naming the artifact.
2. Re-runs are idempotent: each phase reports already-removed artifacts as
   such and skips them, so a partial run interrupted by an error can be
   completed by re-running `apply`. A run that removes nothing at all across
   all three files is a hard failure naming the artifacts — a completed
   removal is re-verified with `status` and `test`, not by a no-op `apply`.
3. Existing cameras' entries are never modified. JSON files are validated by
   parsing before writing; the post-write key set must equal the pre-write key
   set minus exactly the camera's own keys.
4. `/etc/mediamtx/mediamtx.yml` contains embedded camera credentials: the
   working copy is created with `umask 077` and shredded at exit, the backup
   stays `640 mediamtx:mediamtx` in the same directory, and no file content is
   printed.
5. The script never changes nginx, Keycloak, firewall, or DHCP state.

## 1. Apply Removal (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}
scripts/REMOVE_CAMERA/remove_camera_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-ip {{CAMERA_IP}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

The script performs the full removal protocol, mirroring the ADD_CAMERA.md
phases in reverse:

- Preflight: confirms the nginx, MediaMTX, snapshot-proxy, and MCP HTTP
  services are active, the registry file exists, and the backup path is
  reachable.
- Phase 1: resolves the camera's serial from its registry entry (live entry
  first, most recent timestamped backup as fallback for a completed rerun).
  A camera with neither is a hard failure.
- Phase 2 (reverse of add phase 4): removes the camera's snapshot routes after
  writing a timestamped backup, asserts the exact route count, restarts
  `snapshot-proxy.service`.
- Phase 3 (reverse of add phase 3): removes the camera's MediaMTX paths after
  writing a timestamped backup, asserts the exact path count and the
  decremented `# generated_path_count:` line, restarts `mediamtx.service`.
- Phase 4 (reverse of add phase 2): removes the camera's registry entry after
  writing a timestamped backup, asserting exactly one entry was removed.
- Phase 5: time sync has no reverse action and is skipped.
- Phase 6: runs the status checks below.
- Phase 7: publishes an nginx checkpoint through the shared backup script, as
  in STREAM_AUTH.md, under `{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/` triggered
  by `REMOVE_CAMERA.md`. The checkpoint captures
  `/etc/onvif-mcp/camera_registry.json` and
  `/etc/onvif-mcp/snapshot_routes.json`.

## 2. Verify Removal (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/REMOVE_CAMERA/remove_camera_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-ip {{CAMERA_IP}}
```

Acceptance checks:

- nginx, MediaMTX, snapshot-proxy, and MCP HTTP services are active.
- File modes match the target state (`644 root:root` JSON files,
  `640 mediamtx:mediamtx` config, `600 root:root` env file).
- The registry shows no entry for the camera's serial, and a
  `camera_registry.json.backup-<timestamp>` exists for the run.
- Snapshot routes show no key for the serial, and a
  `snapshot_routes.json.backup-<timestamp>` exists for the run.
- MediaMTX shows no path for the serial, the `# generated_path_count:` line is
  decremented by the number of paths removed, and a
  `mediamtx.yml.backup-<timestamp>` exists for the run.
- A surviving camera's snapshot route still returns HTTP 200 `image/jpeg` with
  real JPEG magic bytes through the loopback proxy at
  `http://127.0.0.1:8891/snapshot/<route>/` — proving the removal caused no
  collateral damage.
- Recent MediaMTX logs show no path activity for the removed serial.

## 3. Test Remaining Cameras (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/REMOVE_CAMERA/remove_camera_runbook.sh test \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-ip {{CAMERA_IP}}
```

The script verifies that each removed snapshot route now returns HTTP 404
through the loopback proxy (enumerated from the run's timestamped backup),
that one surviving camera's route still returns HTTP 200 `image/jpeg` with
real JPEG magic bytes, and that unauthenticated requests to the route families
still redirect to `/oauth2/start` — proving route-family authorization is
untouched by the removal. The `test` command exits with the number of failed
checks.

Live video rendering for the surviving cameras remains a human visual
confirmation; HTTP checks prove the authentication and signaling paths.

## Operational Notes

- Multiview is out of scope: the removed camera simply disappears from the
  tile dropdowns once the registry entry is gone. No app changes are required.
- Re-running `scripts/APPS/apps_runbook.sh` regenerates the whole registry from
  live ONVIF names. A disconnected camera is not discovered, so a completed
  removal is consistent with that regeneration; it will still rewrite the
  file, so publish a new nginx checkpoint after any APPS regeneration.
- `/etc/mediamtx/mediamtx.yml` contains embedded camera credentials and is not
  captured by any backup script. This is an accepted gap: restore it by
  re-running the MEDIAMTX.md runbook. The timestamped `mediamtx.yml.backup-*`
  written by this runbook stays in `/etc/mediamtx/` with `640
  mediamtx:mediamtx` permissions.
- No Keycloak checkpoint is published: no Keycloak state changes. Users who
  had access to the removed camera's routes simply find them gone.
- The physical camera and its DHCP lease are out of scope; this runbook only
  removes the system's configuration for it. If the camera is reconnected and
  rediscovered, re-run ADD_CAMERA.md to bring it back.
- After a completed removal, `apply` exits as a hard failure because nothing
  remains to remove; use `status` and `test` to re-verify. A partial run (for
  example one interrupted by an error) can be completed by re-running `apply`:
  already-removed phases report as already removed and the remaining phases
  complete.
