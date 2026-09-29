#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  dns_backup_runbook.sh create-checkpoint --server-fqdn HOST --server-ip IP --rvrs-srv-ip REVERSED_IP --upstream-dns IP --backup-path PATH [--trigger NAME]
  dns_backup_runbook.sh status --backup-path PATH

Implements the "Create a checkpoint" section of docs/DNS_BACKUP.md.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
server_fqdn=""; server_ip=""; rvrs_srv_ip=""; upstream_dns=""; backup_path=""; trigger="DNS.md"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --server-ip) server_ip="${2:?missing --server-ip value}"; shift 2 ;;
    --rvrs-srv-ip) rvrs_srv_ip="${2:?missing --rvrs-srv-ip value}"; shift 2 ;;
    --upstream-dns) upstream_dns="${2:?missing --upstream-dns value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --trigger) trigger="${2:?missing --trigger value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
require_all() { require_arg --server-fqdn "$server_fqdn"; require_arg --server-ip "$server_ip"; require_arg --rvrs-srv-ip "$rvrs_srv_ip"; require_arg --upstream-dns "$upstream_dns"; require_arg --backup-path "$backup_path"; }
backup_root() { printf '%s/dns' "${backup_path%/}"; }

require_mounted_backup() {
  local target="${backup_path%/}"
  if ! findmnt -rn -T "$target" -o TARGET | grep -Fx "$target" >/dev/null; then
    echo "$target is not a mounted filesystem target; refusing DNS checkpoint." >&2
    exit 1
  fi
  test -w "$target" || { echo "$target is not writable by $(id -un)" >&2; exit 1; }
}

require_dns_verified() {
  command -v dnsmasq >/dev/null
  command -v dig >/dev/null
  sudo dnsmasq --test
  systemctl is-active dnsmasq.service >/dev/null
  grep -Fx "IGNORE_RESOLVCONF=yes" /etc/default/dnsmasq >/dev/null
  sudo test -f /etc/systemd/system/dnsmasq.service.d/override.conf
  sudo grep -Fx 'ExecStartPost=' /etc/systemd/system/dnsmasq.service.d/override.conf >/dev/null
  sudo grep -Fx 'ExecStop=' /etc/systemd/system/dnsmasq.service.d/override.conf >/dev/null
  grep -Fx "listen-address=$server_ip" /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx "address=/$server_fqdn/$server_ip" /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx "server=$upstream_dns" /etc/dnsmasq.d/camera-system.conf >/dev/null
  grep -Fx "ptr-record=$rvrs_srv_ip.in-addr.arpa,$server_fqdn" /etc/dnsmasq.d/camera-system.conf >/dev/null
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
}

write_metadata() {
  local dest="$1" checkpoint_timestamp="$2"
  {
    echo "trigger=$trigger"
    echo "timestamp=$checkpoint_timestamp"
    echo "server_fqdn=$server_fqdn"
    echo "server_ip=$server_ip"
    echo "reverse_server_ip=$rvrs_srv_ip"
    echo "upstream_dns=$upstream_dns"
    echo "captured_by=$(id -un)@$(hostname)"
    echo "captured_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "== OS =="
    PRETTY_NAME=""; . /etc/os-release 2>/dev/null || true; echo "${PRETTY_NAME:-unknown}"
    echo
    echo "== dnsmasq package =="
    dpkg-query -W -f='${Package} ${Version}\n' dnsmasq dnsmasq-base 2>/dev/null || true
    echo
    echo "== dnsmasq validation =="
    sudo dnsmasq --test
    echo
    echo "== service state =="
    systemctl is-enabled dnsmasq.service || true
    systemctl is-active dnsmasq.service || true
    systemctl cat dnsmasq.service
    echo
    echo "== listeners =="
    sudo ss -lntup 'sport = :53'
    echo
    echo "== DNS checks =="
    dig @"$server_ip" "$server_fqdn" +noall +answer
    dig @"$server_ip" ubuntu.com +short | sed -n '1,10p'
    dig @"$server_ip" nonexistent-test.home.arpa +noall +comments +answer
    dig @"$server_ip" -x "$server_ip" +noall +answer
    echo
    echo "== managed files =="
    sudo find /etc/dnsmasq.d /etc/systemd/system/dnsmasq.service.d -maxdepth 3 -printf '%m %u:%g %p -> %l\n' 2>/dev/null || true
    sudo stat -c '%a %U:%G %n' /etc/dnsmasq.conf /etc/default/dnsmasq /etc/dnsmasq.d/camera-system.conf /etc/systemd/system/dnsmasq.service.d/override.conf
    if sudo test -f /etc/systemd/system/dnsmasq.service; then
      echo "local_unit_override=present"
    else
      echo "local_unit_override=absent"
    fi
  } > "$dest/metadata.txt"
}

create_checkpoint() {
  require_all; require_mounted_backup; require_dns_verified
  local root timestamp staging final tar_members tmpinspect
  root="$(backup_root)"
  timestamp="$(date -u +%Y%m%d%H%M%SZ)"
  staging="$root/.staging-$timestamp-$$"
  final="$root/$timestamp"
  sudo install -d -m 0700 "$root"
  test ! -e "$staging"
  test ! -e "$final"
  install -d -m 0700 "$staging"
  tar_members=(etc/dnsmasq.conf etc/dnsmasq.d etc/default/dnsmasq etc/systemd/system/dnsmasq.service.d)
  if sudo test -f /etc/systemd/system/dnsmasq.service; then
    tar_members+=(etc/systemd/system/dnsmasq.service)
  fi
  sudo tar --xattrs --acls --one-file-system -C / -cpf "$staging/dns.tar" "${tar_members[@]}"
  sudo chown "$(id -u):$(id -g)" "$staging/dns.tar"
  chmod 600 "$staging/dns.tar"
  tmpinspect="$(mktemp -d "${TMPDIR:-/tmp}/dns-checkpoint.XXXXXX")"
  cleanup() { rm -rf "$tmpinspect"; }
  trap cleanup RETURN
  tar -tf "$staging/dns.tar" | while IFS= read -r member; do
    case "$member" in
      /*|*../*|../*|'' ) echo "Unsafe tar member: $member" >&2; exit 1 ;;
    esac
  done
  tar -tf "$staging/dns.tar" | grep -Fx 'etc/dnsmasq.conf' >/dev/null
  tar -tf "$staging/dns.tar" | grep -Fx 'etc/default/dnsmasq' >/dev/null
  tar -tf "$staging/dns.tar" | grep -Fx 'etc/dnsmasq.d/camera-system.conf' >/dev/null
  tar -tf "$staging/dns.tar" | grep -Fx 'etc/systemd/system/dnsmasq.service.d/override.conf' >/dev/null
  tar -xf "$staging/dns.tar" -C "$tmpinspect"
  cmp -s /etc/dnsmasq.conf "$tmpinspect/etc/dnsmasq.conf"
  cmp -s /etc/default/dnsmasq "$tmpinspect/etc/default/dnsmasq"
  cmp -s /etc/dnsmasq.d/camera-system.conf "$tmpinspect/etc/dnsmasq.d/camera-system.conf"
  cmp -s /etc/systemd/system/dnsmasq.service.d/override.conf "$tmpinspect/etc/systemd/system/dnsmasq.service.d/override.conf"
  require_dns_verified
  write_metadata "$staging" "$timestamp"
  chmod 600 "$staging/metadata.txt"
  (cd "$staging" && sha256sum dns.tar metadata.txt > SHA256SUMS && sha256sum -c SHA256SUMS)
  chmod 600 "$staging/SHA256SUMS"
  mv -T "$staging" "$final"
  echo "create-checkpoint-ok $final"
}

print_status() {
  require_arg --backup-path "$backup_path"
  root="$(backup_root)"
  echo "backup_root=$root"
  if [[ -d "$root" ]]; then
    find "$root" -maxdepth 2 -type f -printf '%m %u:%g %s %p\n' | sort
  else
    echo "missing"
  fi
}

case "$cmd" in
  create-checkpoint) create_checkpoint ;;
  status) print_status ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
