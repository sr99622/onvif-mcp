#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  remove_camera_runbook.sh apply --server-fqdn HOST --camera-ip IP --backup-path PATH --repo-path PATH
  remove_camera_runbook.sh status --server-fqdn HOST --camera-ip IP
  remove_camera_runbook.sh test --server-fqdn HOST --camera-ip IP

Removes one camera per docs/REMOVE_CAMERA.md — the reverse of ADD_CAMERA.md.
The camera may be offline; the registry entry (or its timestamped backup) is
the source of truth for the serial number. Removal is incremental: only entries
whose key starts with the camera's serial are touched; existing cameras are
never modified. Each file is backed up with a timestamp before the update, JSON
is validated, the owning service is restarted, and live state is re-verified.
Re-runs are idempotent: already-removed artifacts are reported as such, and a
run that removes nothing at all is a hard failure. No Keycloak or nginx changes, so no camera password or OAuth token is needed.
An nginx checkpoint is published through the shared backup script with
REMOVE_CAMERA.md as the trigger.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
server_fqdn=""; camera_ip=""; backup_path=""; repo_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --camera-ip) camera_ip="${2:?missing --camera-ip value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --repo-path) repo_path="${2:?missing --repo-path value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
count_of() { sed -n 's/^removed_count: //p' <<< "$1"; }

install_packages() {
  missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v file >/dev/null 2>&1 || missing+=(file)
  if [[ ${#missing[@]} -gt 0 ]]; then sudo apt-get update; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; fi
}

# Serial resolution: live registry entry first; if the camera is already
# removed, fall back to the most recent timestamped registry backup so status
# and test can still prove the removal.
resolve_serial() {
  sudo python3 - "$camera_ip" <<'PY'
import json, pathlib, sys
ip = sys.argv[1]
p = pathlib.Path('/etc/onvif-mcp/camera_registry.json')
reg = json.load(open(p))
entry = next((c for c in reg['cameras'] if c['ip_address'].split(':')[0] == ip), None)
if entry:
    print(entry['serial_number'])
    sys.exit(0)
for b in sorted(p.parent.glob('camera_registry.json.backup-*'), reverse=True):
    try:
        reg = json.load(open(b))
    except Exception:
        continue
    entry = next((c for c in reg.get('cameras', []) if c['ip_address'].split(':')[0] == ip), None)
    if entry:
        print(entry['serial_number'])
        sys.exit(0)
raise SystemExit(f'No registry entry or backup for camera at {ip}; cannot resolve serial')
PY
}

remove_routes() {
  sudo python3 - "$camera_ip" <<'PY'
import datetime, json, pathlib, sys
ip = sys.argv[1]
p = pathlib.Path('/etc/onvif-mcp/snapshot_routes.json')
data = json.load(open(p))
routes = data.get('routes', data)
entry = next((c for c in json.load(open('/etc/onvif-mcp/camera_registry.json'))['cameras'] if c['ip_address'].split(':')[0] == ip), None)
if entry is None:
    raise SystemExit(f'No registry entry for camera at {ip}; cannot resolve serial')
serial = entry['serial_number']
before = set(routes)
keys = [k for k in routes if k.startswith(serial + '/')]
if not keys:
    print('removed_count: 0')
    print(f'routes: already removed for serial {serial}; nothing to remove in this file')
    sys.exit(0)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')
backup = p.with_name(f'snapshot_routes.json.backup-{stamp}')
backup.write_text(p.read_text())
for k in keys:
    del routes[k]
data['routes'] = routes
if set(routes) != before - set(keys):
    raise SystemExit('Assertion failed: routes outside the camera serial were touched')
p.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
print(f'removed_count: {len(keys)}')
print(f'routes: removed {len(keys)} route(s) for {serial}')
print(f'backup: {backup}')
PY
}

remove_mediamtx() {
  umask 077
  tmp="$HOME/.mediamtx.yml.$$"
  sudo cat /etc/mediamtx/mediamtx.yml > "$tmp"
  out="$(python3 - "$(resolve_serial)" "$tmp" "$tmp.new" <<'PY'
import re, sys
from pathlib import Path
serial, src_path, out_path = sys.argv[1:4]
key_re = re.compile(r'^  "([^"]+/[^"]+)":')
out, removed, count_idx, skip = [], 0, None, False
for line in open(src_path).read().splitlines():
    m = key_re.match(line)
    if m:
        skip = m.group(1).startswith(serial + '/')
        if skip:
            removed += 1
            continue
        out.append(line)
        continue
    if skip and line.startswith('    '):
        continue
    skip = False
    if line.startswith('# generated_path_count:'):
        count_idx = len(out)
    out.append(line)
if removed == 0:
    print('removed_count: 0')
    print(f'mediamtx: already removed for serial {serial}; nothing to remove in this file')
    sys.exit(0)
if count_idx is not None:
    old = int(out[count_idx].split(':')[1])
    out[count_idx] = f'# generated_path_count: {old - removed}'
    if sum(1 for l in out if key_re.match(l)) != old - removed:
        raise SystemExit('Assertion failed: generated_path_count does not match remaining paths')
Path(out_path).write_text('\n'.join(out) + '\n')
print(f'removed_count: {removed}')
PY
)"
  n="$(count_of "$out")"
  if [[ "$n" -gt 0 ]]; then
    stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
    sudo cp -p /etc/mediamtx/mediamtx.yml "/etc/mediamtx/mediamtx.yml.backup-$stamp"
    sudo chown mediamtx:mediamtx "/etc/mediamtx/mediamtx.yml.backup-$stamp"
    sudo chmod 0640 "/etc/mediamtx/mediamtx.yml.backup-$stamp"
    sudo install -o mediamtx -g mediamtx -m 0640 "$tmp.new" /etc/mediamtx/mediamtx.yml
    echo "backup: /etc/mediamtx/mediamtx.yml.backup-$stamp"
  fi
  shred -u "$tmp" "$tmp.new"
}

remove_registry() {
  sudo python3 - "$camera_ip" <<'PY'
import datetime, json, pathlib, sys
ip = sys.argv[1]
p = pathlib.Path('/etc/onvif-mcp/camera_registry.json')
reg = json.load(open(p))
before = [c['serial_number'] for c in reg['cameras']]
entry = next((c for c in reg['cameras'] if c['ip_address'].split(':')[0] == ip), None)
if entry is None:
    print('removed_count: 0')
    print(f'registry: entry for {ip} already removed; nothing to remove in this file')
    sys.exit(0)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')
backup = p.with_name(f'camera_registry.json.backup-{stamp}')
backup.write_text(p.read_text())
reg['cameras'] = [c for c in reg['cameras'] if c['ip_address'].split(':')[0] != ip]
removed = len(before) - len(reg['cameras'])
if removed != 1:
    raise SystemExit(f'Assertion failed: expected exactly 1 entry removed, removed {removed}')
reg['generated'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
p.write_text(json.dumps(reg, indent=2) + '\n')
print(f'removed_count: {removed}')
print(f'registry: removed entry for {entry["hostname"]} ({ip}), serial {entry["serial_number"]}')
print(f'backup: {backup}')
PY
}

checkpoints() {
  "$repo_path/scripts/NGINX_BACKUP/nginx_backup_runbook.sh" create-checkpoint --server-fqdn "$server_fqdn" --backup-path "$backup_path" --trigger REMOVE_CAMERA.md
}

probe_route() {
  # Loopback snapshot proxy: proves the route exists (200 image/jpeg with real
  # JPEG magic bytes) or is gone (404).
  local route="$1" expect="$2" d
  d="$HOME/.remove-camera-test.$$"
  mkdir -p "$d"
  local out="$d/$(echo "$route" | tr '/' '_').jpg"
  local c kind ok
  c="$(curl -s --max-time 35 -o "$out" -w '%{http_code} %{content_type}' "http://127.0.0.1:8891/snapshot/$route/")"
  kind="$(file -b "$out" 2>/dev/null | cut -c1-60)"
  ok=0
  if [[ "$expect" == 404 ]]; then
    [[ "$c" == 404* ]] || ok=1
  else
    [[ "$c" == 200*image/jpeg* && "$kind" == JPEG* ]] || ok=1
  fi
  echo "$route $c $kind"
  rm -f "$out"; rmdir "$d" 2>/dev/null || true
  return "$ok"
}

print_status() {
  echo '== services =='
  for svc in nginx mediamtx snapshot-proxy onvif-mcp-http; do printf '%s: %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"; done
  echo '== files =='
  sudo stat -c '%a %U:%G %n' /etc/onvif-mcp/camera_registry.json /etc/onvif-mcp/snapshot_routes.json /etc/mediamtx/mediamtx.yml /etc/onvif-mcp-http.env 2>/dev/null || true
  serial="$(resolve_serial)"
  echo "== camera (serial $serial) =="
  echo 'registry entry:'
  sudo python3 - "$serial" <<'PY' || true
import json, sys
serial = sys.argv[1]
reg = json.load(open('/etc/onvif-mcp/camera_registry.json'))
entry = next((c for c in reg['cameras'] if c['serial_number'] == serial), None)
print(json.dumps(entry, indent=2) if entry else 'MISSING')
PY
  echo 'snapshot routes:'
  sudo python3 - "$serial" <<'PY' || true
import json, sys
serial = sys.argv[1]
routes = json.load(open('/etc/onvif-mcp/snapshot_routes.json'))['routes']
matches = {k: v for k, v in routes.items() if k.startswith(serial + '/')}
print(json.dumps(matches, indent=2) if matches else 'MISSING')
PY
  echo 'mediamtx paths:'
  sudo grep -F "$serial" /etc/mediamtx/mediamtx.yml || echo 'MISSING'
  echo '== listener =='
  ss -ltnp 2>/dev/null | grep ':8891' || true
  echo '== surviving camera probe (proves no collateral damage) =='
  surviving="$(sudo python3 - "$serial" <<'PY' || true
import json, sys
serial = sys.argv[1]
routes = json.load(open('/etc/onvif-mcp/snapshot_routes.json'))['routes']
for k in routes:
    if not k.startswith(serial + '/'):
        print(k)
        break
PY
)"
  if [[ -n "$surviving" ]]; then
    probe_route "$surviving" 200 || true
  else
    echo 'no surviving camera routes to probe'
  fi
  echo '== recent mediamtx logs =='
  sudo journalctl -u mediamtx -n 20 --no-pager | grep -F "$serial" || true
}

test_remaining() {
  require_arg --server-fqdn "$server_fqdn"
  failed=0
  serial="$(resolve_serial)"
  echo "== removed camera routes must now 404 =="
  routes="$(sudo python3 - "$serial" <<'PY' || true
import json, pathlib, sys
serial = sys.argv[1]
p = pathlib.Path('/etc/onvif-mcp/snapshot_routes.json')
routes = json.load(open(p)).get('routes', {})
matches = [k for k in routes if k.startswith(serial + '/')]
if not matches:
    for b in sorted(p.parent.glob('snapshot_routes.json.backup-*'), reverse=True):
        try:
            old = json.load(open(b)).get('routes', {})
        except Exception:
            continue
        matches = [k for k in old if k.startswith(serial + '/')]
        if matches:
            break
print('\n'.join(sorted(matches)))
PY
)"
  if [[ -z "$routes" ]]; then
    echo 'note: no removed routes recorded (live or backup); route-removal check incomplete' >&2
  fi
  for route in $routes; do
    probe_route "$route" 404 || failed=$((failed + 1))
  done
  echo "== surviving camera probe (proves no collateral damage) =="
  surviving="$(sudo python3 - "$serial" <<'PY' || true
import json, sys
serial = sys.argv[1]
routes = json.load(open('/etc/onvif-mcp/snapshot_routes.json'))['routes']
for k in sorted(routes):
    if not k.startswith(serial + '/'):
        print(k)
        break
PY
)"
  if [[ -n "$surviving" ]]; then
    probe_route "$surviving" 200 || failed=$((failed + 1))
  else
    echo 'note: no surviving camera routes to probe' >&2
  fi
  echo "== public unauthenticated redirect (route-family auth intact) =="
  for path in "/snapshot/$serial/" "/webrtc/$serial/"; do
    out="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "https://$server_fqdn$path")"
    echo "$path -> $out"
    if [[ "$out" != 302* || "$out" != *'/oauth2/start?rd='* ]]; then failed=$((failed + 1)); fi
  done
  echo "test failures: $failed"
  exit "$failed"
}

preflight() {
  for svc in nginx mediamtx snapshot-proxy onvif-mcp-http; do
    systemctl is-active "$svc" >/dev/null || { echo "FAIL: $svc is not active" >&2; exit 1; }
  done
  test -f /etc/onvif-mcp/camera_registry.json || { echo 'FAIL: registry file missing' >&2; exit 1; }
  test -d "$backup_path" || { echo "FAIL: backup path not reachable: $backup_path" >&2; exit 1; }
}

apply_removal() {
  require_arg --server-fqdn "$server_fqdn"; require_arg --camera-ip "$camera_ip"; require_arg --backup-path "$backup_path"; require_arg --repo-path "$repo_path"
  install_packages
  echo '== preflight =='
  preflight

  echo '== phase 1: resolve camera from registry (camera may be offline) =='
  serial="$(resolve_serial)"
  sudo python3 - "$serial" <<'PY'
import json, pathlib, sys
serial = sys.argv[1]
p = pathlib.Path('/etc/onvif-mcp/camera_registry.json')
reg = json.load(open(p))
entry = next((c for c in reg['cameras'] if c['serial_number'] == serial), None)
if entry:
    print(f"{entry['hostname']} ({entry['ip_address']}) serial {serial}")
else:
    print(f"serial {serial} resolved from backup; registry entry already removed")
PY

  total=0

  echo '== phase 2: remove snapshot routes (reverse of add phase 4) =='
  out="$(remove_routes)"; echo "$out"
  n="$(count_of "$out")"; total=$((total + n))
  if [[ "$n" -gt 0 ]]; then
    sudo systemctl restart snapshot-proxy
    sleep 5
  fi

  echo '== phase 3: remove mediamtx paths (reverse of add phase 3) =='
  out="$(remove_mediamtx)"; echo "$out"
  n="$(count_of "$out")"; total=$((total + n))
  if [[ "$n" -gt 0 ]]; then
    sudo systemctl restart mediamtx
    sleep 5
  fi

  echo '== phase 4: remove registry entry (reverse of add phase 2) =='
  out="$(remove_registry)"; echo "$out"
  total=$((total + $(count_of "$out")))

  if [[ "$total" -eq 0 ]]; then
    echo 'FAIL: nothing to remove across registry, routes, and paths; the removal is already complete. Use status/test to re-verify instead of re-running apply.' >&2
    exit 1
  fi

  echo '== phase 5: time sync has no reverse action (skipped) =='

  echo '== phase 6: verify =='
  print_status

  echo '== phase 7: publish nginx checkpoint =='
  checkpoints
}

case "$cmd" in
  apply) apply_removal ;;
  status)
    require_arg --server-fqdn "$server_fqdn"; require_arg --camera-ip "$camera_ip"
    print_status
    ;;
  test) test_remaining ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
