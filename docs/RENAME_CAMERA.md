# Camera Rename Protocol

## Purpose

Rename a camera consistently across both name sources: the camera's ONVIF
name and the runtime registry at `/etc/onvif-mcp/camera_registry.json`.

Many ONVIF cameras do not implement `SetHostname` correctly, or accept it and
later lose the setting, which is why some cameras appear in the registry under
their IP address. The protocol therefore treats the registry as authoritative
for name lookups: if the ONVIF name change fails, the error is noted but does
not prevent completion, and the registry is updated so future references by the
new name succeed.

Target state after a rename:

- The camera's ONVIF name is set via the MCP `change_camera_hostname` tool,
  when the camera supports it.
- `/etc/onvif-mcp/camera_registry.json` shows the new name for the camera,
  regardless of whether the ONVIF change succeeded.
- A timestamped backup of the registry is written before the update.
- `status` reports whether the live ONVIF name and the registry name agree.

## Required Values

| Value | Description |
|---|---|
| `{{SERVER_FQDN}}` | Server fully qualified domain name |
| `{{CAMERA_IP}}` | IP address of the camera to rename |
| `{{NEW_NAME}}` | New camera name |
| `{{BACKUP_PATH}}` | Backup folder for the shared checkpoint scripts |
| `{{TOKEN_FILE}}` | Agent OAuth token store for the camera MCP server, default `~/.hermes/mcp-tokens/camera.json` |

Stop and ask the user if any required value is missing. The agent is already
authenticated to the MCP server; the script uses the stored token from
`{{TOKEN_FILE}}` (refreshing it through Keycloak only when expired). Do not
mint a separate Keycloak token or print token values.

## Agent Presentation Rules

This document is a script for the agent. The executable source of truth is:

```text
{{REPO_PATH}}/scripts/RENAME_CAMERA/rename_camera_runbook.sh
```

Before executing any AGENT-run command or presenting any USER-run command,
replace every double-curly placeholder with the real site value. Do not ask the
user to type placeholders literally.

For this runbook, the agent normally runs the commands directly. If a command
must be shown to the user, include `cd {{REPO_PATH}}` as the first line of the
copy-paste block after resolving `{{REPO_PATH}}`.

Do not replace the scripted workflow with ad hoc shell fragments. If behavior
must change, update `scripts/RENAME_CAMERA/rename_camera_runbook.sh` and keep
this runbook as orchestration guidance.

## 1. Apply Rename (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}
scripts/RENAME_CAMERA/rename_camera_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --ip {{CAMERA_IP}} \
  --new-name {{NEW_NAME}} \
  --backup-path {{BACKUP_PATH}}
```

The script performs the full rename protocol:

- Preflight: confirms a registry entry exists for `{{CAMERA_IP}}` and the token
  file is present.
- Phase 1: calls `change_camera_hostname` through the MCP HTTP server. On
  success the camera's ONVIF name is updated. On failure the error is noted and
  the protocol continues — a nonconformant camera does not block the rename.
- Phase 2: writes the new name into the registry entry for `{{CAMERA_IP}}`,
  after saving a timestamped backup of the registry.
- Phase 3: publishes an nginx checkpoint through the shared backup script, as
  in [STREAM_AUTH.md](STREAM_AUTH.md), under `{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/`
  triggered by `RENAME_CAMERA.md`. The checkpoint captures
  `/etc/onvif-mcp/camera_registry.json`. No Keycloak checkpoint is created: the
  rename does not change Keycloak state.
- Phase 4: verifies the registry shows the new name and compares it against the
  live ONVIF name from `get_cameras`.

The apply step exits 0 when the registry update completes, even if the ONVIF
rename was rejected. Only a missing registry entry, missing token file, or
registry write failure is treated as a hard failure.

## 2. Verify Rename (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/RENAME_CAMERA/rename_camera_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --ip {{CAMERA_IP}}
```

Acceptance checks:

- The registry entry for `{{CAMERA_IP}}` shows `{{NEW_NAME}}`.
- A `camera_registry.json.backup-<timestamp>` exists for the run.
- The nginx checkpoint for `RENAME_CAMERA.md` exists under `{{BACKUP_PATH}}`
  and its manifest includes `etc/onvif-mcp/camera_registry.json`.
- `status` reports `consistent` when the live ONVIF name matches, or
  `divergent` with a note that the registry name is authoritative when the
  camera did not keep the ONVIF name. Divergence is an accepted outcome, not a
  failure.

## Operational Notes

Name lookups resolve through the registry, so a divergent camera is fully
usable under its new name. Snapshot routes are keyed by serial number and are
unaffected by renames.

Re-running `scripts/APPS/apps_runbook.sh` regenerates the registry from live
ONVIF names. If the camera did not keep the ONVIF name, that regeneration
reverts the registry entry to the old name; re-run this runbook after any APPS
regeneration.

Do not grind on a camera that rejects `SetHostname` after a couple of attempts;
treat it as nonconformant and let the registry carry the name.
