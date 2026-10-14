# UFW Firewall Configuration Runbook

## Purpose

Configure UFW for the camera server: keep the default posture closed while
allowing the public camera application endpoints, DNS/DHCP support, WebRTC
media, and ONVIF discovery.

The executable workflow lives in:

```bash
scripts/FIREWALL/firewall_runbook.sh
```

That script is the single source of truth for executable actions. Do not
replace it with ad hoc shell fragments from this document. `apply` is
idempotent: defaults and rules are created or verified, never duplicated, and
existing rules are never removed.

The important non-obvious rule is the ONVIF discovery reply range. Opening UDP
3702 alone is not enough for libonvif discovery on this host. Cameras answer
discovery probes back to Linux ephemeral UDP destination ports on the server.
If those replies are blocked, remote MCP calls to `get_cameras` can return an
empty result even though UDP 3702 is open.

## Required Values

| Symbol | Description |
|---|---|
| `{{PRVT_NET_EN_NAME}}` | Isolated camera network interface |
| `{{CAMERA_SUBNET}}` | Isolated camera subnet (`10.2.2.0/24`) |
| `{{SERVER_FQDN}}` | Canonical server DNS name used by the Hermes MCP entry |
| `{{CA_ROOT_PATH}}` | Private CA root; the CA PEM used as the Hermes `ssl_verify` bundle |
| `{{REPO_PATH}}` | Full path to this repository |

## Derived Values

| Symbol | Description |
|---|---|
| `{{EPHEMERAL_UDP_RANGE}}` | Linux UDP destination ports used for discovery replies; captured live from `/proc/sys/net/ipv4/ip_local_port_range` and written as `LOW:HIGH` for UFW, not typed by the user |

Before applying this elsewhere, verify the interface names, subnets, and
ephemeral port range on the target server.

## Design decisions

- Defaults: deny incoming, allow outgoing, deny routed. Routed traffic stays
  denied by default; that is intentional for the isolated camera network.
- Ports:

| Port | Protocol | Scope | Purpose |
|---:|---|---|---|
| 22 | TCP | any | OpenSSH remote administration |
| 80 | TCP | any | Nginx HTTP redirect/app entry point |
| 443 | TCP | any | Nginx HTTPS camera apps, MCP, and auth |
| 53 | TCP/UDP | any | DNS service for camera/LAN names |
| 67 | UDP | `{{PRVT_NET_EN_NAME}}` only | Kea DHCP on isolated camera network |
| 8189 | UDP | any, or restrict to trusted client networks | MediaMTX WebRTC ICE/DTLS/SRTP media |
| 3702 | UDP | any, or restrict to trusted camera networks | ONVIF WS-Discovery probe traffic |
| `{{EPHEMERAL_UDP_RANGE}}` | UDP | trusted camera subnets only | ONVIF/libonvif discovery replies from cameras |

- Loopback-only services do not need public UFW rules: MCP HTTP
  (`127.0.0.1:8001`), Keycloak (`127.0.0.1:8080`), oauth2-proxy
  (`127.0.0.1:4180`), MediaMTX RTSP (`127.0.0.1:8554`), MediaMTX WebRTC
  signaling (`127.0.0.1:8889`), and the snapshot proxy (`127.0.0.1:8891`).
- IPv6 companion rules for SSH, HTTP, HTTPS, DNS, DHCP, 8189, and 3702 are
  acceptable when UFW creates them automatically. The IPv4 ephemeral UDP reply
  rule is the critical libonvif discovery fix.
- Firewall state is not captured by any backup checkpoint. This is an accepted
  gap: restore it by re-running this runbook.

## Agent Presentation Rules

Before presenting or executing any command, replace every double-curly
placeholder with the real site value. Do not ask the user to type or edit
placeholders.

## 0. Preflight (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}
scripts/FIREWALL/firewall_runbook.sh preflight \
  --prvt-net-en-name {{PRVT_NET_EN_NAME}} \
  --camera-subnet {{CAMERA_SUBNET}}
