# Nginx backup and restore

This is the shared procedure for nginx configuration checkpoints. All runbooks
that change nginx use this history, including MEDIAMTX, SNAPSHOT, APPS,
MCP_HTTP, SITE_CERT, CA_DISTRIBUTE, KEYCLOAK, and STREAM_AUTH. Resolve
`{{BACKUP_PATH}}` from the installation's supplied values, not a historical log.

## Layout and scope

```text
{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/
    nginx.tar
    metadata.txt
    SHA256SUMS
```

Generate the UTC capture timestamp with `date -u +%Y%m%d%H%M%SZ`. Each directory
is one complete configuration snapshot, not a delta or one runbook's edits.
Keep completed checkpoints unchanged. Serialize captures and refuse an existing
name; retry with a fresh timestamp rather than replacing an earlier checkpoint.

`nginx.tar` has paths relative to `/`, rooted at `etc/nginx/`, plus any
`etc/systemd/system/nginx.service` override and
`etc/systemd/system/nginx.service.d/` drop-ins that exist. It includes the main
configuration, conf.d, both sites directories, snippets, module configuration,
MIME/parameter files, and public TLS certificates/chain/CA/CSR. Preserve
ownership, permissions, ACLs, xattrs, and symlinks without dereferencing them.
Record the absence of nginx-specific unit overrides as well as their presence.
Do not capture unrelated systemd units or rely on a prior checkpoint for them.

**Private TLS keys are never archived.** Inventory all `ssl_certificate_key`
paths and inspect the proposed archive inputs for key copies, including hidden
files, renamed keys, and old configuration backups. Use an explicit reviewed
file manifest; a `*.key` filename exclusion alone is not sufficient. Exclude
private keys and obsolete scratch/rollback copies such as `/etc/nginx/backups/`
from the manifest. If an active configuration depends on one of those files,
resolve that dependency before capture; do not silently omit active configuration.
Preserve public TLS material only. No runbook copies are included.

An nginx configuration can reference files outside `/etc/nginx`. Inventory
`include`, certificate, authentication-file, module, and symlink targets and
account for every external dependency in metadata. Required configuration
files outside the tree must be included in the archive at their original
root-relative paths, except private keys; review these files for secrets too.
Package-owned modules/binaries are reinstalled using the recorded package
versions, not bundled in the archive. Record external web roots, CA distribution
content, upstream services, and Keycloak checkpoint references separately.
An unaccounted dependency makes the checkpoint incomplete. Treat the backup as
sensitive even though TLS private keys are excluded: nginx configuration may
contain authentication data.

## Create a checkpoint

This section is written for agents that are prone to over-including files. Follow
it literally. A completed checkpoint is published only by an atomic rename from a
hidden staging directory after all checks pass.

### 1. Preflight: prove the live state is checkpoint-worthy

Run these checks before creating any archive:

```bash
sudo nginx -t
sudo nginx -T >/tmp/nginx-effective.txt
sudo ss -lntp 'sport = :443' || true
sudo ls -la /etc/nginx/conf.d /etc/nginx/sites-enabled /etc/nginx/sites-available
systemctl show nginx.service --property=FragmentPath --property=DropInPaths
```

Require all of the following before continuing:

- `nginx -t` reports success.
- HTTPS stages use `listen 443 ssl;` without pinning to `{{SERVER_IP}}:443`.
- There is no enabled default site unless metadata explicitly explains why it is
  active and required. In the verified deployment, `sites-enabled/default` must
  be absent.
- No rollback/backup file is loaded by nginx. Remember: nginx loads every
  regular file under `conf.d/*.conf` and every enabled site target.
- The live HTTPS vhost, the HTTP redirect/CA-distribution vhost, `/ca/`, `/auth/`,
  `/oauth2/`, `/mcp`, application routes, WebRTC, and snapshot routes have all
  passed the originating runbook's functional checks.

If any check fails, stop. Do not publish a checkpoint of a known-bad state.

### 2. Create a private staging directory

Use the supplied backup path, not a path copied from an older checkpoint:

```bash
set -euo pipefail
BACKUP_PATH="{{BACKUP_PATH}}"
ts="$(date -u +%Y%m%d%H%M%SZ)"
parent="$BACKUP_PATH/nginx"
final="$parent/$ts"
staging="$parent/.$ts.staging.$$"
export staging

install -d -m 700 "$parent"
test ! -e "$final"
test ! -e "$staging"
install -d -m 700 "$staging"
```

All temporary manifest, extraction, and metadata files for this checkpoint must
stay under `$staging` or a protected local scratch directory. Never stage files
inside `/etc/nginx`, `conf.d`, or `sites-enabled`.

