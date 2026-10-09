#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  stream_auth_runbook.sh apply --server-fqdn HOST --server-ip IP --backup-path PATH [--repo-path PATH]
  stream_auth_runbook.sh status --server-fqdn HOST [--server-ip IP]

Implements docs/STREAM_AUTH.md executable actions. Site-specific values are passed as arguments.
Secrets are generated/read only inside root-controlled processes and are never printed.
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
server_fqdn=""
server_ip=""
backup_path=""
repo_path="$HOME/onvif-mcp"
realm="mcp"
login_user="mcp-user"
browser_client_id="camera-web"
compose_dir="/opt/keycloak"
nginx_site=""
snapshot_path=""
hermes_name="camera"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --server-fqdn)
    server_fqdn="${2:?missing --server-fqdn value}"
    shift 2
    ;;
  --server-ip)
    server_ip="${2:?missing --server-ip value}"
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
  --login-user)
    login_user="${2:?missing --login-user value}"
    shift 2
    ;;
  --browser-client-id)
    browser_client_id="${2:?missing --browser-client-id value}"
    shift 2
    ;;
  --snapshot-path)
    snapshot_path="${2:?missing --snapshot-path value}"
    shift 2
    ;;
  --hermes-name)
    hermes_name="${2:?missing --hermes-name value}"
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
project_dir() { printf '%s' "${repo_path%/}"; }
origin() { printf 'https://%s' "$server_fqdn"; }
issuer() { printf 'https://%s/auth/realms/%s' "$server_fqdn" "$realm"; }
resource_url() { printf 'https://%s/mcp' "$server_fqdn"; }

resolve_nginx_site() {
  nginx_site="/etc/nginx/conf.d/$server_fqdn.conf"
  sudo test -s "$nginx_site"
}

admin_token_to_file() {
  local outfile="$1"
  sudo python3 - "$outfile" <<'PY'
import json, pathlib, sys, urllib.parse, urllib.request
out = pathlib.Path(sys.argv[1])
password = pathlib.Path('/opt/keycloak/admin.pass').read_text().strip()
data = urllib.parse.urlencode({
    'grant_type': 'password',
    'client_id': 'admin-cli',
    'username': 'keycloak-admin',
    'password': password,
}).encode()
req = urllib.request.Request('http://127.0.0.1:8080/auth/realms/master/protocol/openid-connect/token', data=data)
with urllib.request.urlopen(req) as r:
    token = json.load(r)['access_token']
out.write_text(token)
out.chmod(0o600)
PY
}

preflight() {
  require_arg --server-fqdn "$server_fqdn"
  require_arg --server-ip "$server_ip"
  resolve_nginx_site
  sudo docker compose --project-directory "$compose_dir" ps
  sudo systemctl is-active nginx mediamtx onvif-mcp-http.service snapshot-proxy.service >/dev/null
  if sudo ss -ltnp | grep -E '127\.0\.0\.1:4180\b' >/dev/null && ! sudo docker compose --project-directory "$compose_dir" ps oauth2-proxy 2>/dev/null | grep -q 'Up'; then
    echo "port 4180 is occupied by a non-compose oauth2-proxy process" >&2
    exit 1
  fi
  sudo ss -ltnp | grep -E '127\.0\.0\.1:8080\b' >/dev/null
  sudo ss -ltnp | grep -E '127\.0\.0\.1:8001\b' >/dev/null
  sudo ss -ltnp | grep -E '127\.0\.0\.1:8889\b' >/dev/null
  sudo ss -ltnp | grep -E '127\.0\.0\.1:9996\b' >/dev/null
  sudo ss -ltnp | grep -E '127\.0\.0\.1:8891\b' >/dev/null
  sudo stat -c '%A %U %G %n' "$compose_dir" "$compose_dir/.env" "$compose_dir/compose.yaml"
  sudo docker compose --project-directory "$compose_dir" config --services >/tmp/stream-auth-services.txt
  sudo nginx -t
  sudo grep -F "server_name $server_fqdn" "$nginx_site" >/dev/null
  sudo grep -F 'listen 443 ssl;' "$nginx_site" >/dev/null
  curl --fail --silent --show-error --max-time 65 "http://127.0.0.1:8891${snapshot_path}" -o /tmp/stream-auth-preflight-snapshot.jpg -w 'Snapshot upstream: HTTP %{http_code} type=%{content_type}\n'
  python3 - <<'PY'
from pathlib import Path
p=Path('/tmp/stream-auth-preflight-snapshot.jpg')
b=p.read_bytes()
assert b.startswith(bytes.fromhex('ffd8ff')) and len(b) > 1000
print('snapshot-jpeg-ok', len(b))
PY
  rm -f /tmp/stream-auth-preflight-snapshot.jpg
}

