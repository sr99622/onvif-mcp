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

This procedure intentionally spells out the mechanics. Agents must not guess the
checkpoint, mix archives from different timestamps, layer restored files over stale
state, or start Keycloak before the selected PostgreSQL dump is restored. A restore is
complete only after the database contents and applicable public endpoints are verified.
Nginx recovery remains separate; use `NGINX_BACKUP.md` for nginx configuration and TLS
material.

### 1. Select and verify one completed checkpoint

Select the lexicographically newest completed directory whose name matches fourteen
digits followed by `Z`. Ignore hidden staging directories. Selecting an older
checkpoint is an explicit recovery decision and must be recorded.

```bash
set -euo pipefail
BACKUP_PATH="{{BACKUP_PATH}}"
parent="$BACKUP_PATH/keycloak"
checkpoint_name="$(find "$parent" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' |
  grep -E '^[0-9]{14}Z$' | sort | tail -n 1)"
test -n "$checkpoint_name"
checkpoint="$parent/$checkpoint_name"
export checkpoint

cd "$checkpoint"
test -f keycloak.tar
test -f keycloak-postgres.tar
test -f metadata.txt
test -f SHA256SUMS
sha256sum -c SHA256SUMS
```

Require all checksums to pass. A missing archive, missing metadata file, or failed
checksum stops recovery. Use both archives from this same directory.

### 2. Inspect metadata and archive safety before extraction

Copy the selected checkpoint into protected temporary inspection storage. Do not print
`.env`, `*.pass`, database contents, token caches, or expanded Compose configuration.
Read metadata for compatible image versions and the exact dump basename.

```bash
restore_work="$(mktemp -d /root/keycloak-restore-inspect.XXXXXX)"
chmod 700 "$restore_work"
cp "$checkpoint"/keycloak.tar \
   "$checkpoint"/keycloak-postgres.tar \
   "$checkpoint"/metadata.txt \
   "$restore_work"/
cd "$restore_work"
sed -n '1,220p' metadata.txt
```

Extract the dump basename from metadata, then verify archive roots and path safety:

```bash
dump_name="$(sed -n 's/^New dump basename: //p' metadata.txt)"
test -n "$dump_name"
export dump_name restore_work

python3 - <<'PY'
import os, tarfile
from pathlib import Path
root = Path(os.environ['restore_work'])
dump = os.environ['dump_name']
expected_pg = f'keycloak-postgres-backups/{dump}'
for archive in ['keycloak.tar', 'keycloak-postgres.tar']:
    with tarfile.open(root / archive) as tf:
        members = tf.getmembers()
        for m in members:
            p = Path(m.name)
            if m.name.startswith('/') or '..' in p.parts:
                raise SystemExit(f'{archive}: unsafe member path {m.name}')
            if m.issym() or m.islnk():
                raise SystemExit(f'{archive}: link member not allowed during restore inspection: {m.name} -> {m.linkname}')
        names = [m.name for m in members]
        if archive == 'keycloak.tar':
            if not names or any(not (n == 'keycloak' or n.startswith('keycloak/')) for n in names):
                raise SystemExit('keycloak.tar must contain only keycloak/ members')
        else:
            if names != [expected_pg]:
                raise SystemExit(f'keycloak-postgres.tar must contain exactly {expected_pg!r}, got {names!r}')
print('archive safety and root checks passed')
PY
```

Check the database dump catalog without printing its contents. Prefer the recovered
PostgreSQL container after Docker is prepared; if no compatible container is available
yet, perform this check immediately after Step 5 starts PostgreSQL and before restore.

### 3. Prepare host prerequisites and separate nginx recovery

Prepare Docker/Compose, required service accounts, CA trust, and any non-nginx host
units referenced in metadata. Do not recover nginx from this checkpoint. Nginx
configuration, public TLS files, and nginx-specific unit overrides use
`NGINX_BACKUP.md`. Recover or reissue the server private key through `SITE_CERT.md`; it
is not in these archives.

On Ubuntu, install Docker packages if absent and start Docker:

```bash
if ! command -v docker >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y docker.io docker-compose-v2
fi
sudo systemctl enable --now docker
systemctl is-active docker
sudo docker compose version
```

