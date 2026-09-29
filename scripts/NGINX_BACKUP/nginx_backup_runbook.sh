#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  nginx_backup_runbook.sh create-checkpoint --server-fqdn HOST --backup-path PATH [--trigger NAME] [--compatible-keycloak-checkpoint PATH]
  nginx_backup_runbook.sh status --backup-path PATH

Implements only the "Create a checkpoint" workflow from docs/NGINX_BACKUP.md.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
server_fqdn=""; backup_path=""; trigger="KEYCLOAK.md"; compatible_keycloak_checkpoint="not recorded"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --trigger) trigger="${2:?missing --trigger value}"; shift 2 ;;
    --compatible-keycloak-checkpoint) compatible_keycloak_checkpoint="${2:?missing --compatible-keycloak-checkpoint value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
backup_root() { printf '%s/nginx' "${backup_path%/}"; }

require_mounted_backup() {
  local target="${backup_path%/}"
  findmnt -rn -T "$target" >/dev/null || { echo "$target is not mounted or reachable" >&2; exit 1; }
  [[ -w "$target" ]] || { echo "$target is not writable by $(id -un)" >&2; exit 1; }
}

preflight() {
  sudo nginx -t
  sudo nginx -T > "${TMPDIR:-/tmp}/nginx-effective.txt"
  sudo ss -lntp 'sport = :443' || true
  sudo ls -la /etc/nginx/conf.d /etc/nginx/sites-enabled /etc/nginx/sites-available
  systemctl show nginx.service --property=FragmentPath --property=DropInPaths
  if sudo test -e /etc/nginx/sites-enabled/default; then
    echo "ERROR: /etc/nginx/sites-enabled/default is enabled; refusing checkpoint" >&2
    exit 1
  fi
  sudo nginx -T 2>/dev/null | grep -F 'listen 443 ssl;' >/dev/null
  if sudo nginx -T 2>/dev/null | grep -E 'configuration file: .*(/backups/|\.backup-|backup-[0-9]{4}-[0-9]{2}-[0-9]{2}|nginx\.conf\.backup-|\.pre-)' >/dev/null; then
    echo "ERROR: nginx is loading rollback/backup configuration" >&2
    exit 1
  fi
}

build_manifest() {
  local staging="$1"
  sudo env staging="$staging" python3 - <<'PY'
from pathlib import Path
import os, re
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
    if re.search(r'\.backup-|backup-[0-9]{4}-[0-9]{2}-[0-9]{2}|nginx\.conf\.backup-|\.pre-', rel):
        return True
    if re.search(r'(\.key(\.|$)|key\.pem$)', rel):
        return True
    try:
        if p.is_file():
            head = p.open('rb').read(4096)
            if any(x in head for x in [b'BEGIN PRIVATE KEY', b'BEGIN RSA PRIVATE KEY', b'BEGIN EC PRIVATE KEY']):
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
            continue
        rel = str(p.relative_to('/'))
        if not rejected(rel, p):
            items.append(rel)

for path in ['/etc/onvif-mcp/camera_registry.json', '/etc/onvif-mcp/snapshot_routes.json', '/etc/systemd/system/nginx.service']:
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
  sudo sed -n '1,240p' "$staging/manifest.txt"
  if sudo grep -E '(\.key(\.|$)|key\.pem$|\.backup-|backup-[0-9]{4}-[0-9]{2}-[0-9]{2}|nginx\.conf\.backup-|/default$|/backups/)' "$staging/manifest.txt"; then
    echo 'ERROR: forbidden member in manifest' >&2
    exit 1
  fi
}

