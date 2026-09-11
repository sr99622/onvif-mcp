# UFW Firewall Configuration

This runbook configures UFW for the camera server. It keeps the default posture closed while allowing the public camera application endpoints, DNS/DHCP support, WebRTC media, and ONVIF discovery.

The important non-obvious rule is the ONVIF discovery reply range. Opening UDP 3702 alone is not enough for libonvif discovery on this host. Cameras answer discovery probes back to Linux ephemeral UDP destination ports on the server. If those replies are blocked, remote MCP calls to `get_cameras` can return an empty result even though UDP 3702 is open.

## Values used in this deployment

| Symbol | Current value | Meaning |
|---|---:|---|
| `{{LAN_IFACE}}` | `enp170s0` | Main LAN interface |
| `{{LAN_SUBNET}}` | `10.1.1.0/24` | Trusted LAN camera/client subnet |
| `{{CAMERA_IFACE}}` | `enp171s0` | Isolated camera network interface |
| `{{CAMERA_SUBNET}}` | `10.2.2.0/24` | Isolated camera subnet |
| `{{EPHEMERAL_UDP_RANGE}}` | `32768:60999` | Linux UDP destination ports used for discovery replies |

Before applying this elsewhere, verify the interface names, subnets, and ephemeral port range on the target server.

## Ports

| Port | Protocol | Scope | Purpose |
|---:|---|---|---|
| 22 | TCP | any | OpenSSH remote administration |
| 80 | TCP | any | Nginx HTTP redirect/app entry point |
| 443 | TCP | any | Nginx HTTPS camera apps, MCP, and auth |
| 53 | TCP/UDP | any | DNS service for camera/LAN names |
| 67 | UDP | `{{CAMERA_IFACE}}` only | Kea DHCP on isolated camera network |
| 8189 | UDP | any, or restrict to trusted client networks | MediaMTX WebRTC ICE/DTLS/SRTP media |
| 3702 | UDP | any, or restrict to trusted camera networks | ONVIF WS-Discovery probe traffic |
| `{{EPHEMERAL_UDP_RANGE}}` | UDP | trusted camera subnets only | ONVIF/libonvif discovery replies from cameras |

Loopback-only services do not need public UFW rules:

- MCP HTTP: `127.0.0.1:8001`
- Keycloak: `127.0.0.1:8080`
- oauth2-proxy: `127.0.0.1:4180`
- MediaMTX RTSP: `127.0.0.1:8554`
- MediaMTX WebRTC signaling: `127.0.0.1:8889`, proxied by Nginx
- Snapshot proxy: `127.0.0.1:8891`, proxied by Nginx

## Preflight

Run these checks first:

```bash
ip -br addr
ip route
cat /proc/sys/net/ipv4/ip_local_port_range
sudo ufw status verbose || true
sudo ss -ltnup
```

Confirm:

- The LAN interface and camera interface names match the values you plan to use.
- The trusted camera subnets are correct.
- The ephemeral range is captured exactly from `/proc/sys/net/ipv4/ip_local_port_range` and written as `LOW:HIGH` for UFW.
- SSH is available before enabling UFW on a remote machine.

## Apply from a clean UFW baseline

Use this when building the camera server firewall from scratch. It resets existing UFW user rules.

```bash
LAN_IFACE="enp170s0"
LAN_SUBNET="10.1.1.0/24"
CAMERA_IFACE="enp171s0"
CAMERA_SUBNET="10.2.2.0/24"
EPHEMERAL_UDP_RANGE="$(tr '\t ' ':' < /proc/sys/net/ipv4/ip_local_port_range)"

sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed

sudo ufw allow OpenSSH comment 'remote administration'
sudo ufw allow 80/tcp comment 'nginx HTTP redirect/app access'
sudo ufw allow 443/tcp comment 'nginx HTTPS camera apps/MCP/auth'
sudo ufw allow 53/tcp comment 'DNS service for camera/LAN names'
sudo ufw allow 53/udp comment 'DNS service for camera/LAN names'
sudo ufw allow in on "$CAMERA_IFACE" to any port 67 proto udp comment 'Kea DHCP on isolated camera network'
sudo ufw allow 8189/udp comment 'MediaMTX WebRTC ICE/media'
sudo ufw allow 3702/udp comment 'ONVIF WS-Discovery/libonvif'

sudo ufw allow in on "$LAN_IFACE" from "$LAN_SUBNET" proto udp to any port "$EPHEMERAL_UDP_RANGE" comment 'ONVIF/libonvif UDP discovery replies from LAN cameras'
sudo ufw allow in on "$CAMERA_IFACE" from "$CAMERA_SUBNET" proto udp to any port "$EPHEMERAL_UDP_RANGE" comment 'ONVIF/libonvif UDP discovery replies from isolated cameras'

sudo ufw --force enable
sudo ufw status numbered
```

