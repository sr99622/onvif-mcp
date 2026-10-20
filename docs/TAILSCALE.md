# Tailscale DNS and HTTPS Runbook for the Camera Server

## Purpose

For the purposes of example, the name `nuc.home.arpa` is used as the 
{{SERVER_FQDN}} in this document. Your actual installation will be different.

Enable remote access to the existing OAuth-protected HTTPS camera server at
`https://nuc.home.arpa` over Tailscale, without replacing its certificate or
changing OAuth redirect URLs. Tailscale's MagicDNS name
(`nuc.tailxxxxxx.ts.net`) is **not** used as the HTTPS origin because the
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
| `{{TAILSCALE_IP}}` | Detected from `tailscale ip -4` |
| `{{REPO_PATH}}` | Local checkout of `onvif-mcp` |
| `{{TAILNET_DNS_NAME}}` | `nuc.tailxxxxxx.ts.net` (not the HTTPS URL) |
| `{{LAN_DNS_IP}}` | LAN dnsmasq instance that holds the host mappings |
| `{{LAN_SUBNET}}` | `10.1.1.0/24` — advertised as a Tailscale subnet route |

**Agent presentation rule:** Resolve placeholders before showing or executing
commands. The script detects the Tailscale IPv4 address automatically; never
assume the historical value remains current.

## Architecture and design decisions

| DNS endpoint | dnsmasq configuration | Answer for `{{SERVER_FQDN}}` | Other `home.arpa` names |
|---|---|---|---|
| `192.168.68.6:53` | `/etc/dnsmasq.d/camera-system.conf` | `192.168.68.6` | per that conf-dir |
| `10.1.1.6:53` | `/etc/dnsmasq.d-10/` | `10.1.1.6` | per that conf-dir (authoritative host list) |
| `{{TAILSCALE_IP}}:53` | `/etc/dnsmasq.d-tailscale/tailscale.conf` | `{{TAILSCALE_IP}}` | forwarded to `{{LAN_DNS_IP}}` |

- Values shown above are for example purposes only, do not assume that they apply
  to the current installation. In most cases, there will only be one local network
  to consider, this example shows two local networks.
- The new DNS instance is separate from the existing LAN and camera DNS services.
- Bind only to the Tailscale IPv4 address, on UDP and TCP port 53; do not bind
  to `0.0.0.0`, localhost, or either LAN interface.
- Use `--conf-file=/dev/null` and an isolated include directory so the existing
  dnsmasq configuration cannot override the Tailscale answers.
- `home.arpa` is a private authoritative zone. The Tailscale instance answers
  only the camera-server name locally (with the Tailscale IP); every other
  `home.arpa` name is forwarded to the LAN dnsmasq instance at `{{LAN_DNS_IP}}`,
  which is the single authoritative host list. Do not add `local=/home.arpa/`
  to the Tailscale conf — it blocks forwarding and NXDOMAINs every name not
  listed in that file (this was the original failure mode).

### Tradeoffs of the forwarding design

- **Single source of truth (chosen):** host mappings live only in the LAN
  conf-dir (`/etc/dnsmasq.d-10/`). Adding a host requires editing exactly one
  file. The earlier duplicate-entries design drifted: the Tailscale instance
  knew only the camera server, so every other `home.arpa` name NXDOMAINed
  through the split-DNS path.
- **Reachability tradeoff:** forwarded answers are LAN IPs. They are reachable
  from devices on the LAN, and from tailnet clients only through the advertised
  subnet route once it is enabled in the admin console. Until the route is
  enabled, remote clients receive correct names but unreachable addresses.
  Hosts that are not themselves tailnet nodes (e.g. `taurus`) are expected to
  be unreachable from remote clients until then. The camera server's own name
  is still answered with the Tailscale IP, so HTTPS/OAuth access does not
  depend on the route.
- **Dependency tradeoff:** the Tailscale instance now depends on the LAN
  instance being up for every name except the camera server — one extra hop and
  a single point of failure for the rest of the zone.
- **PTR tradeoff:** `bogus-priv` is intentionally omitted on the Tailscale
  instance so private-zone PTR queries forward to the LAN instance; the LAN
  instance keeps `bogus-priv`, so private reverse queries never reach public
  resolvers.
- **Rejected alternative:** running tailscaled on each host and mapping
  `home.arpa` names to per-host Tailscale IPs keeps answers reachable without a
  subnet route, but reintroduces per-host bookkeeping; MagicDNS already resolves
  tailnet node names on its own.