Confirm that the public CA file referenced by the recovered Compose file exists before
starting oauth2-proxy later:

```bash
sudo test -s /etc/nginx/tls/camera-system-root-ca.crt.pem
```

### 4. Restore `/opt/keycloak` cleanly

On a replacement host, `/opt/keycloak` should be absent. For an explicitly authorized
in-place restore, preserve existing configuration and database state first, then stop
Keycloak and oauth2-proxy writers. Do not layer restored files over stale files.

```bash
stamp="$(date -u +%Y%m%d%H%M%SZ)"
if [ -e /opt/keycloak ]; then
  sudo docker compose --project-directory /opt/keycloak down || true
  sudo tar --acls --xattrs -cpf "/root/opt-keycloak-pre-restore-$stamp.tar" -C /opt keycloak
  sudo rm -rf /opt/keycloak
fi

sudo tar --acls --xattrs --same-owner -xpf "$checkpoint/keycloak.tar" -C /opt
```

Verify ownership and modes without printing secrets:

```bash
sudo stat -c '%a %U:%G %n' /opt/keycloak /opt/keycloak/compose.yaml /opt/keycloak/.env
sudo find /opt/keycloak -maxdepth 1 -type f -name '*.pass' -printf '%m %u:%g %s %p\n'
sudo test "$(sudo stat -c '%a %U:%G' /opt/keycloak/.env)" = '600 root:root'
sudo test "$(sudo stat -c '%a %U:%G' /opt/keycloak/compose.yaml)" = '640 root:root'
sudo find /opt/keycloak -maxdepth 1 -type f -name '*.pass' -exec sh -c '
  for f do [ "$(stat -c "%a %U:%G" "$f")" = "600 root:root" ] || exit 1; done
' sh {} +
sudo docker compose --project-directory /opt/keycloak config --quiet
```

Expected directory mode is `0750` root:root. If the archive restores `/opt/keycloak` as
`0755`, correct it to `0750` before starting services and record the archive-quality
issue.

### 5. Start only PostgreSQL and require an empty destination database

Start PostgreSQL alone. Keep Keycloak and oauth2-proxy stopped until after the dump is
restored.

```bash
sudo docker compose --project-directory /opt/keycloak up -d postgres
```

Wait for PostgreSQL health:

```bash
for i in $(seq 1 60); do
  status="$(sudo docker compose --project-directory /opt/keycloak ps --format json postgres |
    python3 -c 'import json,sys; data=sys.stdin.read().strip(); print(json.loads(data).get("Health", "") if data else "")' 2>/dev/null || true)"
  [ "$status" = "healthy" ] && break
  sleep 2
done
sudo docker compose --project-directory /opt/keycloak ps
```

Confirm the destination database is empty enough for restore. Stop if existing
application tables or realms are present; do not blindly drop data.

```bash
sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  psql --username=keycloak --dbname=keycloak --tuples-only --no-align \
  --command="SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
```

A fresh PostgreSQL initialization may create the `keycloak` database but should not have
Keycloak tables because Keycloak has not been started.

### 6. Restore the selected PostgreSQL dump and validate contents

Extract the exact selected dump to protected temporary storage, list its catalog, and
restore with failure propagation. Read root-only files through `sudo` or a root shell;
an unprivileged shell redirect cannot read them.

```bash
sudo install -d -m 700 /root/keycloak-restore-dump
sudo tar -xf "$checkpoint/keycloak-postgres.tar" -C /root/keycloak-restore-dump
pgdump="/root/keycloak-restore-dump/keycloak-postgres-backups/$dump_name"
sudo test -s "$pgdump"
sudo sh -c "docker compose --project-directory /opt/keycloak exec -T postgres \
  pg_restore --list < '$pgdump' >/dev/null"
sudo sh -c "docker compose --project-directory /opt/keycloak exec -T postgres \
  pg_restore --username=keycloak --dbname=keycloak --exit-on-error < '$pgdump'"
```

Verify expected restored state without exposing credentials:

```bash
sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  psql --username=keycloak --dbname=keycloak --tuples-only --no-align \
  --command="SELECT name FROM realm ORDER BY name;"

sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  psql --username=keycloak --dbname=keycloak --tuples-only --no-align \
  --command="SELECT realm_id, client_id FROM client WHERE client_id IN ('camera-web','mcp-client','account','security-admin-console') ORDER BY realm_id, client_id;"

sudo rm -rf /root/keycloak-restore-dump
```