## Add only the missing ONVIF reply rules

Use this if UFW is already enabled and `get_cameras` returns empty after opening UDP 3702.

```bash
LAN_IFACE="enp170s0"
LAN_SUBNET="10.1.1.0/24"
CAMERA_IFACE="enp171s0"
CAMERA_SUBNET="10.2.2.0/24"
EPHEMERAL_UDP_RANGE="$(tr '\t ' ':' < /proc/sys/net/ipv4/ip_local_port_range)"

sudo ufw allow in on "$LAN_IFACE" from "$LAN_SUBNET" proto udp to any port "$EPHEMERAL_UDP_RANGE" comment 'ONVIF/libonvif UDP discovery replies from LAN cameras'
sudo ufw allow in on "$CAMERA_IFACE" from "$CAMERA_SUBNET" proto udp to any port "$EPHEMERAL_UDP_RANGE" comment 'ONVIF/libonvif UDP discovery replies from isolated cameras'
sudo ufw status numbered
```

## Expected rules on this host

```text
OpenSSH                     ALLOW IN    Anywhere
80/tcp                      ALLOW IN    Anywhere
443/tcp                     ALLOW IN    Anywhere
53/tcp                      ALLOW IN    Anywhere
53/udp                      ALLOW IN    Anywhere
67/udp on enp171s0          ALLOW IN    Anywhere
8189/udp                    ALLOW IN    Anywhere
3702/udp                    ALLOW IN    Anywhere
32768:60999/udp on enp170s0 ALLOW IN    10.1.1.0/24
32768:60999/udp on enp171s0 ALLOW IN    10.2.2.0/24
```

IPv6 companion rules for SSH, HTTP, HTTPS, DNS, DHCP, 8189, and 3702 are acceptable when UFW creates them automatically. The IPv4 ephemeral UDP reply rules are the critical libonvif discovery fix for the camera subnets above.

## Verification

Check UFW state:

```bash
sudo ufw status verbose
sudo ufw status numbered
```

Check listeners:

```bash
sudo ss -H -lunp 'sport = :3702'
sudo ss -H -lunp 'sport = :8189' || true
sudo ss -H -ltnp 'sport = :443'
```

Check the camera MCP locally or through Hermes:

```bash
hermes mcp test camera-new
```

Then run the camera MCP tool `get_cameras`. It must return camera summaries, not an empty string. A healthy result on this deployment includes cameras from both `10.1.1.0/24` and `10.2.2.0/24`.

If `get_cameras` is still empty, inspect UFW blocks while running discovery:

```bash
sudo journalctl -k -n 200 --no-pager | grep -i 'UFW\|3702'
```

Look for blocked UDP packets from camera IPs to destination ports in the ephemeral range. If present, the reply rules are missing, on the wrong interface, or scoped to the wrong subnet.

## Troubleshooting notes

- Do not replace the ephemeral range with only UDP 3702. ONVIF probes use 3702, but libonvif receives replies on ephemeral UDP ports.
- Do not open the ephemeral UDP range from `Anywhere` unless this is a temporary diagnostic step. Keep it restricted to trusted camera subnets and interfaces.
- If the kernel ephemeral range differs from `32768 60999`, use the live range from `/proc/sys/net/ipv4/ip_local_port_range`.
- If cameras live on a different subnet, add a matching interface/subnet rule for that subnet instead of broadening the existing rules.
- Routed traffic remains denied by default. That is intentional for the isolated camera network unless a separate runbook explicitly requires forwarding.
