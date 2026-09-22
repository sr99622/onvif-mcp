# Keycloak backup and restore

This is the shared procedure for Keycloak recovery points. KEYCLOAK.md,
STREAM_AUTH.md, ADD_USER.md and ADD_CLIENT_ON_SERVER.md identify when to run
it and which changes must be included. Resolve `{{BACKUP_PATH}}` from the
installation inputs, not historical logs.

Install the generic backup script and one-shot service using KEYCLOAK.md §14.
The service creates a local database dump only; archiving and publication to
the backup share below are also required. Initial installation must pass
KEYCLOAK.md §15's isolated restore test before its post-login checkpoint.

## Layout and scope

Store all Keycloak recovery points in one history, independent of the
runbook that triggered them:

```text
{{BACKUP_PATH}}/keycloak/YYYYMMDDHHMMSSZ/
    keycloak.tar
    keycloak-postgres.tar
    metadata.txt
    SHA256SUMS
```

Generate the directory timestamp at capture time with `date -u +%Y%m%d%H%M%SZ`.
It is UTC and includes seconds. Never reuse a runbook-start timestamp or
overwrite an existing checkpoint. Serialize checkpoint operations; if the
name already exists, stop and retry with a new timestamp. Do not mutate
Keycloak or its configuration during capture.

This document defines the Keycloak backup layout. Historical BACKUP.md
entries are inventory evidence, not backup or restore instructions. Do not
write these two archives into `keycloak-*`, `stream-auth-*`, `add-user-*`, or
`add-client-on-server-*` folders, and do not archive runbook copies.

## Create a checkpoint

This procedure intentionally spells out the mechanics. Agents must not improvise
folder names, reuse old dump files, or treat a successful local dump as a published
off-host recovery point. A checkpoint is complete only after `SHA256SUMS` verifies
inside the backup share and the hidden staging directory is renamed to its final
timestamp.

### 1. Preflight and staging

Confirm the Keycloak stack is stable before asking it for a dump:

```bash
sudo docker compose --project-directory /opt/keycloak ps
systemctl is-active docker
systemctl is-active keycloak-postgres-backup.service >/dev/null 2>&1 || true
sudo stat -c '%A %U %G %n' /opt/keycloak /opt/keycloak/.env /opt/keycloak/compose.yaml
sudo find /opt/keycloak -maxdepth 1 -type f -name '*.pass' -printf '%M %u %g %s %p\n'
```

Require:

- PostgreSQL is healthy and Keycloak is running, unless the triggering operation
  explicitly stopped them for a maintenance window.
- `/opt/keycloak/.env` and every `/opt/keycloak/*.pass` file are root:root mode
  `0600`.
- `/opt/keycloak/compose.yaml` is root:root mode `0640`.
- The backup script and service were installed from KEYCLOAK.md §14.

Create the hidden staging directory and export its path for the Python snippets:

```bash
set -euo pipefail
BACKUP_PATH="{{BACKUP_PATH}}"
ts="$(date -u +%Y%m%d%H%M%SZ)"
parent="$BACKUP_PATH/keycloak"
final="$parent/$ts"
staging="$parent/.$ts.staging.$$"
export staging

install -d -m 700 "$parent"
test ! -e "$final"
test ! -e "$staging"
install -d -m 700 "$staging"
```

Do not create `keycloak-*`, `stream-auth-*`, `add-user-*`, or
`add-client-on-server-*` folders for these two archives. Those names are not the
shared recovery history.

### 2. Run the one-shot dump service and identify the new dump

Record the dump directory contents before and after the service. This avoids the
common mistake of silently archiving an older dump after a failed run.

```bash
sudo find /var/backups/keycloak-postgres -maxdepth 1 -type f -name 'keycloak-*.dump' \
  -printf '%f\n' | sort > "$staging/dumps.before"

sudo systemctl start keycloak-postgres-backup.service
sudo systemctl show keycloak-postgres-backup.service -p Result -p ExecMainStatus | tee "$staging/service-result.txt"

grep -Fx 'Result=success' "$staging/service-result.txt"
grep -Fx 'ExecMainStatus=0' "$staging/service-result.txt"

sudo find /var/backups/keycloak-postgres -maxdepth 1 -type f -name 'keycloak-*.dump' \
  -printf '%f\n' | sort > "$staging/dumps.after"
comm -13 "$staging/dumps.before" "$staging/dumps.after" > "$staging/new-dump-name"
test "$(wc -l < "$staging/new-dump-name")" -eq 1

dump_name="$(cat "$staging/new-dump-name")"
dump_path="/var/backups/keycloak-postgres/$dump_name"
sudo stat -c '%A %U %G %s %n' "$dump_path" | tee "$staging/new-dump-stat.txt"
sudo test -s "$dump_path"
sudo test "$(sudo stat -c '%a %U %G' "$dump_path")" = '600 root root'
```

