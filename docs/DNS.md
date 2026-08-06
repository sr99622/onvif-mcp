# Local DNS Runbook for the Camera Server

## Purpose

This runbook documents the tested procedure used to make an Ubuntu camera server provide local DNS for a private camera-viewing hostname while forwarding public DNS queries upstream.

The resulting design is:

```text
Wired clients
    |
    | DHCP configuration from macOS bootpd
    | DNS queries to 10.1.1.3
    v
trigkey / dnsmasq
    |-- camera.home.arpa -> 10.1.1.3
    |-- 10.1.1.3 -> camera.home.arpa
    `-- other queries -> 192.168.68.1
```

## Site-specific values

| Role | Value |
|---|---|
| Camera server hostname | `trigkey` |
| Camera server wired address | `10.1.1.3/24` |
| Private DNS name | `camera.home.arpa` |
| Wired DHCP server | macOS `bootpd` at `10.1.1.1` |
| Wired default gateway | `10.1.1.16` |
| DHCP range | `10.1.1.64` through `10.1.1.242` |
| Upstream DNS resolver | `192.168.68.1` |
| Camera-only interface | `10.2.2.1/24` |

When adapting this procedure elsewhere, replace these values deliberately. Do not copy addresses without checking the destination network.

## Important design decisions

- `home.arpa` is used as the private DNS namespace.
- dnsmasq provides DNS only. It does not provide DHCP on `trigkey`.
- dnsmasq listens only on `10.1.1.3`, not on the camera interface, Wi-Fi interface, wildcard address, or loopback.
- `systemd-resolved` remains the Ubuntu host resolver on `127.0.0.53` and `127.0.0.54`.
- The macOS `bootpd` server advertises `10.1.1.3` to wired DHCP clients.
- No public resolver is advertised as a secondary DNS server because clients might bypass the private resolver and fail to resolve `camera.home.arpa`.

## 1. Preflight checks on Ubuntu

Confirm which processes already use DNS port 53:

```bash
sudo ss -lntup 'sport = :53'
sudo ss -lnup 'sport = :53'
```

In the tested system, `systemd-resolved` listened only on:

```text
127.0.0.53:53
127.0.0.54:53
```

That left `10.1.1.3:53` available for dnsmasq.

Check installed DNS packages:

```bash
dpkg -l | grep -E 'dnsmasq|bind9|unbound|adguard'
```

The system already had `dnsmasq-base`. The `dnsmasq` package was added to provide the managed system service.

## 2. Install dnsmasq safely

The default dnsmasq service may attempt to start before its listening address is restricted. Temporarily mask it:

```bash
sudo systemctl mask dnsmasq.service
sudo apt update
sudo apt install dnsmasq
```

During installation, messages saying that the masked service could not be preset or started are expected. Confirm afterward that the package is installed.

## 3. Enable the configuration directory

Ubuntu's packaged `/etc/dnsmasq.conf` contained several commented examples. The desired line was:

```ini
conf-dir=/etc/dnsmasq.d/,*.conf
```

Inspect the relevant area before editing because line numbers may differ by release:

```bash
sudo nl -ba /etc/dnsmasq.conf | sed -n '674,687p'
```

On the tested dnsmasq 2.92 configuration, line 684 was uncommented:

```bash
sudo sed -i '684s/^#//' /etc/dnsmasq.conf
```

Verify the effective include directive:

```bash
grep -n '^[^#]*conf-dir' /etc/dnsmasq.conf
```

Do not reuse the line-number command on another release until the file has been inspected.

## 4. Create the camera DNS configuration

Create `/etc/dnsmasq.d/camera-system.conf` with:

```ini
# Camera-system DNS service
listen-address=10.1.1.3
bind-interfaces

# Private local namespace
local=/home.arpa/
address=/camera.home.arpa/10.1.1.3

# Explicit upstream resolver
no-resolv
server=192.168.68.1

domain-needed
bogus-priv
cache-size=1000

