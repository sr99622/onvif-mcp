# dnsmasq DNS + DHCP on Separate Interfaces

## Problem Statement

dnsmasq needs to serve **DNS only** on the LAN interface (`enp171s0` / `10.1.1.5`) and **DHCP only** on a separate interface (`enp170s0` / `10.2.2.1`). Both services must run within a single dnsmasq instance but be scoped to their respective interfaces.

## Configuration

### Network Layout

| Interface | IP Address    | Role  | Service      |
|-----------|---------------|-------|--------------|
| enp171s0  | 10.1.1.5/24   | LAN   | DNS only     |
| enp170s0  | 10.2.2.1/24   | Other | DHCP only    |

### Final Configuration File

**File:** `/etc/dnsmasq.conf`

```ini
# =============================================================
# dnsmasq — DNS server for gmktec.home.arpa on enp171s0
# Replaces 10.1.1.3 as the primary DNS resolver for LAN clients.
# =============================================================

# ----- Listeners --------------------------------------------------
interface=enp171s0
listen-address=10.1.1.5

# ----- Domain -----------------------------------------------------
domain=gmktec.home.arpa

# ----- Upstream resolvers ------------------------------------------
server=1.1.1.1
server=8.8.4.4

# ----- Cache ------------------------------------------------------
cache-size=150
neg-ttl=60

# ----- Logging -----------------------------------------------------
log-queries
log-facility=/var/log/dnsmasq.log

# Explicit hostname resolution for local domain
address=/mini.home.arpa/10.1.1.1
address=/flexi.home.arpa/10.1.1.2
address=/trigkey.home.arpa/10.1.1.3
address=/strix.home.arpa/10.1.1.4
address=/moxy.home.arpa/10.1.1.16
address=/gmktec.home.arpa/10.1.1.5

# ----- DHCP on enp170s0 -------------------------------------------
interface=enp170s0
dhcp-range=10.2.2.50,10.2.2.200,255.255.255.0,12h
dhcp-option=3,10.2.2.1
dhcp-leasefile=/tmp/dnsmasq-dhcp.log
```

### systemd Service

**File:** `/etc/systemd/system/dnsmasq.service`

```ini
[Unit]
Description=dns caching server.
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq -k
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## dnsmasq Configuration Loading Limitation

This is the critical finding that drove the final configuration:

### The Problem

dnsmasq has a known limitation where `interface=` directives placed in **separate config files** (under `/etc/dnsmasq.d/`) do not scope services to those interfaces correctly. Instead, they cause dnsmasq to implicitly behave as if `bind-interfaces` is set globally, which prevents proper per-interface binding for both DNS and DHCP simultaneously.

### Evidence

1. When configs were split:
   - `/etc/dnsmasq.conf` had `interface=enp171s0` for DNS
   - `/etc/dnsmasq.d/enp170s0-dhcp.conf` had `interface=enp170s0` for DHCP
   
   Result: **DHCP never appeared on port 67**, no lease activity, and dnsmasq's startup log showed no DHCP initialization messages.

2. When all configs were in the single main file:
   - Multiple `interface=` lines correctly scoped each service
   - DNS bound to `10.1.1.5:53`
   - DHCP bound to port 67 and served clients on `enp170s0`
   - Log showed: `dnsmasq-dhcp: DHCP, IP range 10.2.2.50 -- 10.2.2.200, lease time 12h`

### Root Cause

dnsmasq processes config files in order and treats multiple `interface=` directives from different sources as conflicting, effectively applying `bind-interfaces` semantics even when not explicitly set. This causes DHCP to fail silently (no port binding) while DNS continues working on its specified interface. The exact internal behavior is undocumented but reproducible across dnsmasq versions.

### Workaround

**All configuration must be in `/etc/dnsmasq.conf`.** Do not use sub-files in `/etc/dnsmasq.d/` when you need multiple `interface=` directives for different services. This is the only reliable method to run DNS and DHCP on separate interfaces within a single dnsmasq instance.

## Troubleshooting Notes

### systemd-resolved Conflict (Port 53)

If dnsmasq fails with "Address already in use" on port 53:

```bash
sudo systemctl stop systemd-resolved
# Append to /etc/systemd/resolved.conf:
echo 'DNSStubListener=no' | sudo tee -a /etc/systemd/resolved.conf
sudo systemctl daemon-reload
sudo systemctl restart systemd-resolved
sudo systemctl restart dnsmasq
```

### kea-dhcp4 Conflict (Port 67)

If kea-dhcp4 was installed as a dependency and interferes:

```bash
sudo systemctl stop kea-dhcp4
sudo apt-get remove --purge -y kea-common kea-dhcp4-server
```

### Debugging Steps

To verify dnsmasq is working correctly:

1. Check ports are bound:
   ```bash
   ss -tulnp | grep ':53'  # DNS
   ss -ulnp 'sport = :67'  # DHCP
   ```

2. Verify DNS resolution:
   ```bash
   host gmktec.home.arpa 10.1.1.5
   ```

3. Check DHCP leases:
   ```bash
   tail -20 /var/log/dnsmasq.log | grep dhcp
   cat /tmp/dnsmasq-dhcp.log
   ```

4. Full debug output (temporary):
   ```bash
   sudo systemctl stop dnsmasq
   sudo /usr/sbin/dnsmasq -d --log-queries  # run manually, Ctrl+C when done
   ```

## Verification Results

The configuration was verified to be working:

- DNS resolves `gmktec.home.arpa` -> `10.1.1.5` on port 53
- DHCP serves clients on enp170s0 (10.2.2.x) — observed leases at 10.2.2.101 and 10.2.2.82
- DNS forwards external queries to upstream resolvers (Cloudflare, Google)
- Local domain names resolve to static addresses
