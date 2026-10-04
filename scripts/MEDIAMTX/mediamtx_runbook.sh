#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  mediamtx_runbook.sh apply --server-fqdn HOST --camera-username USER --repo-path PATH
  mediamtx_runbook.sh status --server-fqdn HOST
  mediamtx_runbook.sh test --server-fqdn HOST

Configures MediaMTX from docs/MEDIAMTX.md. Camera data is read from the MCP HTTP
server and the camera password is read from `pass show camera`.
USAGE
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then usage; exit 64; fi
if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then usage; exit 0; fi
shift || true

server_fqdn=""
camera_username=""
repo_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --camera-username) camera_username="${2:?missing --camera-username value}"; shift 2 ;;
    --repo-path) repo_path="${2:?missing --repo-path value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }

install_packages() {
  missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v nginx >/dev/null 2>&1 || missing+=(nginx)
  if [[ ${#missing[@]} -gt 0 ]]; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

install_mediamtx_binary() {
  if command -v mediamtx >/dev/null 2>&1; then
    return
  fi
  work="$HOME/.mediamtx-install.$$"
  mkdir -p "$work"
  python3 - "$work/url.txt" <<'PY'
import json, sys, urllib.request
api='https://api.github.com/repos/bluenviron/mediamtx/releases/latest'
with urllib.request.urlopen(api, timeout=30) as r:
    data=json.load(r)
for asset in data.get('assets', []):
    url=asset.get('browser_download_url','')
    if url.endswith('_linux_amd64.tar.gz'):
        open(sys.argv[1], 'w').write(url)
        print(url)
        break
else:
    raise SystemExit('No linux_amd64 MediaMTX asset found')
PY
  url="$(cat "$work/url.txt")"
  curl -fsSL "$url" -o "$work/mediamtx.tar.gz"
  tar -xzf "$work/mediamtx.tar.gz" -C "$work" mediamtx
  sudo install -o root -g root -m 0755 "$work/mediamtx" /usr/local/bin/mediamtx
  rm -rf "$work"
}

ensure_user_dirs() {
  if ! getent group mediamtx >/dev/null; then sudo groupadd --system mediamtx; fi
  if ! getent passwd mediamtx >/dev/null; then sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g mediamtx mediamtx; fi
  sudo install -d -o mediamtx -g mediamtx -m 0750 /etc/mediamtx /var/log/mediamtx /var/lib/mediamtx /var/lib/mediamtx/recordings
}

write_config() {
  require_arg --server-fqdn "$server_fqdn"
  require_arg --camera-username "$camera_username"
  camera_password="$(pass show camera | sed -n '1p')"
  test -n "$camera_password"
  tmp="$HOME/.mediamtx.yml.$$"
  python3 - "$server_fqdn" "$camera_username" "$camera_password" > "$tmp" <<'PY'
import json, os, sys, urllib.parse, urllib.request
server, username, password = sys.argv[1:4]

# OAuth bearer token from the Hermes MCP token file (never printed).
token_path = os.path.expanduser('~/.hermes/mcp-tokens/camera.json')
bearer = ''
if os.path.exists(token_path):
    with open(token_path) as f:
        bearer = json.load(f).get('access_token', '')

def hdrs(sid=None):
    h = {'Content-Type':'application/json','Accept':'text/event-stream, application/json'}
    if sid: h['mcp-session-id'] = sid
    if bearer: h['Authorization'] = f'Bearer {bearer}'
    return h

def mcp_call(name, args=None):
    url=f'https://{server}/mcp'
    init={"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mediamtx-runbook","version":"1"}}}
    req=urllib.request.Request(url, data=json.dumps(init).encode(), headers=hdrs(), method='POST')
    with urllib.request.urlopen(req, timeout=60) as r:
        sid=r.headers.get('mcp-session-id')
        r.read()
    note={"jsonrpc":"2.0","method":"notifications/initialized"}
    try:
        urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(note).encode(), headers=hdrs(sid), method='POST'), timeout=30).read()
    except Exception:
        pass
    payload={"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":name,"arguments":args or {}}}
    req=urllib.request.Request(url, data=json.dumps(payload).encode(), headers=hdrs(sid), method='POST')
    with urllib.request.urlopen(req, timeout=180) as r:
        body=r.read().decode()
    data='\n'.join(line[5:].strip() for line in body.splitlines() if line.startswith('data:'))
    return json.loads(data)['result']['content'][0]['text']

def get_cameras():
    text=mcp_call('get_cameras')
    cams=[]
    for part in text.split('\n--\n'):
        part=part.strip()
        if part:
            cams.append(json.loads(part))
    return cams

cams=get_cameras()
if not cams:
    raise SystemExit('get_cameras returned no cameras')
enc=urllib.parse.quote(password, safe='')
print('logLevel: info')
print('logDestinations: [stdout]')
print('rtsp: true')
print('rtspTransports: [tcp]')
print('rtspAddress: 127.0.0.1:8554')
print('webrtc: true')
print('webrtcAddress: 127.0.0.1:8889')
print('webrtcLocalUDPAddress: :8189')
print('playback: true')
print('playbackAddress: 127.0.0.1:9996')
print('rtmp: false')
print('hls: false')
print('srt: false')
print('moq: false')
print('api: false')
print('authMethod: internal')
print('authInternalUsers:')
print('  - user: any')
print('    pass: ""')
print('    ips: []')
print('    permissions:')
for action in ('publish','read','playback'):
    print(f'      - action: {action}')
    print('        path: ""')