```

The script prints interfaces, routes, the live ephemeral UDP range, and current
UFW state, and warns if sshd is not listening on 22. Confirm before continuing:

- The LAN interface and camera interface names match the values you plan to use.
- The trusted camera subnets are correct.
- SSH is available before enabling UFW on a remote machine.

## 1. Apply firewall rules (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/FIREWALL/firewall_runbook.sh apply \
  --prvt-net-en-name {{PRVT_NET_EN_NAME}} \
  --camera-subnet {{CAMERA_SUBNET}}
```

The `apply` command performs the full workflow:

- verifies the camera interface exists and derives `{{EPHEMERAL_UDP_RANGE}}`
  live from `/proc/sys/net/ipv4/ip_local_port_range`;
- ensures the defaults (deny incoming, allow outgoing, deny routed);
- ensures each expected rule, adding only the missing ones with the documented
  comments;
- enables UFW if not already active;
- runs the status checks below.

To rebuild from a clean baseline, reset UFW manually first
(`sudo ufw --force reset`); the runbook itself never removes existing rules.

## 2. Verify final state (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/FIREWALL/firewall_runbook.sh status \
  --prvt-net-en-name {{PRVT_NET_EN_NAME}} \
  --camera-subnet {{CAMERA_SUBNET}}
```

Acceptance checks:

- UFW is active with the expected defaults.
- Every expected rule is present (the script reports `MISSING` and exits
  nonzero otherwise).
- Listeners are visible on UDP 3702, UDP 8189, and TCP 443.

Expected rules on this host:

```text
OpenSSH                         ALLOW IN    Anywhere
80/tcp                          ALLOW IN    Anywhere
443/tcp                         ALLOW IN    Anywhere
53/tcp                          ALLOW IN    Anywhere
53/udp                          ALLOW IN    Anywhere
67/udp on {{PRVT_NET_EN_NAME}}  ALLOW IN    Anywhere
8189/udp                        ALLOW IN    Anywhere
3702/udp                        ALLOW IN    Anywhere
32768:60999/udp on {{PRVT_NET_EN_NAME}} ALLOW IN {{CAMERA_SUBNET}}
```

Then check the camera MCP locally or through Hermes:

```bash
hermes mcp test camera
```

If the test fails with `CERTIFICATE_VERIFY_FAILED` (self-signed certificate in
certificate chain), the Hermes entry predates `SITE_CERT.md`: nginx now
redirects HTTP to HTTPS and the private CA is not in the system trust store.
Update the Hermes entry with the HTTPS URL and the private CA bundle, then
reload MCP (`/reload-mcp` in a live session, or restart Hermes):

```bash
hermes config set mcp_servers.camera.url https://{{SERVER_FQDN}}/mcp
hermes config set mcp_servers.camera.ssl_verify {{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem
```

Use `hermes config set` rather than editing `config.yaml` by hand.
`ssl_verify` accepts `true` (system CAs), `false` (insecure; do not use), or a
path to a PEM CA bundle — the private CA path above is the correct form for
this deployment. Rerun `hermes mcp test camera` after the reload; it must
connect and list the camera tools.

Then run the camera MCP tool `get_cameras`. It must return camera summaries,
not an empty string. A healthy result on this deployment includes cameras from
`{{CAMERA_SUBNET}}`.

If `get_cameras` is still empty, inspect UFW blocks while running discovery:

```bash
sudo journalctl -k -n 200 --no-pager | grep -i 'UFW\|3702'
```

Look for blocked UDP packets from camera IPs to destination ports in the
ephemeral range. If present, the reply rules are missing, on the wrong
interface, or scoped to the wrong subnet.

## Pitfalls and notes

- Do not replace the ephemeral range with only UDP 3702. ONVIF probes use 3702,
  but libonvif receives replies on ephemeral UDP ports.
- Do not open the ephemeral UDP range from `Anywhere` unless this is a temporary
  diagnostic step. Keep it restricted to trusted camera subnets and interfaces.
- If the kernel ephemeral range differs from `32768 60999`, the script uses the
  live range from `/proc/sys/net/ipv4/ip_local_port_range`.
- If cameras live on a different subnet, add a matching interface/subnet rule
  for that subnet instead of broadening the existing rules.
- Re-running `apply` on an already-configured host is a no-op verification pass;
  it will not reorder or duplicate rules.
