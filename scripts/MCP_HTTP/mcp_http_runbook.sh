#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  mcp_http_runbook.sh apply --server-fqdn HOST --camera-username USER --repo-path PATH --server-user USER
  mcp_http_runbook.sh status --server-fqdn HOST --repo-path PATH
  mcp_http_runbook.sh test --server-fqdn HOST
  mcp_http_runbook.sh configure-hermes --server-fqdn HOST

Configures the ONVIF MCP HTTP service from docs/MCP_HTTP.md.
Site-specific values are passed as arguments; do not edit this script per site.
The camera password is read from `pass show camera` and is never accepted as an argument.
USAGE
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage
  exit 64
fi
if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

server_fqdn=""
camera_username=""
repo_path=""
server_user=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --server-fqdn)
    server_fqdn="${2:?missing --server-fqdn value}"
    shift 2
    ;;
  --camera-username)
    camera_username="${2:?missing --camera-username value}"
    shift 2
    ;;
  --repo-path)
    repo_path="${2:?missing --repo-path value}"
    shift 2
    ;;
  --server-user)
    server_user="${2:?missing --server-user value}"
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
  if [[ -z "$value" ]]; then
    echo "Missing required argument: $name" >&2
    exit 64
  fi
}

project_dir() {
  printf '%s' "${repo_path%/}"
}

install_packages() {
  missing=()
  command -v nginx >/dev/null 2>&1 || missing+=(nginx)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  if [[ ${#missing[@]} -gt 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    else
      printf 'Missing required packages: %s\n' "${missing[*]}" >&2
      exit 1
    fi
  fi
}

ensure_uv() {
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv is required but was not found in PATH." >&2
    exit 1
  fi
}

sync_venv() {
  local dir="$1"
  test -d "$dir"
  cd "$dir"
  uv sync --all-packages
  test -x "$dir/.venv/bin/onvif-mcp-http"
}

write_env_file() {
  require_arg --camera-username "$camera_username"
  require_arg --server-fqdn "$server_fqdn"
  local camera_password
  camera_password="$(pass show camera | sed -n '1p')"
  test -n "$camera_password"
  umask 077
  env_file="$HOME/.onvif-mcp-http.env.$$"
  {
    printf 'MCP_HTTP_HOST=127.0.0.1\n'
    printf 'MCP_HTTP_PORT=8001\n'
    printf 'CAMERA_USERNAME=%s\n' "$camera_username"
    printf 'CAMERA_PASSWORD=%s\n' "$camera_password"
    printf 'STREAM_SERVER_URL=http://%s\n' "$server_fqdn"
    printf 'SERVER_FQDN=%s\n' "$server_fqdn"
  } >"$env_file"
  sudo install -o root -g root -m 0600 "$env_file" /etc/onvif-mcp-http.env
  shred -u "$env_file"
  sudo test -s /etc/onvif-mcp-http.env
}

write_systemd_unit() {
  require_arg --repo-path "$repo_path"
  require_arg --server-user "$server_user"
  local dir
  dir="$(project_dir)"
  id "$server_user" >/dev/null
  test -x "$dir/.venv/bin/onvif-mcp-http"
  cat <<EOF | sudo tee /etc/systemd/system/onvif-mcp-http.service >/dev/null
[Unit]
Description=ONVIF Camera MCP HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$server_user
WorkingDirectory=$dir
EnvironmentFile=/etc/onvif-mcp-http.env
ExecStart=$dir/.venv/bin/onvif-mcp-http
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  sudo chown root:root /etc/systemd/system/onvif-mcp-http.service
  sudo chmod 0644 /etc/systemd/system/onvif-mcp-http.service
  if sudo grep -n 'CAMERA_PASSWORD=' /etc/systemd/system/onvif-mcp-http.service; then
    echo "Unit file contains CAMERA_PASSWORD; refusing to continue." >&2
    exit 1
  fi
  sudo grep -n '^EnvironmentFile=/etc/onvif-mcp-http.env$' /etc/systemd/system/onvif-mcp-http.service >/dev/null
  sudo systemd-analyze verify /etc/systemd/system/onvif-mcp-http.service
}

write_nginx_site() {
  require_arg --server-fqdn "$server_fqdn"
  sudo install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  if [[ ! -f /etc/nginx/sites-available/camera ]]; then
    cat <<EOF | sudo tee /etc/nginx/sites-available/camera >/dev/null
server {
    listen 80;
    server_name $server_fqdn;
}
EOF
  fi
  sudo python3 - "$server_fqdn" <<'PY'
import pathlib, re, sys
fqdn = sys.argv[1]
path = pathlib.Path('/etc/nginx/sites-available/camera')
text = path.read_text()
if re.search(r'\blocation\s+=\s+/mcp\b', text):
    new = text
else:
    block = f'''

    # MCP endpoint - exact match to avoid redirect issues with POST
    location = /mcp {{
        proxy_pass http://127.0.0.1:8001/mcp;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }}

    # Handle trailing slash variant - redirect to no-slash version
    location = /mcp/ {{
        return 301 http://$host/mcp;
    }}
'''
    idx = text.rfind('}')
    if idx == -1:
        raise SystemExit('No closing brace found in /etc/nginx/sites-available/camera')
    new = text[:idx] + block + text[idx:]
new = re.sub(r'(?m)^\s*server_name\s+[^;]+;', f'    server_name {fqdn};', new, count=1)
path.write_text(new)
PY
  sudo ln -sfn /etc/nginx/sites-available/camera /etc/nginx/sites-enabled/camera
  sudo nginx -t
  sudo systemctl enable --now nginx
  sudo systemctl reload nginx
}

start_service() {
  sudo systemctl daemon-reload
  sudo systemctl enable --now onvif-mcp-http
  sudo systemctl restart onvif-mcp-http
  systemctl is-active onvif-mcp-http
}

test_mcp() {
  require_arg --server-fqdn "$server_fqdn"
  local init session tools base cacert
  cacert="$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem"
  if [[ -f "$cacert" ]]; then
    base="https://$server_fqdn/mcp"
  else
    base="http://$server_fqdn/mcp"
    cacert=""
  fi
  init="$(curl -sD- ${cacert:+--cacert "$cacert"} -X POST -H 'Content-Type: application/json' -H 'Accept: text/event-stream, application/json' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl-test","version":"1.0"}}}' "$base")"
  session="$(printf '%s\n' "$init" | awk 'tolower($1)=="mcp-session-id:" {gsub("\r", "", $2); print $2; exit}')"
  if [[ -z "$session" ]]; then
    echo "$init" >&2
    echo "No mcp-session-id received from $base" >&2
    exit 1
  fi
  curl -fsS ${cacert:+--cacert "$cacert"} -X POST -H 'Content-Type: application/json' -H 'Accept: text/event-stream, application/json' -H "mcp-session-id: $session" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$base" >/dev/null || true
  tools="$(curl -fsS ${cacert:+--cacert "$cacert"} -X POST -H 'Content-Type: application/json' -H 'Accept: text/event-stream, application/json' -H "mcp-session-id: $session" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' "$base")"
  printf '%s\n' "$tools" | grep '"name":"get_cameras"' >/dev/null
  printf '%s\n' "$tools" | grep '"name":"get_adapters"' >/dev/null
  adapters="$(curl -fsS ${cacert:+--cacert "$cacert"} -X POST -H 'Content-Type: application/json' -H 'Accept: text/event-stream, application/json' -H "mcp-session-id: $session" -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_adapters","arguments":{}}}' "$base")"
  printf '%s\n' "$adapters" | grep '10.2.2.1' >/dev/null
  echo "mcp-test-ok tools=get_cameras,get_adapters adapter=10.2.2.1"
}

