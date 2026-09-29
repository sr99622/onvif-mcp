#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  snapshot_runbook.sh apply --server-fqdn HOST --camera-username USER --repo-path PATH --server-user USER
  snapshot_runbook.sh status --server-fqdn HOST
  snapshot_runbook.sh test --server-fqdn HOST

Configures services/snapshot_proxy.py from docs/SNAPSHOT.md. Camera routes are
read from the MCP HTTP server and the camera password is read from `pass show camera`.
USAGE
}
cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
server_fqdn=""; camera_username=""; repo_path=""; server_user=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --camera-username) camera_username="${2:?missing --camera-username value}"; shift 2 ;;
    --repo-path) repo_path="${2:?missing --repo-path value}"; shift 2 ;;
    --server-user) server_user="${2:?missing --server-user value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
project_dir() { printf '%s/onvif-mcp' "${repo_path%/}"; }

install_packages() {
  missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v file >/dev/null 2>&1 || missing+=(file)
  command -v nginx >/dev/null 2>&1 || missing+=(nginx)
  if [[ ${#missing[@]} -gt 0 ]]; then sudo apt-get update; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; fi
}

write_env_file() {
  require_arg --server-fqdn "$server_fqdn"; require_arg --camera-username "$camera_username"
  camera_password="$(pass show camera | sed -n '1p')"; test -n "$camera_password"
  tmp="$HOME/.onvif-mcp-http.env.$$"
  umask 077
  {
    printf 'MCP_HTTP_HOST=127.0.0.1\n'
    printf 'MCP_HTTP_PORT=8001\n'
    printf 'SNAPSHOT_PROXY_HOST=127.0.0.1\n'
    printf 'SNAPSHOT_PROXY_PORT=8891\n'
    printf 'SNAPSHOT_ROUTES_FILE=/etc/onvif-mcp/snapshot_routes.json\n'
    printf 'CAMERA_USERNAME=%s\n' "$camera_username"
    printf 'CAMERA_PASSWORD=%s\n' "$camera_password"
    printf 'STREAM_SERVER_URL=http://%s\n' "$server_fqdn"
  } > "$tmp"
  sudo install -o root -g root -m 0600 "$tmp" /etc/onvif-mcp-http.env
  shred -u "$tmp"
}

write_routes() {
  require_arg --server-fqdn "$server_fqdn"
  sudo install -d -o root -g root -m 0755 /etc/onvif-mcp
  tmp="$HOME/.snapshot_routes.json.$$"
  python3 - "$server_fqdn" > "$tmp" <<'PY'
import json, sys, urllib.request
server=sys.argv[1]
def mcp_call(name, args=None):
    url=f'http://{server}/mcp'
    init={"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"snapshot-runbook","version":"1"}}}
    req=urllib.request.Request(url, data=json.dumps(init).encode(), headers={'Content-Type':'application/json','Accept':'text/event-stream, application/json'}, method='POST')
    with urllib.request.urlopen(req, timeout=60) as r:
        sid=r.headers.get('mcp-session-id'); r.read()
    try:
        note={"jsonrpc":"2.0","method":"notifications/initialized"}
        urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(note).encode(), headers={'Content-Type':'application/json','Accept':'text/event-stream, application/json','mcp-session-id':sid}, method='POST'), timeout=30).read()
    except Exception: pass
    payload={"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":name,"arguments":args or {}}}
    with urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(payload).encode(), headers={'Content-Type':'application/json','Accept':'text/event-stream, application/json','mcp-session-id':sid}, method='POST'), timeout=180) as r:
        body=r.read().decode()
    data='\n'.join(line[5:].strip() for line in body.splitlines() if line.startswith('data:'))
    return json.loads(data)['result']['content'][0]['text']
text=mcp_call('get_cameras')
routes={}
for part in text.split('\n--\n'):
    part=part.strip()
    if not part: continue
    cam=json.loads(part)
    serial=cam['serial_number']
    for prof in cam.get('profiles', []):
        uri=prof.get('snapshot_uri')
        if uri:
            routes[f'{serial}/{prof["token"]}']=uri
if not routes: raise SystemExit('No snapshot routes discovered')
print(json.dumps({'routes': routes}, indent=2, sort_keys=True))
PY
  sudo install -o root -g root -m 0644 "$tmp" /etc/onvif-mcp/snapshot_routes.json
  rm -f "$tmp"
}