A successful `pg_restore --list` alone is not enough; require restored realms and expected
clients or policies relevant to the selected checkpoint.

### 7. Reinstall the backup script and one-shot service

Install the repository's current script and recreate the one-shot service from
`KEYCLOAK.md` §14. Do not recover the script from the backup archive.

```bash
sudo install -d -m 700 -o root -g root /var/backups/keycloak-postgres
sudo install -o root -g root -m 750 \
  "{{REPO_PATH}}/onvif-mcp/scripts/backup-keycloak-postgres" \
  /usr/local/sbin/backup-keycloak-postgres
sudo bash -n /usr/local/sbin/backup-keycloak-postgres

sudo tee /etc/systemd/system/keycloak-postgres-backup.service >/dev/null <<'EOF'
[Unit]
Description=Back up the Keycloak PostgreSQL database
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/backup-keycloak-postgres
EOF
sudo chmod 644 /etc/systemd/system/keycloak-postgres-backup.service
sudo systemctl daemon-reload
sudo systemd-analyze verify /etc/systemd/system/keycloak-postgres-backup.service
```

### 8. Start Keycloak, then oauth2-proxy only after public discovery works

Start Keycloak and wait for internal readiness. Restore/start nginx through
`NGINX_BACKUP.md` separately. If nginx is already restored and serving `/auth/`, verify
public discovery before starting oauth2-proxy.

```bash
sudo docker compose --project-directory /opt/keycloak up -d keycloak
for i in $(seq 1 90); do
  code="$(curl -k -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/auth/realms/master/.well-known/openid-configuration || true)"
  [ "$code" = "200" ] && break
  sleep 2
done
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/auth/realms/master/.well-known/openid-configuration
```

If nginx is recovered and TLS is working, verify discovery through the public origin:

```bash
sudo curl --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  -s -o /dev/null -w '%{http_code}\n' \
  https://{{SERVER_FQDN}}/auth/realms/mcp/.well-known/openid-configuration
```

Only then start oauth2-proxy if it is present in Compose:

```bash
if sudo docker compose --project-directory /opt/keycloak config --services | grep -Fxq oauth2-proxy; then
  sudo docker compose --project-directory /opt/keycloak up -d oauth2-proxy
fi
sudo docker compose --project-directory /opt/keycloak ps
```

### 9. Restore the MCP OAuth systemd drop-in when applicable

Keycloak checkpoints do not include host systemd units. If the selected metadata says
KEYCLOAK.md §11 was completed, or if the restored deployment is expected to protect
`/mcp` with OAuth, recreate `/etc/systemd/system/onvif-mcp-http.service.d/oauth.conf`
from KEYCLOAK.md §11 before verifying MCP authentication. Do not rely on the
Keycloak database restore alone; without this host drop-in, the MCP HTTP service can
run but accept unauthenticated requests.

```bash
sudo install -d -m 755 /etc/systemd/system/onvif-mcp-http.service.d
sudo tee /etc/systemd/system/onvif-mcp-http.service.d/oauth.conf >/dev/null <<'EOF'
[Service]
Environment=MCP_OAUTH_ENABLED=true
Environment=MCP_OAUTH_ISSUER=https://{{SERVER_FQDN}}/auth/realms/mcp
Environment=MCP_RESOURCE_URL=https://{{SERVER_FQDN}}/mcp
Environment=MCP_OAUTH_JWKS_URL=http://127.0.0.1:8080/auth/realms/mcp/protocol/openid-connect/certs
EOF
sudo chmod 644 /etc/systemd/system/onvif-mcp-http.service.d/oauth.conf
sudo systemd-analyze verify onvif-mcp-http.service
sudo systemctl daemon-reload
sudo systemctl restart onvif-mcp-http.service
systemctl is-active onvif-mcp-http.service
```

After restart, verify the active environment without printing unrelated service
secrets:

```bash
systemctl show onvif-mcp-http.service -p Environment --no-pager |
  tr ' ' '\n' |
  grep -E '^(Environment=)?MCP_OAUTH_ENABLED=|^MCP_OAUTH_ISSUER=|^MCP_RESOURCE_URL=|^MCP_OAUTH_JWKS_URL='
```

