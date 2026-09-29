# Keycloak backup and restore

This is the shared procedure for Keycloak recovery points. KEYCLOAK.md,
STREAM_AUTH.md, ADD_USER.md, and ADD_CLIENT_ON_SERVER.md identify when to run
it and which changes must be included. Resolve `{{BACKUP_PATH}}` from the
installation inputs, not historical logs.

Only the `Create a checkpoint` workflow is currently implemented as a script:

```bash
scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh
```

That script is the single source of truth for executable checkpoint actions. The
restore procedure remains documented guidance until a restore script is added.

Install the generic backup script and one-shot service using KEYCLOAK.md. The
service creates a local database dump only; archiving and publication to the
backup share below are also required. Initial installation must pass
KEYCLOAK.md's isolated restore test before its post-login checkpoint.

## Required Values

| Symbol | Description |
|---|---|
| `{{BACKUP_PATH}}` | Mounted backup root |

## Layout and scope

Store all Keycloak recovery points in one history, independent of the runbook
that triggered them:

```text
{{BACKUP_PATH}}/keycloak/YYYYMMDDHHMMSSZ/
    keycloak.tar
    keycloak-postgres.tar
    metadata.txt
    SHA256SUMS
```

Generate the directory timestamp at capture time with `date -u +%Y%m%d%H%M%SZ`.
It is UTC and includes seconds. Never reuse a runbook-start timestamp or
overwrite an existing checkpoint. Serialize checkpoint operations; if the name
already exists, stop and retry with a new timestamp. Do not mutate Keycloak or
its configuration during capture.

This document defines the Keycloak backup layout. Historical BACKUP.md entries
are inventory evidence, not backup or restore instructions. Do not write these
two archives into `keycloak-*`, `stream-auth-*`, `add-user-*`, or
`add-client-on-server-*` folders, and do not archive runbook copies.

## Create a checkpoint (AGENT-run)

Run with resolved values:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh create-checkpoint \
  --backup-path {{BACKUP_PATH}} \
  --trigger KEYCLOAK.md
```

When a coordinated nginx checkpoint path is already known, pass it explicitly so
metadata records the compatible pair:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh create-checkpoint \
  --backup-path {{BACKUP_PATH}} \
  --trigger KEYCLOAK.md \
  --compatible-nginx-checkpoint /mnt/camera-backup/nginx/YYYYMMDDHHMMSSZ \
  --host-unit-checkpoint not-recorded
```

The script performs the checkpoint workflow:

- verifies Docker, Keycloak/PostgreSQL, `/opt/keycloak` modes, and the one-shot
  backup service are ready;
- confirms the backup path is mounted and writable;
- creates a unique hidden staging directory under `{{BACKUP_PATH}}/keycloak/`;
- runs `keycloak-postgres-backup.service` and requires exactly one new dump;
- archives `/opt/keycloak` as `keycloak.tar` with root `keycloak/`;
- rejects token/cache artifacts from `keycloak.tar`;
- archives only the new dump as `keycloak-postgres.tar` with root
  `keycloak-postgres-backups/`;
- verifies archive member paths, dump mode, and `pg_restore --list`;
- writes no-secret `metadata.txt` with the actual dump name, compose image
  versions, service result, verification results, and compatible checkpoint
  references;
- writes and verifies `SHA256SUMS`;
- atomically renames the hidden staging directory to the final UTC timestamp
  directory.

A successful local dump is not a completed off-host recovery point until this
script publishes the timestamped checkpoint and verifies its checksums. Failed
staging directories are not recovery points. Retry with a fresh timestamp rather
than editing a completed checkpoint.

## Inspect checkpoint status (AGENT-run)

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh status \
  --backup-path {{BACKUP_PATH}}
```

## Restore from checkpoint

Restore is not yet scripted. If recovery is required, add a restore subcommand
before doing production recovery. The restore workflow must preserve these
principles:

1. Select one completed checkpoint directory matching exactly fourteen digits
   followed by `Z`; ignore hidden staging directories.
2. Require `keycloak.tar`, `keycloak-postgres.tar`, `metadata.txt`, and
   `SHA256SUMS`, and require `sha256sum -c SHA256SUMS` to pass.
3. Inspect metadata and archive safety before touching `/opt/keycloak` or the
   database. Never print `.env`, `*.pass`, token caches, OAuth codes, JWTs,
   cookies, or database contents.
4. Prepare Docker/Compose, CA trust, nginx recovery, and host systemd units as
   separate prerequisites. Keycloak checkpoints do not include nginx or non-
   Keycloak host units.
5. Restore `/opt/keycloak` cleanly, not layered over stale files. Verify
   directory/file modes and `docker compose config --quiet`.
6. Start PostgreSQL alone and require the destination database to be empty
   enough for restore before loading the selected dump.
7. Restore the exact dump from the same checkpoint and validate restored realms,
   users, clients, and policies.
8. Reinstall the repository's current backup script and service rather than
   recovering them from the archive.
9. Start Keycloak only after the database restore passes, restore/restart nginx
   separately, and verify public discovery.
10. Restore MCP OAuth drop-ins when applicable and rerun functional checks:
    anonymous DCR, Hermes MCP OAuth login/test, and stream/snapshot auth checks
    where configured.
11. Record recovery results outside the immutable checkpoint and take fresh
    checkpoints after any recovery-time changes.

## Pitfalls and notes

- The archive pair recovers `/opt/keycloak/` configuration and database state
  only. Host packages, mounts, CA recovery, nginx, and other systemd units are
  separate prerequisites.
- Do not publish a checkpoint that contains an old dump after a failed backup
  service run; the script rejects this by comparing dump inventories before and
  after the service.
- Do not mutate a completed checkpoint to add compatible nginx or host-unit
  references. Create a newer checkpoint instead.
