# Private SMB backup share

## Purpose

Create a private Samba share on `{{SMB_SERVER_FQDN}}` and mount it on the camera
host at `{{SMB_MOUNT}}`, used as `{{BACKUP_PATH}}` for `Camera-CA-Backups`.
This is the SMB storage option; a mounted external drive or a local folder may
be used as `{{BACKUP_PATH}}` instead, provided it enforces the same permission
model this runbook establishes (0700/0600 owner-only, no extra ACL entries).
Access to the SMB host runs through the automated SSH login established by
`SSH_LOGIN.md`.

The executable workflow lives in:

```bash
scripts/SMB_SERVE/smb_serve_runbook.sh
```

That script is the single source of truth for executable actions. Do not
replace it with ad hoc shell fragments from this document.

## Required Values

| Symbol | Required value |
|---|---|
| `{{SMB_SERVER_FQDN}}` | FQDN of the machine hosting the Samba share |
| `{{SMB_USERNAME}}` | Existing Linux account on the SMB host that exclusively owns this share |
| `{{SMB_MOUNT}}` | Mount point on the camera host |
| `{{SMB_PASSWORD}}` | Samba password, entered at the script's no-echo prompt (`read -s`) |

Runbook defaults used by the script:

| Symbol | Meaning | Typical value in this deployment |
|---|---|---|
| share name | fixed share name created on the server | `camera-ca-private` |
| server directory | share path on the SMB host | `/srv/samba/camera-ca-private` |
| credentials file | client credentials file | `/etc/cifs-utils/credentials/camera-backup` |

## Guards (hard rules)