configure_hermes() {
  require_arg --server-fqdn "$server_fqdn"
  python3 - "$server_fqdn" <<'PY'
import pathlib, sys
fqdn = sys.argv[1]
path = pathlib.Path.home()/'.hermes'/'config.yaml'
path.parent.mkdir(parents=True, exist_ok=True)
text = path.read_text() if path.exists() else ''
block = f'''mcp_servers:\n  camera:\n    url: http://{fqdn}/mcp\n    connect_timeout: 60\n    timeout: 180\n'''
if 'mcp_servers:' not in text:
    text = (text.rstrip() + '\n\n' + block).lstrip('\n')
elif re_marker := ('  camera:' in text and 'url: http://' in text):
    # Keep existing config unchanged rather than risk clobbering unrelated YAML.
    print('Hermes config already appears to contain a camera MCP entry; leaving unchanged.')
    path.write_text(text)
    raise SystemExit(0)
else:
    lines = text.splitlines()
    out = []
    inserted = False
    for line in lines:
        out.append(line)
        if line.strip() == 'mcp_servers:':
            out.extend([f'  camera:', f'    url: http://{fqdn}/mcp', '    connect_timeout: 60', '    timeout: 180'])
            inserted = True
    if not inserted:
        out.append(block.rstrip())
    text = '\n'.join(out) + '\n'
path.write_text(text)
print(path)
PY
}

print_status() {
  [[ -n "$repo_path" ]] && echo "project_dir=$(project_dir)"
  echo "== service =="
  systemctl is-enabled onvif-mcp-http 2>/dev/null || true
  systemctl is-active onvif-mcp-http 2>/dev/null || true
  systemctl status onvif-mcp-http --no-pager -l 2>/dev/null | sed -n '1,20p' || true
  echo "== files =="
  sudo stat -c '%a %U:%G %n' /etc/systemd/system/onvif-mcp-http.service /etc/onvif-mcp-http.env 2>/dev/null || true
  if [[ -n "$server_fqdn" ]]; then
    echo "== nginx server_name count =="
    sudo nginx -T 2>/dev/null | grep -c "server_name $server_fqdn" || true
  fi
  echo "== listener =="
  ss -ltnp 2>/dev/null | grep ':8001' || true
  echo "== recent logs =="
  sudo journalctl -u onvif-mcp-http -n 30 --no-pager || true
}

case "$cmd" in
apply)
  require_arg --server-fqdn "$server_fqdn"
  require_arg --camera-username "$camera_username"
  require_arg --repo-path "$repo_path"
  require_arg --server-user "$server_user"
  install_packages
  ensure_uv
  sync_venv "$(project_dir)"
  write_env_file
  write_systemd_unit
  write_nginx_site
  start_service
  print_status
  ;;
status)
  print_status
  ;;
test)
  test_mcp
  ;;
configure-hermes)
  configure_hermes
  ;;
*)
  echo "Unknown command: $cmd" >&2
  usage >&2
  exit 64
  ;;
esac