If any command fails, stop and leave or remove the hidden staging directory. Do
not continue with an older dump.

### 3. Archive `/opt/keycloak` as `keycloak.tar`

The archive root must be `keycloak/`, not `/opt/keycloak/` and not absolute
paths. This archive intentionally contains recovery secrets (`.env` and `*.pass`),
so do not print file contents.

```bash
sudo tar \
  --owner=0 --group=0 --preserve-permissions --acls --xattrs \
  -cf "$staging/keycloak.tar" \
  -C /opt keycloak
```

Verify the member root and reject token/cache artifacts:

```bash
sudo tar -tf "$staging/keycloak.tar" | tee "$staging/keycloak.members"
if grep -Ev '^(keycloak/?|keycloak/)' "$staging/keycloak.members"; then
  echo 'ERROR: keycloak.tar contains a member outside keycloak/' >&2
  exit 1
fi
if grep -Ei '(mcp-tokens|kcadm\.config|\.kctok|\.kctmp|refresh_token|access_token|client-token|token-cache)' "$staging/keycloak.members"; then
  echo 'ERROR: token/cache artifact included in keycloak.tar' >&2
  exit 1
fi
```

Expected secret/config files are allowed and required for recovery:

- `keycloak/.env` mode `0600`;
- `keycloak/admin.pass` and user `*.pass` files mode `0600`;
- `keycloak/compose.yaml` mode `0640`.

### 4. Archive only the new PostgreSQL dump

Do not archive `/var/backups/keycloak-postgres/` as a directory. It contains local
history, not just this recovery point. Stage only the new dump under the required
archive root:

```bash
dump_name="$(cat "$staging/new-dump-name")"
install -d -m 700 "$staging/dumpstage/keycloak-postgres-backups"
sudo install -o root -g root -m 600 \
  "/var/backups/keycloak-postgres/$dump_name" \
  "$staging/dumpstage/keycloak-postgres-backups/$dump_name"

sudo tar \
  --owner=0 --group=0 --preserve-permissions --acls --xattrs \
  -cf "$staging/keycloak-postgres.tar" \
  -C "$staging/dumpstage" "keycloak-postgres-backups/$dump_name"
```

Verify it has exactly one member and that the mode is preserved:

```bash
sudo tar -tf "$staging/keycloak-postgres.tar" | tee "$staging/postgres.members"
test "$(wc -l < "$staging/postgres.members")" -eq 1
grep -Fx "keycloak-postgres-backups/$dump_name" "$staging/postgres.members"
sudo tar -tvf "$staging/keycloak-postgres.tar" | tee "$staging/postgres.member-stat"
grep -E '^-rw------- .* keycloak-postgres-backups/' "$staging/postgres.member-stat"
```

### 5. Read back and validate the staged dump archive

List both tar files and reject unsafe paths:

```bash
python3 - <<'PY'
import os, tarfile
from pathlib import Path
staging = Path(os.environ['staging'])
for name in ['keycloak.tar', 'keycloak-postgres.tar']:
    with tarfile.open(staging / name) as tf:
        for m in tf.getmembers():
            if m.name.startswith('/') or '..' in Path(m.name).parts:
                raise SystemExit(f'{name}: unsafe member path {m.name}')
print('archive path safety checks passed')
PY
```

Extract the staged database dump to protected temporary storage and run
`pg_restore --list` with catalog output suppressed. Prefer the running PostgreSQL
container so the check uses the deployment's compatible tool version:

```bash
sudo install -d -m 700 "$staging/pgcheck"
sudo tar -xf "$staging/keycloak-postgres.tar" -C "$staging/pgcheck"
pgcheck_dump="$staging/pgcheck/keycloak-postgres-backups/$dump_name"

sudo sh -c "docker compose --project-directory /opt/keycloak exec -i postgres \
  pg_restore --list < '$pgcheck_dump' >/dev/null"
```

This proves the dump catalog is readable. It is not a full restore test. Initial
installation still requires KEYCLOAK.md §15's isolated restore test.

### 6. Write metadata before checksums

Create `$staging/metadata.txt` after the archive checks and before `SHA256SUMS`.
It must contain actual values from this run:

- capture UTC and triggering runbook/operation;
- exact new dump basename;
- `keycloak-postgres-backup.service` result lines;
- Keycloak, PostgreSQL, and oauth2-proxy image versions (`docker compose images` is
  sufficient; do not print expanded Compose config because it resolves secrets);
- configuration changes captured by this checkpoint, described without secret values;
- compatible nginx checkpoint path when this Keycloak state depends on nginx/oauth2;
- host-unit checkpoint reference when applicable;
- verification results: exactly one new dump, archive member checks, `pg_restore --list`,
  checksum.

Do not include passwords, `.env` values, OAuth codes, browser cookies, JWTs,
refresh tokens, DCR registration access tokens, or database contents. It is fine
to state that `.env` and `*.pass` files are intentionally archived inside
`keycloak.tar` for recovery.