1. `apply` refuses to overwrite existing state: a share directory that is
   nonempty (beyond this runbook's own `Camera-CA-Backups` subdirectory) or
   differently owned, an existing `smbpasswd` entry, an existing share block
   in `smb.conf`, an existing credentials file whose content differs from
   the prompted password, or an existing fstab line for `{{SMB_MOUNT}}` that
   differs from the required entry all cause a refusal naming the artifact.
   Idempotent reruns re-verify instead of recreating.
2. The Samba password is prompted interactively without echo (`read -s`)
   inside the script only. It is never printed, logged, written to a file,
   or placed on a command line. `apply` and `verify` must run in a terminal
   so the prompt can read from the TTY; the script fails cleanly if no TTY
   is available or the entered password is empty.
3. The share must enforce `0600` files and `0700` directories on the
   **server's filesystem**. Client mode alone is insufficient: without
   negotiated POSIX extensions, `file_mode`/`dir_mode` are display settings
   and `chmod` can appear to succeed without changing server permissions.
   `apply` and `verify` check server-side `stat` and ACLs, not just the
   client view.
4. The negative access test requires an unrelated Samba account. The script
   can only prove denial via a null session; the full test with the account's
   real password is USER-run interactively (`smbclient` prompts). If no
   unrelated account exists, the script records the test as incomplete.
5. The script never changes the pre-existing `storage` share or any parent
   directory permissions.

## Workflow (AGENT-run)

```bash
cd {{REPO_PATH}}
scripts/SMB_SERVE/smb_serve_runbook.sh apply \
  --server-fqdn {{SMB_SERVER_FQDN}} \
  --username {{SMB_USERNAME}} \
  --mount {{SMB_MOUNT}} \
  [--test-account NAME] [--allow-install]
```

The `apply` command:

- server stage: verifies the account, creates the private `0700` share
  directory, creates the Samba password entry only if none exists, appends
  the share block (with a config backup) only if absent, validates the
  **effective** `testparm` output against the required enforcement, reloads
  or starts the Samba daemon, and confirms the prompted password
  authenticates against the live share;
- client stage: verifies `cifs-utils` and hostname resolution, creates the
  credentials file from the prompted password only if absent (mode `0600 root:root`),
  creates the mount point, adds the fstab automount entry only if absent,
  validates fstab, activates the automount, and requires a live `cifs` row
  (an `autofs` row alone is not success);
- probe test: creates `Camera-CA-Backups` and a temporary probe file,
  requires `0700`/`0600` on both client and server with owner-only ACLs, and
  removes the probe at exit via an EXIT trap;
- negative test: null-session denial when `--test-account` is supplied.

Expected final output:

```text
apply-ok server=<fqdn> share=camera-ca-private mount=<mount> user=<user>
```

Non-mutating inspection:

```bash
cd {{REPO_PATH}}
scripts/SMB_SERVE/smb_serve_runbook.sh status \
  --server-fqdn {{SMB_SERVER_FQDN}} \
  --username {{SMB_USERNAME}} \
  --mount {{SMB_MOUNT}}
```

Acceptance re-check (runs the probe test and the negative test without
changing configuration):

```bash
cd {{REPO_PATH}}
scripts/SMB_SERVE/smb_serve_runbook.sh verify \
  --server-fqdn {{SMB_SERVER_FQDN}} \
  --username {{SMB_USERNAME}} \
  --mount {{SMB_MOUNT}} \
  [--test-account NAME]
```

Expected: `verify-ok`.

## Acceptance criteria

After `apply`: the server share directory is `0700 {{SMB_USERNAME}}`, the
effective `testparm` share block matches the required enforcement exactly,
the prompted password authenticates against the live share, the client shows a live
`cifs` row for `{{SMB_MOUNT}}` with `rw`, the intended numeric UID/GID, and
`file_mode=0600,dir_mode=0700`, the probe test reports `0700`/`0600` on
**both** hosts with owner-only ACLs, and the probe is removed at exit. The
negative test either denies access or is explicitly recorded as incomplete.
Results must persist after a reboot; re-run `verify` after reboot before
copying any secrets.

## Pitfalls and notes

- The server firewall must allow TCP 445 from the camera host. On gmktec the
  UFW baseline (FIREWALL.md) denies incoming by default, so the mount fails
  with `mount error(115)` until a rule like
  `sudo ufw allow from <camera-host-ip> to any port 445 proto tcp` is added.
  Check `ss -ltn` for the listener and UFW for the rule before blaming the
  credentials.
- The Ubuntu `samba` server package does not ship `smbclient` (that is
  `samba-client`); when it is absent on the server, the client mount itself
  is the effective proof that the prompted password authenticates.
- `daemon-reload` alone does not start the automount, and `ls -ld` does not
  reliably trigger it; reading the directory contents does. The automount
  upcall is asynchronous, so the script retries the trigger-and-check pair
  before declaring failure.
- `systemctl is-active` exits 3 for inactive units; under `set -euo pipefail`
  that aborts a command substitution, so unit detection uses `if` form.
- The Samba daemon unit name varies by distribution (`smbd.service` on
  Debian/Ubuntu, `smb.service` on Arch-family); the script detects it.
- On Arch-family hosts the plain `samba` package ships no default
  `smb.conf` and enables no service, so `testparm` fails with
  "Can't load /etc/samba/smb.conf" until `cachyos-samba-settings` is
  installed; the pacman install branch includes it (it creates the default
  `smb.conf`, enables `smb`/`nmb`, and adds the user to `sambashare`).
- The remote login shell may be fish, which rejects POSIX constructs; the
  script forces `sh -c` for every remote command.
- `testparm` emits tab-indented entries; the effective-config comparison
  normalizes whitespace before comparing.
- `grep -v` exits 1 on empty results; filter steps tolerate that status
  explicitly so `set -euo pipefail` does not abort the probe test.
- `umask` is a shell builtin, not an executable, so `sudo umask` always
  fails ("command not found"); the credentials file mode is enforced by an
  explicit `chmod 0600` instead.
- systemd mount/automount unit names escape `-` inside a path element as
  `\x2d` (`/mnt/camera-backup` → `mnt-camera\x2dbackup.automount`); a plain
  dash substitution produces an invalid unit name that `systemctl start`
  silently fails, so the automount never fires.
- A `Password for root@...` prompt means the saved credentials file is not
  being supplied: check the file has both correctly formatted, nonempty
  entries and that fstab references it. Do not use `install -m 0600 /dev/null`
  on the credentials file — that erases saved credentials.
- Never treat a successful client `chmod` or a client `stat` alone as proof
  of server-side enforcement. Stop before copying secrets if the CIFS row is
  absent or read-only, credentials are exposed, creation fails, server files
  are broader than `0600`/`0700`, an ACL grants unexpected access, or an
  unrelated account can open the share.