prepare_user_and_client() {
  local tokfile
  tokfile="$(mktemp "${TMPDIR:-/tmp}/kc-token.XXXXXX")"
  admin_token_to_file "$tokfile"
  sudo python3 - "$tokfile" "$server_fqdn" "$realm" "$login_user" "$browser_client_id" <<'PY'
import json, pathlib, sys, urllib.parse, urllib.request, urllib.error
_tok, fqdn, realm, login_user, client_id = sys.argv[1:]
token = pathlib.Path(_tok).read_text().strip()
base = 'http://127.0.0.1:8080/auth/admin'

def req(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    r = urllib.request.Request(base + path, data=body, method=method,
        headers={'Authorization': 'Bearer '+token, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None), resp.headers
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors='replace')[:500]
        raise SystemExit(f'Admin REST {method} {path} failed HTTP {e.code}: {detail}')

st, users, _ = req('GET', f'/realms/{realm}/users?username={urllib.parse.quote(login_user)}')
exact = [u for u in users if u.get('username') == login_user]
if len(exact) != 1:
    raise SystemExit(f'expected one exact login user {login_user}, got {len(exact)}')
uid = exact[0]['id']
st, user, _ = req('GET', f'/realms/{realm}/users/{uid}')
if not user.get('enabled') or not user.get('email') or not user.get('emailVerified') or user.get('requiredActions'):
    raise SystemExit('login user is not enabled with verified email and no required actions')

st, clients, _ = req('GET', f'/realms/{realm}/clients?clientId={urllib.parse.quote(client_id)}')
exact_clients = [c for c in clients if c.get('clientId') == client_id]
if len(exact_clients) == 0:
    payload = {
        'clientId': client_id,
        'enabled': True,
        'publicClient': False,
        'clientAuthenticatorType': 'client-secret',
        'standardFlowEnabled': True,
        'implicitFlowEnabled': False,
        'directAccessGrantsEnabled': False,
        'serviceAccountsEnabled': False,
        'authorizationServicesEnabled': False,
        'consentRequired': False,
        'baseUrl': f'https://{fqdn}/',
        'attributes': {
            'frontend_url': f'https://{fqdn}/cameras/',
            'post.logout.redirect.uris': f'https://{fqdn}/cameras/',
            'pkce.code.challenge.method': 'S256',
        },
        'redirectUris': [f'https://{fqdn}/oauth2/callback'],
        'webOrigins': [f'https://{fqdn}'],
    }
    req('POST', f'/realms/{realm}/clients', payload)
    st, clients, _ = req('GET', f'/realms/{realm}/clients?clientId={urllib.parse.quote(client_id)}')
    exact_clients = [c for c in clients if c.get('clientId') == client_id]
if len(exact_clients) != 1:
    raise SystemExit(f'expected one exact client {client_id}, got {len(exact_clients)}')
internal = exact_clients[0]['id']
st, c, _ = req('GET', f'/realms/{realm}/clients/{internal}')
checks = [
    c.get('enabled') is True,
    c.get('publicClient') is False,
    c.get('standardFlowEnabled') is True,
    c.get('implicitFlowEnabled', False) is False,
    c.get('directAccessGrantsEnabled', False) is False,
    c.get('serviceAccountsEnabled', False) is False,
    c.get('consentRequired', False) is False,
    f'https://{fqdn}/oauth2/callback' in c.get('redirectUris', []),
    f'https://{fqdn}' in c.get('webOrigins', []),
    c.get('attributes', {}).get('pkce.code.challenge.method') == 'S256',
]
if not all(checks):
    raise SystemExit('browser client verification failed')
print('keycloak-client-ok', client_id)
PY
  rm -f "$tokfile"
}

store_oauth2_secrets() {
  local tokfile
  tokfile="$(mktemp "${TMPDIR:-/tmp}/kc-token.XXXXXX")"
  admin_token_to_file "$tokfile"
  sudo python3 - "$tokfile" "$realm" "$browser_client_id" <<'PY'
import base64, json, os, pathlib, secrets, sys, urllib.parse, urllib.request, urllib.error
_tok, realm, client_id = sys.argv[1:]
token = pathlib.Path(_tok).read_text().strip()
env = pathlib.Path('/opt/keycloak/.env')
backup = pathlib.Path('/opt/keycloak/.env.pre-oauth2-proxy')
if not backup.exists():
    backup.write_bytes(env.read_bytes()); os.chmod(backup, 0o600)
base = 'http://127.0.0.1:8080/auth/admin'
def req(path):
    r=urllib.request.Request(base+path, headers={'Authorization':'Bearer '+token})
    with urllib.request.urlopen(r) as resp: return json.load(resp)
clients=req(f'/realms/{realm}/clients?clientId={urllib.parse.quote(client_id)}')
exact=[c for c in clients if c.get('clientId')==client_id]
if len(exact)!=1: raise SystemExit('browser client missing for secret retrieval')
secret=req(f'/realms/{realm}/clients/{exact[0]["id"]}/client-secret').get('value')
if not secret: raise SystemExit('empty live client secret')
lines=env.read_text().splitlines()
kv={}
for line in lines:
    if '=' in line:
        k,v=line.split('=',1); kv.setdefault(k,[]).append(v)
for k in ['OAUTH2_PROXY_CLIENT_SECRET','OAUTH2_PROXY_COOKIE_SECRET']:
    if len(kv.get(k,[]))>1: raise SystemExit(f'duplicate {k}')
changed=False
if not kv.get('OAUTH2_PROXY_CLIENT_SECRET'):
    lines.append('OAUTH2_PROXY_CLIENT_SECRET='+secret); changed=True
elif kv['OAUTH2_PROXY_CLIENT_SECRET'][0] != secret:
    raise SystemExit('stored oauth2 client secret does not match live Keycloak secret')
if not kv.get('OAUTH2_PROXY_COOKIE_SECRET'):
    cookie=base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip('=')
    lines.append('OAUTH2_PROXY_COOKIE_SECRET='+cookie); changed=True
else:
    padded=kv['OAUTH2_PROXY_COOKIE_SECRET'][0] + '='*((4-len(kv['OAUTH2_PROXY_COOKIE_SECRET'][0])%4)%4)
    if len(base64.urlsafe_b64decode(padded)) != 32:
        raise SystemExit('cookie secret does not decode to 32 bytes')
if changed:
    env.write_text('\n'.join(lines)+'\n')
os.chmod(env,0o600)
print('oauth2-secret-store-ok')
PY
  sudo test "$(sudo stat -c '%a %U %G' "$compose_dir/.env")" = '600 root root'
  rm -f "$tokfile"
}

configure_compose() {
  sudo cp --update=none "$compose_dir/compose.yaml" "$compose_dir/compose.yaml.pre-oauth2-proxy" || true
  sudo python3 - "$server_fqdn" "$browser_client_id" <<'PY'
from pathlib import Path
import sys
fqdn, client_id = sys.argv[1:]
p=Path('/opt/keycloak/compose.yaml')
s=p.read_text()
if '  oauth2-proxy:' not in s:
    marker='volumes:\n  keycloak_postgres_data:\n'
    service=f'''
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.15.3
    command:
      - --provider-ca-file=/etc/oauth2-proxy/private-root-ca.crt.pem
      - --use-system-trust-store=true
    restart: unless-stopped
    depends_on:
      - keycloak
    environment:
      OAUTH2_PROXY_PROVIDER: keycloak-oidc
      OAUTH2_PROXY_CLIENT_ID: {client_id}
      OAUTH2_PROXY_CLIENT_SECRET: ${{OAUTH2_PROXY_CLIENT_SECRET}}
      OAUTH2_PROXY_COOKIE_SECRET: ${{OAUTH2_PROXY_COOKIE_SECRET}}
      OAUTH2_PROXY_OIDC_ISSUER_URL: https://{fqdn}/auth/realms/mcp
      OAUTH2_PROXY_REDIRECT_URL: https://{fqdn}/oauth2/callback
      OAUTH2_PROXY_HTTP_ADDRESS: 0.0.0.0:4180
      OAUTH2_PROXY_UPSTREAMS: static://202
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      OAUTH2_PROXY_SCOPE: "openid profile email"
      OAUTH2_PROXY_CODE_CHALLENGE_METHOD: S256
      OAUTH2_PROXY_REVERSE_PROXY: "true"
      OAUTH2_PROXY_SET_XAUTHREQUEST: "true"
      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: "true"
      OAUTH2_PROXY_COOKIE_NAME: _camera_auth
      OAUTH2_PROXY_COOKIE_SECURE: "true"
      OAUTH2_PROXY_COOKIE_SAMESITE: lax
      OAUTH2_PROXY_COOKIE_EXPIRE: 8h
      OAUTH2_PROXY_COOKIE_REFRESH: 4m
    volumes:
      - /etc/nginx/tls/camera-system-root-ca.crt.pem:/etc/oauth2-proxy/private-root-ca.crt.pem:ro
    ports:
      - "127.0.0.1:4180:4180"

'''
    if marker not in s: raise SystemExit('compose volumes marker not found')
    s=s.replace(marker, service+marker)
    p.write_text(s)
PY
  sudo docker compose --project-directory "$compose_dir" config --quiet
  sudo docker compose --project-directory "$compose_dir" config --services | grep -Fx oauth2-proxy >/dev/null
  sudo docker compose --project-directory "$compose_dir" pull oauth2-proxy
  sudo docker compose --project-directory "$compose_dir" up -d oauth2-proxy
  for _ in $(seq 1 30); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:4180/ping || true)"
    [[ "$code" == 200 ]] && break
    sleep 1
  done
  curl -sS -o /dev/null -w 'Ping: HTTP %{http_code}\n' http://127.0.0.1:4180/ping | grep -F 'HTTP 200'
  curl -sS -D /tmp/oauth2-auth.headers -o /dev/null -H "Host: $server_fqdn" -H 'X-Forwarded-Proto: https' http://127.0.0.1:4180/oauth2/auth || true
  grep -E '^HTTP/.* 401' /tmp/oauth2-auth.headers >/dev/null
  sudo ss -ltnp | grep -E '127\.0\.0\.1:4180\b' >/dev/null
}