write_metadata() {
  local dest="$1" timestamp="$2"
  {
    echo "Trigger: $trigger"
    echo "Capture UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Checkpoint timestamp: $timestamp"
    echo "Server FQDN: $server_fqdn"
    echo "Compatible Keycloak checkpoint: $compatible_keycloak_checkpoint"
    echo "Captured by: $(id -un)@$(hostname)"
    echo
    echo "== nginx package =="
    nginx -v 2>&1 || true
    dpkg-query -W -f='${Package} ${Version}\n' nginx 'nginx-*' 2>/dev/null || true
    echo
    echo "== service user and unit overrides =="
    sudo nginx -T 2>/dev/null | awk '/^user[[:space:]]/{print; exit}' || true
    systemctl show nginx.service --property=FragmentPath --property=DropInPaths
    if sudo test -e /etc/systemd/system/nginx.service || sudo test -d /etc/systemd/system/nginx.service.d; then echo nginx_unit_overrides=present; else echo nginx_unit_overrides=absent; fi
    echo
    echo "== active vhosts =="
    sudo nginx -T 2>/dev/null | grep -nE 'configuration file:|server_name|listen .*443|listen .*80|location (=? )?/(auth|oauth2|mcp|ca|cameras|snapshot|webrtc|outputs)' || true
    echo
    echo "== public certificate =="
    if sudo test -s "/etc/nginx/tls/$server_fqdn.crt.pem"; then
      sudo openssl x509 -in "/etc/nginx/tls/$server_fqdn.crt.pem" -noout -subject -issuer -fingerprint -sha256
    else
      echo "certificate_missing=/etc/nginx/tls/$server_fqdn.crt.pem"
    fi
    echo
    echo "== ssl_certificate_key paths explicitly excluded =="
    sudo nginx -T 2>/dev/null | awk '/ssl_certificate_key/{print}' || true
    echo
    echo "== external dependencies and exclusions =="
    echo "application web roots, /etc/onvif-mcp JSON files, /srv/camera-pki/public files, loopback upstream services, and public TLS files are captured or referenced according to manifest.txt."
    echo "private TLS keys, /etc/nginx/backups, default sites, rollback files, and runbook copies excluded."
    echo
    echo "== verification results =="
    echo "nginx -t passed"
    echo "manifest diff passed"
    echo "private-key archive scan passed"
    echo "checksum verified before publication"
  } > "$dest/metadata.txt"
  chmod 600 "$dest/metadata.txt"
}

create_checkpoint() {
  require_arg --server-fqdn "$server_fqdn"; require_arg --backup-path "$backup_path"; require_mounted_backup; preflight
  local root timestamp staging final
  root="$(backup_root)"
  timestamp="$(date -u +%Y%m%d%H%M%SZ)"
  staging="$root/.$timestamp.staging.$$"
  final="$root/$timestamp"
  install -d -m 700 "$root"
  test ! -e "$final"
  test ! -e "$staging"
  install -d -m 700 "$staging"
  build_manifest "$staging"
  sudo tar --owner=0 --group=0 --preserve-permissions --acls --xattrs -cf "$staging/nginx.tar" -C / --files-from "$staging/manifest.txt"
  sudo tar -tf "$staging/nginx.tar" | sort > "$staging/archive-members.txt"
  sort "$staging/manifest.txt" > "$staging/manifest.sorted"
  diff -u "$staging/manifest.sorted" "$staging/archive-members.txt"
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
            if any(x in data for x in [b'BEGIN PRIVATE KEY', b'BEGIN RSA PRIVATE KEY', b'BEGIN EC PRIVATE KEY']):
                raise SystemExit(f'private-key material found in archive member {m.name}')
print('nginx.tar path and private-key scan passed')
PY
  sudo tar -tvf "$staging/nginx.tar" | grep '^l' > "$staging/symlinks.txt" || true
  write_metadata "$staging" "$timestamp"
  rm -f "$staging/manifest.txt" "$staging/archive-members.txt" "$staging/manifest.sorted" "$staging/symlinks.txt"
  (cd "$staging" && sha256sum nginx.tar metadata.txt > SHA256SUMS && sha256sum -c SHA256SUMS)
  chmod 600 "$staging/SHA256SUMS"
  mv -T "$staging" "$final"
  echo "create-checkpoint-ok $final"
}

status() {
  require_arg --backup-path "$backup_path"
  local root; root="$(backup_root)"
  echo "backup_root=$root"
  if [[ -d "$root" ]]; then
    find "$root" -maxdepth 2 -type f -printf '%m %u:%g %s %p\n' | sort
  else
    echo "missing"
  fi
}

case "$cmd" in
  create-checkpoint) create_checkpoint ;;
  status) status ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
