#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  dhcp_runbook.sh apply --interface IFACE
  dhcp_runbook.sh status --interface IFACE

Configures the isolated private camera subnet from docs/DHCP.md.
Site-specific values are passed as arguments; do not edit this script per site.
USAGE
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then usage; exit 64; fi
if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then usage; exit 0; fi
shift || true

iface=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interface) iface="${2:?missing --interface value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then echo "Missing required argument: $name" >&2; exit 64; fi
}

require_iface() {
  require_arg --interface "$iface"
  ip link show dev "$iface" >/dev/null
}

install_packages() {
  missing=()
  command -v nmcli >/dev/null 2>&1 || missing+=(network-manager)
  command -v kea-dhcp4 >/dev/null 2>&1 || missing+=(kea-dhcp4-server)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
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

write_kea_config() {
  local iface="$1"
  sudo install -d -m 0755 /etc/kea
  if [[ -f /etc/kea/kea-dhcp4.conf && ! -f /etc/kea/kea-dhcp4.conf.backup ]]; then
    sudo cp /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.backup
  fi
  python3 - "$iface" <<'PY' | sudo tee /etc/kea/kea-dhcp4.conf >/dev/null
import json, sys
iface = sys.argv[1]
conf = {
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [iface],
      "dhcp-socket-type": "raw"
    },
    "lease-database": {
      "type": "memfile",
      "persist": True,
      "name": "/var/lib/kea/kea-leases4.csv"
    },
    "match-client-id": False,
    "decline-probation-period": 0,
    "valid-lifetime": 3600,
    "renew-timer": 900,
    "rebind-timer": 1800,
    "subnet4": [
      {
        "id": 1,
        "subnet": "10.2.2.0/24",
        "pools": [{"pool": "10.2.2.100 - 10.2.2.200"}],
        "option-data": [
          {"name": "routers", "data": "10.2.2.1"},
          {"name": "dhcp-server-identifier", "data": "10.2.2.1"}
        ]
      }
    ],
    "loggers": [
      {
        "name": "kea-dhcp4",
        "output-options": [{"output": "stdout"}],
        "severity": "INFO"
      }
    ]
  }
}
print(json.dumps(conf, indent=2))
PY
  if getent group _kea >/dev/null; then
    sudo chown root:_kea /etc/kea/kea-dhcp4.conf
  else
    sudo chown root:root /etc/kea/kea-dhcp4.conf
  fi
  sudo chmod 0640 /etc/kea/kea-dhcp4.conf
}

configure_networkmanager() {
  local iface="$1"
  if nmcli -t -f NAME connection show | grep -Fxq isolated; then
    sudo nmcli connection modify isolated \
      type ethernet \
      connection.interface-name "$iface" \
      ipv4.method manual \
      ipv4.addresses 10.2.2.1/24 \
      ipv4.never-default yes \
      ipv4.ignore-auto-dns yes \
      ipv4.gateway "" \
      ipv4.dns "" \
      ipv4.routes "" \
      ipv6.method disabled \
      connection.autoconnect yes
  else
    sudo nmcli connection add \
      type ethernet \
      ifname "$iface" \
      con-name isolated \
      ipv4.method manual \
      ipv4.addresses 10.2.2.1/24 \
      ipv4.never-default yes \
      ipv4.ignore-auto-dns yes \
      ipv6.method disabled \
      connection.autoconnect yes
    sudo nmcli connection modify isolated ipv4.gateway "" ipv4.dns "" ipv4.routes ""
  fi

  active_on_iface="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$iface" '$2 == dev { print $1 }' || true)"
  while IFS= read -r con; do
    [[ -z "$con" || "$con" == "isolated" ]] && continue
    sudo nmcli connection down "$con" || true
  done <<< "$active_on_iface"

  sudo nmcli connection up isolated
}

configure_forwarding() {
  printf 'net.ipv4.ip_forward=0\nnet.ipv6.conf.all.forwarding=0\n' | sudo tee /etc/sysctl.d/90-isolated.conf >/dev/null
  sudo sysctl --system >/dev/null
}

validate_and_start_kea() {
  if getent passwd _kea >/dev/null; then
    sudo -u _kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
  else
    sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
  fi
  sudo systemctl enable --now kea-dhcp4-server
  sudo systemctl restart kea-dhcp4-server
  systemctl is-active kea-dhcp4-server
}

print_status() {
  local iface="$1"
  echo "== NetworkManager device =="
  nmcli device status | sed -n '1p;/^'"$iface"'[[:space:]]/p'
  echo "== Interface address =="
  ip address show dev "$iface"
  echo "== Interface routes =="
  ip route show dev "$iface" || true
  echo "== Forwarding =="
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
  echo "== Kea config validation =="
  if [[ -f /etc/kea/kea-dhcp4.conf ]]; then
    if getent passwd _kea >/dev/null; then sudo -u _kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf; else sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf; fi
  else
    echo "missing /etc/kea/kea-dhcp4.conf"
  fi
  echo "== Kea service =="
  systemctl is-enabled kea-dhcp4-server 2>/dev/null || true
  systemctl is-active kea-dhcp4-server 2>/dev/null || true
  echo "== DHCP listener =="
  sudo ss -ulpn | grep ':67' || true
  echo "== Recent Kea logs =="
  sudo journalctl -u kea-dhcp4-server -n 30 --no-pager || true
}

case "$cmd" in
  apply)
    require_iface
    install_packages
    configure_networkmanager "$iface"
    write_kea_config "$iface"
    configure_forwarding
    validate_and_start_kea
    print_status "$iface"
    ;;
  status)
    require_iface
    print_status "$iface"
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 64
    ;;
esac
