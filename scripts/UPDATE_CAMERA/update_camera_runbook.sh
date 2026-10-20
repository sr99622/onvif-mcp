#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  update_camera_runbook.sh apply --server-fqdn HOST --camera-serial SERIAL --new-ip IP --backup-path PATH --repo-path PATH [--old-ip IP] [--token-file PATH]
  update_camera_runbook.sh status --server-fqdn HOST --camera-serial SERIAL
  update_camera_runbook.sh test --server-fqdn HOST --camera-serial SERIAL

Corrects one camera's recorded address per docs/UPDATE_CAMERA.md when its
address on the isolated camera network changes. Identity is the serial number:
registry keys, snapshot route keys, and MediaMTX path keys are never rewritten,
only the host they point at. All three generated artifacts are updated because
all three embed the address: /etc/onvif-mcp/camera_registry.json,
/etc/onvif-mcp/snapshot_routes.json, and /etc/mediamtx/mediamtx.yml. Each file
is backed up with a timestamp before the update, the owning service is
restarted, and live state is re-verified. Re-runs are idempotent; a run that
changes nothing is a hard failure (re-verify with status/test). No camera
password is read: only the host portion of existing values changes. No Keycloak
or nginx state changes, so no Keycloak checkpoint is created; an nginx
checkpoint is published through the shared backup script with UPDATE_CAMERA.md
as the trigger.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
server_fqdn=""; camera_serial=""; new_ip=""; old_ip=""; backup_path=""; token_file="$HOME/.hermes/mcp-tokens/camera.json"
repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --camera-serial) camera_serial="${2:?missing --camera-serial value}"; shift 2 ;;
    --new-ip) new_ip="${2:?missing --new-ip value}"; shift 2 ;;
    --old-ip) old_ip="${2:?missing --old-ip value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --repo-path) repo_path="${2:?missing --repo-path value}"; shift 2 ;;
    --token-file) token_file="${2:?missing --token-file value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
count_of() { sed -n 's/^changed_count: //p' <<< "$1"; }

log_file="$repo_path/scripts/UPDATE_CAMERA/update_camera_runbook.log"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H%M%SZ)" "$*" >> "$log_file"; }

install_packages() {
  missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v file >/dev/null 2>&1 || missing+=(file)
  if [[ ${#missing[@]} -gt 0 ]]; then sudo apt-get update; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; fi
}

mcp_call() {
  python3 - "$server_fqdn" "$token_file" "$1" "${2:-}" <<'PY'
import json, os, sys, time, urllib.parse, urllib.request
server, token_file, tool, args_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] or '{}'
d = json.load(open(token_file))
tok = d['access_token']
if d.get('expires_at', 0) < time.time():
    issuer = d.get('hermes_issuer') or f'https://{server}/auth/realms/mcp'
    client_file = os.path.join(os.path.dirname(token_file), os.path.basename(token_file).replace('.json', '.client.json'))
    client = json.load(open(client_file))
    data = urllib.parse.urlencode({'grant_type': 'refresh_token', 'client_id': client['client_id'], 'refresh_token': d['refresh_token'], 'scope': d.get('scope', 'mcp:tools')}).encode()
    req = urllib.request.Request(issuer.rstrip('/') + '/protocol/openid-connect/token', data=data)
    tok = json.load(urllib.request.urlopen(req, timeout=30))['access_token']
def post(payload, sid=None):
    headers = {'Content-Type': 'application/json', 'Accept': 'text/event-stream, application/json', 'Authorization': 'Bearer ' + tok}
    if sid: headers['mcp-session-id'] = sid
    req = urllib.request.Request(f'https://{server}/mcp', data=json.dumps(payload).encode(), headers=headers, method='POST')
    with urllib.request.urlopen(req, timeout=180) as r:
        return r.headers.get('mcp-session-id'), r.read().decode()
sid, _ = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "update-camera-runbook", "version": "1"}}})
post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
_, body = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": json.loads(args_json)}}, sid)
res = None
for line in body.splitlines():
    if line.startswith('data:'):
        obj = json.loads(line[5:].strip())
        if 'result' in obj: res = obj['result']
