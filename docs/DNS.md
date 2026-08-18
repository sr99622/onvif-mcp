# Local DNS Runbook for the Camera Server

## Purpose

This runbook documents the tested procedure used to make an Ubuntu camera server provide local DNS for a private camera-viewing hostname while forwarding public DNS queries upstream.

The resulting design is:

```text
Wired clients
    |
    | DHCP configuration from macOS bootpd
    | DNS queries to {{SERVER_IP}}
    v
{{SERVER_FQDN}} / dnsmasq
    |-- {{SERVER_FQDN}} -> {{SERVER_IP}}
    |-- {{SERVER_IP}} -> {{SERVER_FQDN}}
    `-- other queries -> 192.168.68.1
```

Symbolic values used in this file:

| Symbol | Example Value | Description |
|---|---|---|
| {{SERVER_FQDN}} | camera.home.arpa | Fully Qualified Domain Name of the server |
| {{SERVER_IP}} | 10.1.1.3 | IP Address of the server |
| {{RVRS_SRV_IP}} | 3.1.1.10 | Reverse IP address of the server for DNS Lookup |

## Site-specific values

| Role | Value |
|---|---|
| Camera server hostname | `{{SERVER_FQDN}}` |
| Camera server wired address | `{{SERVER_IP}}/24` |
| Private DNS name | `{{SERVER_FQDN}}` |
| Wired DHCP server | macOS `bootpd` at `10.1.1.1` |
| Wired default gateway | `10.1.1.16` |
| DHCP range | `10.1.1.64` through `10.1.1.242` |
| Upstream DNS resolver | `192.168.68.1` |
| Camera-only interface | `10.2.2.1/24` |

When adapting this procedure elsewhere, replace these values deliberately. Do not copy addresses without checking the destination network.

## Important design decisions

- `home.arpa` is used as the private DNS namespace.
- dnsmasq provides DNS only. It does not provide DHCP on `{{SERVER_FQDN}}`.
- dnsmasq listens only on `{{SERVER_IP}}`, not on the camera interface, Wi-Fi interface, wildcard address, or loopback.
- `systemd-resolved` remains the Ubuntu host resolver on `127.0.0.53` and `127.0.0.54`.
- The macOS `bootpd` server advertises `{{SERVER_IP}}` to wired DHCP clients.
- No public resolver is advertised as a secondary DNS server because clients might bypass the private resolver and fail to resolve `{{SERVER_FQDN}}`.

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

That left `{{SERVER_IP}}:53` available for dnsmasq.

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
listen-address={{SERVER_IP}}
bind-interfaces

# Private local namespace
local=/home.arpa/
address=/{{SERVER_FQDN}}/{{SERVER_IP}}

# Explicit upstream resolver
no-resolv
server=192.168.68.1

domain-needed
bogus-priv
cache-size=1000

# Reverse lookup for clearer diagnostics
ptr-record={{RVRS_SRV_IP}}.in-addr.arpa,{{SERVER_FQDN}}
```

The PTR owner is the reversed IPv4 address. For example, `{{SERVER_IP}}` becomes `{{RVRS_SRV_IP}}.in-addr.arpa`.

Validate before every initial start or restart:

```bash
sudo dnsmasq --test
```

Expected result:

```text
dnsmasq: syntax check OK.
```

## 5. Prevent inappropriate resolver integration

Ubuntu's dnsmasq service normally runs helper hooks that try to register dnsmasq as the host's loopback resolver. This conflicted with the selected architecture, where `systemd-resolved` remains the host resolver and dnsmasq listens only on `{{SERVER_IP}}`.

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

- dnsmasq listens on `{{SERVER_IP}}:53` over UDP and TCP.
- `systemd-resolved` listens on `127.0.0.53:53` and `127.0.0.54:53`.
- dnsmasq does not listen on `10.2.2.1`, the Wi-Fi address, or `0.0.0.0`.

## 9. Test DNS on the server

Test the private record:

```bash
dig @{{SERVER_IP}} {{SERVER_FQDN}} +noall +answer
```

Expected answer:

```text
{{SERVER_FQDN}}.  0  IN  A  {{SERVER_IP}}
```

Test public forwarding:

```bash
dig @{{SERVER_IP}} ubuntu.com +noall +answer
```

Test that unknown private names are not forwarded publicly:

```bash
dig @{{SERVER_IP}} nonexistent-test.home.arpa +noall +comments +answer
```

Expected status:

```text
NXDOMAIN
```

Test reverse lookup:

```bash
dig @{{SERVER_IP}} -x {{SERVER_IP}} +noall +answer
```

Expected answer:

```text
{{RVRS_SRV_IP}}.in-addr.arpa.  0  IN  PTR  {{SERVER_FQDN}}.
```

Important: `systemctl reload dnsmasq` does not reread every configuration directive. When adding a `ptr-record` directive, a reload did not activate it. After validating the configuration, use a full restart:

```bash
sudo systemctl restart dnsmasq.service
```

## 10. Test a client explicitly

Before changing client or DHCP settings, query the server directly.

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

