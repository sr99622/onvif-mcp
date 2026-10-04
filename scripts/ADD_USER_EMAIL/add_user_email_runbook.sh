#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  add_user_email_runbook.sh apply --new-login-user USER --first-name FIRST --last-name LAST --user-email EMAIL --server-fqdn HOST --backup-path PATH [--repo-path PATH] [--realm REALM]
  add_user_email_runbook.sh resend --new-login-user USER --user-email EMAIL --server-fqdn HOST --backup-path PATH [--repo-path PATH] [--realm REALM]
  add_user_email_runbook.sh status --new-login-user USER --user-email EMAIL --server-fqdn HOST [--realm REALM]

Creates or resumes a human Keycloak user invited by email. No password input is accepted.
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

new_login_user=""
first_name=""
last_name=""
user_email=""
server_fqdn=""
backup_path=""
repo_path="$HOME"
realm="mcp"
admin_user="keycloak-admin"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --new-login-user)
    new_login_user="${2:?missing --new-login-user value}"
    shift 2
    ;;
  --first-name)
    first_name="${2:?missing --first-name value}"
    shift 2
    ;;
  --last-name)
    last_name="${2:?missing --last-name value}"
    shift 2
    ;;
  --user-email)
    user_email="${2:?missing --user-email value}"
    shift 2
    ;;
  --server-fqdn)
    server_fqdn="${2:?missing --server-fqdn value}"
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
issuer() { printf 'https://%s/auth/realms/%s' "$server_fqdn" "$realm"; }
backup_script() { printf '%s/scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh' "$(project_dir)"; }
artifact_dir() { printf '%s/scripts/ADD_USER_EMAIL' "$(project_dir)"; }

validate_identity_common() {
  require_arg --new-login-user "$new_login_user"
  require_arg --user-email "$user_email"
  require_arg --server-fqdn "$server_fqdn"
  python3 - "$new_login_user" "$user_email" <<'PY'
import sys
username, email = sys.argv[1:3]
if any(c.isspace() for c in username) or not username:
    raise SystemExit('Username must be nonempty and contain no whitespace.')
if '@' not in email or any(c.isspace() for c in email):
    raise SystemExit('User email must be a full address with no whitespace.')
PY
}

validate_apply_identity() {
  validate_identity_common
  require_arg --first-name "$first_name"
  require_arg --last-name "$last_name"
  python3 - "$first_name" "$last_name" <<'PY'
import sys
if any(not v.strip() for v in sys.argv[1:]):
    raise SystemExit('First and last name must be nonempty.')
PY
}

authenticate_cli() {
  sudo test -s /opt/keycloak/admin.pass
  sudo cat /opt/keycloak/admin.pass | sudo docker compose --project-directory /opt/keycloak exec -T keycloak sh -c 'IFS= read -r admin_password || [ -n "$admin_password" ]; /opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config --server http://127.0.0.1:8080/auth --realm master --user "$1" --password "$admin_password" >/dev/null' sh "$admin_user"
}

preflight() {
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
  local script
  script="$(backup_script)"
  [[ -x "$script" ]] || {
    echo "Missing executable backup script: $script" >&2
    exit 1
  }
  "$script" create-checkpoint --backup-path "$backup_path" --trigger "$trigger"
}

admin_api_python() {
  sudo python3 - "$@"
}