if res is None: raise SystemExit('No result in MCP response: ' + body[:200])
if res.get('isError'): raise SystemExit('MCP tool error: ' + res['content'][0]['text'])
print(res['content'][0]['text'])
PY
}

# Live discovery is informational here: the supplied --new-ip is executed
# exactly. A disagreement between the supplied value and live discovery is
# flagged, not substituted.
discover_live_ip() {
  raw="$HOME/.update_camera_raw.$$"
  mcp_call get_cameras > "$raw" || { rm -f "$raw"; return 1; }
  python3 - "$camera_serial" "$raw" <<'PY'
import json, sys
serial, raw_path = sys.argv[1], sys.argv[2]
for part in open(raw_path).read().split('\n--\n'):
    part = part.strip()
    if not part:
        continue
    cam = json.loads(part)
    if cam['serial_number'] == serial:
        print(cam['ip_address'])
        break
else:
    print('NOT DISCOVERED')
PY
  rm -f "$raw"
}

recorded_ip() {
  sudo python3 - "$camera_serial" <<'PY'
import json, sys
serial = sys.argv[1]
reg = json.load(open('/etc/onvif-mcp/camera_registry.json'))
entry = next((c for c in reg['cameras'] if c['serial_number'] == serial), None)
if entry is None: raise SystemExit(f'No registry entry for serial {serial}')
print(entry['ip_address'])
PY
}

