#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  add_camera_runbook.sh apply --server-fqdn HOST --camera-ip IP --camera-username USER --backup-path PATH --repo-path PATH [--token-file PATH]
  add_camera_runbook.sh status --server-fqdn HOST --camera-ip IP
  add_camera_runbook.sh test --server-fqdn HOST --camera-ip IP

Integrates one newly discovered camera per docs/ADD_CAMERA.md. Camera data is
read from the MCP HTTP server using the agent's stored OAuth token (default
~/.hermes/mcp-tokens/camera.json) and the camera password is read from
`pass show camera`. Addition is incremental: existing registry entries,
MediaMTX paths, and snapshot routes are left undisturbed. Recording is enabled
only on the main (first) profile. Browser authorization is route-family based
(Keycloak + oauth2-proxy), so the new camera inherits it automatically; the
runbook verifies inheritance rather than re-applying it. An nginx checkpoint is
published through the shared backup script with ADD_CAMERA.md as the trigger;
no Keycloak checkpoint is created because no Keycloak state changes.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
server_fqdn=""; camera_ip=""; camera_username=""; backup_path=""; token_file="$HOME/.hermes/mcp-tokens/camera.json"
repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --camera-ip) camera_ip="${2:?missing --camera-ip value}"; shift 2 ;;
    --camera-username) camera_username="${2:?missing --camera-username value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --repo-path) repo_path="${2:?missing --repo-path value}"; shift 2 ;;
    --token-file) token_file="${2:?missing --token-file value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }

summary_file="$HOME/.add_camera_summary.$$"
trap 'rm -f "$summary_file"' EXIT

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
sid, _ = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "add-camera-runbook", "version": "1"}}})
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

discover_camera() {
  raw="$HOME/.add_camera_raw.$$"
  mcp_call get_cameras > "$raw"
  python3 - "$camera_ip" "$raw" > "$summary_file" <<'PY'
import json, sys
ip, raw_path = sys.argv[1], sys.argv[2]
for part in open(raw_path).read().split('\n--\n'):
    part = part.strip()
    if not part:
        continue
    cam = json.loads(part)
    if cam['ip_address'].split(':')[0] == ip:
        print(json.dumps(cam))
        break
else:
    raise SystemExit(f'Camera not discovered at {ip}')
PY
  rm -f "$raw"
  test -s "$summary_file"
}

camera_serial() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serial_number"])' "$summary_file"; }