configure_nginx() {
  resolve_nginx_site
  sudo cp --update=none "$nginx_site" "$compose_dir/$server_fqdn.conf.pre-stream-auth" || true
  sudo cmp -s "$nginx_site" "$compose_dir/$server_fqdn.conf.pre-stream-auth" || true
  sudo python3 - "$nginx_site" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text()
oauth='''
    location = /oauth2/auth {
        proxy_pass http://127.0.0.1:4180;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Uri $request_uri;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /oauth2/ {
        proxy_pass http://127.0.0.1:4180;
        proxy_http_version 1.1;
        proxy_buffer_size 32k;
        proxy_buffers 8 32k;
        proxy_busy_buffers_size 64k;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location @oauth2_signin {
        return 302 /oauth2/start?rd=$request_uri;
    }

'''
if 'location = /oauth2/auth' not in s:
    anchor='    location /cameras/ {'
    if anchor not in s: raise SystemExit('location /cameras/ anchor not found')
    s=s.replace(anchor, oauth+anchor, 1)

auth='''        auth_request /oauth2/auth;
        error_page 401 = @oauth2_signin;
        auth_request_set $auth_cookie $upstream_http_set_cookie;
        add_header Set-Cookie $auth_cookie always;
'''

def protect_block(text, pattern, transform=None):
    m=re.search(pattern, text, re.S)
    if not m: raise SystemExit(f'block not found: {pattern}')
    block=m.group(0)
    if transform:
        block=transform(block)
    if 'auth_request /oauth2/auth;' not in block:
        insert=block.find('{')+1
        block=block[:insert]+'\n'+auth+block[insert:]
    return text[:m.start()]+block+text[m.end():]

def no_return_404(block):
    return block.replace('return 404;', 'try_files "" =404;')

def playback(block):
    return block

def cache(block):
    return block

patterns=[
 r'    location /cameras/ \{.*?\n    \}',
 r'    location /multiview/ \{.*?\n    \}',
 r'    location = /outputs/camera_registry\.json \{.*?\n    \}',
 r'    location /outputs/ \{.*?\n    \}',
 r'    location /webrtc/ \{.*?\n    \}',
 r'    location /snapshot/ \{.*?\n    \}',
 r'    location /playback/ \{.*?\n    \}',
 r'    location /playback-cache/ \{.*?\n    \}',
]
for pat in patterns:
    s=protect_block(s, pat, no_return_404 if 'outputs/' in pat else None)
p.write_text(s)
PY
  sudo nginx -t
  sudo systemctl reload nginx
  sudo systemctl is-active nginx >/dev/null
  sudo grep -F 'STREAM_SERVER_URL=https://'$server_fqdn /etc/onvif-mcp-http.env >/dev/null || true
}