update_registry() {
  sudo python3 - "$camera_serial" "$new_ip" <<'PY'
import datetime, json, pathlib, sys
serial, new_ip = sys.argv[1], sys.argv[2]
p = pathlib.Path('/etc/onvif-mcp/camera_registry.json')
reg = json.load(open(p))
before = [c['serial_number'] for c in reg['cameras']]
entry = next((c for c in reg['cameras'] if c['serial_number'] == serial), None)
if entry is None:
    raise SystemExit(f'Assertion failed: no registry entry for serial {serial}')
old = entry['ip_address']
if old.split(':')[0] == new_ip:
    print('changed_count: 0')
    print(f'registry: entry for {serial} already records {new_ip}')
    sys.exit(0)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')
backup = p.with_name(f'camera_registry.json.backup-{stamp}')
backup.write_text(p.read_text())
entry['ip_address'] = new_ip
reg['generated'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
if [c['serial_number'] for c in reg['cameras']] != before:
    raise SystemExit('Assertion failed: registry entry set changed; only the address may change')
p.write_text(json.dumps(reg, indent=2) + '\n')
print('changed_count: 1')
print(f'registry: {entry["hostname"]} address {old} -> {new_ip}')
print(f'backup: {backup}')
PY
}

update_routes() {
  sudo python3 - "$camera_serial" "$new_ip" <<'PY'
import datetime, json, pathlib, sys, urllib.parse
serial, new_ip = sys.argv[1], sys.argv[2]
p = pathlib.Path('/etc/onvif-mcp/snapshot_routes.json')
data = json.load(open(p))
routes = data.get('routes', data)
keys = [k for k in routes if k.startswith(serial + '/')]
if not keys:
    print('changed_count: 0')
    print(f'routes: no route for serial {serial}; nothing to change in this file')
    sys.exit(0)
changed = 0
for k in keys:
    u = urllib.parse.urlsplit(routes[k])
    host = u.netloc.split(':')[0]
    if host == new_ip:
        continue
    netloc = new_ip + ((':' + u.netloc.split(':', 1)[1]) if ':' in u.netloc else '')
    routes[k] = urllib.parse.urlunsplit((u.scheme, netloc, u.path, u.query, u.fragment))
    changed += 1
if changed == 0:
    print('changed_count: 0')
    print(f'routes: all {len(keys)} route(s) for {serial} already point at {new_ip}')
    sys.exit(0)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')
backup = p.with_name(f'snapshot_routes.json.backup-{stamp}')
backup.write_text(p.read_text())
data['routes'] = routes
p.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
print(f'changed_count: {changed}')
print(f'routes: repointed {changed} of {len(keys)} route(s) for {serial}')
print(f'backup: {backup}')
PY
}

# Credentials are embedded in the source URLs: work on a private copy, print
# only the path key and the host, never the full source line.
update_mediamtx() {
  umask 077
  tmp="$HOME/.mediamtx.yml.$$"
  sudo cat /etc/mediamtx/mediamtx.yml > "$tmp"
  out="$(python3 - "$camera_serial" "$new_ip" "$tmp" "$tmp.new" <<'PY'
import re, sys
from pathlib import Path
serial, new_ip, src_path, out_path = sys.argv[1:5]
key_re = re.compile(r'^  "([^"]+/[^"]+)":')
src_re = re.compile(r'^    source: "(rtsp://[^:]+:[^@]+@)([^/:]+)([^"]*)"$')
out, changed, current_key, count_idx = [], 0, None, None
for line in open(src_path).read().splitlines():
    m = key_re.match(line)
    if m:
        current_key = m.group(1)
        out.append(line)
        continue
    if line.startswith('# generated_path_count:'):
        count_idx = len(out)
        out.append(line)
        continue
    s = src_re.match(line)
    if s and current_key and current_key.startswith(serial + '/'):
        host = s.group(2).split(':')[0]
        if host == new_ip:
            out.append(line)
            continue
        netloc = new_ip + ((':' + s.group(2).split(':', 1)[1]) if ':' in s.group(2) else '')
        out.append(f'    source: "{s.group(1)}{netloc}{s.group(3)}"')
        changed += 1
        continue
    out.append(line)
if changed == 0:
    print('changed_count: 0')
    print(f'mediamtx: no path for serial {serial}, or every path already points at {new_ip}')
    sys.exit(0)
if count_idx is not None:
    n = int(out[count_idx].split(':')[1])
    if sum(1 for l in out if key_re.match(l)) != n:
        raise SystemExit('Assertion failed: generated_path_count does not match remaining paths')
Path(out_path).write_text('\n'.join(out) + '\n')
print('changed_count: %d' % changed)
PY
)"
  n="$(count_of "$out")"
  if [[ "$n" -gt 0 ]]; then
    stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
    sudo cp -p /etc/mediamtx/mediamtx.yml "/etc/mediamtx/mediamtx.yml.backup-$stamp"
    sudo chown mediamtx:mediamtx "/etc/mediamtx/mediamtx.yml.backup-$stamp"
    sudo chmod 0640 "/etc/mediamtx/mediamtx.yml.backup-$stamp"
    sudo install -o mediamtx -g mediamtx -m 0640 "$tmp.new" /etc/mediamtx/mediamtx.yml
    echo "changed_count: $n"
    echo "mediamtx: repointed $n path(s) for $camera_serial"
    echo "backup: /etc/mediamtx/mediamtx.yml.backup-$stamp"
  else
    echo "$out"
  fi
  shred -u "$tmp" "$tmp.new"
}

checkpoints() {
  "$repo_path/scripts/NGINX_BACKUP/nginx_backup_runbook.sh" create-checkpoint --server-fqdn "$server_fqdn" --backup-path "$backup_path" --trigger UPDATE_CAMERA.md
}

probe_route() {
  local route="$1" d
  d="$HOME/.update-camera-test.$$"
  mkdir -p "$d"
  local out="$d/$(echo "$route" | tr '/' '_').jpg"
  local c kind ok=0
  c="$(curl -s --max-time 35 -o "$out" -w '%{http_code} %{content_type}' "http://127.0.0.1:8891/snapshot/$route/")"
  kind="$(file -b "$out" 2>/dev/null | cut -c1-60)"
  [[ "$c" == 200*image/jpeg* && "$kind" == JPEG* ]] || ok=1
  echo "$route $c $kind"
  rm -f "$out"; rmdir "$d" 2>/dev/null || true
  return "$ok"
}