update_registry() {
  sudo python3 - "$camera_ip" "$server_fqdn" "$summary_file" <<'PY'
import datetime, json, pathlib, sys
ip, fqdn, summary_path = sys.argv[1:4]
cam = json.load(open(summary_path))
profiles = cam.get('profiles', [])
if not profiles:
    raise SystemExit('Discovered camera has no profiles')
serial = cam['serial_number']
media_token = profiles[0]['token']
sub_token = profiles[1]['token'] if len(profiles) > 1 else media_token
p = pathlib.Path('/etc/onvif-mcp/camera_registry.json')
reg = json.load(open(p))
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')
backup = p.with_name(f'camera_registry.json.backup-{stamp}')
backup.write_text(p.read_text())
entry = {
    'hostname': cam['hostname'],
    'ip_address': cam['ip_address'],
    'manufacturer': cam['manufacturer'],
    'model': cam['model'],
    'serial_number': serial,
    'media_profile_token': media_token,
    'substream_profile_token': sub_token,
    'media_player_url': f'https://{fqdn}/webrtc/{serial}/{media_token}/',
    'substream_player_url': f'https://{fqdn}/webrtc/{serial}/{sub_token}/',
    'snapshot_url': f'https://{fqdn}/snapshot/{serial}/{media_token}/',
}
existing = next((c for c in reg['cameras'] if c['ip_address'].split(':')[0] == ip), None)
if existing is None:
    reg['cameras'].append(entry)
    print(f'registry: added entry for {entry["hostname"]} ({ip})')
else:
    existing.update(entry)
    print(f'registry: entry for {ip} already present; fields refreshed')
reg['generated'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
p.write_text(json.dumps(reg, indent=2) + '\n')
print(f'backup: {backup}')
PY
}

update_mediamtx() {
  camera_password="$(pass show camera | sed -n '1p')"
  test -n "$camera_password"
  umask 077
  tmp="$HOME/.mediamtx.yml.$$"
  sudo cat /etc/mediamtx/mediamtx.yml > "$tmp"
  python3 - "$camera_username" "$camera_password" "$summary_file" "$tmp" "$tmp.new" <<'PY'
import json, re, sys, urllib.parse
from pathlib import Path
username, password, summary_path, src_path, out_path = sys.argv[1:6]
cam = json.load(open(summary_path))
text = open(src_path).read()
enc = urllib.parse.quote(password, safe='')
serial = cam['serial_number']
existing, count_idx = set(), None
for i, line in enumerate(text.splitlines()):
    m = re.match(r'^  "([^"]+/[^"]+)":', line)
    if m:
        existing.add(m.group(1))
    if line.startswith('# generated_path_count:'):
        count_idx = i
if 'paths:' not in text:
    raise SystemExit('No paths section in mediamtx.yml')
new = []
for i, prof in enumerate(cam.get('profiles', [])):
    stream = prof.get('stream_uri')
    if not stream:
        continue
    key = serial + '/' + prof['token']
    if key in existing:
        continue
    if not stream.startswith('rtsp://'):
        raise SystemExit(f'Unexpected stream URI for {key}: {stream}')
    source = 'rtsp://' + username + ':' + enc + '@' + stream[len('rtsp://'):]
    entry = f'  {json.dumps(key)}:\n    source: {json.dumps(source)}'
    if i == 0:
        entry += '\n    record: true'
    new.append(entry)
lines = text.splitlines()
new_lines = []
inserted = False
for line in lines:
    if count_idx is not None and line.startswith('# generated_path_count:'):
        new_lines.extend(new)
        new_lines.append(f'# generated_path_count: {len(existing) + len(new)}')
        inserted = True
    else:
        new_lines.append(line)
if not inserted and new:
    new_lines.extend(new)
    new_lines.append(f'# generated_path_count: {len(existing) + len(new)}')
Path(out_path).write_text('\n'.join(new_lines) + '\n')
print(f'mediamtx: added {len(new)} path(s) for {serial}' if new else 'mediamtx: no change (paths already present)')
PY
  sudo install -o mediamtx -g mediamtx -m 0640 "$tmp.new" /etc/mediamtx/mediamtx.yml
  shred -u "$tmp" "$tmp.new"
}

update_routes() {
  sudo python3 - "$summary_file" <<'PY'
import datetime, json, pathlib, sys
summary_path = sys.argv[1]
cam = json.load(open(summary_path))
p = pathlib.Path('/etc/onvif-mcp/snapshot_routes.json')
data = json.load(open(p))
routes = data.get('routes', data)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')
backup = p.with_name(f'snapshot_routes.json.backup-{stamp}')
backup.write_text(p.read_text())
added = 0
for prof in cam.get('profiles', []):
    uri = prof.get('snapshot_uri')
    if not uri:
        continue
    key = f'{cam["serial_number"]}/{prof["token"]}'
    if key not in routes:
        routes[key] = uri
        added += 1
data['routes'] = routes
p.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
print(f'routes: added {added} route(s) for {cam["serial_number"]}')
print(f'backup: {backup}')
PY
}

sync_time() {
  result="$(mcp_call sync_camera_time "$(python3 -c 'import json,sys; print(json.dumps({"ip_address": sys.argv[1]}))' "$camera_ip")" 2>&1 || true)"
  if [[ "$result" == *uccess* ]]; then echo "$result"; else echo "NOTED (non-blocking): $result"; fi
}

checkpoints() {
  "$repo_path/scripts/NGINX_BACKUP/nginx_backup_runbook.sh" create-checkpoint --server-fqdn "$server_fqdn" --backup-path "$backup_path" --trigger ADD_CAMERA.md
}

auth_inheritance_check() {
  local serial="$1" failed=0
  echo '== auth inheritance (unauthenticated) =='
  for path in "/snapshot/$serial/" "/webrtc/$serial/"; do
    out="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "https://$server_fqdn$path")"
    echo "$path -> $out"
    if [[ "$out" != 302* || "$out" != *'/oauth2/start?rd='* ]]; then failed=$((failed + 1)); fi
  done
  [[ "$failed" -eq 0 ]] || echo 'FAIL: protected routes did not redirect to /oauth2/start'
  return "$failed"
}

print_status() {
  echo '== services =='
  for svc in nginx mediamtx snapshot-proxy onvif-mcp-http; do printf '%s: %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"; done
  echo '== files =='
  sudo stat -c '%a %U:%G %n' /etc/onvif-mcp/camera_registry.json /etc/onvif-mcp/snapshot_routes.json /etc/mediamtx/mediamtx.yml /etc/onvif-mcp-http.env 2>/dev/null || true
  if [[ ! -s "$summary_file" ]]; then discover_camera; fi
  serial="$(camera_serial)"
  echo '== new camera =='
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
  sudo grep -F "$serial" /etc/mediamtx/mediamtx.yml || true
  echo '== listener =='
  ss -ltnp 2>/dev/null | grep ':8891' || true
  auth_inheritance_check "$serial" || true
  echo '== recent mediamtx logs =='
  sudo journalctl -u mediamtx -n 20 --no-pager | grep -F "$serial" || true
}

test_new_camera() {
  require_arg --server-fqdn "$server_fqdn"
  test -s "$token_file" || { echo "Token file not found: $token_file" >&2; exit 1; }
  discover_camera
  serial="$(camera_serial)"
  failed=0
  echo '== loopback snapshot proxy (proves route + camera credentials) =='
  routes="$(sudo python3 -c 'import json,sys; s=sys.argv[1]; print("\n".join(k for k in json.load(open("/etc/onvif-mcp/snapshot_routes.json"))["routes"] if k.startswith(s + "/")))' "$serial")"
  test -n "$routes" || { echo 'FAIL: no snapshot routes for this camera' >&2; exit 1; }
  d="$HOME/.add-camera-test.$$"
  mkdir -p "$d"
  for route in $routes; do
    out="$d/$(echo "$route" | tr '/' '_').jpg"
    c="$(curl -s --max-time 35 -o "$out" -w '%{http_code} %{content_type}' "http://127.0.0.1:8891/snapshot/$route/")"
    kind="$(file -b "$out" 2>/dev/null | cut -c1-60)"
    ok=0
    [[ "$c" == 200*image/jpeg* && "$kind" == JPEG* ]] || ok=1
    echo "$route $c $kind"
    failed=$((failed + ok))
  done
  echo '== public unauthenticated redirect (proves auth inheritance) =='
  rc=0; auth_inheritance_check "$serial" || rc=$?
  failed=$((failed + rc))
  rm -rf "$d"
  echo "test failures: $failed"
  exit "$failed"
}

apply_camera() {
  require_arg --server-fqdn "$server_fqdn"; require_arg --camera-ip "$camera_ip"; require_arg --camera-username "$camera_username"; require_arg --backup-path "$backup_path"; require_arg --repo-path "$repo_path"
  test -s "$token_file" || { echo "Token file not found: $token_file" >&2; exit 1; }
  install_packages
  echo '== preflight =='
  for svc in nginx mediamtx snapshot-proxy onvif-mcp-http; do
    systemctl is-active "$svc" >/dev/null || { echo "FAIL: $svc is not active" >&2; exit 1; }
  done
  if ! pass show camera >/dev/null 2>&1; then
    echo 'FAIL: pass show camera failed. Ask the user to prime the password cache in their own terminal:' >&2
    echo "  cd $repo_path && pass show camera >/dev/null" >&2
    exit 1
  fi

  echo '== phase 1: discover camera =='
  discover_camera
  python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(f\"{c['hostname']} ({c['ip_address']}) serial {c['serial_number']}, {len(c['profiles'])} profile(s)\")" "$summary_file"

  echo '== phase 2: registry entry =='
  update_registry

  echo '== phase 3: mediamtx paths =='
  update_mediamtx
  sudo systemctl restart mediamtx
  sleep 5

  echo '== phase 4: snapshot routes =='
  update_routes
  sudo systemctl restart snapshot-proxy
  sleep 5

  echo '== phase 5: time sync (non-blocking) =='
  sync_time

  echo '== phase 6: verify =='
  print_status

  echo '== phase 7: publish nginx checkpoint =='
  checkpoints

  serial="$(camera_serial)"
  if sudo journalctl -u mediamtx -n 60 --no-pager | grep -F "$serial" | grep -qi 'online'; then
    echo 'stream online confirmed'
  else
    echo 'NOTED (non-blocking): stream not yet reported online; cameras may need a few minutes. Re-run status.'
  fi
}

case "$cmd" in
  apply) apply_camera ;;
  status)
    require_arg --server-fqdn "$server_fqdn"; require_arg --camera-ip "$camera_ip"
    test -s "$token_file" || { echo "Token file not found: $token_file" >&2; exit 1; }
    print_status
    ;;
  test) test_new_camera ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
