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

1. Select the lexicographically newest completed directory matching exactly
   fourteen digits followed by `Z`. Ignore hidden staging directories. Verify
   both required files and `SHA256SUMS`; stop on failure. Choosing an older
   recovery point is an explicit recovery decision, not an automatic fallback.
   Restore one snapshot; do not merge nginx artifacts from procedure folders.

2. Inspect metadata and archive members in a protected temporary directory.
   Install compatible nginx packages/modules and create the required service
   user. Restore web content, CA distribution files, upstream services and any
   external dependencies using the recorded sources. Check compatibility with
   the chosen Keycloak checkpoint; newer independent histories need not describe
   a mutually compatible application state.

3. Recover TLS credentials through SITE_CERT.md: reuse a surviving private key
   only after verifying it matches the certificate, otherwise generate a new
   key and reissue through the restored CA. Private keys are not in nginx.tar.
   Keep recovered/reissued key and matching certificate files in protected
   staging until after installing the archived configuration.

4. During the authorized restore window, stop nginx and preserve the current
   `/etc/nginx` tree and nginx-specific systemd overrides in a protected local
   rollback location outside all include paths. Restore into a clean
   `/etc/nginx` tree, not over an existing tree: extraction alone cannot remove
   obsolete sites or package-created defaults. Restore the archived override
   set exactly, including recorded absence, without changing unrelated units.
   Handle inventoried external configuration files explicitly and preserve
   rollback copies. Validate member paths and symlinks before extraction; never
   let an archive symlink redirect extraction outside its intended destination.
   
5. Install the recovered/reissued TLS material at the configured paths, with
   keys root-owned mode 0600. A newly issued certificate replaces the archived
   public certificate; do not overwrite it with the old one afterward. Ensure
   external include and module targets exist and the default site is disabled.
   Verify the intended HTTPS listener is unpinned. Run `systemctl daemon-reload`
   if units were restored, then require `nginx -t` success before starting nginx.
   
6. Start nginx. If oauth2-proxy requires Keycloak discovery through nginx,
   make Keycloak ready first, start nginx to expose `/auth/`, then start
   oauth2-proxy and wait for health. Only then verify the routes and access
   controls recorded for this
   checkpoint: HTTP redirects, `/ca/`, TLS hostname/chain, and, where deployed,
   `/auth/`, `/oauth2/`, `/mcp`, camera pages and snapshots. Check both allowed
   requests and expected authentication/denial behavior. If verification fails,
   stop and diagnose or restore the preserved configuration and matching TLS
   material; never repair by layering older stage archives over this snapshot.

