#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ca_distribute_runbook.sh apply --server-fqdn HOST --server-ip IP [--allowed-subnets CIDR[,CIDR...]]
  ca_distribute_runbook.sh verify --server-fqdn HOST --server-ip IP
  ca_distribute_runbook.sh status --server-fqdn HOST --server-ip IP
  ca_distribute_runbook.sh test --server-fqdn HOST --server-ip IP

Implements docs/CA_DISTRIBUTE.md. Only the public CA certificate is distributed.
If --allowed-subnets is omitted or empty, /ca/ is reachable from any subnet.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
server_fqdn=""; server_ip=""; allowed_subnets=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --server-ip) server_ip="${2:?missing --server-ip value}"; shift 2 ;;
    --allowed-subnets)
      [[ $# -ge 2 ]] || { echo "missing --allowed-subnets value" >&2; exit 64; }
      allowed_subnets="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
require_all() { require_arg --server-fqdn "$server_fqdn"; require_arg --server-ip "$server_ip"; }
dist_dir=/srv/camera-pki/public
source_ca=/etc/nginx/tls/camera-system-root-ca.crt.pem

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

nginx_ca_access_directives() {
  local subnet trimmed
  local -a subnets
  [[ -n "$(trim "$allowed_subnets")" ]] || return 0

  IFS=',' read -r -a subnets <<< "$allowed_subnets"
  for subnet in "${subnets[@]}"; do
    trimmed="$(trim "$subnet")"
    if [[ ! "$trimmed" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]; then
      echo "Invalid --allowed-subnets entry: $subnet" >&2
      echo "Expected comma-separated IPv4/IPv6 CIDR subnets, for example: 10.1.1.0/24,192.168.68.0/22" >&2
      exit 64
    fi
    printf '        allow %s;\n' "$trimmed"
  done
  printf '        deny all;\n'
}

install_packages() {
  missing=()
  command -v nginx >/dev/null 2>&1 || missing+=(nginx)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
  if [[ ${#missing[@]} -gt 0 ]]; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

install_distribution_files() {
  sudo test -s "$source_ca"
  sudo install -d -o root -g root -m 0755 "$dist_dir"
  sudo install -o root -g root -m 0644 "$source_ca" "$dist_dir/camera-system-root-ca.crt.pem"
  sudo install -o root -g root -m 0644 "$source_ca" "$dist_dir/camera-system-root-ca.crt"
  cmp -s "$dist_dir/camera-system-root-ca.crt.pem" "$dist_dir/camera-system-root-ca.crt"
  (cd "$dist_dir" && sha256sum camera-system-root-ca.crt.pem) | sudo tee "$dist_dir/camera-system-root-ca.crt.pem.sha256" >/dev/null
  (cd "$dist_dir" && sha256sum camera-system-root-ca.crt) | sudo tee "$dist_dir/camera-system-root-ca.crt.sha256" >/dev/null
  sudo chmod 0644 "$dist_dir"/*.sha256
  file_sha="$(sha256sum "$dist_dir/camera-system-root-ca.crt.pem" | awk '{print $1}')"
  cert_fp="$(openssl x509 -in "$dist_dir/camera-system-root-ca.crt.pem" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//')"
  tmp="$(mktemp "${TMPDIR:-/tmp}/ca-readme.XXXXXX")"
  cat > "$tmp" <<EOF
Camera System Root CA
=====================

Certificate download:
http://$server_fqdn/ca/camera-system-root-ca.crt.pem
http://$server_fqdn/ca/camera-system-root-ca.crt

Checksum files:
http://$server_fqdn/ca/camera-system-root-ca.crt.pem.sha256
http://$server_fqdn/ca/camera-system-root-ca.crt.sha256

File SHA-256 for both certificate downloads:
$file_sha

Certificate SHA-256 fingerprint:
$cert_fp

Verify the downloaded PEM file:

macOS:
  shasum -a 256 camera-system-root-ca.crt.pem
  shasum -a 256 camera-system-root-ca.crt

Linux:
  sha256sum camera-system-root-ca.crt.pem
  sha256sum camera-system-root-ca.crt

Windows:
  certutil -hashfile camera-system-root-ca.crt.pem SHA256
  certutil -hashfile camera-system-root-ca.crt SHA256

Inspect the certificate fingerprint with OpenSSL:
  openssl x509 -in camera-system-root-ca.crt.pem -noout -fingerprint -sha256
  openssl x509 -in camera-system-root-ca.crt -noout -fingerprint -sha256

Install this certificate only as a trusted root for websites.
Never install or request a private-key file.

Important:
The certificate and checksum are delivered over the same HTTP connection.
Compare the certificate fingerprint with a separately trusted copy supplied
by the camera-system administrator before trusting the certificate.
EOF
  sudo install -o root -g root -m 0644 "$tmp" "$dist_dir/README.txt"
  rm -f "$tmp"
}

configure_nginx_http_ca_endpoint() {
  local today; today="$(date +%F)"
  local ca_access_directives; ca_access_directives="$(nginx_ca_access_directives)"
  sudo test -f /etc/nginx/sites-available/camera
  sudo cp --update=none /etc/nginx/sites-available/camera "/etc/nginx/sites-available/camera.backup-ca-dist-$today" || true
  sudo tee /etc/nginx/sites-available/camera >/dev/null <<EOF
server {
    listen 80;
    server_name $server_fqdn;

    location /ca/ {
        alias /srv/camera-pki/public/;
        autoindex off;
$ca_access_directives
    }

    location / { return 301 https://$server_fqdn\$request_uri; }
}
EOF
  sudo ln -sfn /etc/nginx/sites-available/camera /etc/nginx/sites-enabled/camera
  sudo nginx -t
  sudo systemctl reload nginx.service
  systemctl is-active nginx.service
}

verify_distribution_files() {
  sudo test -d "$dist_dir"
  sudo stat -c '%a %U:%G %n' "$dist_dir" "$dist_dir/camera-system-root-ca.crt.pem" "$dist_dir/camera-system-root-ca.crt" "$dist_dir/camera-system-root-ca.crt.pem.sha256" "$dist_dir/camera-system-root-ca.crt.sha256" "$dist_dir/README.txt"
  cmp -s "$dist_dir/camera-system-root-ca.crt.pem" "$dist_dir/camera-system-root-ca.crt"
  sudo cmp -s "$source_ca" "$dist_dir/camera-system-root-ca.crt.pem"
  openssl x509 -in "$dist_dir/camera-system-root-ca.crt.pem" -noout -subject -issuer -fingerprint -sha256
  (cd "$dist_dir" && sha256sum --check camera-system-root-ca.crt.pem.sha256 && sha256sum --check camera-system-root-ca.crt.sha256)
  if sudo find "$dist_dir" -maxdepth 1 -type f \( -name '*key*' -o -name '*archive*' -o -name '*serial*' -o -name 'index.txt*' -o -name '*.age' -o -name '*.csr*' \) | grep -q .; then
    echo "Forbidden private/CA-state-looking file found in $dist_dir" >&2
    sudo find "$dist_dir" -maxdepth 1 -type f \( -name '*key*' -o -name '*archive*' -o -name '*serial*' -o -name 'index.txt*' -o -name '*.age' -o -name '*.csr*' \) >&2
    exit 1
  fi
}

test_http_endpoints() {
  local failed=0 url code body tmp pem_sum remote_sum
  for path in /ca/camera-system-root-ca.crt.pem /ca/camera-system-root-ca.crt /ca/camera-system-root-ca.crt.pem.sha256 /ca/camera-system-root-ca.crt.sha256 /ca/README.txt; do
    code="$(curl -sS --resolve "$server_fqdn:80:$server_ip" -o /dev/null -w '%{http_code}' "http://$server_fqdn$path" || true)"
    printf '%-45s %s\n' "$path" "$code"
    [[ "$code" == 200 ]] || failed=1
  done
  code="$(curl -sS --resolve "$server_fqdn:80:$server_ip" -o /dev/null -w '%{http_code}' "http://$server_fqdn/cameras/" || true)"
  printf '%-45s %s\n' /cameras/ "$code"
  [[ "$code" == 301 ]] || failed=1
  tmp="$(mktemp "${TMPDIR:-/tmp}/downloaded-ca.XXXXXX.pem")"
  curl -sS --resolve "$server_fqdn:80:$server_ip" "http://$server_fqdn/ca/camera-system-root-ca.crt.pem" -o "$tmp"
  cmp -s "$tmp" "$dist_dir/camera-system-root-ca.crt.pem" || failed=1
  remote_sum="$(curl -sS --resolve "$server_fqdn:80:$server_ip" "http://$server_fqdn/ca/camera-system-root-ca.crt.pem.sha256" | awk '{print $1}')"
  pem_sum="$(sha256sum "$tmp" | awk '{print $1}')"
  [[ "$remote_sum" == "$pem_sum" ]] || failed=1
  rm -f "$tmp"
  return "$failed"
}

print_status() {
  echo "== Distribution files =="
  [[ -d "$dist_dir" ]] && sudo find "$dist_dir" -maxdepth 1 -type f -printf '%m %u:%g %s %p\n' | sort || echo "missing $dist_dir"
  echo "== Certificate =="
  [[ -f "$dist_dir/camera-system-root-ca.crt.pem" ]] && openssl x509 -in "$dist_dir/camera-system-root-ca.crt.pem" -noout -subject -issuer -fingerprint -sha256 || true
  echo "== nginx /ca config =="
  sudo nginx -t 2>&1 || true
  sudo sed -n '1,120p' /etc/nginx/sites-available/camera || true
}

case "$cmd" in
  apply)
    require_all; install_packages; install_distribution_files; configure_nginx_http_ca_endpoint; verify_distribution_files; test_http_endpoints; echo "apply-ok" ;;
  verify)
    require_all; verify_distribution_files; sudo nginx -t; test_http_endpoints; echo "verify-ok" ;;
  test)
    require_all; test_http_endpoints ;;
  status)
    require_all; print_status ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