### 3. Build the explicit manifest

Do not archive `/etc/nginx` as a directory operand. A directory operand makes tar
recurse and re-add files you meant to exclude. Instead, generate a reviewed list
of root-relative file/symlink paths and feed that list to tar.

The manifest must include:

- current active nginx configuration files under `/etc/nginx`;
- public TLS material: `.crt.pem`, `.chain.pem`, `.csr.pem`, CA certificates;
- `sites-enabled` symlinks, preserved as symlinks;
- nginx-specific systemd override files if they exist;
- required external configuration inputs such as `/etc/onvif-mcp/camera_registry.json`,
  `/etc/onvif-mcp/snapshot_routes.json`, and `/srv/camera-pki/public/*` when those
  are referenced by nginx.

The manifest must exclude:

- every private key, including the active `ssl_certificate_key` target;
- `/etc/nginx/backups/`;
- `*.backup-*`, `*.pre-*` rollback copies unless they are active configuration
  inputs, and `nginx.conf.backup-*`;
- inactive `sites-available/default` and inactive enabled-site targets;
- runbook copies, logs, extracted inspection directories, and temporary files.

Recommended manifest-generation pattern:

```bash
sudo env staging="$staging" python3 - <<'PY'
from pathlib import Path
import os, re, sys
out = Path(os.environ['staging']) / 'manifest.txt'
items = []

def add_file(path):
    p = Path(path)
    if p.exists() and (p.is_file() or p.is_symlink()):
        items.append(str(p.relative_to('/')))

def rejected(rel, p):
    if rel.startswith('etc/nginx/backups/'):
        return True
    if re.search(r'(^|/)default$', rel):
        return True
    if re.search(r'\.backup-|backup-\d{4}-\d{2}-\d{2}|nginx\.conf\.backup-|\.pre-', rel):
        return True
    if re.search(r'(\.key(\.|$)|key\.pem$)', rel):
        return True
    try:
        if p.is_file():
            head = p.open('rb').read(4096)
            if b'BEGIN PRIVATE KEY' in head or b'BEGIN RSA PRIVATE KEY' in head or b'BEGIN EC PRIVATE KEY' in head:
                return True
    except PermissionError:
        raise SystemExit(f'cannot inspect candidate file: {p}')
    return False

for root in ['/etc/nginx', '/srv/camera-pki/public']:
    r = Path(root)
    if not r.exists():
        continue
    for p in sorted(r.rglob('*')):
        if p.is_dir():
            continue              # avoid tar recursion from directory operands
        rel = str(p.relative_to('/'))
        if not rejected(rel, p):
            items.append(rel)

for path in [
    '/etc/onvif-mcp/camera_registry.json',
    '/etc/onvif-mcp/snapshot_routes.json',
    '/etc/systemd/system/nginx.service',
]:
    add_file(path)

d = Path('/etc/systemd/system/nginx.service.d')
if d.exists():
    for p in sorted(d.rglob('*')):
        if p.is_file() or p.is_symlink():
            items.append(str(p.relative_to('/')))

items = sorted(set(items))
for rel in items:
    if rel.startswith('/') or '..' in Path(rel).parts:
        raise SystemExit(f'bad manifest path: {rel}')
out.write_text('\n'.join(items) + '\n')
os.chmod(out, 0o600)
print(f'wrote {out} with {len(items)} members')
PY
```

Review the manifest before archiving:

```bash
sudo sed -n '1,240p' "$staging/manifest.txt"
if sudo grep -E '(\.key(\.|$)|key\.pem$|\.backup-|backup-[0-9]{4}-[0-9]{2}-[0-9]{2}|nginx\.conf\.backup-|/default$|/backups/)' "$staging/manifest.txt"; then
  echo 'ERROR: forbidden member in manifest' >&2
  exit 1
fi
```

If the grep prints any line, fix the live/staging state and rebuild the manifest.
Do not continue by deciding the line is harmless.

### 4. Create and validate `nginx.tar`

```bash
sudo tar \
  --owner=0 --group=0 --preserve-permissions --acls --xattrs \
  -cf "$staging/nginx.tar" \
  -C / --files-from "$staging/manifest.txt"

sudo tar -tf "$staging/nginx.tar" | sort > "$staging/archive-members.txt"
sort "$staging/manifest.txt" > "$staging/manifest.sorted"
diff -u "$staging/manifest.sorted" "$staging/archive-members.txt"
```

The diff must be empty. A nonempty diff means tar included extra files or missed
files; do not publish.

Then run these archive checks:

```bash
sudo env staging="$staging" python3 - <<'PY'
import os, tarfile
from pathlib import Path
staging = Path(os.environ['staging'])
with tarfile.open(staging / 'nginx.tar') as tf:
    for m in tf.getmembers():
        if m.name.startswith('/') or '..' in Path(m.name).parts:
            raise SystemExit(f'unsafe member path: {m.name}')
        if m.isfile() and m.size < 2_000_000:
            data = tf.extractfile(m).read()
            if b'BEGIN PRIVATE KEY' in data or b'BEGIN RSA PRIVATE KEY' in data or b'BEGIN EC PRIVATE KEY' in data:
                raise SystemExit(f'private-key material found in archive member {m.name}')
print('nginx.tar path and private-key scan passed')
PY
```

Record symlinks, especially `sites-enabled/*`, with:

```bash
sudo tar -tvf "$staging/nginx.tar" | grep '^l' || true
```

### 5. Write metadata before checksums

Create `$staging/metadata.txt`. It must include actual facts from this capture,
not generic statements:

- capture UTC and triggering runbook/operation;
- nginx package version and service user;
- exact active HTTPS vhost file(s) and HTTP vhost file(s);
- public certificate subject/issuer/fingerprint;
- nginx-specific unit override presence or absence;
- external dependencies not archived, including application web roots and loopback
  upstream services;
- compatible Keycloak checkpoint path if this nginx state depends on Keycloak or
  oauth2-proxy;
- explicit exclusions, especially private key path and backup/default files;
- verification results: `nginx -t`, manifest diff, private-key scan, checksum.

Example fields to collect:

```bash
nginx -v 2>&1
sudo openssl x509 -in /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem -noout -subject -issuer -fingerprint -sha256
systemctl show nginx.service --property=FragmentPath --property=DropInPaths
```

Do not put private key bytes, `.env` values, passwords, cookies, bearer tokens, or
client tokens in metadata.

### 6. Checksum and publish atomically

```bash
cd "$staging"
sha256sum nginx.tar metadata.txt > SHA256SUMS
sha256sum -c SHA256SUMS
cd "$parent"
mv "$staging" "$final"
printf 'published nginx checkpoint: %s\n' "$final"
```

After publication, completed timestamp directories are immutable. If metadata is
wrong or the archive contains an excluded file, create a new checkpoint; do not edit
the completed one in place.

Take a fresh checkpoint after each later nginx configuration or public certificate
change, including certificate renewal. A pre-change rollback copy may be kept locally
outside nginx include paths, but it is not a completed post-change checkpoint. Do not
create `final-etc-nginx-*.tar` artifacts in procedure-named folders. Other backup
targets retain their own procedures.

## Restore from checkpoint

This procedure intentionally spells out the mechanics. Agents must not merge nginx
artifacts from procedure folders, restore over a stale `/etc/nginx` tree, or overwrite a
newly reissued leaf certificate with an archived public certificate that no longer matches
the live private key. A restore is complete only after nginx configuration, TLS,
authentication routes, and public endpoints are verified.

### 1. Select and verify one completed checkpoint

Select the lexicographically newest completed directory matching exactly fourteen digits
followed by `Z`. Ignore hidden staging directories. Choosing an older recovery point is an
explicit recovery decision and must be recorded.

```bash
set -euo pipefail
BACKUP_PATH="{{BACKUP_PATH}}"
parent="$BACKUP_PATH/nginx"
checkpoint_name="$(find "$parent" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' |
  grep -E '^[0-9]{14}Z$' | sort | tail -n 1)"
test -n "$checkpoint_name"
checkpoint="$parent/$checkpoint_name"
export checkpoint

cd "$checkpoint"
test -f nginx.tar
test -f metadata.txt
test -f SHA256SUMS
sha256sum -c SHA256SUMS
```

Require all checksums to pass. A missing archive, missing metadata file, or failed
checksum stops recovery.

### 2. Inspect metadata and archive safety before extraction

Copy the selected checkpoint into protected temporary inspection storage. Review metadata,
then verify archive roots, symlinks, and private-key exclusion before touching `/etc/nginx`.

```bash
restore_work="$(mktemp -d /root/nginx-restore-inspect.XXXXXX)"
chmod 700 "$restore_work"
cp "$checkpoint"/nginx.tar "$checkpoint"/metadata.txt "$restore_work"/
cd "$restore_work"
sed -n '1,240p' metadata.txt
sudo tar -tvf nginx.tar | sed -n '1,240p'
```

Run path and private-key scans:

```bash
export restore_work
python3 - <<'PY'
import os, tarfile
from pathlib import Path
root = Path(os.environ['restore_work'])
with tarfile.open(root / 'nginx.tar') as tf:
    names = []
    for m in tf.getmembers():
        names.append(m.name)
        if m.name.startswith('/') or '..' in Path(m.name).parts:
            raise SystemExit(f'unsafe member path: {m.name}')
        if m.issym() or m.islnk():
            link = Path(m.linkname)
            if '..' in link.parts:
                raise SystemExit(f'unsafe link target: {m.name} -> {m.linkname}')
            if m.linkname.startswith('/') and not m.linkname.startswith('/etc/nginx/'):
                raise SystemExit(f'absolute link target outside /etc/nginx: {m.name} -> {m.linkname}')
        if m.isfile() and m.size < 2_000_000:
            data = tf.extractfile(m).read()
            if b'BEGIN PRIVATE KEY' in data or b'BEGIN RSA PRIVATE KEY' in data or b'BEGIN EC PRIVATE KEY' in data:
                raise SystemExit(f'private-key material found in archive member {m.name}')
    required = {
        'etc/nginx/nginx.conf',
        'etc/nginx/conf.d/gmktec.home.arpa.conf',
        'etc/nginx/sites-available/camera',
        'etc/nginx/sites-enabled/camera',
    }
    missing = sorted(required - set(names))
    if missing:
        raise SystemExit(f'missing required nginx members: {missing}')
print('nginx archive safety checks passed')
PY
```

### 3. Prepare host prerequisites and external dependencies

Install compatible nginx packages/modules and create the service user named by the archived
`nginx.conf`. Restore or verify external dependencies recorded in metadata before starting
nginx:

- application web roots such as `{{REPO_PATH}}/onvif-mcp/apps/cameras/` and
  `{{REPO_PATH}}/onvif-mcp/apps/multiview/`;
- `/etc/onvif-mcp/camera_registry.json` and `/etc/onvif-mcp/snapshot_routes.json` if
  included;
- `/srv/camera-pki/public/*` if `/ca/` distribution is included;
- upstream services: MediaMTX, snapshot-proxy, MCP HTTP, Keycloak, and oauth2-proxy where
  configured.

```bash
sudo apt update
sudo apt install -y nginx
# Replace webcam with the actual user from archived nginx.conf if different.
sudo id webcam >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin webcam
sudo usermod -aG {{SERVER_USER}} webcam
```

Do not restore nginx before recovering or reissuing the TLS private key/certificate pair
through `SITE_CERT.md`. Private keys are not in `nginx.tar`.

### 4. Preserve current nginx and stage live TLS material

During the authorized restore window, stop nginx and preserve the current tree and
nginx-specific systemd overrides outside all include paths. Also stage the current matching
TLS material. If the current private key was reissued after the checkpoint, its matching
leaf certificate must replace the archived public certificate after extraction.

```bash
stamp="$(date -u +%Y%m%d%H%M%SZ)"
rollback="/root/nginx-pre-restore-$stamp"
sudo install -d -m 700 "$rollback"
sudo systemctl stop nginx.service || true
sudo tar --acls --xattrs -cpf "$rollback/etc-nginx.tar" -C / etc/nginx
if [ -e /etc/systemd/system/nginx.service ]; then
  sudo tar --acls --xattrs -cpf "$rollback/nginx-service.tar" -C / etc/systemd/system/nginx.service
fi
if [ -e /etc/systemd/system/nginx.service.d ]; then
  sudo tar --acls --xattrs -cpf "$rollback/nginx-service-d.tar" -C / etc/systemd/system/nginx.service.d
fi
sudo install -d -m 700 "$rollback/tls-live"
sudo cp -a /etc/nginx/tls/{{SERVER_FQDN}}.key.pem "$rollback/tls-live/"
sudo cp -a /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem "$rollback/tls-live/"
sudo cp -a /etc/nginx/tls/{{SERVER_FQDN}}.chain.pem "$rollback/tls-live/"
sudo cp -a /etc/nginx/tls/camera-system-root-ca.crt.pem "$rollback/tls-live/"
```

Verify the staged key and certificate match before continuing:

```bash
sudo openssl pkey -in "$rollback/tls-live/{{SERVER_FQDN}}.key.pem" -pubout | openssl sha256
sudo openssl x509 -in "$rollback/tls-live/{{SERVER_FQDN}}.crt.pem" -pubkey -noout | openssl sha256
```

The two hashes must match. Stop if they differ.

### 5. Restore into a clean `/etc/nginx` tree

Restore into a clean tree, not over an existing tree. Extraction alone cannot remove
obsolete enabled sites, package defaults, or old rollback files.

```bash
sudo rm -rf /etc/nginx
sudo install -d -m 755 -o root -g root /etc/nginx
sudo tar --acls --xattrs --same-owner -xpf "$checkpoint/nginx.tar" -C /
```

