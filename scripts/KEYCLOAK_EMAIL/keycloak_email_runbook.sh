#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  keycloak_email_runbook.sh user-store-password
  keycloak_email_runbook.sh apply --gmail-address ADDRESS --server-fqdn HOST --backup-path PATH [--repo-path PATH] [--realm REALM]
  keycloak_email_runbook.sh status --gmail-address ADDRESS --server-fqdn HOST [--realm REALM]

Implements docs/KEYCLOAK_EMAIL.md. Secrets are read only from root-owned files and are never printed.
The user-store-password subcommand is intentionally user-run in an interactive terminal.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true

gmail_address=""; server_fqdn=""; backup_path=""; repo_path="/home/stephen"; realm="mcp"; admin_user="keycloak-admin"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gmail-address) gmail_address="${2:?missing --gmail-address value}"; shift 2 ;;
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --repo-path) repo_path="${2:?missing --repo-path value}"; shift 2 ;;
    --realm) realm="${2:?missing --realm value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
project_dir() { printf '%s/onvif-mcp' "${repo_path%/}"; }
issuer() { printf 'https://%s/auth/realms/%s' "$server_fqdn" "$realm"; }
backup_script() { printf '%s/scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh' "$(project_dir)"; }

kc_exec() {
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config
}

validate_gmail_address() {
  require_arg --gmail-address "$gmail_address"
  python3 - "$gmail_address" <<'PY'
import sys
addr = sys.argv[1]
if not addr.endswith('@gmail.com') or any(c.isspace() for c in addr) or addr.count('@') != 1:
    raise SystemExit('Supply the dedicated full @gmail.com address with no whitespace.')
PY
}

user_store_password() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Re-run this subcommand with sudo so /opt/keycloak/gmail-smtp.pass is root-owned." >&2
    exit 77
  fi
  python3 - <<'PY'
import getpass
import os
import pathlib
import warnings
warnings.simplefilter('error', getpass.GetPassWarning)
path = pathlib.Path('/opt/keycloak/gmail-smtp.pass')
password = ''.join(getpass.getpass('Camera Keycloak SMTP/app password (hidden): ').split())
if len(password) < 8:
    raise SystemExit('Password too short; nothing saved.')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
try:
    with os.fdopen(fd, 'w') as f:
        f.write(password + '\n')
finally:
    try:
        os.close(fd)
    except OSError:
        pass
os.chown(path, 0, 0)
os.chmod(path, 0o600)
print('Saved SMTP password in /opt/keycloak/gmail-smtp.pass; value not displayed.')
PY
}

verify_secret_file() {
  sudo test -s /opt/keycloak/gmail-smtp.pass
  local mode_owner
  mode_owner="$(sudo stat -c '%a %U:%G' /opt/keycloak/gmail-smtp.pass)"
  [[ "$mode_owner" == "600 root:root" ]] || { echo "Expected /opt/keycloak/gmail-smtp.pass mode/owner 600 root:root, got $mode_owner" >&2; exit 1; }
  sudo stat -c 'smtp-password-file: %a %U:%G %n' /opt/keycloak/gmail-smtp.pass
}

authenticate_cli() {
  sudo test -s /opt/keycloak/admin.pass
  sudo cat /opt/keycloak/admin.pass | sudo docker compose --project-directory /opt/keycloak exec -T keycloak sh -c 'IFS= read -r admin_password || [ -n "$admin_password" ]; /opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config --server http://127.0.0.1:8080/auth --realm master --user "$1" --password "$admin_password" >/dev/null' sh "$admin_user"
  kc_exec get realms --fields realm,enabled
}

preflight() {
  validate_gmail_address
  require_arg --server-fqdn "$server_fqdn"
  verify_secret_file
  curl --fail --silent --show-error --output /dev/null http://127.0.0.1:8080/auth/realms/master/.well-known/openid-configuration
  authenticate_cli
  python3 - "$(issuer)/.well-known/openid-configuration" "$server_fqdn" "$realm" <<'PY'
import json, sys, urllib.request
url, fqdn, realm = sys.argv[1:4]
expected = f'https://{fqdn}/auth/realms/{realm}'
with urllib.request.urlopen(url, timeout=30) as response:
    data = json.load(response)
actual = data.get('issuer')
print('public-issuer:', actual)
if actual != expected:
    raise SystemExit(f'issuer mismatch: expected {expected!r}, got {actual!r}')
PY
}

create_checkpoint() {
  local trigger="$1"
  require_arg --backup-path "$backup_path"
  local script; script="$(backup_script)"
  [[ -x "$script" ]] || { echo "Missing executable backup script: $script" >&2; exit 1; }
  "$script" create-checkpoint --backup-path "$backup_path" --trigger "$trigger"
}

