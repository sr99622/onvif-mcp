#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  add_client_on_server_runbook.sh apply --client-source-ip IP --backup-path PATH [--repo-path PATH] [--realm REALM]
  add_client_on_server_runbook.sh status --client-source-ip IP [--realm REALM]

Adds one client source IP to Keycloak anonymous DCR Trusted Hosts. The mutating
mint/resolve/fetch/update/put/verify sequence runs inside one root Python process.
USAGE
}

cmd="${1:-}"
[[ -n "$cmd" ]] || {
  usage
  exit 64
}
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && {
  usage
  exit 0
}
shift || true

client_source_ip=""
backup_path=""
repo_path="$HOME"
realm="mcp"
admin_user="keycloak-admin"
keycloak_port="8080"
keycloak_path="/auth"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --client-source-ip)
    client_source_ip="${2:?missing --client-source-ip value}"
    shift 2
    ;;
  --backup-path)
    backup_path="${2:?missing --backup-path value}"
    shift 2
    ;;
  --repo-path)
    repo_path="${2:?missing --repo-path value}"
    shift 2
    ;;
  --realm)
    realm="${2:?missing --realm value}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 64
    ;;
  esac
done

require_arg() {
  local name="$1" value="$2"
  [[ -n "$value" ]] || {
    echo "Missing required argument: $name" >&2
    exit 64
  }
}
project_dir() { printf '%s/onvif-mcp' "${repo_path%/}"; }
backup_script() { printf '%s/scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh' "$(project_dir)"; }
artifact_dir() { printf '%s/scripts/ADD_CLIENT_ON_SERVER' "$(project_dir)"; }
server_url() { printf 'http://127.0.0.1:%s%s' "$keycloak_port" "$keycloak_path"; }

validate_ip() {
  require_arg --client-source-ip "$client_source_ip"
  python3 - "$client_source_ip" <<'PY'
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
print('client-source-ip:', sys.argv[1])
PY
}

preflight() {
  validate_ip
  echo "== server identity =="
  hostname -I
  echo "== keycloak listener =="
  ss -ltnp | grep ':8080\b' || true
  curl -sS -o /dev/null -w 'Health: HTTP %{http_code}\n' "$(server_url)/realms/master/.well-known/openid-configuration" | grep -F 'HTTP 200'
  echo "== recent DCR log entries =="
  sudo grep 'clients-registrations/openid-connect' /var/log/nginx/access.log | tail -n 5 || true
}

create_checkpoint() {
  local trigger="$1"
  require_arg --backup-path "$backup_path"
  local script
  script="$(backup_script)"
  [[ -x "$script" ]] || {
    echo "Missing executable backup script: $script" >&2
    exit 1
  }
  "$script" create-checkpoint --backup-path "$backup_path" --trigger "$trigger"
}

trusted_hosts_status() {
  sudo python3 - "$client_source_ip" "$realm" "$admin_user" "$(server_url)" <<'PY'
import json, pathlib, sys, urllib.parse, urllib.request
client_ip, realm, admin_user, server = sys.argv[1:5]
admin_password = pathlib.Path('/opt/keycloak/admin.pass').read_text().strip()
def req(url, method='GET', data=None, token=None, content_type='application/json'):
    headers={}; body=None
    if token: headers['Authorization']='Bearer '+token
    if data is not None:
        body=data if isinstance(data, bytes) else data.encode(); headers['Content-Type']=content_type
    with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers, method=method), timeout=30) as r:
        return r.status, r.read()
form=urllib.parse.urlencode({'grant_type':'password','client_id':'admin-cli','username':admin_user,'password':admin_password}).encode()
token=json.loads(req(server+'/realms/master/protocol/openid-connect/token','POST',form,content_type='application/x-www-form-urlencoded')[1])['access_token']
components=json.loads(req(server+'/admin/realms/'+urllib.parse.quote(realm, safe='')+'/components?subType=anonymous', token=token)[1])
matches=[c for c in components if c.get('providerId')=='trusted-hosts' and c.get('subType')=='anonymous']
print('exact-trusted-hosts-components:', len(matches))
if len(matches) != 1:
    raise SystemExit('Expected exactly one anonymous trusted-hosts component')
