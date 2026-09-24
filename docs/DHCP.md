# Isolated Kea DHCP Network on Ubuntu

## Purpose

This configuration creates an isolated IPv4 network on {{PRVT_CAMERA_NET_EN_NAME}}:

- Server address: `10.2.2.1/24`
- DHCP pool: `10.2.2.100` through `10.2.2.200`
- DHCP interface: {{PRVT_CAMERA_NET_EN_NAME}}
- No default gateway supplied to clients
- No DNS server supplied to clients
- No routing between this subnet and the server's other network interface

The server's other interface and its existing LAN/Internet configuration are not changed.

## Required Value
| Value | Description |
|---|---|
| {{PRVT_CAMERA_NET_EN_NAME}} | Ethernet Adapter Interface name hosting the private camera subnet |

This value is required for operation. Stop and prompt the user if it is not provided.

## 1. Configure Private Network Interface with NetworkManager

Review current connections first:

```bash
nmcli -f NAME,UUID,TYPE,DEVICE connection show
nmcli device status
```

Create the isolated connection profile:

```bash
sudo nmcli connection add \
  type ethernet \
  ifname {{PRVT_CAMERA_NET_EN_NAME}} \
  con-name isolated \
  ipv4.method manual \
  ipv4.addresses 10.2.2.1/24 \
  ipv4.never-default yes \
  ipv4.ignore-auto-dns yes \
  ipv6.method disabled \
  connection.autoconnect yes
```

Explicitly remove gateway, DNS, and static route settings:

```bash
sudo nmcli connection modify isolated \
  ipv4.gateway "" \
  ipv4.dns "" \
  ipv4.routes ""
```

Activate the profile:

```bash
sudo nmcli connection up isolated
```

If another NetworkManager profile is already active on {{PRVT_CAMERA_NET_EN_NAME}}, deactivate that profile before activating `isolated`:

```bash
sudo nmcli connection down "OLD-CONNECTION-NAME"
sudo nmcli connection up isolated
```

Note: a netplan-generated profile (e.g. `netplan-{{PRVT_CAMERA_NET_EN_NAME}}`) may already be active on {{PRVT_CAMERA_NET_EN_NAME}} even when the port shows no carrier — that is the expected "old" profile to deactivate.

Verify the result:

```bash
nmcli device show {{PRVT_CAMERA_NET_EN_NAME}}
ip address show dev {{PRVT_CAMERA_NET_EN_NAME}}
ip route show dev {{PRVT_CAMERA_NET_EN_NAME}}
```

The interface should have `10.2.2.1/24`. Its route table should contain only the directly connected subnet, similar to:

```text
10.2.2.0/24 proto kernel scope link src 10.2.2.1
```

There must be no default route through {{PRVT_CAMERA_NET_EN_NAME}}.

## 2. Install Kea DHCPv4

```bash
sudo apt update
sudo apt install kea-dhcp4-server
```

## 3. Configure Kea

Back up the packaged configuration:

```bash
sudo cp /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.backup
sudoedit /etc/kea/kea-dhcp4.conf
```

If writing the file programmatically (e.g. `sudo install` or `sudo tee`) instead of using `sudoedit`, set ownership and mode so the service user can read it:

```bash
sudo chown root:_kea /etc/kea/kea-dhcp4.conf
sudo chmod 640 /etc/kea/kea-dhcp4.conf
```

The `kea-dhcp4-server` unit runs as the `_kea` user (see `systemctl cat kea-dhcp4-server`). On Ubuntu the netplan config files under `/etc/netplan/` are mode 600 root-only, so inspect NM state with `nmcli` instead of reading them directly.

Use this configuration:

```json
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "enp171s0" ],
      "dhcp-socket-type": "raw"
    },

    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv"
    },

    "match-client-id": false,
    "decline-probation-period": 0,

    "valid-lifetime": 3600,
    "renew-timer": 900,
    "rebind-timer": 1800,

    "subnet4": [
      {
        "id": 1,
        "subnet": "10.2.2.0/24",
        "pools": [
          {
            "pool": "10.2.2.100 - 10.2.2.200"
          }
        ],
        // Dahua style cameras reject DHCP replies if these options are missing
        "option-data": [
          {
            "name": "routers",
            "data": "10.2.2.1"
          },
          {
            "name": "dhcp-server-identifier",
            "data": "10.2.2.1"
          }
        ]
      }
    ],

    "loggers": [
      {
        "name": "kea-dhcp4",
        "output-options": [
          {
            "output": "stdout"
          }
        ],
        "severity": "INFO"
      }
    ]
  }
}
```

## 4. Prevent Routing Between Interfaces

The configuration contains no `domain-name-servers` DHCP options. Many cameras have hard coded DNS entries anyway. Some cameras may not operate properly under DHCP if no gateway is specified. The server address is included under `routers` so that these cameras will accept the DHCP configuration.

The server does not have forwarding capability, but the server must also have IP forwarding disabled to enforce isolation:

```bash
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding
```

Both values should be `0`. To disable forwarding immediately:

```bash
sudo sysctl -w net.ipv4.ip_forward=0
sudo sysctl -w net.ipv6.conf.all.forwarding=0
```

To make this persistent, create `/etc/sysctl.d/90-isolated.conf`:

```ini
net.ipv4.ip_forward=0
net.ipv6.conf.all.forwarding=0
```

Then apply it:

```bash
sudo sysctl --system
```

Disabling forwarding does not prevent the Ubuntu server itself from using its LAN-facing interface. If forwarding is required for some unrelated workload, enforce isolation with interface-specific firewall forwarding rules instead of globally disabling it.

## 5. Validate and Start Kea

Check the configuration before restarting the service:

```bash
sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
```

Known pitfall (observed on Ubuntu 26.04): that command as **root** can fail with
`Syntax check failed with: Unable to open file /etc/kea/kea-dhcp4.conf` even when the
file is root-readable. The enforced AppArmor profile `kea-dhcp4` denies the process the
`dac_read_search`/`dac_override` capabilities it probes during startup
(`audit: apparmor="DENIED" ... capability=2 capname="dac_read_search"`). This does NOT
affect the systemd service, which runs as `_kea` and reads the file via group access.

Validate in the same context the service will run under:

```bash
sudo -u _kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf   # exit 0 = valid (warnings are informational)
```

If you want the literal `sudo kea-dhcp4 -t ...` command to work as root, add these lines
to `/etc/apparmor.d/usr.sbin.kea-dhcp4` inside the profile block and reload it with
`sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.kea-dhcp4`:

```text
  capability dac_read_search,
  capability dac_override,
```

If validation succeeds:

```bash
sudo systemctl enable --now kea-dhcp4-server
sudo systemctl restart kea-dhcp4-server
sudo systemctl status kea-dhcp4-server
```

Confirm that Kea is listening on DHCP server port UDP 67:

```bash
sudo ss -ulpn | grep ':67'
```

View recent logs:

```bash
sudo journalctl -u kea-dhcp4-server -n 100 --no-pager
```

Follow logs during client testing:

```bash
sudo journalctl -u kea-dhcp4-server -f
```

## 6. Acceptance Checks

A client attached to the isolated network should:

- Receive an address between `10.2.2.100` and `10.2.2.200`
- Receive subnet mask `/24` (`255.255.255.0`)
- Receive no default gateway
- Receive no DNS server
- Reach `10.2.2.1`
- Be unable to reach the main LAN or Internet through this server

Inspect issued leases on the server with:

```bash
sudo cat /var/lib/kea/kea-leases4.csv
```
