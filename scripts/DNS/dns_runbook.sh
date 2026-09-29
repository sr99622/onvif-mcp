#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  dns_runbook.sh apply --server-fqdn HOST --server-ip IP --rvrs-srv-ip REVERSED_IP --upstream-dns IP --backup-path PATH
  dns_runbook.sh verify --server-fqdn HOST --server-ip IP --rvrs-srv-ip REVERSED_IP --upstream-dns IP
  dns_runbook.sh status --server-fqdn HOST --server-ip IP

Configures dnsmasq DNS-only service from docs/DNS.md and creates a DNS_BACKUP checkpoint.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
server_fqdn=""; server_ip=""; rvrs_srv_ip=""; upstream_dns=""; backup_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --server-ip) server_ip="${2:?missing --server-ip value}"; shift 2 ;;
    --rvrs-srv-ip) rvrs_srv_ip="${2:?missing --rvrs-srv-ip value}"; shift 2 ;;
    --upstream-dns) upstream_dns="${2:?missing --upstream-dns value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
require_dns_args() { require_arg --server-fqdn "$server_fqdn"; require_arg --server-ip "$server_ip"; require_arg --rvrs-srv-ip "$rvrs_srv_ip"; require_arg --upstream-dns "$upstream_dns"; }

install_packages() {
  missing=()
  if ! dpkg-query -W -f='${Status}' dnsmasq 2>/dev/null | grep -Fx 'install ok installed' >/dev/null; then missing+=(dnsmasq); fi
  command -v dig >/dev/null 2>&1 || missing+=(dnsutils)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  if [[ ${#missing[@]} -gt 0 ]]; then
    sudo systemctl mask dnsmasq.service || true
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "${missing[@]}"
  fi
}

assert_port_available_or_dnsmasq() {
  if sudo ss -lntup 'sport = :53' | grep -vE 'systemd-resolve|dnsmasq|State|Netid' | grep -q .; then
    echo "Unexpected non-resolved/non-dnsmasq listener on port 53" >&2
    sudo ss -lntup 'sport = :53' >&2
    exit 1
  fi
}

configure_dnsmasq_conf_dir() {
  sudo python3 - <<'PY'
from pathlib import Path
p=Path('/etc/dnsmasq.conf')
text=p.read_text() if p.exists() else ''
lines=text.splitlines()
out=[]; done=False
for line in lines:
    stripped=line.strip()
    if stripped in {'#conf-dir=/etc/dnsmasq.d/,*.conf','conf-dir=/etc/dnsmasq.d/,*.conf'}:
        if not done:
            out.append('conf-dir=/etc/dnsmasq.d/,*.conf')
            done=True
        continue
    out.append(line)
if not done:
    out.append('conf-dir=/etc/dnsmasq.d/,*.conf')
p.write_text('\n'.join(out)+'\n')
PY
  grep -Fx 'conf-dir=/etc/dnsmasq.d/,*.conf' /etc/dnsmasq.conf >/dev/null
}

write_camera_config() {
  sudo install -d -o root -g root -m 0755 /etc/dnsmasq.d
  tmp="$(mktemp "${TMPDIR:-/tmp}/camera-dnsmasq.XXXXXX")"
  cat > "$tmp" <<EOF
# Camera-system DNS service
listen-address=$server_ip
bind-interfaces

# Private local namespace
local=/home.arpa/
address=/$server_fqdn/$server_ip

# Explicit upstream resolver
no-resolv
server=$upstream_dns

domain-needed
bogus-priv
cache-size=1000

# Reverse lookup for clearer diagnostics
ptr-record=$rvrs_srv_ip.in-addr.arpa,$server_fqdn
EOF
  sudo install -o root -g root -m 0644 "$tmp" /etc/dnsmasq.d/camera-system.conf
  rm -f "$tmp"
}

write_service_overrides() {
  sudo install -d -o root -g root -m 0755 /etc/systemd/system/dnsmasq.service.d
  sudo tee /etc/systemd/system/dnsmasq.service.d/override.conf >/dev/null <<'EOF'
[Service]
ExecStartPost=
ExecStop=
EOF
  sudo python3 - <<'PY'
from pathlib import Path
p=Path('/etc/default/dnsmasq')
text=p.read_text() if p.exists() else ''
lines=[]; done=False
for line in text.splitlines():
    if line.startswith('IGNORE_RESOLVCONF='):
        lines.append('IGNORE_RESOLVCONF=yes'); done=True
    else:
        lines.append(line)
if not done: lines.append('IGNORE_RESOLVCONF=yes')
p.write_text('\n'.join(lines)+'\n')
PY
  sudo systemctl daemon-reload
}

start_dnsmasq() {
  sudo dnsmasq --test
  sudo systemctl unmask dnsmasq.service || true
  sudo systemctl restart dnsmasq.service
  sudo systemctl enable dnsmasq.service >/dev/null
  systemctl is-enabled dnsmasq.service
  systemctl is-active dnsmasq.service
}

verify_dns() {
  require_dns_args
  sudo dnsmasq --test
  systemctl is-active dnsmasq.service >/dev/null
  systemctl is-enabled dnsmasq.service >/dev/null
  grep -Fx 'conf-dir=/etc/dnsmasq.d/,*.conf' /etc/dnsmasq.conf >/dev/null
  grep -Fx "listen-address=$server_ip" /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx 'bind-interfaces' /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx 'local=/home.arpa/' /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx "address=/$server_fqdn/$server_ip" /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx 'no-resolv' /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx "server=$upstream_dns" /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx "ptr-record=$rvrs_srv_ip.in-addr.arpa,$server_fqdn" /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx 'IGNORE_RESOLVCONF=yes' /etc/default/dnsmasq >/dev/null
  sudo grep -Fx 'ExecStartPost=' /etc/systemd/system/dnsmasq.service.d/override.conf >/dev/null
  sudo grep -Fx 'ExecStop=' /etc/systemd/system/dnsmasq.service.d/override.conf >/dev/null
  dig @"$server_ip" "$server_fqdn" +short | grep -Fx "$server_ip" >/dev/null
  dig @"$server_ip" ubuntu.com +short | grep -Eq '^[0-9a-fA-F:.]+$'
  dig @"$server_ip" nonexistent-test.home.arpa +noall +comments | grep -F 'status: NXDOMAIN' >/dev/null
  dig @"$server_ip" -x "$server_ip" +short | grep -Fx "$server_fqdn." >/dev/null
  sudo ss -lntup 'sport = :53' | grep -E "(^|[[:space:]])$server_ip:53[[:space:]]" >/dev/null
  if sudo ss -lntup 'sport = :53' | grep -E 'dnsmasq' | grep -E '0\.0\.0\.0:53|10\.2\.2\.1:53|127\.0\.0\.(53|54):53' >/dev/null; then
    echo "dnsmasq is listening on an unintended address" >&2
    sudo ss -lntup 'sport = :53' >&2
    exit 1
  fi
  echo "verify-ok"
}

create_checkpoint() {
  require_arg --backup-path "$backup_path"
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$script_dir/../DNS_BACKUP/dns_backup_runbook.sh" create-checkpoint \
    --server-fqdn "$server_fqdn" \
    --server-ip "$server_ip" \
    --rvrs-srv-ip "$rvrs_srv_ip" \
    --upstream-dns "$upstream_dns" \
    --backup-path "$backup_path" \
    --trigger DNS.md
}

print_status() {
  require_arg --server-fqdn "$server_fqdn"; require_arg --server-ip "$server_ip"
  echo "== service =="; systemctl is-enabled dnsmasq.service 2>/dev/null || true; systemctl is-active dnsmasq.service 2>/dev/null || true
  echo "== config =="; grep -nE '^(conf-dir=|listen-address=|address=|server=|ptr-record=|local=|no-resolv|bind-interfaces|IGNORE_RESOLVCONF=)' /etc/dnsmasq.conf /etc/dnsmasq.d/camera-system.conf /etc/default/dnsmasq 2>/dev/null || true
  echo "== listeners =="; sudo ss -lntup 'sport = :53' || true
  echo "== DNS =="; dig @"$server_ip" "$server_fqdn" +noall +answer || true; dig @"$server_ip" -x "$server_ip" +noall +answer || true
}

case "$cmd" in
  apply)
    require_dns_args; require_arg --backup-path "$backup_path"
    install_packages; assert_port_available_or_dnsmasq; configure_dnsmasq_conf_dir; write_camera_config; write_service_overrides; start_dnsmasq; verify_dns; create_checkpoint; echo "apply-ok" ;;
  verify) verify_dns ;;
  status) print_status ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