write_service() {
  require_arg --repo-path "$repo_path"; require_arg --server-user "$server_user"
  dir="$(project_dir)"; test -f "$dir/services/snapshot_proxy.py"; id "$server_user" >/dev/null
  cat <<EOF | sudo tee /etc/systemd/system/snapshot-proxy.service >/dev/null
[Unit]
Description=Loopback-only camera snapshot proxy (services/snapshot_proxy.py)
Documentation=file:$dir/services/snapshot_proxy.py
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$server_user
WorkingDirectory=$dir
EnvironmentFile=/etc/onvif-mcp-http.env
ExecStart=$dir/.venv/bin/python $dir/services/snapshot_proxy.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  sudo chown root:root /etc/systemd/system/snapshot-proxy.service
  sudo chmod 0644 /etc/systemd/system/snapshot-proxy.service
  if sudo grep -n 'CAMERA_PASSWORD=' /etc/systemd/system/snapshot-proxy.service; then echo 'unit leaked CAMERA_PASSWORD' >&2; exit 1; fi
  sudo grep -n '^EnvironmentFile=/etc/onvif-mcp-http.env$' /etc/systemd/system/snapshot-proxy.service >/dev/null
  sudo systemd-analyze verify /etc/systemd/system/snapshot-proxy.service
}

ensure_nginx_location() {
  require_arg --server-fqdn "$server_fqdn"
  sudo python3 - "$server_fqdn" <<'PY'
import pathlib, re, sys
fqdn=sys.argv[1]
p=pathlib.Path('/etc/nginx/sites-available/camera')
text=p.read_text() if p.exists() else f'server {{\n    listen 80;\n    server_name {fqdn};\n}}\n'
text=re.sub(r'(?m)^\s*server_name\s+[^;]+;', f'    server_name {fqdn};', text, count=1)
if 'location /snapshot/' not in text:
    block='''

    location /snapshot/ {
        proxy_pass http://127.0.0.1:8891/snapshot/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
        proxy_no_cache on;
        proxy_cache_bypass on;
    }
'''
    idx=text.rfind('}')
    if idx == -1: raise SystemExit('No closing brace in nginx camera site')
    text=text[:idx]+block+text[idx:]
p.write_text(text)
PY
  sudo ln -sfn /etc/nginx/sites-available/camera /etc/nginx/sites-enabled/camera
  sudo nginx -t
  sudo systemctl reload nginx
}

start_service() { sudo systemctl daemon-reload; sudo systemctl enable --now snapshot-proxy; sudo systemctl restart snapshot-proxy; systemctl is-active snapshot-proxy; }

print_status() {
  echo '== service =='; systemctl is-enabled snapshot-proxy 2>/dev/null || true; systemctl is-active snapshot-proxy 2>/dev/null || true; systemctl status snapshot-proxy --no-pager -l 2>/dev/null | sed -n '1,18p' || true
  echo '== files =='; sudo stat -c '%a %U:%G %n' /etc/systemd/system/snapshot-proxy.service /etc/onvif-mcp-http.env /etc/onvif-mcp/snapshot_routes.json 2>/dev/null || true
  echo '== listener =='; ss -ltnp 2>/dev/null | grep ':8891' || true
  echo '== route count =='; sudo python3 -c 'import json; print(len(json.load(open("/etc/onvif-mcp/snapshot_routes.json"))["routes"]))' 2>/dev/null || true
  echo '== recent logs =='; sudo journalctl -u snapshot-proxy -n 30 --no-pager || true
}

test_snapshots() {
  require_arg --server-fqdn "$server_fqdn"
  python3 - "$server_fqdn" <<'PY'
import json, os, subprocess, sys, tempfile
server=sys.argv[1]
routes=json.load(open('/etc/onvif-mcp/snapshot_routes.json'))['routes']
failed=0
with tempfile.TemporaryDirectory(prefix='snapshot-test-', dir=os.path.expanduser('~')) as d:
    for route in routes:
        out=os.path.join(d, route.replace('/','_')+'.jpg')
        url=f'http://{server}/snapshot/{route}/'
        c=subprocess.run(['curl','-s','--max-time','35','-o',out,'-w','%{http_code} %{content_type}',url], text=True, capture_output=True, timeout=40)
        kind=subprocess.run(['file','-b',out], text=True, capture_output=True).stdout.strip() if os.path.exists(out) else ''
        ok=c.stdout.startswith('200 image/jpeg') and kind.startswith('JPEG image data')
        print(f'{route} {c.stdout} {kind[:60]}')
        failed += 0 if ok else 1
raise SystemExit(failed)
PY
}

case "$cmd" in
  apply)
    require_arg --server-fqdn "$server_fqdn"; require_arg --camera-username "$camera_username"; require_arg --repo-path "$repo_path"; require_arg --server-user "$server_user"
    install_packages; write_env_file; write_routes; write_service; ensure_nginx_location; start_service; print_status ;;
  status) print_status ;;
  test) test_snapshots ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