print('pathDefaults:')
print('  record: false')
print('  recordPath: /var/lib/mediamtx/recordings/%path/%Y-%m-%d_%H-%M-%S-%f')
print('  recordFormat: fmp4')
print('  recordPartDuration: 1s')
print('  recordMaxPartSize: 50M')
print('  recordSegmentDuration: 1h')
print('  recordDeleteAfter: 3d')
print('paths:')
count=0
for cam in cams:
    serial=cam['serial_number']
    for i, prof in enumerate(cam.get('profiles', [])):
        token=prof['token']
        stream=prof.get('stream_uri')
        if not stream:
            continue
        if not stream.startswith('rtsp://'):
            raise SystemExit(f'Unexpected stream URI for {serial}/{token}: {stream}')
        source='rtsp://' + username + ':' + enc + '@' + stream[len('rtsp://'):]
        print(f'  {json.dumps(serial + "/" + token)}:')
        print(f'    source: {json.dumps(source)}')
        if i == 0:
            print('    record: true')
        count += 1
print(f'# generated_path_count: {count}')
PY
  sudo install -o mediamtx -g mediamtx -m 0640 "$tmp" /etc/mediamtx/mediamtx.yml
  shred -u "$tmp"
  sudo test -s /etc/mediamtx/mediamtx.yml
}

write_service() {
  cat <<'EOF' | sudo tee /etc/systemd/system/mediamtx.service >/dev/null
[Unit]
Description=MediaMTX RTSP-to-WebRTC streaming server
Documentation=https://github.com/bluenviron/mediamtx
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mediamtx
Group=mediamtx
WorkingDirectory=/var/lib/mediamtx
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mediamtx
ReadWritePaths=/var/log/mediamtx /var/lib/mediamtx

[Install]
WantedBy=multi-user.target
EOF
  sudo chown root:root /etc/systemd/system/mediamtx.service
  sudo chmod 0644 /etc/systemd/system/mediamtx.service
  sudo systemd-analyze verify /etc/systemd/system/mediamtx.service
}

ensure_nginx_locations() {
  require_arg --server-fqdn "$server_fqdn"
  sudo install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled /srv/camera-playback-cache
  if [[ ! -f /etc/nginx/sites-available/camera ]]; then
    printf 'server {\n    listen 80;\n    server_name %s;\n}\n' "$server_fqdn" | sudo tee /etc/nginx/sites-available/camera >/dev/null
  fi
  sudo python3 - "$server_fqdn" <<'PY'
import pathlib, re, sys
fqdn=sys.argv[1]
p=pathlib.Path('/etc/nginx/sites-available/camera')
text=p.read_text()
text=re.sub(r'(?m)^\s*server_name\s+[^;]+;', f'    server_name {fqdn};', text, count=1)
blocks=[]
if 'location /webrtc/' not in text:
    blocks.append('''

    location /webrtc/ {
        proxy_pass http://127.0.0.1:8889/;
        proxy_redirect / /webrtc/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
''')
if 'location = /playback' not in text:
    blocks.append('''

    location = /playback {
        return 301 /playback/;
    }

    location /playback/ {
        proxy_pass http://127.0.0.1:9996/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /playback-cache/ {
        alias /srv/camera-playback-cache/;
        add_header Accept-Ranges bytes always;
    }
''')
if 'MediaMTX server at' not in text and 'location = / {' not in text:
    blocks.append(f'''

    location = / {{
        return 200 "MediaMTX server at {fqdn}\n";
        add_header Content-Type text/plain;
    }}
''')
if blocks:
    idx=text.rfind('}')
    if idx == -1: raise SystemExit('No closing brace in nginx camera site')
    text=text[:idx]+''.join(blocks)+text[idx:]
p.write_text(text)
PY
  sudo ln -sfn /etc/nginx/sites-available/camera /etc/nginx/sites-enabled/camera
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t
  sudo systemctl enable --now nginx
  sudo systemctl reload nginx
}

start_service() {
  sudo systemctl daemon-reload
  sudo systemctl enable --now mediamtx
  sudo systemctl restart mediamtx
  systemctl is-active mediamtx
}

print_status() {
  echo '== mediamtx binary =='
  command -v mediamtx && mediamtx --version || true
  echo '== service =='
  systemctl is-enabled mediamtx 2>/dev/null || true
  systemctl is-active mediamtx 2>/dev/null || true
  systemctl status mediamtx --no-pager -l 2>/dev/null | sed -n '1,20p' || true
  echo '== files =='
  sudo stat -c '%a %U:%G %n' /etc/mediamtx /etc/mediamtx/mediamtx.yml /etc/systemd/system/mediamtx.service 2>/dev/null || true
  echo '== listeners =='
  ss -ltnup 2>/dev/null | grep -E ':(8554|8889|8189|9996)\b' || true
  echo '== paths =='
  sudo grep -c '^  ".*/.*":' /etc/mediamtx/mediamtx.yml 2>/dev/null || true
  echo '== recent logs =='
  sudo journalctl -u mediamtx -n 40 --no-pager || true
}

test_webrtc() {
  require_arg --server-fqdn "$server_fqdn"
  first_path="$(sudo python3 - <<'PY'
import re
for line in open('/etc/mediamtx/mediamtx.yml'):
    m=re.match(r'^  "([^"]+/[^"]+)":', line)
    if m:
        print(m.group(1)); break
PY
)"
  test -n "$first_path"
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://$server_fqdn/webrtc/$first_path/")"
  echo "webrtc_path=$first_path http_code=$code"
  [[ "$code" =~ ^(200|301|302)$ ]]
}

case "$cmd" in
  apply)
    require_arg --server-fqdn "$server_fqdn"; require_arg --camera-username "$camera_username"; require_arg --repo-path "$repo_path"
    install_packages
    install_mediamtx_binary
    ensure_user_dirs
    write_config
    write_service
    ensure_nginx_locations
    start_service
    print_status
    ;;
  status)
    print_status
    ;;
  test)
    test_webrtc
    ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
