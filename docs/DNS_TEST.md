## 1. Configure one macOS client manually for testing

Identify its network services and active interface:

```bash
networksetup -listallnetworkservices
route -n get default | grep interface
networksetup -listallhardwareports
```

On the tested Mac, the active interface was `en0`, mapped to the `Ethernet` service.

Record its existing DNS configuration:

```bash
networksetup -getdnsservers "Ethernet"
```

Set dnsmasq as the resolver:

```bash
sudo networksetup -setdnsservers "Ethernet" 10.1.1.3
```

Verify:

```bash
networksetup -getdnsservers "Ethernet"
nslookup camera.home.arpa
nslookup ubuntu.com
```

To restore the original site-specific setting used here:

```bash
sudo networksetup -setdnsservers "Ethernet" 192.168.68.1
```

If the original configuration said there were no explicit DNS servers, restore DHCP-supplied DNS with:

```bash
sudo networksetup -setdnsservers "Ethernet" Empty
```

## 2. Configure macOS bootpd to advertise the DNS server

The wired DHCP server was macOS `bootpd` at `10.1.1.1`; it was not the gateway. This is valid: DHCP can advertise a gateway and DNS resolver on other machines.

Inspect the configuration:

```bash
sudo plutil -p /etc/bootpd.plist
```

The relevant original configuration advertised:

```text
DNS:     192.168.68.1
Router:  10.1.1.16
Range:   10.1.1.64 through 10.1.1.242
```

Back up the plist before editing:

```bash
sudo cp -pn /etc/bootpd.plist /etc/bootpd.plist.backup-2026-08-03
```

Change only the DNS value:

```bash
sudo /usr/libexec/PlistBuddy \
  -c "Set :Subnets:0:dhcp_domain_name_server:0 10.1.1.3" \
  /etc/bootpd.plist
```

Verify the array:

```bash
sudo /usr/libexec/PlistBuddy \
  -c "Print :Subnets:0:dhcp_domain_name_server" \
  /etc/bootpd.plist
```

Validate the complete plist:

```bash
sudo plutil -lint /etc/bootpd.plist
```

Inspect the launchd service before reloading:

```bash
sudo launchctl print system/com.apple.bootpd
```

Reload it:

```bash
sudo launchctl kickstart -k system/com.apple.bootpd
```

Verify that it is running:

```bash
sudo launchctl print system/com.apple.bootpd \
  | grep -E 'state =|pid =|last exit code'
```

Clients receive the new DNS value when their DHCP lease is issued or renewed.

## 3. Final Windows verification

Confirm the active adapter shows `10.1.1.3` under DNS servers:

```cmd
ipconfig /all
```

Test forward resolution:

```cmd
nslookup camera.home.arpa
```

Test reverse resolution:

```cmd
nslookup 10.1.1.3 10.1.1.3
```

Expected server identity after the PTR record is active:

```text
Server:  camera.home.arpa
Address: 10.1.1.3
```

Without the PTR record, Windows displays `Server: UnKnown` even though forward DNS works. That label alone does not mean the DNS server is broken.

## Rollback

### Restore the macOS bootpd configuration

First validate that the backup exists. Then restore it:

```bash
sudo cp -p /etc/bootpd.plist.backup-2026-08-03 /etc/bootpd.plist
sudo plutil -lint /etc/bootpd.plist
sudo launchctl kickstart -k system/com.apple.bootpd
```

### Stop dnsmasq

```bash
sudo systemctl disable --now dnsmasq.service
```

### Remove the systemd override

```bash
sudo systemctl revert dnsmasq.service
```

This removes local drop-ins for the service. Inspect with `systemctl cat dnsmasq.service` before and after using it.

### Restore client DNS manually

Restore each client's original resolver or renew its DHCP lease after restoring the bootpd configuration.

## Operational checks

Useful troubleshooting commands:

```bash
systemctl --no-pager --full status dnsmasq.service
sudo journalctl -u dnsmasq.service -n 100 --no-pager
sudo dnsmasq --test
sudo ss -lntup 'sport = :53'
dig @10.1.1.3 camera.home.arpa
dig @10.1.1.3 ubuntu.com
dig @10.1.1.3 -x 10.1.1.3
```

When troubleshooting, validate one transition at a time: inspect, change one item, verify it, and only then proceed.
