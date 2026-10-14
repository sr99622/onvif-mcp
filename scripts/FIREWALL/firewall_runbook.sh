#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  firewall_runbook.sh preflight --prvt-net-en-name IFACE --camera-subnet SUBNET [--ephemeral-udp-range LOW:HIGH]
  firewall_runbook.sh apply --prvt-net-en-name IFACE --camera-subnet SUBNET [--ephemeral-udp-range LOW:HIGH]
  firewall_runbook.sh status --prvt-net-en-name IFACE --camera-subnet SUBNET [--ephemeral-udp-range LOW:HIGH]

Implements only the UFW configuration workflow from docs/FIREWALL.md.
Site-specific values are passed as arguments; do not edit this script per site.
The ephemeral UDP range is derived live from /proc/sys/net/ipv4/ip_local_port_range
unless explicitly overridden. apply is idempotent: existing defaults and rules are
verified, not duplicated, and existing rules are never removed.
USAGE
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then usage; exit 64; fi
if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then usage; exit 0; fi
shift || true

iface=""; camera_subnet=""; ephemeral_range=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prvt-net-en-name) iface="${2:?missing --prvt-net-en-name value}"; shift 2 ;;
    --camera-subnet) camera_subnet="${2:?missing --camera-subnet value}"; shift 2 ;;
    --ephemeral-udp-range) ephemeral_range="${2:?missing --ephemeral-udp-range value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then echo "Missing required argument: $name" >&2; exit 64; fi
}

require_values() {
  require_arg --prvt-net-en-name "$iface"
  require_arg --camera-subnet "$camera_subnet"
  ip link show dev "$iface" >/dev/null
  if [[ -z "$ephemeral_range" ]]; then
    ephemeral_range="$(tr '\t ' ':' < /proc/sys/net/ipv4/ip_local_port_range)"
  fi
}

# Expected rule set: comment text (matched against `ufw status verbose`) and the
# `ufw allow` arguments used when the rule is missing.
expected_rules() {
  printf '%s\t%s\n' 'remote administration' "OpenSSH comment 'remote administration'"
  printf '%s\t%s\n' 'nginx HTTP redirect/app access' "80/tcp comment 'nginx HTTP redirect/app access'"
  printf '%s\t%s\n' 'nginx HTTPS camera apps/MCP/auth' "443/tcp comment 'nginx HTTPS camera apps/MCP/auth'"
  printf '%s\t%s\n' 'DNS service for camera/LAN names' "53/tcp comment 'DNS service for camera/LAN names'"
  printf '%s\t%s\n' 'DNS service for camera/LAN names' "53/udp comment 'DNS service for camera/LAN names'"
  printf '%s\t%s\n' 'Kea DHCP on isolated camera network' "in on $iface to any port 67 proto udp comment 'Kea DHCP on isolated camera network'"
  printf '%s\t%s\n' 'MediaMTX WebRTC ICE/media' "8189/udp comment 'MediaMTX WebRTC ICE/media'"
  printf '%s\t%s\n' 'ONVIF WS-Discovery/libonvif' "3702/udp comment 'ONVIF WS-Discovery/libonvif'"
  printf '%s\t%s\n' 'ONVIF/libonvif UDP discovery replies from isolated cameras' "in on $iface from $camera_subnet proto udp to any port $ephemeral_range comment 'ONVIF/libonvif UDP discovery replies from isolated cameras'"
}

expected_defaults() {
  printf '%s\t%s\n' 'deny (incoming)' 'deny incoming'
  printf '%s\t%s\n' 'allow (outgoing)' 'allow outgoing'
  printf '%s\t%s\n' 'deny (routed)' 'deny routed'
}

preflight() {
  require_values
  echo '== preflight =='
  ip -br addr
  echo
  ip route
  echo
  echo "ephemeral_udp_range=$ephemeral_range (from /proc/sys/net/ipv4/ip_local_port_range)"
  if ! ss -ltn 'sport = :22' | grep -q ':22'; then
    echo 'WARNING: sshd is not listening on 22; confirm SSH access before enabling UFW on a remote machine.' >&2
  fi
  sudo ufw status verbose || true
}

ensure_defaults() {
  local status_line line want set
  status_line="$(sudo ufw status verbose | sed -n 's/^Default: //p')"
  echo "current defaults: ${status_line:-none}"
  while IFS=$'\t' read -r want set; do
    if [[ "$status_line" == *"$want"* ]]; then
      echo "default ok: $want"
    else
      sudo ufw default "$set"
      echo "default set: $set"
    fi
  done < <(expected_defaults)
}

ensure_rules() {
  local status_out desc args
  status_out="$(sudo ufw status verbose)"
  while IFS=$'\t' read -r desc args; do
    if grep -qF "$desc" <<< "$status_out"; then
      echo "rule present: $desc"
    else
      # shellcheck disable=SC2086
      sudo ufw allow $args
      echo "rule added: $desc"
    fi
  done < <(expected_rules)
}

ensure_enabled() {
  if sudo ufw status verbose | grep -q '^Status: active'; then
    echo 'ufw: active'
  else
    sudo ufw --force enable
    echo 'ufw: enabled'
  fi
}

check_listeners() {
  echo '== listeners =='
  sudo ss -H -lunp 'sport = :3702' || true
  sudo ss -H -lunp 'sport = :8189' || true
  sudo ss -H -ltnp 'sport = :443' || true
}

apply_firewall() {
  require_values
  preflight
  echo '== ensure defaults (idempotent) =='
  ensure_defaults
  echo '== ensure rules (idempotent) =='
  ensure_rules
  echo '== enable =='
  ensure_enabled
  echo '== verify =='
  status_firewall
}

status_firewall() {
  require_values
  local status_out missing=0 desc args
  status_out="$(sudo ufw status verbose)"
  echo '== ufw status =='
  echo "$status_out"
  echo '== expected rule check =='
  while IFS=$'\t' read -r desc args; do
    if grep -qF "$desc" <<< "$status_out"; then
      echo "present: $desc"
    else
      echo "MISSING: $desc"
      missing=$((missing + 1))
    fi
  done < <(expected_rules)
  check_listeners
  if [[ "$missing" -gt 0 ]]; then
    echo "FAIL: $missing expected rule(s) missing" >&2
    exit 1
  fi
  echo 'all expected rules present'
}

case "$cmd" in
  preflight) preflight ;;
  apply) apply_firewall ;;
  status) status_firewall ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
