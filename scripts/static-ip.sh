#!/usr/bin/env bash
# Replace the active DHCP Ethernet profile with one static IPv4 address.
# Run locally with sudo. Requires nmcli, ip, flock and Python 3.
# IPv6 is preserved. Reserve/exclude the new address on your DHCP server:
# ARP probing cannot detect offline devices or future DHCP allocations.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo from a local terminal.' >&2; exit 1; }
[[ -z ${SSH_CONNECTION:-} ]] || { echo 'Run locally: Ethernet will disconnect during replacement.' >&2; exit 1; }
for tool in nmcli ip flock python3; do
    command -v "$tool" >/dev/null || { echo "Missing required command: $tool" >&2; exit 1; }
done
exec 9>/run/lock/static-ip.lock
flock -n 9 || { echo 'Another static-ip script is running.' >&2; exit 1; }
# Python code arrives via heredoc; prompts read directly from the terminal.
python3 - <<'PYTHON'
import ipaddress
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import time
import uuid

os.environ['LC_ALL'] = 'C'
os.umask(0o077)

def run(*args):
    return subprocess.check_output(args, text=True).strip()

def nm(*args):
    return run('nmcli', *args)

def setting(profile, field):
    return nm('-g', field, 'connection', 'show', 'uuid', profile)

def device(iface, field):
    return nm('-g', field, 'device', 'show', iface)

def addresses(iface=None):
    args = ['ip', '-j', '-4', 'address', 'show']
    if iface:
        args += ['dev', iface]
    return [f"{a['local']}/{a['prefixlen']}"
            for d in json.loads(run(*args)) for a in d.get('addr_info', [])
            if a.get('family') == 'inet']

def available(iface, address):
    """Three ARP probes, then listen for ownership and competing probes."""
    with open(f'/sys/class/net/{iface}/address') as source:
        mac = bytes.fromhex(source.read().strip().replace(':', ''))
    target = socket.inet_aton(str(address))
    packet = (b'\xff' * 6 + mac + struct.pack('!H', 0x0806)
              + struct.pack('!HHBBH', 1, 0x0800, 6, 4, 1)
              + mac + b'\x00' * 4 + b'\x00' * 6 + target)
    with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0806)) as sock:
        sock.bind((iface, 0))
        sock.settimeout(0.2)
        start, sent = time.monotonic(), 0
        while time.monotonic() - start < 5:
            if sent < 3 and time.monotonic() - start >= sent:
                sock.send(packet)
                sent += 1
            try:
                data = sock.recv(2048)
            except socket.timeout:
                continue
            if len(data) < 42 or data[12:14] != b'\x08\x06':
                continue
            if data[14:20] != struct.pack('!HHBB', 1, 0x0800, 6, 4):
                continue
            opcode = struct.unpack('!H', data[20:22])[0]
            sender_mac, sender_ip, target_ip = data[22:28], data[28:32], data[38:42]
            if sender_mac == mac or opcode not in (1, 2):
                continue
            if sender_ip == target or (opcode == 1 and sender_ip == b'\x00' * 4 and target_ip == target):
                print(f'Address conflict: {address} claimed/probed by {sender_mac.hex(":")}', file=sys.stderr)
                return False
    return True

def validate(value, current, gateway):
    proposed = ipaddress.IPv4Address(value)
    if proposed not in current.network:
        raise ValueError(f'Address must belong to {current.network}')
    if proposed in (current.ip, current.network.network_address, current.network.broadcast_address, ipaddress.IPv4Address(gateway)):
        raise ValueError('Choose a different host address, not the current IP, gateway, network or broadcast')
    if proposed.is_multicast or proposed.is_unspecified or proposed.is_loopback or proposed.is_link_local:
        raise ValueError('Choose a normal unicast LAN address')
    if str(proposed) in [x.split('/')[0] for x in addresses()]:
        raise ValueError('Address is already assigned on this machine')
    return proposed

def verify(iface, expected, gateway, dns, profile):
    actual = addresses(iface)
    if actual != [expected]:
        raise RuntimeError(f'Expected exactly one IPv4 address ({expected}); found {actual}')
    if device(iface, 'GENERAL.CON-UUID') != profile:
        raise RuntimeError('Unexpected active connection profile')
    if device(iface, 'IP4.GATEWAY') != gateway:
        raise RuntimeError('Gateway differs from captured DHCP gateway')
    if device(iface, 'IP4.DNS').splitlines() != dns:
        raise RuntimeError('DNS differs from captured DHCP DNS servers')
    routes = json.loads(run('ip', '-j', '-4', 'route', 'show', 'default', 'dev', iface))
    if not any(r.get('gateway') == gateway for r in routes):
        raise RuntimeError('Expected default route is missing')

