# Isolated Network Interface on Ubuntu

## Purpose

This configuration creates an isolated IPv4 network on {{IF_NAME}}, where {{IF_NAME}} represents the target ethernet interface adapter name. There will be another ethernet interface on the machine that is not part of this configuration.

- Static IP address: `10.2.2.1/24`
- No default gateway
- No DNS server
- No routing between this subnet and the server's other network interfaces

The server's other interfaces and existing LAN/Internet configurations are not changed.

## 1. Configure {{IF_NAME}} with NetworkManager

Review current connections first:

```bash
nmcli -f NAME,UUID,TYPE,DEVICE connection show
nmcli device status
```

Create the isolated connection profile:

```bash
sudo nmcli connection add \
  type ethernet \
  ifname {{IF_NAME}} \
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

If another NetworkManager profile is already active on {{IF_NAME}}, deactivate that profile before activating `isolated`:

```bash
sudo nmcli connection down "OLD-CONNECTION-NAME"
sudo nmcli connection up isolated
```

Verify the result:

```bash
nmcli device show {{IF_NAME}}
ip address show dev {{IF_NAME}}
ip route show dev {{IF_NAME}}
```

The interface should have `10.2.2.1/24`. Its route table should contain only the directly connected subnet, similar to:

```text
10.2.2.0/24 proto kernel scope link src 10.2.2.1
```

There must be no default route through {{IF_NAME}}.
