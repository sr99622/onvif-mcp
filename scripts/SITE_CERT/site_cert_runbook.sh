#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  site_cert_runbook.sh prime-gpg-cache
  site_cert_runbook.sh apply --server-fqdn HOST --server-ip IP --server-user USER --ca-root PATH --backup-path PATH --repo-path PATH [--timestamp TS]
  site_cert_runbook.sh verify --server-fqdn HOST --server-ip IP --server-user USER --ca-root PATH --backup-path PATH --repo-path PATH --timestamp TS
  site_cert_runbook.sh status --server-fqdn HOST --server-ip IP --ca-root PATH --backup-path PATH --repo-path PATH

Implements docs/SITE_CERT.md. Site-specific values are passed as arguments.
The script never prints CA passphrases. If GPG requires interactive unlocking,
run prime-gpg-cache in a real terminal before apply.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true

server_fqdn=""; server_ip=""; server_user=""; ca_root=""; backup_path=""; repo_path=""; timestamp=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --server-ip) server_ip="${2:?missing --server-ip value}"; shift 2 ;;
    --server-user) server_user="${2:?missing --server-user value}"; shift 2 ;;
    --ca-root) ca_root="${2:?missing --ca-root value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --repo-path) repo_path="${2:?missing --repo-path value}"; shift 2 ;;
    --timestamp) timestamp="${2:?missing --timestamp value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
require_all() { require_arg --server-fqdn "$server_fqdn"; require_arg --server-ip "$server_ip"; require_arg --server-user "$server_user"; require_arg --ca-root "$ca_root"; require_arg --backup-path "$backup_path"; require_arg --repo-path "$repo_path"; }
project_dir() { printf '%s' "${repo_path%/}"; }
ca_dir() { printf '%s/camera-system-ca' "${ca_root%/}"; }
local_backup_dir() { printf '%s/backups' "${ca_root%/}"; }
backup_dir() { printf '%s/Camera-CA-Backups' "${backup_path%/}"; }
short_label() { printf '%s' "$server_fqdn" | sed 's/[^A-Za-z0-9._-]/-/g' | cut -d. -f1; }

ensure_timestamp() {
  [[ -n "$timestamp" ]] || timestamp="$(date -u +%Y%m%d%H%M%SZ)"
  [[ "$timestamp" =~ ^[0-9]{14}Z$ ]] || { echo "Timestamp must be UTC form YYYYMMDDhhmmssZ; got: $timestamp" >&2; exit 64; }
}

require_backup_location() {
  local target="${backup_path%/}"
  [[ -d "$target" ]] || { echo "$target does not exist; the backup location must already be mounted or created before running the runbook." >&2; exit 1; }
  [[ -w "$target" ]] || { echo "$target is not writable by $(id -un)" >&2; exit 1; }
  # Storage type is free (SMB share, mounted external drive, or local folder),
  # but the SMB-mount permission model is enforced on all of them: owner-only
  # 0700 directory, no ACL entries beyond the base owner-only set.
  local mode owner extra_acl
  mode="$(stat -c '%a' "$target")"
  owner="$(stat -c '%U:%G' "$target")"
  [[ "$mode" == "700" ]] || { echo "$target is mode $mode, not 0700; refusing to write backups into a group- or world-readable location." >&2; exit 1; }
  [[ "$owner" == "$(id -un):$(id -gn)" ]] || { echo "$target is owned by $owner, not $(id -un):$(id -gn); refusing." >&2; exit 1; }
  if command -v getfacl >/dev/null; then
    extra_acl="$(getfacl -p "$target" 2>/dev/null | grep -v '^#' | grep -v '^$' | grep -v -E '^(user::rw-?x?|group::---|other::---)$' || true)"
    [[ -z "$extra_acl" ]] || { echo "FAIL: unexpected ACL entry on the backup location:"; echo "$extra_acl" >&2; exit 1; }
  else
    echo "note: getfacl not installed; ACL check skipped (install acl for full enforcement)." >&2
  fi
}