cid=matches[0]['id']
component=json.loads(req(server+'/admin/realms/'+urllib.parse.quote(realm, safe='')+'/components/'+urllib.parse.quote(cid, safe=''), token=token)[1])
if component.get('providerId') != 'trusted-hosts' or component.get('subType') != 'anonymous':
    raise SystemExit('Unexpected component shape')
config=component.get('config') or {}
hosts=list(config.get('trusted-hosts') or [])
print('component-id:', cid)
print('trusted-hosts:', ','.join(hosts))
print('client-present:', str(client_ip in hosts).lower())
print('host-sending-registration-request-must-match:', config.get('host-sending-registration-request-must-match'))
print('client-uris-must-match:', config.get('client-uris-must-match'))
PY
}

update_trusted_hosts_one_root_command() {
  sudo python3 - "$client_source_ip" "$realm" "$admin_user" "$(server_url)" "$(artifact_dir)/last-trusted-hosts-update.json" <<'PY'
import json
import pathlib
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

client_ip, realm, admin_user, server, report_path = sys.argv[1:6]
admin_password = pathlib.Path('/opt/keycloak/admin.pass').read_text().strip()

def req(url, method='GET', data=None, token=None, content_type='application/json', expect=None):
    headers = {}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    body = None
    if data is not None:
        body = data if isinstance(data, bytes) else data.encode()
        headers['Content-Type'] = content_type
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=45) as response:
        if expect and response.status not in expect:
            raise RuntimeError(f'unexpected HTTP {response.status} for {url}')
        return response.status, response.read()

# This is the runbook's required single bounded root-controlled sequence:
# mint token, resolve component live, fetch by ID, modify, PUT, verify by a
# second direct by-ID GET, and write only non-secret metadata before exiting.
form = urllib.parse.urlencode({
    'grant_type': 'password', 'client_id': 'admin-cli',
    'username': admin_user, 'password': admin_password,
}).encode()
token = json.loads(req(server + '/realms/master/protocol/openid-connect/token',
                       'POST', form, content_type='application/x-www-form-urlencoded')[1])['access_token']
realm_q = urllib.parse.quote(realm, safe='')
components = json.loads(req(server + f'/admin/realms/{realm_q}/components?subType=anonymous', token=token)[1])
matches = [c for c in components if c.get('providerId') == 'trusted-hosts' and c.get('subType') == 'anonymous']
if len(matches) != 1:
    raise SystemExit('stop: zero or multiple components; wrong realm or hand-modified realm')
cid = matches[0]['id']
status, raw_before = req(server + f'/admin/realms/{realm_q}/components/' + urllib.parse.quote(cid, safe=''), token=token)
component = json.loads(raw_before)
if component.get('providerId') != 'trusted-hosts' or component.get('subType') != 'anonymous':
    raise SystemExit('unexpected component shape (possible transient or error body): ' + raw_before[:200].decode('utf-8', 'replace'))
config = component.setdefault('config', {})
before_hosts = list(config.get('trusted-hosts') or [])
after_hosts = list(before_hosts)
changed = False
if client_ip not in after_hosts:
    after_hosts.append(client_ip)
    changed = True
config['trusted-hosts'] = after_hosts
config['host-sending-registration-request-must-match'] = ['true']
config['client-uris-must-match'] = ['true']
update_body = json.dumps(component, separators=(',', ':'))
put_status, _ = req(server + f'/admin/realms/{realm_q}/components/' + urllib.parse.quote(cid, safe=''),
                    'PUT', update_body, token=token, expect={200, 204})