- No DHCP service is enabled by this procedure. Subnet routing for
  `{{LAN_SUBNET}}` is advertised by the script but must be enabled in the admin
  console.
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
   `bind-interfaces`, `server={{LAN_DNS_IP}}` (forwarding for unknown zone
   names), and the camera server's address record. No `local=/home.arpa/`.
3. Creates `/etc/systemd/system/dnsmasq-tailscale.service`, ordered after and
   requiring `tailscaled.service`.
4. Validates dnsmasq configuration, reloads systemd, and enables/restarts the
   isolated service.
5. Advertises `{{LAN_SUBNET}}` via `sudo tailscale set --advertise-routes=`
   (the CLI requires root unless an operator grant was set).
6. Runs server-side verification and prints the next manual steps.

The operation is repeatable. Re-run `apply` after the Tailscale IPv4 address
changes. It does not modify either existing dnsmasq service.

## 2. Advertise the LAN subnet route (AGENT-run plus MANUAL enable)

The script's `apply` advertises `{{LAN_SUBNET}}` from this node. Advertising is
not activation: the route must be enabled in the admin console
(Machines > this node > Edit route settings) before tailnet clients can use it.

Until the route is enabled, remote clients resolve `home.arpa` names correctly
but cannot reach the LAN addresses they are given — expected for hosts that are
not tailnet nodes. If remote reachability is not desired yet, leave the route
un-advertised (`sudo tailscale set --advertise-routes=`); LAN clients are
unaffected.

Tailnet ACLs/grants must permit the subnet for the clients that need it.

## 3. Configure split DNS in Tailscale (MANUAL)

In the [Tailscale DNS admin console](https://login.tailscale.com/admin/dns):

1. Under **Nameservers**, add a **Custom** nameserver.
2. Set its address to `{{TAILSCALE_IP}}`.
3. Enable **Restrict to domain** and set the domain to `home.arpa`.
4. Save. Ensure clients accept Tailscale DNS settings.

Do not replace the default resolver for all domains. The restricted nameserver
only receives queries for the private zone. Check for overlapping `home.arpa`
resolver settings on remote devices.

## 4. Verify (AGENT-run and remote-client test)

Run the script's `verify` command with `--server-fqdn {{SERVER_FQDN}}`.
It checks configuration syntax, service enabled/active state, the expected DNS
record, the `server={{LAN_DNS_IP}}` forwarding line, the advertised route, and
UDP/TCP listeners on the Tailscale IP.

Forwarding verification requires a `home.arpa` name that exists only in the LAN
conf-dir (e.g. `dig +short taurus.home.arpa @{{TAILSCALE_IP}}` must return the
LAN answer, not NXDOMAIN).

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

## 5. Status and troubleshooting

Use the script's `status` command. Investigate the following in order:

- **Connection refused / timeout on port 53:** check service status, listening
  address, host firewall, and tailnet access policy.
- **Explicit DNS query works, ordinary lookup fails:** check Tailscale split DNS,
  the client's *accept DNS* setting, and competing resolver configuration.
- **Name resolves to a LAN IP:** expected for every name except the camera
  server (forwarded from the LAN instance). If a remote client cannot reach
  that IP, check the subnet route is enabled in the admin console and that
  ACLs/grants permit the subnet; hosts that are not tailnet nodes are
  unreachable from remote clients until the route is active.
- **HTTPS hostname mismatch:** use `nuc.home.arpa`, not the `.ts.net` alias.
- **Untrusted certificate:** install/trust the camera system's private CA on
  the remote device; do not disable certificate verification.
- **OAuth redirect fails:** check provider reachability and redirect/origin
  settings; preserve the existing `nuc.home.arpa` hostname.
- **After a reboot:** verify the Tailscale address is assigned before the
  service starts. A changed IP requires re-running `apply` and updating the
  Tailscale nameserver setting.

## 6. Rollback (AGENT-run plus MANUAL)

Run the script's `remove` command to disable the Tailscale-only DNS service,
remove its unit/configuration, and un-advertise `{{LAN_SUBNET}}`. Then remove
the restricted `home.arpa` nameserver from the Tailscale admin console. Existing
LAN and camera DNS are unchanged.

## Security and scope

Tailscale provides private network connectivity, not automatic browser trust
for a private HTTPS CA. Restrict DNS and HTTPS access with tailnet policy and
host firewall rules. This runbook does not configure public DNS, Tailscale
Funnel, or a new TLS certificate; it advertises the `{{LAN_SUBNET}}` subnet
route (enablement in the admin console is a manual step) and forwards the
private `home.arpa` zone to the LAN dnsmasq instance.
