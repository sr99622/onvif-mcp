# Tailscale DNS and HTTPS Runbook for the Camera Server

## Purpose

Enable remote access to the existing OAuth-protected HTTPS camera server at
`https://nuc.home.arpa` over Tailscale, without replacing its certificate or
changing OAuth redirect URLs. Tailscale's MagicDNS name
(`nuc.tail7fbde1.ts.net`) is **not** used as the HTTPS origin because the
existing certificate covers `nuc.home.arpa`.

The executable workflow lives in:

```text
scripts/TAILSCALE/tailscale_runbook.sh
```

That script is the **single source of truth for executable server-side actions**.
Do not copy shell commands into this document and independently maintain them.
The Tailscale admin-console operation is a manual step.

## Required values

| Symbol | Value / description |
|---|---|
| `{{SERVER_FQDN}}` | `nuc.home.arpa` for this installation |
| `{{TAILSCALE_IP}}` | Detected from `tailscale ip -4`; currently `100.102.249.72` |
| `{{REPO_PATH}}` | Local checkout of `onvif-mcp` |
| `{{TAILNET_DNS_NAME}}` | `nuc.tail7fbde1.ts.net` (not the HTTPS URL) |

**Agent presentation rule:** Resolve placeholders before showing or executing
commands. The script detects the Tailscale IPv4 address automatically; never
assume the historical value remains current.

## Architecture and design decisions

| DNS endpoint | dnsmasq configuration | Answer for `nuc.home.arpa` |
|---|---|---|
| `192.168.68.6:53` | `/etc/dnsmasq.d/camera-system.conf` | `192.168.68.6` |
| `10.1.1.6:53` | `/etc/dnsmasq.d-10/` | `10.1.1.6` |
| `{{TAILSCALE_IP}}:53` | `/etc/dnsmasq.d-tailscale/tailscale.conf` | `{{TAILSCALE_IP}}` |

- The new DNS instance is separate from the existing LAN and camera DNS services.
- Bind only to the Tailscale IPv4 address, on UDP and TCP port 53; do not bind
  to `0.0.0.0`, localhost, or either LAN interface.
- Use `--conf-file=/dev/null` and an isolated include directory so the existing
  dnsmasq configuration cannot override the Tailscale answers.
- `home.arpa` is a private authoritative zone; this instance answers only the
  configured camera-server name. Other `home.arpa` names require explicit
  additional configuration and reachable routes.
- No DHCP service or subnet routing is enabled by this procedure.
- `systemd-resolved` remains on its existing loopback stub addresses.
- The HTTPS hostname stays `nuc.home.arpa`; remote devices must trust the
  existing private root CA.
- Tailscale ACL/grants and host firewall rules must allow authorized clients to
  reach DNS (UDP/TCP 53) and the HTTPS/OAuth endpoints. Keep DNS limited to
  trusted tailnet devices.

## Prerequisites

- Tailscale is installed, authenticated, and connected on `nuc` and the remote client.
- The DNS configuration in [DNS.md](DNS.md) is already functioning.
- `dnsmasq`, `dig` (`dnsutils`), and `ss` (`iproute2`) are installed.
- The HTTPS service is listening on an address reachable through `tailscale0`.
- If the OAuth identity provider runs elsewhere, it must also be reachable from
  remote clients and use hostname/certificate combinations they can validate.

## 0. Detect and inspect (AGENT-run)

From the repository checkout, run the script's `status` command. It reports the
current Tailscale IPv4 address, service state, DNS listeners, and configuration.
Review the output before applying changes, especially if Tailscale's IP changed.

## 1. Apply the Tailscale DNS configuration (AGENT-run)

Run the script's `apply` command with `--server-fqdn {{SERVER_FQDN}}`.

The `apply` command:

1. Obtains and validates the current Tailscale IPv4 address.
2. Creates `/etc/dnsmasq.d-tailscale/tailscale.conf` with `listen-address`,
   `bind-interfaces`, `local=/home.arpa/`, and the server's address record.
3. Creates `/etc/systemd/system/dnsmasq-tailscale.service`, ordered after and
   requiring `tailscaled.service`.
4. Validates dnsmasq configuration, reloads systemd, and enables/restarts the
   isolated service.
5. Runs server-side verification and prints the next manual DNS step.

The operation is repeatable. Re-run `apply` after the Tailscale IPv4 address
changes. It does not modify either existing dnsmasq service.

## 2. Configure split DNS in Tailscale (MANUAL)

In the [Tailscale DNS admin console](https://login.tailscale.com/admin/dns):

1. Under **Nameservers**, add a **Custom** nameserver.
2. Set its address to `{{TAILSCALE_IP}}`.
3. Enable **Restrict to domain** and set the domain to `home.arpa`.
4. Save. Ensure clients accept Tailscale DNS settings.

Do not replace the default resolver for all domains. The restricted nameserver
only receives queries for the private zone. Check for overlapping `home.arpa`
resolver settings on remote devices.

## 3. Verify (AGENT-run and remote-client test)

Run the script's `verify` command with `--server-fqdn {{SERVER_FQDN}}`.
It checks configuration syntax, service enabled/active state, the expected DNS
record, and UDP/TCP listeners on the Tailscale IP.

From a **different** device connected to the tailnet, confirm that:

- A DNS query explicitly directed to `{{TAILSCALE_IP}}` returns that address for
  `{{SERVER_FQDN}}`.
- A normal system DNS lookup for `{{SERVER_FQDN}}` also returns that address.
- `https://{{SERVER_FQDN}}` connects with a trusted certificate whose name
  matches the requested host.
- The OAuth login and callback work end-to-end.

A successful local DNS lookup alone does **not** verify Tailscale split DNS,
firewall reachability, or certificate trust on the remote device. Note that
`dig` can bypass the OS's split-DNS resolver on some platforms; prefer a
system-resolver lookup for the second check.

## 4. Status and troubleshooting

Use the script's `status` command. Investigate the following in order:

- **Connection refused / timeout on port 53:** check service status, listening
  address, host firewall, and tailnet access policy.
- **Explicit DNS query works, ordinary lookup fails:** check Tailscale split DNS,
  the client's *accept DNS* setting, and competing resolver configuration.
- **Name resolves to a LAN IP:** check that the client is using the Tailscale
  DNS instance, not the LAN or camera-network dnsmasq instance.
- **HTTPS hostname mismatch:** use `nuc.home.arpa`, not the `.ts.net` alias.
- **Untrusted certificate:** install/trust the camera system's private CA on
  the remote device; do not disable certificate verification.
- **OAuth redirect fails:** check provider reachability and redirect/origin
  settings; preserve the existing `nuc.home.arpa` hostname.
- **After a reboot:** verify the Tailscale address is assigned before the
  service starts. A changed IP requires re-running `apply` and updating the
  Tailscale nameserver setting.

## 5. Rollback (AGENT-run plus MANUAL)

Run the script's `remove` command to disable the Tailscale-only DNS service and
remove its unit/configuration. Then remove the restricted `home.arpa` nameserver
from the Tailscale admin console. Existing LAN and camera DNS are unchanged.

## Security and scope

Tailscale provides private network connectivity, not automatic browser trust
for a private HTTPS CA. Restrict DNS and HTTPS access with tailnet policy and
host firewall rules. This runbook does not configure public DNS, Tailscale
Funnel, subnet routers, or a new TLS certificate.