If the deployment intentionally does not enable MCP OAuth, record that exception in the
recovery note and skip this step deliberately.

### 10. Verify restored authentication state

Verify public issuer/discovery, expected unauthenticated MCP behavior, restored
realms/users/clients/policies, Dynamic Client Registration, Hermes MCP OAuth,
and browser stream/snapshot authentication. Do not print password files, `.env`,
tokens, DCR registration access tokens, browser cookies, or database secrets.

First verify restored database content directly:

```bash
sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  psql --username=keycloak --dbname=keycloak --tuples-only --no-align \
  --command="SELECT realm_id, username, enabled FROM user_entity ORDER BY realm_id, username;"

sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  psql --username=keycloak --dbname=keycloak --tuples-only --no-align \
  --command="SELECT realm_id, client_id, enabled FROM client ORDER BY realm_id, client_id;"
```

Then run these functional checks before declaring recovery complete:

1. Run `KEYCLOAK.md` §12, **Test DCR without exposing registration
   credentials**.
   - Expected: anonymous DCR for scope `mcp:tools` returns HTTP `201`.
   - Print only safe fields: `client_id`, `scope`, `error`, and
     `error_description`.
   - Resolve the temporary client through the Admin API, require the name
     `temporary-dcr-verification`, delete it, and verify it is gone.
   - Remove the response artifact because it contains a registration access
     token.

2. Run `KEYCLOAK.md` §13, **Verify the Hermes login end-to-end**, for the
   deployment's real MCP server entry (for example `camera-new`).
   - Configure the entry with `auth: oauth`, the HTTPS `/mcp` URL, and an
     explicit `ssl_verify` path to the private CA; never set `ssl_verify=false`.
   - Prevent concurrent OAuth flows as described in §13.2.
   - Complete the browser authorization headlessly with
     `scripts/kc-headless-login-driver.py` or an equivalent no-secret driver.
   - Require token files to exist with mode `0600`, then run
     `hermes mcp test <name>` and require a successful OAuth connection and tool
     discovery.
   - Client token caches are not recovery inputs; reauthenticate clients after
     restore rather than expecting token files from the checkpoint.

3. If browser stream authentication is configured, run `STREAM_AUTH.md` §8,
   **Verify unauthenticated behavior**.
   - Require `/cameras/`, `/multiview/`, `/outputs/`, `/webrtc/`, `/snapshot/`,
     and a known concrete `SNAPSHOT_PATH` to redirect to `/oauth2/start` with
     the original path in `rd=`.
   - Require the old HTTP snapshot entry point to redirect to the same HTTPS
     snapshot path, and following that path without cookies must reach the login
     redirect rather than serve a JPEG.
   - Require unauthenticated MCP JSON-RPC to return `401` with protected-resource
     metadata, while Keycloak discovery remains HTTP `200`.

4. If browser stream authentication is configured, run `STREAM_AUTH.md` §9,
   **Verify browser behavior**.
   - Run `python3 scripts/stream_auth_step9_driver.py --origin
     "https://{{SERVER_FQDN}}"` with deployment-specific overrides for any known
     snapshot or WebRTC paths that differ from the defaults.
   - Require `RESULT=PASS`: exact login landing on `/cameras/`, authenticated
     `/oauth2/ping` returning `202 Authenticated`, same-session `/multiview/`,
     WebRTC pass-through without a sign-in bounce, and both same-session and
     fresh-session snapshots serving valid JPEGs with `Cache-Control: no-store`.
   - Run the MCP regression checks from §9, including `hermes mcp test <name>`.

Do not declare the system ready until every applicable authentication and service
check above passes. If a check is intentionally not applicable, record why in the
recovery note.

### 11. Record recovery results and take fresh checkpoints after changes

Record actual recovery results outside the immutable checkpoint. Preserve the selected
checkpoint unchanged. Any changes made during recovery, including new registrations,
certificates, nginx changes, or user changes, require fresh checkpoints after verification.
A restored Keycloak state that depends on nginx/oauth2 configuration should be paired with
a compatible nginx checkpoint from `NGINX_BACKUP.md`.