def main():
    candidates = []
    for line in nm('-t', '-f', 'DEVICE,TYPE,STATE', 'device', 'status').splitlines():
        iface, kind, state = line.split(':')
        if kind != 'ethernet' or state != 'connected':
            continue
        profile = device(iface, 'GENERAL.CON-UUID')
        if setting(profile, 'ipv4.method') == 'auto' and device(iface, 'IP4.GATEWAY'):
            candidates.append((iface, profile))
    if len(candidates) != 1:
        raise RuntimeError(f'Expected one connected DHCP Ethernet adapter with a gateway; found {len(candidates)}')
    iface, old = candidates[0]
    old_name = setting(old, 'connection.id')
    old_auto = setting(old, 'connection.autoconnect')
    options = device(iface, 'DHCP4.OPTION')
    initial_addresses = addresses(iface)
    # --get-values may join DHCP options on one line, with ip_address
    # anywhere in the string. Match the complete option name only.
    matches = re.findall(r'(?<![A-Za-z0-9_])ip_address\s*=\s*((?:[0-9]+\.){3}[0-9]+)', options)
    lease_cidrs = [x for x in initial_addresses if x.split('/')[0] in set(matches)]
    if not matches:
        # Accept an omitted lease option only if exactly one kernel IPv4
        # address is explicitly marked dynamic. Never guess among addresses.
        kernel = json.loads(run('ip', '-j', '-4', 'address', 'show', 'dev', iface))
        lease_cidrs = [f"{a['local']}/{a['prefixlen']}"
                       for d in kernel for a in d.get('addr_info', [])
                       if a.get('family') == 'inet'
                       and (a.get('dynamic') is True or 'dynamic' in a.get('flags', []))]
    if len(lease_cidrs) != 1:
        raise RuntimeError(f'Cannot uniquely identify the DHCP lease. Live IPv4 addresses: {initial_addresses}; DHCP ip_address values: {matches}')
    cidr = lease_cidrs[0]
    current = ipaddress.IPv4Interface(cidr)
    gateway = device(iface, 'IP4.GATEWAY')
    dns = device(iface, 'IP4.DNS').splitlines()
    search = device(iface, 'IP4.DOMAIN').splitlines()
    if not gateway or not dns:
        raise RuntimeError('DHCP gateway or DNS is missing')
    print(f'Adapter: {iface}\nDHCP profile: {old_name} ({old})\nCurrent lease: {current}\nGateway: {gateway}\nDNS: {", ".join(dns)}', flush=True)
    print('Choose an IP reserved/excluded from your DHCP pool. ARP cannot detect offline devices.', flush=True)
    with open('/dev/tty', 'r') as tty_in, open('/dev/tty', 'w') as tty_out:
        while True:
            tty_out.write('Enter the new static IPv4 address (without /prefix): ')
            tty_out.flush()
            value = tty_in.readline()
            if not value:
                raise RuntimeError('No address entered')
            try:
                proposed = validate(value.strip(), current, gateway)
            except ValueError as error:
                print(f'Invalid address: {error}', file=sys.stderr, flush=True)
                continue
            print(f'Checking {proposed} on {iface} using ARP probes...', flush=True)
            # Any probe error aborts before profiles are modified.
            if available(iface, proposed):
                break
            print('Choose another address.', flush=True)
    if device(iface, 'GENERAL.CON-UUID') != old or addresses(iface) != initial_addresses:
        raise RuntimeError('Connection or addresses changed during input; rerun the script')
    if device(iface, 'IP4.GATEWAY') != gateway or device(iface, 'IP4.DNS').splitlines() != dns:
        raise RuntimeError('DHCP settings changed during input; rerun the script')

    recovery = static = None
    recovery_name = f'dhcp-recovery-{uuid.uuid4()}'
    static_name = f'static-{iface}-{uuid.uuid4()}'
    expected = f'{proposed}/{current.network.prefixlen}'
    cutover = False
    success = False
    # Block Ctrl-C only while a profile is being cloned and its UUID recorded.
    def clone(name):
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            nm('connection', 'clone', 'uuid', old, name)
            return nm('-g', 'connection.uuid', 'connection', 'show', 'id', name)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    def attempt(*args):
        try:
            nm(*args)
            return True
        except subprocess.CalledProcessError:
            return False

    try:
        # Preserve Ethernet, IPv6 and other profile properties in both clones.
        recovery = clone(recovery_name)
        nm('connection', 'modify', 'uuid', recovery, 'connection.autoconnect', 'no')
        static = clone(static_name)
        nm('connection', 'modify', 'uuid', static,
           'connection.interface-name', iface, 'connection.autoconnect', 'no',
           'ipv4.method', 'manual', 'ipv4.addresses', expected,
           'ipv4.gateway', gateway, 'ipv4.dns', ','.join(dns),
           'ipv4.dns-search', ','.join(search), 'ipv4.routes', '',
           'ipv4.routing-rules', '', 'ipv4.ignore-auto-dns', 'yes',
           'ipv4.ignore-auto-routes', 'yes', 'ipv4.never-default', 'no',
           'ipv4.may-fail', 'no', 'ipv4.link-local', 'disabled',
           'ipv4.dad-timeout', '3000')
        print('Replacing DHCP profile; Ethernet will briefly disconnect.', flush=True)
        nm('connection', 'modify', 'uuid', old, 'connection.autoconnect', 'no')
        cutover = True
        nm('device', 'disconnect', iface)
        nm('connection', 'delete', 'uuid', old)
        if os.path.exists(f'/etc/netplan/90-NM-{old}.yaml'):
            raise RuntimeError('Old Netplan YAML remains after profile deletion; refusing cutover')
        # Remove old DHCP and any stale additional IPv4 addresses.
        run('ip', '-4', 'address', 'flush', 'dev', iface)
        nm('--wait', '30', 'connection', 'up', 'uuid', static, 'ifname', iface)
        verify(iface, expected, gateway, dns, static)
        nm('connection', 'modify', 'uuid', static, 'connection.autoconnect', 'yes')
        time.sleep(5)
        verify(iface, expected, gateway, dns, static)
        nm('connection', 'delete', 'uuid', recovery)
        success = True
        print(f'\nSUCCESS: {iface} has exactly one IPv4 address: {expected}\nGateway: {gateway}\nDNS: {", ".join(dns)}\nStatic profile UUID: {static}', flush=True)
    finally:
        if not success:
            # Avoid another interrupt halfway through recovery.
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            print('Configuration failed; attempting DHCP recovery.', file=sys.stderr, flush=True)
            if cutover:
                attempt('device', 'disconnect', iface)
                try:
                    run('ip', '-4', 'address', 'flush', 'dev', iface)
                except subprocess.CalledProcessError:
                    pass
            # Resolve names too, in case interruption occurred just after cloning.
            if static is None:
                try:
                    static = nm('-g', 'connection.uuid', 'connection', 'show', 'id', static_name)
                except subprocess.CalledProcessError:
                    pass
            if recovery is None:
                try:
                    recovery = nm('-g', 'connection.uuid', 'connection', 'show', 'id', recovery_name)
                except subprocess.CalledProcessError:
                    pass
            if static:
                attempt('connection', 'delete', 'uuid', static)
            old_exists = attempt('-g', 'connection.uuid', 'connection', 'show', 'uuid', old)
            if old_exists:
                attempt('connection', 'modify', 'uuid', old, 'connection.autoconnect', old_auto)
                restored = not cutover or attempt('--wait', '30', 'connection', 'up', 'uuid', old, 'ifname', iface)
                if restored and recovery:
                    attempt('connection', 'delete', 'uuid', recovery)
                elif not restored:
                    print(f'DHCP recovery failed. Original UUID: {old}; backup UUID: {recovery}', file=sys.stderr)
            elif recovery:
                attempt('connection', 'modify', 'uuid', recovery, 'connection.id', old_name, 'connection.autoconnect', old_auto)
                if not attempt('--wait', '30', 'connection', 'up', 'uuid', recovery, 'ifname', iface):
                    print(f'DHCP recovery failed. Recovery profile UUID: {recovery}', file=sys.stderr)
            else:
                print('No recovery profile available; inspect NetworkManager locally.', file=sys.stderr)

def terminate(signum, frame):
    raise KeyboardInterrupt(f'Signal {signum}')

signal.signal(signal.SIGTERM, terminate)
try:
    main()
except (Exception, KeyboardInterrupt) as error:
    print(f'ERROR: {error}', file=sys.stderr)
    sys.exit(1)
PYTHON
