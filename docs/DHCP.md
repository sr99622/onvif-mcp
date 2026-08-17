# Isolated Kea DHCP Network on Ubuntu

## Purpose

This configuration creates an isolated IPv4 network on ${EN_NAME}:

- Server address: `10.2.2.1/24`
- DHCP pool: `10.2.2.100` through `10.2.2.200`
- DHCP interface: ${EN_NAME}
- No default gateway supplied to clients
- No DNS server supplied to clients
- No routing between this subnet and the server's other network interface

The server's other interface and its existing LAN/Internet configuration are not changed.

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
  ifname ${EN_NAME} \
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

If another NetworkManager profile is already active on ${EN_NAME}, deactivate that profile before activating `isolated`:

```bash
sudo nmcli connection down "OLD-CONNECTION-NAME"
sudo nmcli connection up isolated
```

Verify the result:

```bash
nmcli device show ${EN_NAME}
ip address show dev ${EN_NAME}
ip route show dev ${EN_NAME}
```

The interface should have `10.2.2.1/24`. Its route table should contain only the directly connected subnet, similar to:

```text
10.2.2.0/24 proto kernel scope link src 10.2.2.1
```

There must be no default route through ${EN_NAME}.

## 2. Install Kea DHCPv4

```bash
sudo apt update
sudo apt install kea-dhcp4-server
```

On Ubuntu 22.04, enable the Universe repository first if the package is unavailable:

```bash
sudo add-apt-repository universe
sudo apt update
sudo apt install kea-dhcp4-server
```

## 3. Configure Kea

Back up the packaged configuration:

```bash
sudo cp /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.backup
sudoedit /etc/kea/kea-dhcp4.conf
```

Use this configuration:

```json
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "${EN_NAME}" ]
    },

    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv"
    },

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

The configuration intentionally contains no `routers` or `domain-name-servers` DHCP options. Clients therefore receive an address and subnet mask, but no gateway or DNS server.

## 4. Prevent Routing Between Interfaces

Omitting a gateway from DHCP prevents normal client routing, but the server must also have IP forwarding disabled to enforce isolation:

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
