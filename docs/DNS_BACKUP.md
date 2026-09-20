# DNS backup and restore

This is the shared backup and restore procedure for the camera server's
DNS-only dnsmasq service. DNS.md defines installation and when to take a
checkpoint. Resolve `{{BACKUP_PATH}}` and site values from the installation
inputs.

## Layout and scope

```text
{{BACKUP_PATH}}/dns/YYYYMMDDHHMMSSZ/
    dns.tar
    metadata.txt
    SHA256SUMS
```

Generate the UTC capture timestamp with `date -u +%Y%m%d%H%M%SZ`. Every
checkpoint is a complete configuration snapshot, not a delta. Serialize
captures and refuse an existing destination; retry with a fresh timestamp
rather than overwriting. Keep completed checkpoints unchanged.

`dns.tar` uses paths relative to `/` and contains:

| Source | Recovery purpose |
|---|---|
| `etc/dnsmasq.conf` | Main configuration and include rules |
| `etc/dnsmasq.d/` | Complete active configuration directory, including binding, private zone, upstream and PTR settings |
| `etc/default/dnsmasq` | Package settings, including `IGNORE_RESOLVCONF=yes` |
| `etc/systemd/system/dnsmasq.service.d/` | Complete drop-in set, including disabled resolver-registration hooks |
| `etc/systemd/system/dnsmasq.service`, if a genuine local unit override exists | Local service definition; package-owned units are reinstalled |

Record the absence of local unit overrides explicitly. A temporary service
mask is not a service definition to archive. Preserve ownership, permissions,
ACLs, xattrs, and symlinks without dereferencing them. Use an explicit member
inventory and account for external `conf-file`, `conf-dir`, `addn-hosts`,
`hostsdir`, symlink targets, and service command-line inputs. Include required
external dnsmasq-specific configuration at its original root-relative path;
record shared host files such as `/etc/hosts` as dependencies and verify their
required records during recovery rather than replacing unrelated host state.
Unaccounted active inputs make the checkpoint incomplete.

Record OS/package versions, interface/address prerequisites, site FQDN/IP,
private zone, PTR mapping, upstream resolver, enabled state, effective unit
settings and validation results in `metadata.txt`. Record host resolver and
client/DHCP DNS-advertisement dependencies separately. The intended deployment
leaves systemd-resolved as the host resolver and runs dnsmasq on the server's
LAN address only. No DHCP service, leases, DNS cache, logs, package binaries,
or runbook copies belong in this archive. If dnsmasq has acquired DHCP duties,
stop and revise the scope instead of claiming this DNS-only backup covers it.
Treat configuration and site metadata as private installation data.

## Create a checkpoint

1. Complete DNS.md's configuration and verification checks. Require
   `sudo dnsmasq --test` success and inspect the effective service configuration
   for alternate configuration paths or arguments. Verify DNS-only operation,
   LAN-only UDP/TCP listeners, the private A/PTR records, public forwarding,
   and private-zone NXDOMAIN behavior. Confirm the resolver-registration hooks
   and `IGNORE_RESOLVCONF=yes` match DNS.md. Syntax success alone cannot prove
   that the service is using the intended records or bindings.
2. Confirm the intended backup share is mounted and writable. Create a unique
   hidden staging directory under `{{BACKUP_PATH}}/dns/`, with restricted
   access. Freeze configuration edits during capture; DNS queries can continue.
   Never place staging files, archives or rollback copies inside a dnsmasq
   include directory, regardless of their filename extension.
3. Create `dns.tar` with `-C /` from the reviewed inventory, preserving file
   metadata and symlinks. Include the whole configuration set even if this
   change touched only one file. Do not include inactive scratch copies or
   temporary masks. If a supposed scratch file is actively included, resolve
   that configuration problem before capture rather than silently omitting it.
4. Read the archive back from the share into protected temporary inspection
   storage. Reject absolute paths, `..` traversal and symlinks that would
   redirect extraction outside the intended destination. Compare members,
   contents and metadata with the captured source and required inventory.
   Require the main config, active directory, defaults, and expected drop-ins.
   Run `dnsmasq --test` again while the source remains unchanged. Testing an
   extracted config with absolute includes can accidentally test live files;
   do not label that an isolated restore test.
