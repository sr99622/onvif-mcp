# DNS backup and restore

This is the shared backup and restore procedure for the camera server's DNS-only
dnsmasq service. DNS.md defines installation and when to take a checkpoint.

Only the `Create a checkpoint` workflow is currently implemented as a script:

```bash
scripts/DNS_BACKUP/dns_backup_runbook.sh
```

That script is the single source of truth for executable checkpoint actions. The
restore procedure remains documented guidance until a restore script is added.

## Required Values

| Symbol | Description |
|---|---|
| `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server |
| `{{SERVER_IP}}` | LAN IP address of the server |
| `{{RVRS_SRV_IP}}` | Reverse IP address of the server for PTR lookup |
| `{{UPSTREAM_DNS}}` | Upstream DNS resolver |
| `{{BACKUP_PATH}}` | Backup location (SMB shared folder, mounted external drive, or local folder); must already exist and enforce the SMB-mount permission model (mode 0700 owner-only, no extra ACL entries) |

## Layout and scope

Each checkpoint is a complete configuration snapshot, not a delta:

```text
{{BACKUP_PATH}}/dns/YYYYMMDDHHMMSSZ/
├── dns.tar
├── metadata.txt
└── SHA256SUMS
```

`dns.tar` uses paths relative to `/` and contains:

| Source | Recovery purpose |
|---|---|
| `etc/dnsmasq.conf` | Main configuration and include rules |
| `etc/dnsmasq.d/` | Complete active configuration directory |
| `etc/default/dnsmasq` | Package settings, including `IGNORE_RESOLVCONF=yes` |
| `etc/systemd/system/dnsmasq.service.d/` | Drop-ins disabling resolver-registration hooks |
| `etc/systemd/system/dnsmasq.service`, if a genuine local unit override exists | Local service definition |

No DHCP leases, DNS cache, logs, package binaries, private keys, password-store
files, or runbook copies belong in this archive.

## Create a checkpoint (AGENT-run)

Run with resolved values:

```bash
cd {{REPO_PATH}}
scripts/DNS_BACKUP/dns_backup_runbook.sh create-checkpoint \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}} \
  --rvrs-srv-ip {{RVRS_SRV_IP}} \
  --upstream-dns {{UPSTREAM_DNS}} \
  --backup-path {{BACKUP_PATH}} \
  --trigger DNS.md
```

The script performs the checkpoint workflow:

- verifies `dnsmasq --test` succeeds;
- verifies dnsmasq is active and DNS-only;
- verifies the LAN-only UDP/TCP listeners;
- verifies the private A record, PTR record, public forwarding, and private-zone
  NXDOMAIN behavior;
- verifies `IGNORE_RESOLVCONF=yes` and disabled resolver-registration hooks;
- confirms the backup path exists, is writable, and enforces the SMB-mount
  permission model (mode 0700 owner-only, no extra ACL entries);
- creates a unique hidden staging directory under `{{BACKUP_PATH}}/dns/`;
- archives the complete managed configuration set into `dns.tar`;
- reads the archive back into protected temporary inspection storage;
- rejects unsafe archive paths and verifies required members and contents;
- writes `metadata.txt` with site values, OS/package versions, service state,
  listener state, validation output, and local-unit override status;
- writes and verifies `SHA256SUMS`;
- atomically renames the staging directory to the final UTC timestamp directory.

Failed staging directories are not recovery points. Retry with a fresh timestamp
rather than overwriting a completed checkpoint.

## Inspect checkpoint status (AGENT-run)

```bash
cd {{REPO_PATH}}
scripts/DNS_BACKUP/dns_backup_runbook.sh status \
  --backup-path {{BACKUP_PATH}}
```

## Restore from checkpoint

Restore is not yet scripted. If recovery is required, follow the original restore
principles and add a restore subcommand before doing production recovery:

1. Select the lexicographically newest completed directory matching exactly
   fourteen digits followed by `Z`. Ignore hidden staging directories.
2. Require valid `dns.tar`, `metadata.txt`, and `SHA256SUMS`.
3. Inspect metadata and archive members before extraction. Verify server LAN
   address/interface, hostname, upstream reachability, private zone, and PTR
   mapping still apply.
4. Mask/protect dnsmasq from auto-start before package installation or config
   replacement.
5. Restore only the recorded DNS configuration paths. Do not overwrite unrelated
   host resolver state.
6. Run DNS.md verification checks before declaring recovery complete.
7. Create a fresh checkpoint after any recovery-time adaptation.

## Pitfalls and notes

- Keep staging files, rollback copies, and archives outside all dnsmasq include
  directories.
- Syntax success alone is not enough; require live DNS query behavior before
  checkpointing.
- Do not label a test of extracted configs with absolute includes as an isolated
  restore test; it can accidentally test live files.