# The stale check compares against the address the camera had BEFORE the change.
# Without --old-ip there is nothing to compare against: the live address is by
# definition the current one, so the check is skipped rather than reporting the
# current address as stale.
stale_reference_count() {
  if [[ -z "$old_ip" ]]; then
    echo 'note: --old-ip not supplied; stale-reference check skipped (nothing to compare against)'
    echo 'stale_count: skipped'
    return 0
  fi
  sudo python3 - "$camera_serial" "$old_ip" <<'PY'
import json, pathlib, sys, urllib.parse
serial, old_ip = sys.argv[1], sys.argv[2]
hits = 0
reg = json.load(open('/etc/onvif-mcp/camera_registry.json'))
entry = next((c for c in reg['cameras'] if c['serial_number'] == serial), None)
if entry and entry['ip_address'].split(':')[0] == old_ip:
    hits += 1
    print(f'stale registry entry: {entry["hostname"]} still records {entry["ip_address"]}')
routes = json.load(open('/etc/onvif-mcp/snapshot_routes.json'))['routes']
for k, v in routes.items():
    if k.startswith(serial + '/') and urllib.parse.urlsplit(v).netloc.split(':')[0] == old_ip:
        hits += 1
        print(f'stale route: {k}')
for line in open('/etc/mediamtx/mediamtx.yml'):
    if old_ip in line:
        hits += 1
        print('stale mediamtx source line (content not printed)')
print(f'stale_count: {hits}')
PY
}

print_status() {
  echo '== services =='
  for svc in nginx mediamtx snapshot-proxy onvif-mcp-http; do printf '%s: %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"; done
  echo '== files =='
  sudo stat -c '%a %U:%G %n' /etc/onvif-mcp/camera_registry.json /etc/onvif-mcp/snapshot_routes.json /etc/mediamtx/mediamtx.yml /etc/onvif-mcp-http.env 2>/dev/null || true
  echo "== camera (serial $camera_serial) =="
  echo 'registry entry:'
  sudo python3 - "$camera_serial" <<'PY' || true
import json, sys
serial = sys.argv[1]
reg = json.load(open('/etc/onvif-mcp/camera_registry.json'))
entry = next((c for c in reg['cameras'] if c['serial_number'] == serial), None)
print(json.dumps(entry, indent=2) if entry else 'MISSING')
PY
  echo 'snapshot routes:'
  sudo python3 - "$camera_serial" <<'PY' || true
import json, sys
serial = sys.argv[1]
routes = json.load(open('/etc/onvif-mcp/snapshot_routes.json'))['routes']
matches = {k: v for k, v in routes.items() if k.startswith(serial + '/')}
print(json.dumps(matches, indent=2) if matches else 'MISSING')
PY
  echo 'mediamtx paths (key and host only; credentials not printed):'
  sudo python3 - "$camera_serial" <<'PY' || true
import re, sys
serial = sys.argv[1]
key_re = re.compile(r'^  "([^"]+/[^"]+)":')
src_re = re.compile(r'^    source: "rtsp://[^:]+:[^@]+@([^/:]+)')
current = None
for line in open('/etc/mediamtx/mediamtx.yml'):
    m = key_re.match(line)
    if m:
        current = m.group(1)
        continue
    s = src_re.match(line)
    if s and current and current.startswith(serial + '/'):
        print(f'{current} -> {s.group(1)}')
PY
  echo '== listener =='
  ss -ltnp 2>/dev/null | grep ':8891' || true
  echo '== stale references (live files only) =='
  stale_reference_count || true
  echo '== recent mediamtx logs =='
  sudo journalctl -u mediamtx -n 20 --no-pager | grep -F "$camera_serial" || true
}