create_and_invite() {
  admin_api_python "$new_login_user" "$first_name" "$last_name" "$user_email" "$realm" apply <<'PY'
import json
import pathlib
import sys
import urllib.parse
import urllib.request

username, first_name, last_name, email, realm, mode = sys.argv[1:7]
server = 'http://127.0.0.1:8080/auth'
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
        return response.status, response.read(), dict(response.headers)

def jget(path):
    return json.loads(req(server + path, token=token)[1])

form = urllib.parse.urlencode({'grant_type':'password','client_id':'admin-cli','username':'keycloak-admin','password':admin_password}).encode()
token = json.loads(req(server + '/realms/master/protocol/openid-connect/token', 'POST', form, content_type='application/x-www-form-urlencoded')[1])['access_token']
realm_rep = jget('/admin/realms/' + urllib.parse.quote(realm, safe=''))
print('registrationAllowed:', realm_rep.get('registrationAllowed'))
print('passwordPolicy:', realm_rep.get('passwordPolicy') or '')
required_actions = jget('/admin/realms/' + urllib.parse.quote(realm, safe='') + '/authentication/required-actions')
for alias in ('VERIFY_EMAIL', 'UPDATE_PASSWORD'):
    matches = [a for a in required_actions if a.get('alias') == alias]
    if len(matches) != 1 or not matches[0].get('enabled'):
        raise SystemExit(f'Required action {alias} is not enabled')
    print(f'required-action-{alias}: enabled')
if realm_rep.get('registrationAllowed'):
    raise SystemExit('Self-registration is enabled; stop before creating invited user.')

base_path = '/admin/realms/' + urllib.parse.quote(realm, safe='') + '/users'
by_username = jget(base_path + '?' + urllib.parse.urlencode({'exact':'true','username':username, 'briefRepresentation':'true'}))
by_email = jget(base_path + '?' + urllib.parse.urlencode({'exact':'true','email':email, 'briefRepresentation':'true'}))
print('username-collision-count:', len(by_username))
print('email-collision-count:', len(by_email))
if by_username or by_email:
    raise SystemExit('Username or email already exists. Use resend/status only after verifying it is the intended pending user.')
baseline = jget(base_path + '?first=0&max=1000&briefRepresentation=true')
baseline_map = {u.get('id'): {'username': u.get('username'), 'enabled': u.get('enabled')} for u in baseline}

new_user = {
    'username': username,
    'firstName': first_name,
    'lastName': last_name,
    'email': email,
    'enabled': True,
    'emailVerified': False,
    'requiredActions': ['VERIFY_EMAIL', 'UPDATE_PASSWORD'],
}
status, _body, headers = req(server + base_path, 'POST', json.dumps(new_user), token=token, expect={201})
location = headers.get('Location') or headers.get('location') or ''
new_id = location.rstrip('/').split('/')[-1] if location else ''
if not new_id:
    users = jget(base_path + '?' + urllib.parse.urlencode({'exact':'true','username':username}))
    if len(users) != 1:
        raise SystemExit('Could not resolve exactly one new user after create')
    new_id = users[0]['id']
user = jget(base_path + '/' + urllib.parse.quote(new_id, safe=''))
creds = jget(base_path + '/' + urllib.parse.quote(new_id, safe='') + '/credentials')
checks = [
    user.get('username') == username,
    user.get('email') == email,
    user.get('firstName') == first_name,
    user.get('lastName') == last_name,
    user.get('enabled') is True,
    user.get('emailVerified') is False,
    set(user.get('requiredActions') or []) >= {'VERIFY_EMAIL', 'UPDATE_PASSWORD'},
    creds == [],
]
if not all(checks):
    raise SystemExit('New user readback failed validation before email send')
status, _body, _headers = req(
    server + base_path + '/' + urllib.parse.quote(new_id, safe='') + '/execute-actions-email?' + urllib.parse.urlencode({'lifespan':'86400'}),
    'PUT', json.dumps(['VERIFY_EMAIL', 'UPDATE_PASSWORD']), token=token, expect={204})
print('invitation-api-status:', status)
after = jget(base_path + '?first=0&max=1000&briefRepresentation=true')
after_map = {u.get('id'): {'username': u.get('username'), 'enabled': u.get('enabled')} for u in after}
changed_existing = []
for uid, before in baseline_map.items():
    if after_map.get(uid) != before:
        changed_existing.append({'id': uid, 'before': before, 'after': after_map.get(uid)})
if changed_existing:
    raise SystemExit('Existing-user baseline changed: ' + json.dumps(changed_existing, sort_keys=True))
print('new-user-id:', new_id)
print('username:', user.get('username'))
print('email:', user.get('email'))
print('enabled:', user.get('enabled'))
print('emailVerified:', user.get('emailVerified'))
print('requiredActions:', ','.join(user.get('requiredActions') or []))
print('credential-types:', ','.join(c.get('type','') for c in creds) or '(none)')
print('existing-user-comparison: unchanged')
PY
}

resend_invitation() {
  admin_api_python "$new_login_user" "$user_email" "$realm" resend <<'PY'
import json, pathlib, sys, urllib.parse, urllib.request
username, email, realm, mode = sys.argv[1:5]
server='http://127.0.0.1:8080/auth'
admin_password=pathlib.Path('/opt/keycloak/admin.pass').read_text().strip()
def req(url, method='GET', data=None, token=None, content_type='application/json', expect=None):
    headers={}; body=None
    if token: headers['Authorization']='Bearer '+token
    if data is not None:
        body=data if isinstance(data, bytes) else data.encode(); headers['Content-Type']=content_type
    with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers, method=method), timeout=45) as r:
        if expect and r.status not in expect: raise RuntimeError(f'unexpected HTTP {r.status}')
        return r.status, r.read()