verify_unauth() {
  # Playback test paths derive from the resolved --snapshot-path route; no
  # site-specific camera IDs or dates are hardcoded in this script.
  local route="${snapshot_path#/snapshot/}"
  local enc_route="${route//\//%2F}"
  local start
  start="$(date -u -d 'yesterday' +%Y-%m-%dT09:00:00Z)"
  local paths=(/cameras/ /multiview/ /outputs/ /webrtc/ /playback/ "/playback/list?path=${enc_route}" "/playback/get?path=${enc_route}&start=${start}&duration=60&format=mp4" /playback-cache/ /snapshot/ "$snapshot_path")
  for path in "${paths[@]}"; do
    out="$(curl -sS -o /dev/null -w "%{http_code} %{redirect_url}" "https://$server_fqdn${path}")"
    echo "$path HTTP $out"
    [[ "$out" == 302*oauth2/start* ]] || {
      echo "expected login redirect for $path" >&2
      exit 1
    }
  done
  out="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "http://$server_fqdn${snapshot_path}")"
  echo "Snapshot HTTP: $out"
  [[ "$out" == 301*"https://$server_fqdn${snapshot_path}"* || "$out" == 302*"https://$server_fqdn${snapshot_path}"* ]] || {
    echo "HTTP snapshot did not redirect to HTTPS" >&2
    exit 1
  }
  curl -sS -o /dev/null -w 'start: HTTP %{http_code} redirect=%{redirect_url}\n' "https://$server_fqdn/oauth2/start?rd=/cameras/" | grep -E 'HTTP 302 redirect=.*/auth/realms/.*/protocol/openid-connect/auth' >/dev/null
  curl -sS -o /dev/null -w 'discovery: HTTP %{http_code}\n' "$(issuer)/.well-known/openid-configuration" | grep -F 'HTTP 200'
  curl -sS -D /tmp/stream-auth-mcp.headers -o /dev/null "$(resource_url)"
  grep -E '^HTTP/.* 401' /tmp/stream-auth-mcp.headers >/dev/null
}