### 7. Checksum and publish atomically

Remove temporary extraction directories from staging before checksumming:

```bash
sudo rm -rf "$staging/dumpstage" "$staging/pgcheck"
cd "$staging"
sha256sum keycloak.tar keycloak-postgres.tar metadata.txt > SHA256SUMS
sha256sum -c SHA256SUMS
cd "$parent"
mv "$staging" "$final"
printf 'published keycloak checkpoint: %s\n' "$final"
```

After publication, completed timestamp directories are immutable. If the wrong
dump, bad metadata, or an extra file was included, create a newer checkpoint;
do not edit the completed one in place.

The archive pair recovers `/opt/keycloak/` configuration and database state. Host
packages, external mounts, CA recovery, nginx, and other systemd units remain
separate prerequisites recorded in metadata. For coordinated nginx and Keycloak
changes, prepare both checkpoint paths before checksumming and publication, record
the compatible pair in both metadata files, and publish only after each checkpoint's
own checks pass. Do not mutate a completed checkpoint to add links.

## Restore from checkpoint

1. Select the lexicographically newest completed directory whose name matches
   fourteen digits followed by `Z`. Ignore hidden staging directories. Verify
   `SHA256SUMS` and require both archives and metadata. A missing file or failed
   checksum stops recovery; selecting an older checkpoint is an explicit
   recovery decision. Use both archives from the same directory.

2. Inspect the selected archives in a protected temporary directory. Reject
   absolute paths, `..` traversal and symlinks that redirect extraction outside
   the intended destination. Require configuration paths rooted at `keycloak/`
   and exactly the dump named in metadata under `keycloak-postgres-backups/`.
   Check the dump catalog without printing its contents. Select compatible
   PostgreSQL and Keycloak image versions from metadata; recovery and software
   upgrades are separate operations. Account for Compose mounts and other
   external configuration dependencies before proceeding.

3. Prepare Docker/Compose, required service accounts, CA trust, and the
   non-nginx host units referenced in metadata. Nginx configuration, public TLS
   material, and nginx-specific unit overrides use NGINX_BACKUP.md. Recover or
   reissue the server private key through SITE_CERT.md; it is not in these
   archives. Check compatibility between the chosen nginx and Keycloak states.

4. On a replacement host, prepare a clean `/opt/keycloak/` destination. For
   an explicitly authorized in-place restore, first preserve the existing
   configuration and database and stop Keycloak and oauth2-proxy writers.
   Extract `keycloak.tar` with `/opt` as the base, rather than layering it over
   stale files. Verify root ownership, directory mode 0750, secrets mode 0600,
   and Compose configuration mode 0640. Never print `.env` or password files.

5. Start only PostgreSQL from the recovered Compose configuration and wait
   for health. Keep Keycloak and oauth2-proxy stopped. Confirm the exact
   database/volume selected for recovery and require an empty destination
   database owned by the configured database user. On a fresh host, PostgreSQL
   initialization may already create that database. Stop on unexpected data;
   do not ignore errors or blindly drop an existing database. Do not run
   Keycloak first to initialize the schema.

6. Extract the exact selected dump to protected temporary storage and restore
   it using the compatible PostgreSQL container's `pg_restore` with
   `--username=keycloak --dbname=keycloak --exit-on-error`. Read root-only files
   through a root shell or `sudo cat`; an unprivileged shell redirect cannot
   read them. Preserve pipeline failure status and stop on any restore error.
   Verify expected realms, users, clients and policies without exposing
   credentials. A successful catalog listing alone does not prove recovery.
   Remove temporary dump copies after validation.

7. Install the repository's `scripts/backup-keycloak-postgres` and recreate
   its one-shot service using KEYCLOAK.md §14. No archived script is required.
   Restore necessary non-nginx units from their recorded source; inspect
   archive roots and exclude nginx-specific overrides from any legacy whole-
   system unit archive. Reload systemd after installing units. The selected
   nginx checkpoint owns its exact override set, including recorded absence.

8. Start Keycloak and wait for internal readiness. Restore/start nginx through
   NGINX_BACKUP.md. If oauth2-proxy is configured, start it once Keycloak
   discovery through nginx's public `/auth/` origin works, then verify its
   health. This ordering avoids waiting for oauth2-proxy before nginx can
   expose the discovery endpoint it needs.

9. Verify the public issuer/discovery document, expected unauthenticated MCP
   response, and the restored users/clients/policies. If browser authentication
   is configured, run STREAM_AUTH.md's functional verification, checking login
   and denied/unauthenticated access. Reauthenticate client applications as
   needed; client token caches are not recovery inputs. Do not declare the
   system ready until the applicable authentication and service checks pass.
   
10. Record actual recovery results outside the immutable checkpoint. Changes
    made during recovery, including new registrations or certificates, require
    fresh checkpoints after verification. Preserve the selected recovery point.