def jget(path): return json.loads(req(server+path, token=token)[1])
form=urllib.parse.urlencode({'grant_type':'password','client_id':'admin-cli','username':'keycloak-admin','password':admin_password}).encode()
token=json.loads(req(server+'/realms/master/protocol/openid-connect/token','POST',form,content_type='application/x-www-form-urlencoded')[1])['access_token']
base='/admin/realms/'+urllib.parse.quote(realm, safe='')+'/users'
users=jget(base+'?'+urllib.parse.urlencode({'exact':'true','username':username}))
if len(users) != 1 or users[0].get('email') != email:
    raise SystemExit('Expected exactly one matching intended user before resend')
user=users[0]; uid=user['id']
creds=jget(base+'/'+urllib.parse.quote(uid, safe='')+'/credentials')
required=set(user.get('requiredActions') or [])
if creds or not {'VERIFY_EMAIL','UPDATE_PASSWORD'} <= required or user.get('emailVerified'):
    raise SystemExit('User is not in pending no-credential invite state; not resending')
status, _ = req(base+'/'+urllib.parse.quote(uid, safe='')+'/execute-actions-email?'+urllib.parse.urlencode({'lifespan':'86400'}), 'PUT', json.dumps(['VERIFY_EMAIL','UPDATE_PASSWORD']), token=token, expect={204})
print('resend-api-status:', status)
print('new-user-id:', uid)
print('username:', user.get('username'))
print('email:', user.get('email'))
print('onboarding: pending')
PY
}

status_user() {
  admin_api_python "$new_login_user" "$user_email" "$realm" status <<'PY'
import json, pathlib, sys, urllib.parse, urllib.request
username, email, realm, mode = sys.argv[1:5]
server='http://127.0.0.1:8080/auth'
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
base='/admin/realms/'+urllib.parse.quote(realm, safe='')+'/users'
users=json.loads(req(server+base+'?'+urllib.parse.urlencode({'exact':'true','username':username}), token=token))
print('match-count:', len(users))
if len(users) != 1:
    raise SystemExit('Expected exactly one matching user')
user=users[0]
if user.get('email') != email:
    raise SystemExit('Matching username has different email')
uid=user['id']
creds=json.loads(req(server+base+'/'+urllib.parse.quote(uid, safe='')+'/credentials', token=token))
print('new-user-id:', uid)
for k in ('username','email','firstName','lastName','enabled','emailVerified'):
    print(f'{k}: {user.get(k)}')
print('requiredActions:', ','.join(user.get('requiredActions') or []) or '(none)')
print('credential-types:', ','.join(c.get('type','') for c in creds) or '(none)')
complete = user.get('enabled') is True and user.get('emailVerified') is True and any(c.get('type') == 'password' for c in creds) and not ({'VERIFY_EMAIL','UPDATE_PASSWORD'} & set(user.get('requiredActions') or []))
pending = user.get('enabled') is True and user.get('emailVerified') is False and not creds and {'VERIFY_EMAIL','UPDATE_PASSWORD'} <= set(user.get('requiredActions') or [])
print('onboarding:', 'complete' if complete else ('pending' if pending else 'other'))
PY
}

write_report() {
  local report_dir report
  report_dir="$(artifact_dir)"
  install -d -m 755 "$report_dir"
  report="$report_dir/last-invitation-status.txt"
  {
    echo "Runbook: ADD_USER_EMAIL.md"
    echo "Timestamp UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Username: $new_login_user"
    echo "Name: $first_name $last_name"
    echo "Email: $user_email"
    echo "Server FQDN: $server_fqdn"
    echo "Realm: $realm"
    echo "Invitation lifespan seconds: 86400"
    echo "Status: invitation sent; onboarding pending until recipient confirms email and sets password"
  } >"$report"
  chmod 600 "$report"
  echo "report: $report"
}

apply() {
  validate_apply_identity
  require_arg --backup-path "$backup_path"
  preflight
  create_and_invite
  write_report
  create_checkpoint ADD_USER_EMAIL.md-invitation-sent
  status_user
  echo "apply-ok invitation sent; onboarding pending"
}

resend() {
  validate_identity_common
  require_arg --backup-path "$backup_path"
  preflight
  resend_invitation
  create_checkpoint ADD_USER_EMAIL.md-invitation-resent
  status_user
  echo "resend-ok invitation sent; onboarding pending"
}

status_cmd() {
  validate_identity_common
  preflight >/dev/null
  status_user
}

case "$cmd" in
apply) apply ;;
resend) resend ;;
status) status_cmd ;;
*)
  echo "Unknown command: $cmd" >&2
  usage >&2
  exit 64
  ;;
esac
