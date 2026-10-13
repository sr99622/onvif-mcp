#!/usr/bin/env bash
set -euo pipefail
usage() { cat <<'HELP'
Usage: tailscale_runbook.sh apply|verify|status --server-fqdn FQDN [--tailscale-ip IP]
       tailscale_runbook.sh remove
Configures an isolated DNS-only dnsmasq instance for Tailscale.
The Tailscale admin console split-DNS setting is configured separately.
HELP
}
cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }; shift || :
fqdn=""; ip=""
while (($#)); do
 case "$1" in
  --server-fqdn) fqdn="${2:?missing fqdn}"; shift 2;;
  --tailscale-ip) ip="${2:?missing IP}"; shift 2;;
  -h|--help) usage; exit 0;;
  *) echo "Unknown argument: $1" >&2; exit 64;;
 esac
done
DIR=/etc/dnsmasq.d-tailscale
CONF="$DIR/tailscale.conf"
SERVICE=/etc/systemd/system/dnsmasq-tailscale.service
get_ip() {
 command -v tailscale >/dev/null || { echo 'tailscale is required' >&2; exit 1; }
 local actual
 actual="$(tailscale ip -4 | head -n1)"
 [[ "$actual" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'No Tailscale IPv4 address detected' >&2; exit 1; }
 if [[ -n "$ip" && "$ip" != "$actual" ]]; then echo "Provided IP $ip differs from current Tailscale IP $actual" >&2; exit 1; fi
 ip="$actual"
}
validate() {
 [[ "$fqdn" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.home\.arpa$ ]] || { echo 'Expected --server-fqdn under home.arpa' >&2; exit 64; }
 get_ip
}
apply() {
 validate
 command -v dnsmasq >/dev/null || { echo 'Install dnsmasq first (see docs/DNS.md)' >&2; exit 1; }
 sudo install -d -m 0755 -o root -g root "$DIR"
 local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
 cat > "$tmp" <<ENDCONF
# Isolated Tailscale DNS instance; do not include other dnsmasq config directories.
port=53
listen-address=$ip
bind-interfaces
local=/home.arpa/
address=/$fqdn/$ip
# Prevent forwarding unknown private-zone queries to public resolvers.
no-resolv
domain-needed
bogus-priv
ENDCONF
 sudo install -m 0644 -o root -g root "$tmp" "$CONF"
 cat > "$tmp" <<'ENDUNIT'
[Unit]
Description=dnsmasq DNS Server for Tailscale
After=tailscaled.service
Requires=tailscaled.service

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --no-daemon --conf-file=/dev/null --conf-dir=/etc/dnsmasq.d-tailscale
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
ENDUNIT
 sudo install -m 0644 -o root -g root "$tmp" "$SERVICE"
 sudo dnsmasq --test --conf-file=/dev/null --conf-dir="$DIR"
 sudo systemctl daemon-reload
 sudo systemctl enable --now dnsmasq-tailscale.service
 sudo systemctl restart dnsmasq-tailscale.service
 verify
 echo 'Next: Tailscale Admin Console > DNS > Add nameserver > Custom; IP above; restrict to home.arpa.'
}
verify() {
 validate
 sudo dnsmasq --test --conf-file=/dev/null --conf-dir="$DIR"
 systemctl is-active --quiet dnsmasq-tailscale.service
 systemctl is-enabled --quiet dnsmasq-tailscale.service
 grep -Fx "listen-address=$ip" "$CONF" >/dev/null
 grep -Fx "address=/$fqdn/$ip" "$CONF" >/dev/null
 [[ "$(dig +time=2 +tries=1 +short @"$ip" "$fqdn" A)" == "$ip" ]] || { echo 'DNS lookup failed' >&2; exit 1; }
 for proto in udp tcp; do
  sudo ss -H "$( [[ "$proto" == tcp ]] && echo -lntp || echo -lnup )" 'sport = :53' | grep -F "$ip:53" >/dev/null || { echo "Missing $proto listener" >&2; exit 1; }
 done
 echo "verify-ok: $fqdn -> $ip"
}
status() {
 echo '== Tailscale =='; tailscale ip -4
 echo '== service =='; systemctl status --no-pager dnsmasq-tailscale.service || :
 echo '== listeners =='; sudo ss -lunpt | grep ':53' || :
 echo '== configuration =='; sudo cat "$CONF" || :
}
remove() {
 sudo systemctl disable --now dnsmasq-tailscale.service
 sudo rm -f "$SERVICE" "$CONF"
 sudo systemctl daemon-reload
 echo 'Tailscale DNS service removed. Remove the home.arpa split-DNS nameserver in Tailscale Admin Console manually.'
}
case "$cmd" in
 apply) apply;; verify) verify;; status) status;; remove) remove;; *) usage; exit 64;;
esac