test_update() {
  require_arg --server-fqdn "$server_fqdn"
  failed=0
  echo '== snapshot routes through the loopback proxy =='
  routes="$(sudo python3 - "$camera_serial" <<'PY' || true
import json, sys
serial = sys.argv[1]
routes = json.load(open('/etc/onvif-mcp/snapshot_routes.json'))['routes']
print('\n'.join(sorted(k for k in routes if k.startswith(serial + '/'))))
PY
)"
  if [[ -z "$routes" ]]; then
    echo 'FAIL: no snapshot routes for this serial' >&2
    exit 1
  fi
  for route in $routes; do
    probe_route "$route" || failed=$((failed + 1))
  done
  echo '== mediamtx path online =='
  if sudo journalctl -u mediamtx -n 60 --no-pager | grep -F "$camera_serial" | grep -qi 'online'; then
    echo 'stream online confirmed'
  else
    echo 'FAIL: no path reported online for this serial in recent logs' >&2
    failed=$((failed + 1))
  fi
  echo '== no stale address remains in live files =='
  stale="$(stale_reference_count)"
  echo "$stale"
  n="$(sed -n 's/^stale_count: //p' <<< "$stale")"
  if [[ "$n" == "skipped" ]]; then
    echo 'note: stale-address check skipped; pass --old-ip to run it'
  else
    [[ "$n" == 0 ]] || failed=$((failed + 1))
  fi
  echo '== public unauthenticated redirect (route-family auth untouched) =='
  for path in "/snapshot/$camera_serial/" "/webrtc/$camera_serial/"; do
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
  test -s "$token_file" || { echo "Token file not found: $token_file" >&2; exit 1; }
}

apply_update() {
  require_arg --server-fqdn "$server_fqdn"; require_arg --camera-serial "$camera_serial"; require_arg --new-ip "$new_ip"; require_arg --backup-path "$backup_path"; require_arg --repo-path "$repo_path"
  install_packages
  echo '== preflight =='
  preflight

  echo '== phase 1: resolve the camera and its recorded address =='
  recorded="$(recorded_ip)"
  supplied_old_ip="$old_ip"
  if [[ -z "$old_ip" ]]; then old_ip="$recorded"; fi
  echo "serial $camera_serial: recorded $recorded, target $new_ip"
  log "camera $camera_serial: recorded $recorded, target $new_ip (old-ip ${supplied_old_ip:-from registry})"

  echo '== phase 2: live discovery (informational; supplied value is executed exactly) =='
  live="$(discover_live_ip || echo 'discovery failed')"
  echo "live: $live"
  log "live discovery: $live"
  if [[ "$live" != "$new_ip" && "$live" != "NOT DISCOVERED" ]]; then
    echo "NOTE: live discovery reports $live, not the supplied $new_ip. The supplied value is applied as given; re-run this runbook with the observed address only if the camera's next attempt fails."
    log "discrepancy flagged: supplied $new_ip vs observed $live"
  fi

  total=0

  echo '== phase 3: registry entry (mirrors add phase 2) =='
  out="$(update_registry)"; echo "$out"
  n="$(count_of "$out")"; total=$((total + n))
  log "registry: $n change(s)"

  echo '== phase 4: mediamtx paths (mirrors add phase 3) =='
  out="$(update_mediamtx)"; echo "$out"
  n="$(count_of "$out")"; total=$((total + n))
  if [[ "$n" -gt 0 ]]; then
    sudo systemctl restart mediamtx
    sleep 5
  fi
  log "mediamtx: $n change(s)"

  echo '== phase 5: snapshot routes (mirrors add phase 4) =='
  out="$(update_routes)"; echo "$out"
  n="$(count_of "$out")"; total=$((total + n))
  if [[ "$n" -gt 0 ]]; then
    sudo systemctl restart snapshot-proxy
    sleep 5
  fi
  log "routes: $n change(s)"

  if [[ "$total" -eq 0 ]]; then
    echo 'FAIL: nothing to change across registry, routes, and paths; the correction is already complete. Use status/test to re-verify instead of re-running apply.' >&2
    exit 1
  fi

  echo '== phase 6: verify =='
  print_status

  echo '== phase 7: publish nginx checkpoint =='
  checkpoints

  if sudo journalctl -u mediamtx -n 60 --no-pager | grep -F "$camera_serial" | grep -qi 'online'; then
    echo 'stream online confirmed'
  else
    echo 'NOTED (non-blocking): stream not yet reported online; cameras may need a few minutes. Re-run status.'
  fi

  mkdir -p "$backup_path/log" 2>/dev/null || true
  cp -p "$log_file" "$backup_path/log/" 2>/dev/null || echo "note: audit log not copied to $backup_path/log"
}

case "$cmd" in
  apply) apply_update ;;
  status)
    require_arg --server-fqdn "$server_fqdn"; require_arg --camera-serial "$camera_serial"
    print_status
    ;;
  test) test_update ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