Restore nginx-specific systemd override absence or presence exactly. If the archive does
not contain `etc/systemd/system/nginx.service` or `etc/systemd/system/nginx.service.d/`,
remove nginx-specific local overrides; do not touch unrelated units.

```bash
if ! sudo tar -tf "$checkpoint/nginx.tar" | grep -Fxq 'etc/systemd/system/nginx.service'; then
  sudo rm -f /etc/systemd/system/nginx.service
fi
if ! sudo tar -tf "$checkpoint/nginx.tar" | grep -q '^etc/systemd/system/nginx.service.d/'; then
  sudo rm -rf /etc/systemd/system/nginx.service.d
fi
sudo systemctl daemon-reload
```

### 6. Install the recovered/reissued TLS material and validate config

Install the staged live TLS material after extraction so a newly reissued certificate is not
overwritten by the archived public certificate. Keep the private key root-owned mode 0600;
public TLS files should be mode 0644.

```bash
sudo install -d -o root -g root -m 700 /etc/nginx/tls
sudo install -o root -g root -m 600 "$rollback/tls-live/{{SERVER_FQDN}}.key.pem" /etc/nginx/tls/{{SERVER_FQDN}}.key.pem
sudo install -o root -g root -m 644 "$rollback/tls-live/{{SERVER_FQDN}}.crt.pem" /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem
sudo install -o root -g root -m 644 "$rollback/tls-live/camera-system-root-ca.crt.pem" /etc/nginx/tls/camera-system-root-ca.crt.pem
sudo sh -c 'cat /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem /etc/nginx/tls/camera-system-root-ca.crt.pem > /etc/nginx/tls/{{SERVER_FQDN}}.chain.pem'
sudo chmod 644 /etc/nginx/tls/{{SERVER_FQDN}}.chain.pem
```

Validate the restored configuration before starting nginx:

```bash
sudo nginx -t
sudo nginx -T | grep -c 'server_name {{SERVER_FQDN}}'
sudo test ! -e /etc/nginx/sites-enabled/default
sudo nginx -T 2>/dev/null | grep -F 'listen 443 ssl;'
sudo nginx -T 2>/dev/null | grep -F '/auth/'
sudo nginx -T 2>/dev/null | grep -F '/oauth2/'
sudo nginx -T 2>/dev/null | grep -F '/ca/'
```

### 7. Start nginx, then oauth2-proxy when Keycloak discovery is public

Start nginx first so Keycloak public discovery is available at `/auth/`. Then start
oauth2-proxy, which depends on that public issuer URL.

```bash
sudo systemctl start nginx.service
systemctl is-active nginx.service
sudo ss -lntp 'sport = :443'

sudo curl --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  -s -o /dev/null -w '%{http_code}\n' \
  https://{{SERVER_FQDN}}/auth/realms/mcp/.well-known/openid-configuration

if sudo docker compose --project-directory /opt/keycloak config --services | grep -Fxq oauth2-proxy; then
  sudo docker compose --project-directory /opt/keycloak up -d oauth2-proxy
fi
sudo docker compose --project-directory /opt/keycloak ps
```

### 8. Final route and access-control verification

Verify both allowed requests and expected authentication/denial behavior. Use the private CA
explicitly; do not rely on ambient trust.

```bash
sudo curl --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  --head https://{{SERVER_FQDN}}/auth/realms/mcp/.well-known/openid-configuration

curl -sI --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} \
  http://{{SERVER_FQDN}}/cameras/ | sed -n '1,8p'

curl -sI --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} \
  http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem | sed -n '1,8p'

sudo curl --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  -s -o /dev/null -w '%{http_code}\n' https://{{SERVER_FQDN}}/cameras/

sudo curl --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  -H 'Accept: text/event-stream, application/json' \
  -s -o /dev/null -w '%{http_code}\n' https://{{SERVER_FQDN}}/mcp
```

Expected examples for an auth-enabled checkpoint:

- `/auth/realms/mcp/.well-known/openid-configuration` returns `200`;
- `/ca/camera-system-root-ca.crt.pem` over HTTP returns `200` from an allowed LAN address;
- non-CA HTTP requests return `301` to HTTPS;
- protected web routes such as `/cameras/`, `/snapshot/`, and `/webrtc/` return an OAuth
  redirect (`302`) or auth denial when unauthenticated;
- `/mcp` returns the MCP server's expected unauthenticated protocol response for the
  supplied headers.

If verification fails, stop and diagnose or restore the preserved rollback tree and
matching TLS material. Never repair by layering older stage archives over this snapshot.