configure_smtp() {
  sudo python3 - "$gmail_address" "$realm" <<'PY'
import json
import pathlib
import sys
import urllib.parse
import urllib.request

server = 'http://127.0.0.1:8080/auth'
address = sys.argv[1]
realm = sys.argv[2]
if not address.endswith('@gmail.com') or any(c.isspace() for c in address) or address.count('@') != 1:
    raise SystemExit('Supply the dedicated full @gmail.com address.')
admin_password = pathlib.Path('/opt/keycloak/admin.pass').read_text().strip()
smtp_password = pathlib.Path('/opt/keycloak/gmail-smtp.pass').read_text().strip()
if not smtp_password:
    raise SystemExit('SMTP password file is empty.')

def req(url, method='GET', data=None, token=None, content_type='application/json'):
    headers = {}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    body = None
    if data is not None:
        body = data if isinstance(data, bytes) else data.encode()
        headers['Content-Type'] = content_type
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()

form = urllib.parse.urlencode({
    'grant_type': 'password', 'client_id': 'admin-cli',
    'username': 'keycloak-admin', 'password': admin_password,
}).encode()
token = json.loads(req(server + '/realms/master/protocol/openid-connect/token',
                       'POST', form, content_type='application/x-www-form-urlencoded'))['access_token']
realm_rep = json.loads(req(server + '/admin/realms/' + realm, token=token))
realm_rep['smtpServer'] = {
    'host': 'smtp.gmail.com', 'port': '587',
    'from': address, 'fromDisplayName': 'Camera System',
    'auth': 'true', 'user': address, 'password': smtp_password,
    'starttls': 'true', 'ssl': 'false'
}
req(server + '/admin/realms/' + realm, 'PUT', json.dumps(realm_rep), token=token)

smtp = json.loads(req(server + '/admin/realms/' + realm, token=token)).get('smtpServer', {})
expected = {'host':'smtp.gmail.com','port':'587','auth':'true','starttls':'true','ssl':'false'}
assert all(str(smtp.get(k)) == v for k, v in expected.items()), 'SMTP settings mismatch'
assert smtp.get('from') == address and smtp.get('user') == address, 'SMTP address mismatch'
for k in ('host','port','from','fromDisplayName','user','auth','starttls','ssl'):
    print(k + ': ' + str(smtp.get(k, '')))
print('smtp-password-present:', bool(smtp.get('password')))
PY
}

status() {
  validate_gmail_address
  require_arg --server-fqdn "$server_fqdn"
  echo "== secret file =="
  verify_secret_file || true
  echo "== keycloak cli =="
  authenticate_cli >/dev/null
  echo "cli-auth: ok"
  echo "== public discovery =="
  python3 - "$(issuer)/.well-known/openid-configuration" "$server_fqdn" "$realm" <<'PY'
import json, sys, urllib.request
url, fqdn, realm = sys.argv[1:4]
with urllib.request.urlopen(url, timeout=30) as response:
    data=json.load(response)
print('issuer:', data.get('issuer'))
print('expected:', f'https://{fqdn}/auth/realms/{realm}')
PY
  echo "== smtp redacted readback =="
  sudo python3 - "$gmail_address" "$realm" <<'PY'
import json, pathlib, sys, urllib.parse, urllib.request
server='http://127.0.0.1:8080/auth'; address=sys.argv[1]; realm=sys.argv[2]
admin_password=pathlib.Path('/opt/keycloak/admin.pass').read_text().strip()
def req(url, method='GET', data=None, token=None, content_type='application/json'):
    headers={}; body=None
    if token: headers['Authorization']='Bearer '+token
    if data is not None:
        body=data if isinstance(data, bytes) else data.encode(); headers['Content-Type']=content_type
    with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers, method=method), timeout=30) as r:
        return r.read()
form=urllib.parse.urlencode({'grant_type':'password','client_id':'admin-cli','username':'keycloak-admin','password':admin_password}).encode()
token=json.loads(req(server+'/realms/master/protocol/openid-connect/token','POST',form,content_type='application/x-www-form-urlencoded'))['access_token']
smtp=json.loads(req(server+'/admin/realms/'+realm, token=token)).get('smtpServer', {})
for k in ('host','port','from','fromDisplayName','user','auth','starttls','ssl'):
    print(k + ': ' + str(smtp.get(k, '')))
print('password-configured:', bool(smtp.get('password')))
if smtp.get('from') != address or smtp.get('user') != address:
    raise SystemExit('SMTP Gmail address mismatch')
PY
}

apply() {
  require_arg --backup-path "$backup_path"
  preflight
  create_checkpoint KEYCLOAK_EMAIL.md-pre-smtp
  configure_smtp
  sleep 1
  create_checkpoint KEYCLOAK_EMAIL.md-post-smtp
  status
  echo "apply-ok keycloak SMTP configured for $gmail_address in realm $realm"
  echo "delivery-test: not run; no first recipient was supplied for ADD_USER_EMAIL.md"
}

case "$cmd" in
  user-store-password) user_store_password ;;
  apply) apply ;;
  status) status ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
