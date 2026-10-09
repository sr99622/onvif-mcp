# Local DNS Runbook for the Camera Server

## Purpose

Configure the Ubuntu camera server to provide local DNS for the private camera
hostname while forwarding public DNS queries upstream.

The executable workflow lives in:

```bash
scripts/DNS/dns_runbook.sh
```

That script is the single source of truth for executable actions. Do not replace
it with ad hoc shell fragments from this document.

## Required Values

| Symbol | Description |
|---|---|
| `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server |
| `{{SERVER_IP}}` | LAN IP address of the server |
| `{{RVRS_SRV_IP}}` | Reverse IP address of the server for PTR lookup |
| `{{UPSTREAM_DNS}}` | Upstream DNS resolver |
| `{{BACKUP_PATH}}` | Backup location (SMB shared folder, mounted external drive, or local folder); must already exist and enforce the SMB-mount permission model (mode 0700 owner-only, no extra ACL entries) |

## Design decisions

- `home.arpa` is used as the private DNS namespace.
- dnsmasq provides DNS only. It does not provide DHCP.
- dnsmasq listens only on `{{SERVER_IP}}`, not on the camera interface, Wi-Fi
  interface, wildcard address, or loopback.
- `systemd-resolved` remains the Ubuntu host resolver on `127.0.0.53` and
  `127.0.0.54`.
- Backups and rollback copies must live outside all dnsmasq include directories.

## DNS backup checkpoint

After the DNS service verifies, the script calls the DNS_BACKUP runbook's
checkpoint script:

```bash
scripts/DNS_BACKUP/dns_backup_runbook.sh create-checkpoint ... --trigger DNS.md
```

That creates a complete checkpoint under:

```text
{{BACKUP_PATH}}/dns/YYYYMMDDHHMMSSZ/
├── dns.tar
├── metadata.txt
└── SHA256SUMS
```

Repeat this runbook after later record, upstream, binding, include, or service
configuration changes.

## Agent Presentation Rules

Before presenting or executing any command, replace every double-curly placeholder
with the real site value. Do not ask the user to type or edit placeholders.

## 1. Configure and verify DNS (AGENT-run)

Run the script with resolved values:

```bash
cd {{REPO_PATH}}
scripts/DNS/dns_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}} \
  --rvrs-srv-ip {{RVRS_SRV_IP}} \
  --upstream-dns {{UPSTREAM_DNS}} \
  --backup-path {{BACKUP_PATH}}
```

The `apply` command performs the full workflow:

- masks `dnsmasq.service` before package installation when installation is needed;
- installs `dnsmasq`, `dnsutils`, and required networking tools;
- verifies port 53 is not held by an unexpected DNS service;
- enables `/etc/dnsmasq.d/*.conf` includes in `/etc/dnsmasq.conf`;
- writes `/etc/dnsmasq.d/camera-system.conf` with:
  - `listen-address={{SERVER_IP}}`
  - `bind-interfaces`
  - `local=/home.arpa/`
  - `address=/{{SERVER_FQDN}}/{{SERVER_IP}}`
  - `no-resolv`
  - `server={{UPSTREAM_DNS}}`
  - `ptr-record={{RVRS_SRV_IP}}.in-addr.arpa,{{SERVER_FQDN}}`
- writes the systemd drop-in that disables resolver-registration hooks;
- sets `IGNORE_RESOLVCONF=yes` in `/etc/default/dnsmasq`;
- validates with `dnsmasq --test`, restarts and enables dnsmasq;
- verifies listeners, A record, PTR record, public forwarding, and private-zone
  NXDOMAIN behavior;
- creates the DNS_BACKUP checkpoint.

## 2. Verify final state (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/DNS/dns_runbook.sh verify \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}} \
  --rvrs-srv-ip {{RVRS_SRV_IP}} \
  --upstream-dns {{UPSTREAM_DNS}}
```

Then inspect status:

```bash
cd {{REPO_PATH}}
scripts/DNS/dns_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}}
```

Verification requires:

- `dnsmasq --test` succeeds.
- dnsmasq is active and enabled.
- dnsmasq listens on UDP/TCP `{{SERVER_IP}}:53` only.
- `{{SERVER_FQDN}}` resolves to `{{SERVER_IP}}` through `@{{SERVER_IP}}`.
- `ubuntu.com` resolves through the configured upstream.
- `nonexistent-test.home.arpa` returns NXDOMAIN.
- reverse lookup for `{{SERVER_IP}}` returns `{{SERVER_FQDN}}.`.
- resolver-registration hooks are disabled and `IGNORE_RESOLVCONF=yes` is set.

## Client configurations

The LAN DHCP server should advertise `{{SERVER_IP}}` as the DNS server to wired
clients. Do not advertise a public resolver as a secondary DNS server, because
clients might bypass the private resolver and fail to resolve `{{SERVER_FQDN}}`.
Clients using static IP settings must be edited individually.

## Client tests

On macOS:

```bash
nslookup {{SERVER_FQDN}} {{SERVER_IP}}
nslookup ubuntu.com {{SERVER_IP}}
```

On Windows:

```cmd
nslookup {{SERVER_FQDN}} {{SERVER_IP}}
nslookup ubuntu.com {{SERVER_IP}}
```

## Pitfalls and notes

- Use a full `systemctl restart dnsmasq.service` after changing records or
  `ptr-record`; reload is not sufficient for every directive.
- Keep rollback copies and checkpoint staging outside `/etc/dnsmasq.d` and any
  other dnsmasq include path.
- This runbook does not configure DHCP. DHCP/DNS advertisement is a separate
  client-network step.
