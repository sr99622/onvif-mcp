#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  rename_camera_runbook.sh apply --server-fqdn HOST --ip IP --new-name NAME --backup-path PATH [--repo-path PATH] [--token-file PATH]
  rename_camera_runbook.sh status --server-fqdn HOST --ip IP

Renames a camera per docs/RENAME_CAMERA.md. The script attempts the ONVIF
name change through the MCP HTTP server using the agent's stored OAuth token
(default ~/.hermes/mcp-tokens/camera.json), then updates
/etc/onvif-mcp/camera_registry.json. A failed ONVIF rename is noted but does
not stop the protocol: the registry update always completes, and future
references by the new name resolve through the registry. After the registry
update, an nginx checkpoint is published through the shared backup script, as
in STREAM_AUTH.md; the nginx checkpoint captures /etc/onvif-mcp JSON files.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
server_fqdn=""; camera_ip=""; new_name=""; backup_path=""; token_file="$HOME/.hermes/mcp-tokens/camera.json"
repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --ip) camera_ip="${2:?missing --ip value}"; shift 2 ;;
    --new-name) new_name="${2:?missing --new-name value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --repo-path) repo_path="${2:?missing --repo-path value}"; shift 2 ;;
    --token-file) token_file="${2:?missing --token-file value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }

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
sid, _ = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "rename-runbook", "version": "1"}}})
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

registry_entry() {
  sudo python3 - "$camera_ip" <<'PY'
import json, sys
ip = sys.argv[1]
reg = json.load(open('/etc/onvif-mcp/camera_registry.json'))
entry = next((c for c in reg['cameras'] if c['ip_address'].split(':')[0] == ip), None)
if entry is None: raise SystemExit(f'No registry entry for camera at {ip}')
print(json.dumps(entry, indent=2))
PY
}

update_registry() {
  sudo python3 - "$camera_ip" "$new_name" <<'PY'
import datetime, json, pathlib, sys
ip, name = sys.argv[1], sys.argv[2]
p = pathlib.Path('/etc/onvif-mcp/camera_registry.json')
reg = json.load(open(p))
entry = next((c for c in reg['cameras'] if c['ip_address'].split(':')[0] == ip), None)
if entry is None: raise SystemExit(f'No registry entry for camera at {ip}')
old = entry['hostname']
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')
backup = p.with_name(f'camera_registry.json.backup-{stamp}')
backup.write_text(p.read_text())
entry['hostname'] = name
p.write_text(json.dumps(reg, indent=2) + '\n')
print(f'backup: {backup}')
print(f'registry hostname: {old} -> {name}')
PY
}

print_status() {
  echo '== registry entry =='
  registry_entry
  echo '== live ONVIF name =='
  live="$(mcp_call get_cameras | python3 -c 'import json,sys; print(next(json.loads(p)["hostname"] for p in sys.stdin.read().split("\n--\n") if p.strip() and json.loads(p)["ip_address"].split(":")[0] == sys.argv[1]))' "$camera_ip")"
  reg="$(sudo python3 -c 'import json,sys; print(next(c["hostname"] for c in json.load(open("/etc/onvif-mcp/camera_registry.json"))["cameras"] if c["ip_address"].split(":")[0] == sys.argv[1]))' "$camera_ip")"
  echo "live:  $live"
  echo "registry: $reg"
  if [[ "$live" == "$reg" ]]; then echo 'consistent'; else echo 'divergent: ONVIF name did not stick; registry name is authoritative for name lookups'; fi
}

checkpoints() {
  "$repo_path/scripts/NGINX_BACKUP/nginx_backup_runbook.sh" create-checkpoint --server-fqdn "$server_fqdn" --backup-path "$backup_path" --trigger RENAME_CAMERA.md
}

apply_rename() {
  require_arg --server-fqdn "$server_fqdn"; require_arg --ip "$camera_ip"; require_arg --new-name "$new_name"; require_arg --backup-path "$backup_path"
  test -s "$token_file" || { echo "Token file not found: $token_file" >&2; exit 1; }
  echo '== preflight =='
  registry_entry

  echo '== phase 1: ONVIF rename attempt =='
  result="$(mcp_call change_camera_hostname "$(python3 -c 'import json,sys; print(json.dumps({"ip_address": sys.argv[1], "new_hostname": sys.argv[2]}))' "$camera_ip" "$new_name")")"
  onvif_ok=0
  if [[ "$result" == Successfully* ]]; then onvif_ok=1; echo "$result"; else echo "NOTED (non-blocking): $result"; fi

  echo '== phase 2: registry update =='
  update_registry

  echo '== phase 3: publish nginx checkpoint =='
  checkpoints

  echo '== phase 4: verify =='
  print_status
  if [[ "$onvif_ok" -ne 1 ]]; then
    echo 'NOTE: ONVIF name change failed or was rejected by the camera. The registry is updated and is authoritative for name lookups. Re-running scripts/APPS/apps_runbook.sh will regenerate the registry from live ONVIF names and revert this entry; re-run this runbook after any APPS regeneration.'
  fi
}

case "$cmd" in
  apply) apply_rename ;;
  status) require_arg --server-fqdn "$server_fqdn"; require_arg --ip "$camera_ip"; print_status ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