install_packages() {
  missing=()
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v nginx >/dev/null 2>&1 || missing+=(nginx)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v age >/dev/null 2>&1 || missing+=(age)
  command -v pass >/dev/null 2>&1 || missing+=(pass)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v script >/dev/null 2>&1 || missing+=(util-linux)
  if [[ ${#missing[@]} -gt 0 ]]; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

prime_gpg_cache() {
  if ! tty_path="$(tty)" || [[ "$tty_path" == "not a tty" ]]; then
    echo "prime-gpg-cache must be run in a real terminal or SSH session with a TTY." >&2
    exit 1
  fi
  export GPG_TTY="$tty_path"
  gpg-connect-agent updatestartuptty /bye >/dev/null || true
  pass show camera-ca/root-key-passphrase >/dev/null
  latest_age="$(find "$HOME/.password-store/camera-ca" -maxdepth 1 -type f -name 'age-archive-*.gpg' -printf '%f\n' 2>/dev/null | sed 's/\.gpg$//' | sort | tail -1 || true)"
  [[ -n "$latest_age" ]] && pass show "camera-ca/$latest_age" >/dev/null || true
  echo "prime-gpg-cache-ok"
}

verify_prereqs() {
  test -d "$(project_dir)"
  test -s "$(ca_dir)/openssl.cnf"
  test -s "$(ca_dir)/certs/camera-system-root-ca.crt.pem"
  test -s "$(ca_dir)/private/camera-system-root-ca.key.pem"
  test -s "$HOME/.password-store/camera-ca/root-key-passphrase.gpg"
  pass show camera-ca/root-key-passphrase >/dev/null
  mkdir -p "$(local_backup_dir)"
  require_backup_location
  mkdir -p "$(backup_dir)"
}

generate_tls_key_and_csr() {
  sudo install -d -o root -g root -m 700 /etc/nginx/tls
  local key="/etc/nginx/tls/$server_fqdn.key.pem" csr="/etc/nginx/tls/$server_fqdn.csr.pem"
  if ! sudo test -e "$key"; then
    sudo openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$key"
    sudo chmod 600 "$key"
    sudo chown root:root "$key"
  fi
  sudo test -s "$key"
  sudo openssl pkey -in "$key" -check -noout
  sudo sed -n '1p' "$key" | grep -Fx -- '-----BEGIN PRIVATE KEY-----' >/dev/null
  if ! sudo test -e "$csr"; then
    sudo openssl req -new -sha256 -key "$key" -out "$csr" -subj "/CN=$server_fqdn" -addext "subjectAltName=DNS:$server_fqdn" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=serverAuth"
    sudo chmod 644 "$csr"
    sudo chown root:root "$csr"
  fi
  sudo openssl req -in "$csr" -noout -verify -subject
  sudo openssl req -in "$csr" -noout -text | grep -F "DNS:$server_fqdn" >/dev/null
  key_hash="$(sudo openssl pkey -in "$key" -pubout | openssl sha256)"
  csr_hash="$(sudo openssl req -in "$csr" -noout -pubkey | openssl sha256)"
  [[ "$key_hash" == "$csr_hash" ]] || { echo "CSR public key does not match TLS key" >&2; exit 1; }
}

stage_csr_and_ext() {
  install -d -m 700 "$(ca_dir)/csr" "$(ca_dir)/issued" "$(ca_dir)/newcerts"
  tmp="$(mktemp "${TMPDIR:-/tmp}/site-csr.XXXXXX")"
  sudo cat "/etc/nginx/tls/$server_fqdn.csr.pem" > "$tmp"
  install -m 600 "$tmp" "$(ca_dir)/csr/$server_fqdn.csr.pem"
  shred -u "$tmp"
  cat > "$(ca_dir)/csr/$server_fqdn.ext.cnf" <<EOF
[ server_cert ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = DNS:$server_fqdn
EOF
  chmod 600 "$(ca_dir)/csr/$server_fqdn.ext.cnf"
}

sign_certificate() {
  local cert="$(ca_dir)/issued/$server_fqdn.crt.pem" key_hash cert_hash
  sign_new_cert() {
    bash -lc 'pass show camera-ca/root-key-passphrase; echo y; echo y' \
      | script -qec "stty -echo 2>/dev/null; openssl ca -config '$(ca_dir)/openssl.cnf' -extfile '$(ca_dir)/csr/$server_fqdn.ext.cnf' -extensions server_cert -days 397 -md sha256 -notext -in '$(ca_dir)/csr/$server_fqdn.csr.pem' -out '$cert'" /dev/null
    chmod 644 "$cert"
  }
  if [[ ! -e "$cert" ]]; then
    sign_new_cert
  fi
  key_hash="$(sudo openssl pkey -in "/etc/nginx/tls/$server_fqdn.key.pem" -pubout | openssl sha256)"
  cert_hash="$(openssl x509 -in "$cert" -pubkey -noout | openssl sha256)"
  if [[ "$key_hash" != "$cert_hash" ]]; then
    mv "$cert" "${cert}.mismatched-$timestamp"
    sign_new_cert
    cert_hash="$(openssl x509 -in "$cert" -pubkey -noout | openssl sha256)"
  fi
  [[ "$key_hash" == "$cert_hash" ]] || { echo "Issued certificate public key does not match TLS key" >&2; exit 1; }
  openssl verify -CAfile "$(ca_dir)/certs/camera-system-root-ca.crt.pem" -purpose sslserver -verify_hostname "$server_fqdn" "$cert"
}

ensure_age_entry() {
  local entry="camera-ca/age-archive-$timestamp"
  if [[ -e "$HOME/.password-store/${entry}.gpg" ]]; then
    pass show "$entry" >/dev/null
    return 0
  fi
  umask 077
  tmp="$(mktemp "${TMPDIR:-/tmp}/site-age-pass.XXXXXX")"
  cleanup() { shred -u "$tmp" 2>/dev/null || true; }
  trap cleanup RETURN
  openssl rand -base64 24 | tr -d '=+/' | cut -c1-28 > "$tmp"
  pass insert -m "$entry" < "$tmp"
  pass show "$entry" >/dev/null
}

backup_password_store() {
  local label="$timestamp-site-cert-passphrase"
  local local_file="$(local_backup_dir)/password-store-backup-$label.tar.gz"
  local backup_file="$(backup_dir)/password-store-backup-$label.tar.gz"
  if [[ ! -e "$local_file" ]]; then
    tar -C "$HOME" -czf "$local_file" .password-store
    chmod 600 "$local_file"
  fi
  test -s "$local_file"
  [[ -e "$backup_file" ]] || cp --update=none "$local_file" "$(backup_dir)/"
  cmp -s "$local_file" "$backup_file"
  tr -d '\n' < "$HOME/.password-store/.gpg-id" > "$(backup_dir)/pass-gpg-id.txt"
  printf '\n' >> "$(backup_dir)/pass-gpg-id.txt"
}

archive_ca_state() {
  local label="$(short_label)-cert"
  local archive="$(local_backup_dir)/camera-system-ca-after-$label-$timestamp.tar.gz.age"
  if [[ ! -e "$archive" ]]; then
    find "$(ca_dir)" -type d -exec chmod 700 {} +
    find "$(ca_dir)" -type d -exec stat -c '%a %n' {} \; | awk '$1 != "700" { bad=1; print } END { exit bad }'
    bash -lc "pass show camera-ca/age-archive-$timestamp; pass show camera-ca/age-archive-$timestamp" \
      | script -qec "stty -echo 2>/dev/null; set -o pipefail; tar -C '${ca_root%/}' -czf - camera-system-ca | age -p -o '$archive'" /dev/null
    chmod 600 "$archive"
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/site-ca-decrypted.XXXXXX.tgz")"
  cleanup_archive() { shred -u "$tmp" 2>/dev/null || true; }
  trap cleanup_archive RETURN
  bash -lc "pass show camera-ca/age-archive-$timestamp" | script -qec "stty -echo 2>/dev/null; age -d '$archive' > '$tmp'" /dev/null
  tar -tzf "$tmp" | grep -Fx "camera-system-ca/issued/$server_fqdn.crt.pem" >/dev/null
  tar -tzf "$tmp" | grep -Fx "camera-system-ca/csr/$server_fqdn.csr.pem" >/dev/null
  tar -tzf "$tmp" | grep -Fx "camera-system-ca/csr/$server_fqdn.ext.cnf" >/dev/null
  tar -tzf "$tmp" | grep -Fx "camera-system-ca/index.txt" >/dev/null
  tar -tzf "$tmp" | grep -Fx "camera-system-ca/serial" >/dev/null
  local backup_archive="$(backup_dir)/$(basename "$archive")"
  [[ -e "$backup_archive" ]] || cp --update=none "$archive" "$(backup_dir)/"
  cmp -s "$archive" "$backup_archive"
  sha256sum "$archive" "$backup_archive"
}

install_nginx_certs() {
  sudo install -m 644 "$(ca_dir)/issued/$server_fqdn.crt.pem" "/etc/nginx/tls/$server_fqdn.crt.pem"
  sudo install -m 644 "$(ca_dir)/certs/camera-system-root-ca.crt.pem" /etc/nginx/tls/camera-system-root-ca.crt.pem
  tmp="$(mktemp "${TMPDIR:-/tmp}/site-chain.XXXXXX")"
  cat "$(ca_dir)/issued/$server_fqdn.crt.pem" "$(ca_dir)/certs/camera-system-root-ca.crt.pem" > "$tmp"
  sudo install -o root -g root -m 644 "$tmp" "/etc/nginx/tls/$server_fqdn.chain.pem"
  rm -f "$tmp"
  sudo stat -c '%a %U:%G %n' "/etc/nginx/tls/$server_fqdn.key.pem" "/etc/nginx/tls/$server_fqdn.crt.pem" "/etc/nginx/tls/$server_fqdn.chain.pem" /etc/nginx/tls/camera-system-root-ca.crt.pem
}

write_nginx_https_config() {
  local proj="$(project_dir)" today; today="$(date +%F)"
  test -d "$proj/apps/cameras"
  sudo cp --update=none /etc/nginx/sites-available/camera "/etc/nginx/sites-available/camera.backup-$today" || true
  sudo cp --update=none /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.backup-$today" || true
  sudo tee "/etc/nginx/conf.d/$server_fqdn.conf" >/dev/null <<EOF
server {
    listen 443 ssl;
    server_name $server_fqdn;

    ssl_certificate     /etc/nginx/tls/$server_fqdn.chain.pem;
    ssl_certificate_key /etc/nginx/tls/$server_fqdn.key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:camera_tls:10m;
    ssl_session_timeout 1d;

    location = /cameras { return 301 /cameras/; }
    location = /multiview { return 301 /multiview/; }

    location /cameras/ { alias $proj/apps/cameras/; }
    location /multiview/ { alias $proj/apps/multiview/; }

    location = /outputs/camera_registry.json { alias /etc/onvif-mcp/camera_registry.json; }
    location /outputs/ { return 404; }

    location /webrtc/ {
        proxy_pass http://127.0.0.1:8889/;
        proxy_redirect / /webrtc/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location = /mcp {
        proxy_pass http://127.0.0.1:8001/mcp;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    location = /mcp/ { return 301 https://\$host/mcp; }

    location /snapshot/ {
        proxy_pass http://127.0.0.1:8891/snapshot/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
        proxy_no_cache on;
        proxy_cache_bypass on;
    }

    location = /playback { return 301 /playback/; }
    location /playback/ {
        proxy_pass http://127.0.0.1:9996/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    location /playback-cache/ {
        alias /srv/camera-playback-cache/;
        add_header Accept-Ranges bytes always;
    }

    location = / {
        return 200 "MediaMTX server at $server_fqdn | apps: /cameras/ (switchboard), /multiview/ (four-camera view)\n";
        add_header Content-Type text/plain;
    }
}
EOF
  sudo tee /etc/nginx/sites-available/camera >/dev/null <<EOF
server {
    listen 80;
    server_name $server_fqdn;

    location = /ca/camera-system-root-ca.crt.pem {
        alias /etc/nginx/tls/camera-system-root-ca.crt.pem;
    }

    location = /ca/camera-system-root-ca.crt {
        alias /etc/nginx/tls/camera-system-root-ca.crt.pem;
    }

    location /ca/ { return 404; }

    location / { return 301 https://$server_fqdn\$request_uri; }
}
EOF
  sudo ln -sfn /etc/nginx/sites-available/camera /etc/nginx/sites-enabled/camera
  sudo nginx -t
  count="$(sudo nginx -T 2>/dev/null | grep -c "server_name $server_fqdn")"
  [[ "$count" == "2" ]] || { echo "Expected exactly 2 server_name $server_fqdn declarations, found $count" >&2; exit 1; }
  sudo systemctl reload nginx.service
  systemctl is-active nginx.service
  sudo ss -lntp 'sport = :443' | grep ':443' >/dev/null
}

update_downstream() {
  if [[ -f /etc/onvif-mcp/camera_registry.json ]]; then
    sudo cp --update=none /etc/onvif-mcp/camera_registry.json "/etc/onvif-mcp/camera_registry.json.backup-$(date +%F)" || true
    tmp="$(mktemp "${TMPDIR:-/tmp}/camera-registry.XXXXXX.json")"
    sudo python3 - "$server_fqdn" > "$tmp" <<'PY'
import json, sys
server=sys.argv[1]
p='/etc/onvif-mcp/camera_registry.json'
with open(p) as f: data=json.load(f)
old=f'http://{server}/'
new=f'https://{server}/'
for cam in data.get('cameras', []):
    for k,v in list(cam.items()):
        if isinstance(v, str) and v.startswith(old):
            cam[k]=new+v[len(old):]
print(json.dumps(data, indent=2))
PY
    sudo install -o root -g root -m 0644 "$tmp" /etc/onvif-mcp/camera_registry.json
    rm -f "$tmp"
    sudo python3 -m json.tool /etc/onvif-mcp/camera_registry.json >/dev/null
    if sudo grep -R "http://$server_fqdn/" /etc/onvif-mcp/camera_registry.json >/dev/null; then
      echo "Registry still contains plain HTTP URLs" >&2; exit 1
    fi
  fi
  if [[ -f /etc/onvif-mcp-http.env ]]; then
    sudo cp --update=none /etc/onvif-mcp-http.env "/etc/onvif-mcp-http.env.backup-$(date +%F)" || true
    sudo python3 - "$server_fqdn" <<'PY'
import pathlib, sys
server=sys.argv[1]
p=pathlib.Path('/etc/onvif-mcp-http.env')
lines=p.read_text().splitlines()
out=[]; done=False
for line in lines:
    if line.startswith('STREAM_SERVER_URL='):
        out.append(f'STREAM_SERVER_URL=https://{server}'); done=True
    else:
        out.append(line)
if not done: out.append(f'STREAM_SERVER_URL=https://{server}')
p.write_text('\n'.join(out)+'\n')
PY
    sudo systemctl daemon-reload
    sudo systemctl restart onvif-mcp-http
    systemctl is-active onvif-mcp-http
    sudo grep -Fx "STREAM_SERVER_URL=https://$server_fqdn" /etc/onvif-mcp-http.env >/dev/null
  fi
}

curl_code_with_retries() {
  local url="$1" code="" attempt
  for attempt in 1 2 3 4 5; do
    code="$(sudo curl -sS --resolve "$server_fqdn:443:$server_ip" --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem -o /dev/null -w '%{http_code}' "$url" || true)"
    [[ "$code" != "000" && "$code" != "502" && "$code" != "503" ]] && break
    sleep 1
  done
  printf '%s' "$code"
}

validate_https() {
  sudo curl -sS --resolve "$server_fqdn:443:$server_ip" --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem --head "https://$server_fqdn/cameras/" | grep -E '^HTTP/.* 200' >/dev/null
  for u in /cameras/ /multiview/ /outputs/camera_registry.json /mcp; do
    code="$(curl_code_with_retries "https://$server_fqdn$u")"
    printf '%-40s %s\n' "$u" "$code"
    case "$u" in
      /mcp) [[ "$code" =~ ^(200|400|405|406)$ ]] || exit 1 ;;
      *) [[ "$code" == 200 ]] || exit 1 ;;
    esac
  done
  code="$(curl -sS -o /dev/null -w '%{http_code}' --resolve "$server_fqdn:80:$server_ip" "http://$server_fqdn/cameras/")"
  [[ "$code" == 301 ]] || { echo "HTTP redirect returned $code, expected 301" >&2; exit 1; }
  sudo openssl s_client -connect "$server_ip:443" -servername "$server_fqdn" -CAfile /etc/nginx/tls/camera-system-root-ca.crt.pem -verify_hostname "$server_fqdn" </dev/null 2>/dev/null | grep -F 'Verify return code: 0 (ok)' >/dev/null
}

print_status() {
  echo "== TLS files =="; sudo find /etc/nginx/tls -maxdepth 1 -type f -name "*${server_fqdn}*" -o -name 'camera-system-root-ca.crt.pem' 2>/dev/null | sudo xargs -r stat -c '%a %U:%G %s %n'
  echo "== certificate =="; [[ -f "/etc/nginx/tls/$server_fqdn.crt.pem" ]] && sudo openssl x509 -in "/etc/nginx/tls/$server_fqdn.crt.pem" -noout -subject -issuer -dates -serial || true
  echo "== nginx =="; sudo nginx -t 2>&1 || true; systemctl is-active nginx 2>/dev/null || true; sudo ss -lntp 'sport = :443' || true
  echo "== endpoints =="; for u in /cameras/ /multiview/ /outputs/camera_registry.json; do code="$(sudo curl -k -sS --resolve "$server_fqdn:443:$server_ip" -o /dev/null -w '%{http_code}' "https://$server_fqdn$u" || true)"; printf '%-40s %s\n' "$u" "$code"; done
  echo "== backups =="; find "$(backup_dir)" -maxdepth 1 -type f -name "*${timestamp:-}*" -printf '%m %u:%g %s %p\n' 2>/dev/null | sort || true
}

case "$cmd" in
  prime-gpg-cache) prime_gpg_cache ;;
  apply)
    require_all; ensure_timestamp; install_packages; verify_prereqs
    generate_tls_key_and_csr; stage_csr_and_ext; sign_certificate
    ensure_age_entry; backup_password_store; archive_ca_state
    install_nginx_certs; write_nginx_https_config; update_downstream; validate_https
    echo "apply-ok timestamp=$timestamp"
    ;;
  verify)
    require_all; require_arg --timestamp "$timestamp"; verify_prereqs
    sign_certificate; archive_ca_state; install_nginx_certs; sudo nginx -t; validate_https
    test -s "$(backup_dir)/camera-system-ca-after-$(short_label)-cert-$timestamp.tar.gz.age"
    echo "verify-ok timestamp=$timestamp"
    ;;
  status)
    require_arg --server-fqdn "$server_fqdn"; require_arg --server-ip "$server_ip"; require_arg --ca-root "$ca_root"; require_arg --backup-path "$backup_path"; require_arg --repo-path "$repo_path"; print_status ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