verify_browser() {
  "$(project_dir)/.venv/bin/python3" "$(project_dir)/scripts/stream_auth_step9_driver.py" --origin "$(origin)" --snapshot-path "$snapshot_path" --webrtc-url "/webrtc${snapshot_path#/snapshot}"
  hermes mcp test "$hermes_name"
}

checkpoints() {
  local kc
  kc="$($(project_dir)/scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh create-checkpoint --backup-path "$backup_path" --trigger STREAM_AUTH.md --host-unit-checkpoint not-recorded | tee /tmp/stream-auth-kc-checkpoint.out | awk '/create-checkpoint-ok/{print $2}')"
  [[ -n "$kc" ]]
  "$(project_dir)/scripts/NGINX_BACKUP/nginx_backup_runbook.sh" create-checkpoint --server-fqdn "$server_fqdn" --backup-path "$backup_path" --trigger STREAM_AUTH.md --compatible-keycloak-checkpoint "$kc"
}

apply() {
  require_arg --server-fqdn "$server_fqdn"
  require_arg --server-ip "$server_ip"
  require_arg --backup-path "$backup_path"
  require_arg --repo-path "$repo_path"
  preflight
  prepare_user_and_client
  store_oauth2_secrets
  configure_compose
  configure_nginx
  verify_unauth
  verify_browser
  check_paths_before="$(find "${backup_path%/}/keycloak" "${backup_path%/}/nginx" -maxdepth 1 -mindepth 1 -type d -printf '%p\n' 2>/dev/null | sort | tail -n 4 || true)"
  checkp_out="$($(project_dir)/scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh create-checkpoint --backup-path "$backup_path" --trigger STREAM_AUTH.md --host-unit-checkpoint not-recorded | tee /tmp/stream-auth-keycloak-checkpoint.out)"
  keycloak_checkpoint="$(printf '%s\n' "$checkp_out" | awk '/create-checkpoint-ok/{print $2}')"
  [[ -n "$keycloak_checkpoint" ]]
  nginx_out="$($(project_dir)/scripts/NGINX_BACKUP/nginx_backup_runbook.sh create-checkpoint --server-fqdn "$server_fqdn" --backup-path "$backup_path" --trigger STREAM_AUTH.md --compatible-keycloak-checkpoint "$keycloak_checkpoint" | tee /tmp/stream-auth-nginx-checkpoint.out)"
  nginx_checkpoint="$(printf '%s\n' "$nginx_out" | awk '/create-checkpoint-ok/{print $2}')"
  echo "$checkp_out"
  echo "$nginx_out"
  echo "apply-ok stream-auth keycloak_checkpoint=$keycloak_checkpoint nginx_checkpoint=$nginx_checkpoint"
}

status() {
  require_arg --server-fqdn "$server_fqdn"
  systemctl is-active nginx mediamtx onvif-mcp-http.service snapshot-proxy.service || true
  sudo docker compose --project-directory "$compose_dir" ps || true
  curl -sS -o /dev/null -w 'oauth2 ping: HTTP %{http_code}\n' http://127.0.0.1:4180/ping || true
  curl -sS -o /dev/null -w 'cameras unauth: HTTP %{http_code} redirect=%{redirect_url}\n' "https://$server_fqdn/cameras/" || true
  curl -sS -D - -o /dev/null "$(resource_url)" | sed -n '1,8p' || true
}

case "$cmd" in
apply) apply ;;
status) status ;;
*)
  echo "Unknown command: $cmd" >&2
  usage >&2
  exit 64
  ;;
esac