verify_status, raw_after = req(server + f'/admin/realms/{realm_q}/components/' + urllib.parse.quote(cid, safe=''), token=token)
verified = json.loads(raw_after)
if verified.get('providerId') != 'trusted-hosts' or verified.get('subType') != 'anonymous':
    raise SystemExit('unexpected component representation: ' + raw_after[:200].decode('utf-8', 'replace'))
verified_config = verified.get('config') or {}
stored_hosts = list(verified_config.get('trusted-hosts') or [])
if client_ip not in stored_hosts:
    raise SystemExit('new client address missing after PUT')
for keep in ['localhost', '127.0.0.1']:
    if keep not in stored_hosts:
        raise SystemExit(f'pre-existing host lost: {keep}')
if verified_config.get('host-sending-registration-request-must-match') != ['true']:
    raise SystemExit('host-sending-registration-request-must-match not true')
if verified_config.get('client-uris-must-match') != ['true']:
    raise SystemExit('client-uris-must-match not true')
report = {
    'runbook': 'ADD_CLIENT_ON_SERVER.md',
    'timestamp_utc': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'realm': realm,
    'client_source_ip': client_ip,
    'component_id': cid,
    'put_status': put_status,
    'before_trusted_hosts': before_hosts,
    'after_trusted_hosts': stored_hosts,
    'changed': changed,
    'host_sending_registration_request_must_match': verified_config.get('host-sending-registration-request-must-match'),
    'client_uris_must_match': verified_config.get('client-uris-must-match'),
    'verification': 'VERIFY OK',
    'dcr_client_registration': 'pending until client retries DCR/login',
}
path = pathlib.Path(report_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
path.chmod(0o600)
print('component-id:', cid)
print('before-trusted-hosts:', ','.join(before_hosts))
print('after-trusted-hosts:', ','.join(stored_hosts))
print('changed:', str(changed).lower())
print('matching-controls: true')
print('VERIFY OK')
print('report:', str(path))
PY
}

verify_tmp_cleanup() {
  echo "== temp artifact cleanup =="
  if compgen -G '/tmp/.kctmp.*' >/dev/null || compgen -G '/tmp/.kctok.*' >/dev/null || compgen -G '/tmp/kc-components.json' >/dev/null || compgen -G '/tmp/kc-cid.txt' >/dev/null || compgen -G '/tmp/kc-th-*' >/dev/null; then
    ls -la /tmp/.kctmp.* /tmp/.kctok.* /tmp/kc-components.json /tmp/kc-cid.txt /tmp/kc-th-* 2>/dev/null || true
    echo 'Unexpected Keycloak temp artifacts remain' >&2
    exit 1
  fi
  echo "temp-artifacts: none"
}

recent_dcr_log() {
  echo "== recent DCR log entries =="
  sudo grep 'clients-registrations/openid-connect' /var/log/nginx/access.log | tail -n 5 || true
}

apply() {
  require_arg --backup-path "$backup_path"
  preflight
  echo "== trusted hosts before =="
  trusted_hosts_status
  echo "== update trusted hosts =="
  update_trusted_hosts_one_root_command
  verify_tmp_cleanup
  echo "== trusted hosts after =="
  trusted_hosts_status
  create_checkpoint ADD_CLIENT_ON_SERVER.md-trusted-host-added
  recent_dcr_log
  echo "apply-ok trusted host $client_source_ip allowed; client DCR/login verification pending until next client attempt"
}

status_cmd() {
  validate_ip
  curl -sS -o /dev/null -w 'Health: HTTP %{http_code}\n' "$(server_url)/realms/master/.well-known/openid-configuration" | grep -F 'HTTP 200'
  trusted_hosts_status
  verify_tmp_cleanup
  recent_dcr_log
}

case "$cmd" in
apply) apply ;;
status) status_cmd ;;
*)
  echo "Unknown command: $cmd" >&2
  usage >&2
  exit 64
  ;;
esac
