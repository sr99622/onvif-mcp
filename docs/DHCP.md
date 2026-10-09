# Isolated Kea DHCP Network on Ubuntu

## Purpose

Configure an isolated IPv4 camera network on `{{PRVT_NET_EN_NAME}}`.

Target state:

- Server address: `10.2.2.1/24`
- DHCP pool: `10.2.2.100` through `10.2.2.200`
- DHCP interface: `{{PRVT_NET_EN_NAME}}`
- Kea DHCPv4 listens on UDP 67 for that interface
- IPv4 and IPv6 forwarding are disabled
- No routing is added between this subnet and the server's LAN interface

The server's other interface and existing LAN/Internet configuration must not be changed.

## Required Values

| Value | Description |
|---|---|
| `{{PRVT_NET_EN_NAME}}` | Ethernet adapter hosting the private camera subnet |
| `{{REPO_PATH}}` | Full path to this repository |

Stop and ask the user if any required value is missing.

## Agent Presentation Rules

This document is a script for the agent. The executable source of truth is:

```text
{{REPO_PATH}}/scripts/DHCP/dhcp_runbook.sh
```

Before executing any AGENT-run command or presenting any USER-run command, replace every double-curly placeholder with the real site value. Do not ask the user to type placeholders literally.

For this runbook, the agent normally runs the commands directly. If a command must be shown to the user, include `cd {{REPO_PATH}}` as the first line of the copy-paste block after resolving `{{REPO_PATH}}`.

Do not replace the scripted workflow with ad hoc shell fragments. If behavior must change, update `scripts/DHCP/dhcp_runbook.sh` and keep this runbook as orchestration guidance.

## 1. Apply DHCP Network Configuration (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}
scripts/DHCP/dhcp_runbook.sh apply --interface {{PRVT_NET_EN_NAME}}
```

The script performs the full DHCP runbook:

- Installs missing Debian/Ubuntu packages when `apt-get` is available.
- Creates or updates the NetworkManager `isolated` profile on `{{PRVT_NET_EN_NAME}}`.
- Assigns `10.2.2.1/24` to the private camera interface.
- Removes gateway, DNS, and static route settings from the private interface profile.
- Deactivates any other active NetworkManager profile on that interface.
- Writes `/etc/kea/kea-dhcp4.conf` with the interface-specific Kea configuration.
- Sets `/etc/kea/kea-dhcp4.conf` ownership and mode for the `_kea` service user.
- Disables IPv4 and IPv6 forwarding persistently via `/etc/sysctl.d/90-isolated.conf`.
- Validates the Kea configuration in the service context.
- Enables and restarts `kea-dhcp4-server`.
- Prints non-secret status output.

## 2. Verify DHCP Network Configuration (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/DHCP/dhcp_runbook.sh status --interface {{PRVT_NET_EN_NAME}}
```

Acceptance checks:

- `{{PRVT_NET_EN_NAME}}` is connected to the `isolated` NetworkManager profile.
- `{{PRVT_NET_EN_NAME}}` has `10.2.2.1/24`.
- The route table for `{{PRVT_NET_EN_NAME}}` contains the directly connected `10.2.2.0/24` route only.
- There is no default route through `{{PRVT_NET_EN_NAME}}`.
- `net.ipv4.ip_forward = 0`.
- `net.ipv6.conf.all.forwarding = 0`.
- Kea configuration validation exits successfully.
- `kea-dhcp4-server` is enabled and active.
- A Kea DHCP listener is present on UDP 67.

## 3. Camera-Side Acceptance

**Important** It may take a few minutes for all cameras to absorb DHCP settings and become responsive on the network. Wait before checking for cameras so that they have time to initialize.

A client attached to the isolated camera network should:

- Receive an address between `10.2.2.100` and `10.2.2.200`.
- Receive subnet mask `/24` (`255.255.255.0`).
- Reach `10.2.2.1`.
- Be unable to reach the main LAN or Internet through this server.

Some camera models require a DHCP router option to accept the lease. The script includes router `10.2.2.1` and DHCP server identifier `10.2.2.1`, while host forwarding remains disabled so the server does not route camera traffic to the LAN.

Issued leases are reported in the script status output when Kea has created `/var/lib/kea/kea-leases4.csv`; absence of leases before cameras are connected is not a failure.