# Reverse lookup for clearer diagnostics
ptr-record=3.1.1.10.in-addr.arpa,camera.home.arpa
```

The PTR owner is the reversed IPv4 address. For example, `10.1.1.3` becomes `3.1.1.10.in-addr.arpa`.

Validate before every initial start or restart:

```bash
sudo dnsmasq --test
```

Expected result:

```text
dnsmasq: syntax check OK.
```

## 5. Prevent inappropriate resolver integration

Ubuntu's dnsmasq service normally runs helper hooks that try to register dnsmasq as the host's loopback resolver. This conflicted with the selected architecture, where `systemd-resolved` remains the host resolver and dnsmasq listens only on `10.1.1.3`.

The original service emitted:

```text
Failed to set DNS configuration: Unit dbus-org.freedesktop.network1.service not found.
```

Create a systemd drop-in that disables only the resolver-registration hooks:

```bash
printf '%s\n' \
'[Service]' \
'ExecStartPost=' \
'ExecStop=' \
| sudo systemctl edit dnsmasq.service --stdin
```

The resulting file is:

```text
/etc/systemd/system/dnsmasq.service.d/override.conf
```

with:

```ini
[Service]
ExecStartPost=
ExecStop=
```

Using a drop-in preserves the package-owned unit at `/usr/lib/systemd/system/dnsmasq.service`.

Inspect the combined unit:

```bash
systemctl cat dnsmasq.service
```

## 6. Stop the package helper from supplying a resolver file

Because the camera configuration uses `no-resolv` and an explicit `server=192.168.68.1`, enable the package-supported setting in `/etc/default/dnsmasq`:

```ini
IGNORE_RESOLVCONF=yes
```

This removes the otherwise confusing warning:

```text
warning: ignoring resolv-file flag because no-resolv is set
```

The related `DNSMASQ_EXCEPT="lo"` setting was not used as the complete solution because the packaged stop helper does not apply the same exception. The systemd drop-in disables both inappropriate hooks consistently.

## 7. Start and enable dnsmasq

Remove the temporary mask:

```bash
sudo systemctl unmask dnsmasq.service
```

Start the service without initially enabling it:

```bash
sudo systemctl start dnsmasq.service
```

Inspect its status and logs:

```bash
systemctl --no-pager --full status dnsmasq.service
```

After successful verification, enable automatic startup:

```bash
sudo systemctl enable dnsmasq.service
systemctl is-enabled dnsmasq.service
```

Expected final state:

```text
enabled
```

## 8. Verify listening addresses

```bash
sudo ss -lntup 'sport = :53'
```

Expected arrangement:

- dnsmasq listens on `10.1.1.3:53` over UDP and TCP.
- `systemd-resolved` listens on `127.0.0.53:53` and `127.0.0.54:53`.
- dnsmasq does not listen on `10.2.2.1`, the Wi-Fi address, or `0.0.0.0`.

## 9. Test DNS on the server

Test the private record:

```bash
dig @10.1.1.3 camera.home.arpa +noall +answer
```

Expected answer:

```text
camera.home.arpa.  0  IN  A  10.1.1.3
```

Test public forwarding:

```bash
dig @10.1.1.3 ubuntu.com +noall +answer
```

Test that unknown private names are not forwarded publicly:

```bash
dig @10.1.1.3 nonexistent-test.home.arpa +noall +comments +answer
```

Expected status:

```text
NXDOMAIN
```

Test reverse lookup:

```bash
dig @10.1.1.3 -x 10.1.1.3 +noall +answer
```

Expected answer:

```text
3.1.1.10.in-addr.arpa.  0  IN  PTR  camera.home.arpa.
```

Important: `systemctl reload dnsmasq` does not reread every configuration directive. When adding a `ptr-record` directive, a reload did not activate it. After validating the configuration, use a full restart:

```bash
sudo systemctl restart dnsmasq.service
```

## 10. Test a client explicitly

Before changing client or DHCP settings, query the server directly.

On macOS:

```bash
nslookup camera.home.arpa 10.1.1.3
nslookup ubuntu.com 10.1.1.3
```

On Windows:

```cmd
nslookup camera.home.arpa 10.1.1.3
nslookup ubuntu.com 10.1.1.3
```

## 11. Configure one macOS client manually for testing

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

## 12. Configure macOS bootpd to advertise the DNS server

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

## 13. Final Windows verification

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