5. Write `metadata.txt`, including actual validation results and dependencies.
   Generate `SHA256SUMS` for `dns.tar` and `metadata.txt`; verify the files on
   the share with `sha256sum -c SHA256SUMS`. Only after all checks pass, rename
   the staging directory to the final UTC timestamp within the same parent,
   without replacing an existing destination. Failed staging directories are
   not recovery points. Remove protected temporary inspection files.

Take a fresh checkpoint after initial verification and after later DNS
record, upstream, binding, include, or service-override changes. Each capture
uses this same history; do not create new `dns-*` procedure folders or separate
`final-etc-dnsmasq*.tar` fragments. Record execution details in checkpoint
metadata.

## Restore a checkpoint

1. Select the lexicographically newest completed directory matching exactly
   fourteen digits followed by `Z`. Ignore hidden staging directories. Require
   `dns.tar`, `metadata.txt` and valid `SHA256SUMS`. Stop on missing or invalid
   data; choosing an older checkpoint is an explicit recovery decision.
2. Inspect metadata and archive members in protected temporary storage.
   Verify the server's LAN address/interface, hostname, upstream reachability,
   private zone and shared host-file dependencies match the selected state.
   If the replacement host needs different values, plan that adaptation
   explicitly and capture the verified resulting state as a new checkpoint.
   Do not blindly restore a stale listen address or PTR mapping.
3. Prepare compatible dnsmasq/dnsmasq-base packages. Follow DNS.md's temporary
   mask-before-install procedure so package installation cannot start an
   unrestricted default service. On an authorized in-place recovery, preserve
   existing configuration first and stop dnsmasq before replacement. Keep a
   working host resolver available for package installation; do not repoint
   `/etc/resolv.conf` or disable systemd-resolved as part of this restore.
   If a local unit override prevents masking, preserve it and handle the mask
   deliberately; do not ignore a failed mask or allow package auto-start.
4. With dnsmasq stopped and protected from auto-start, install the selected
   snapshot at its recorded root-relative paths. Replace the managed config
   directory and drop-in set cleanly after preserving them outside all include
   paths; do not overlay stale files. Restore recorded absence of optional
   overrides too. Inspect archive paths and symlinks before extraction. Stage
   any local unit definition while the temporary mask is in place, and install
   it only when removing that mask immediately before validation/start.
   Do not overwrite unrelated systemd units or host resolver configuration.
5. Verify the include rules, `listen-address`, `bind-interfaces`, private-zone
   and PTR records, explicit upstream with `no-resolv`, disabled registration
   hooks, and `IGNORE_RESOLVCONF=yes`. Use the selected metadata and DNS.md's
   design, not hardcoded line numbers. Require `dnsmasq --test` success using
   the same config inputs as the service. Remove the temporary mask, install
   any recorded local unit override, reload systemd, and inspect the resulting
   unit. Confirm UDP/TCP port 53 is available on the intended LAN address.
6. Start dnsmasq and verify all of the following before declaring recovery
   complete or enabling it according to the recorded intended state:

   - The private FQDN resolves to the intended LAN address.
   - Public lookups forward successfully to the intended upstream.
   - Unknown private-zone names return NXDOMAIN; configuration keeps the
     private zone local rather than forwarding it upstream.
   - Reverse lookup returns the intended FQDN.
   - dnsmasq owns UDP and TCP port 53 only on the intended LAN address, not
     wildcard, loopback, camera-network or Wi-Fi addresses.
   - systemd-resolved and the host's own resolver still work as intended.
   - A LAN client querying the server directly obtains the expected answers.

   Use DNS.md §§8–10 for concrete `ss`, `dig`, and client test commands.
   Configuration changes require a full restart after validation, not just
   reload. On failure, stop and diagnose or restore the preserved configuration;
   do not layer older checkpoints over the selected state.
7. Confirm client/DHCP DNS advertisement separately; this archive does not
   configure an external DHCP server. Record recovery results outside the
   immutable checkpoint. Publish a fresh checkpoint after any recovery-time
   changes pass verification. Restore DNS before dependent client HTTPS and
   authentication validation.
