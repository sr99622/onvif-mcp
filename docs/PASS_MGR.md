# Password Store (`pass` + GPG) Setup Record

## Purpose

Record the local, offline password manager set up on `intel` (this workstation) to hold the
passphrases created during private CA generation (`CREATE_CA_CERT.md`) so they are recoverable
without relying on an agent transcript.

No cloud service or account is involved. Everything is GPG-encrypted locally; encrypted copies
live on the SMB share at `/mnt/taurus/Camera-CA-Backups/`.

## Environment (as verified during setup, 2026-08-31)

- Host: `intel`, Debian userland, `stephen`
- GnuPG 2.4.8 already present; no password manager preinstalled (`pass`, `bw`, `gopass`, `op` all absent)
- `sudo` requires interactive TTY authentication, so apt could not be used for the install

## 1. Install `pass` without root

The original upstream repo (`zx2c4/pass`) was unavailable, but the Ubuntu package was:

```bash
cd /tmp
apt-get download pass                      # pass_1.7.4-8_all.deb (no root needed)
dpkg -x pass_1.7.4-8_all.deb .pass-x
install -m 755 .pass-x/usr/bin/pass ~/.local/bin/pass
rm -rf /tmp/pass_1.7.4-8_all.deb /tmp/.pass-x
```

No `.bashrc` changes were needed: `~/.local/bin` is already on `PATH` via the existing
`~/.local/bin/env` (uv) sourced from `~/.bashrc`.

Verify:

```bash
bash -lc 'command -v pass'    # -> /home/stephen/.local/bin/pass
pass --version                # pass 1.7.4
```

## 2. GPG key (created by the user, not the agent)

The user ran `gpg --full-gen-key` in a real terminal; neither the private key nor its
passphrase ever passed through an agent session. Resulting key:

- Algorithm: ed25519 `[SC]` + subkey cv25519 `[E]`, created 2026-08-31
- User ID: `Stephen Rhodes (Temp keystore) <sr99622@gmail.com>`
- Fingerprint: `8F14838E4865FB5AB5378496980454F927034D0A`

The GPG passphrase for this key is the one remaining secret — it guards both the vault and
the exported private key. Keep it out of files on this machine.

## 3. Initialize the store

Bare `pass init` failed with a usage error (key not auto-detected); an explicit key ID was
required:

```bash
pass init sr99622@gmail.com
```

This writes `~/.password-store/.gpg-id` containing `sr99622@gmail.com`.

## 4. Stored entries

Added with `-m` (mask output):

| Entry | Holds |
|---|---|
| `camera-ca/root-key-passphrase` | Passphrase for `/home/stephen/Private-CA/camera-system-ca/private/camera-system-root-ca.key.pem` |
| `camera-ca/age-archive-2026-08-31` | Passphrase for the age archive `camera-system-ca-initial-2026-08-31.tar.gz.age` (local + SMB) |

This pass version stores **per-entry files**, not a single `store.gpg`:

```text
~/.password-store/
├── .gpg-id                                  # "sr99622@gmail.com"
└── camera-ca/
    ├── root-key-passphrase.gpg              # 390 bytes, GPG-encrypted to the key above
    └── age-archive-2026-08-31.gpg          # 186 bytes
```

Read a secret: `pass show camera-ca/<name>` (prompts for the GPG passphrase; gpg-agent caches it).

## 5. Verification performed (secrets never printed)

Both stored passphrases were proven correct by piping them directly into their consumers:

CA key passphrase — pipe straight into openssl:

```bash
pass show camera-ca/root-key-passphrase | \
  openssl pkey -in /home/stephen/Private-CA/camera-system-ca/private/camera-system-root-ca.key.pem \
  -check -noout
# -> Key is valid
```

age archive passphrase — `age` reads its passphrase from `/dev/tty`, so feed the stored value
into a PTY via `script`. The working pattern (stdin-fed; a foreground one-shot `script`
wrapper that ran everything inside hung and timed out):

```bash
pass show camera-ca/age-archive-2026-08-31 | \
  script -qec "stty -echo 2>/dev/null; age -d /home/stephen/Private-CA/backups/camera-system-ca-initial-2026-08-31.tar.gz.age > /tmp/ca-decrypted.tgz" /dev/null
tar -tzf /tmp/ca-decrypted.tgz   # lists the CA tree -> success
shred -u /tmp/ca-decrypted.tgz   # wipe decrypted copy immediately
```

All temporary files used during verification were securely wiped.

## 6. Backups (on `/mnt/taurus/Camera-CA-Backups/`)

Backup of the whole store directory (entries are GPG-encrypted inside; `.gpg-id` included):

```bash
tar -C ~/.password-store -czf \
  /home/stephen/Private-CA/backups/password-store-backup-2026-08-31.tar.gz \
  camera-ca .gpg-id
cp --update=none \
  /home/stephen/Private-CA/backups/password-store-backup-2026-08-31.tar.gz \
  /mnt/taurus/Camera-CA-Backups/
sha256sum <local> <smb>   # both d663a805... (matched)
```

The GPG private key export was run by the user in their own terminal:

```bash
gpg --armor --export-secret-key sr99622@gmail.com > ~/ca-vault-gpg.key.gpg
```

then copied to `/mnt/taurus/Camera-CA-Backups/ca-vault-gpg.key.gpg` (SHA-256 matched on both
sides, `9d40a929...`; verified with `gpg --list-packets` that it contains a v4
passphrase-protected secret key packet; local copy set to mode 600).

Final SMB contents:

```text
/mnt/taurus/Camera-CA-Backups/
├── camera-system-ca-initial-2026-08-31.tar.gz.age   # full CA state (age, passphrase)
├── password-store-backup-2026-08-31.tar.gz          # vault entries + .gpg-id (GPG-encrypted)
├── pass-gpg-id.txt                                  # the store's .gpg-id value
└── ca-vault-gpg.key.gpg                             # GPG private key export (passphrase-protected)
```

## 7. Recovery procedure

On a fresh machine, in order:

1. Import the GPG key (prompts for the GPG passphrase):

   ```bash
   gpg --import ca-vault-gpg.key.gpg
   ```

2. Restore the store:

   ```bash
   mkdir -p ~/.password-store
   tar -xzf password-store-backup-2026-08-31.tar.gz -C ~/.password-store
   ```

3. Ensure `pass` is on `PATH` (`~/.local/bin`) and check a secret:

   ```bash
   pass show camera-ca/age-archive-2026-08-31 | wc -c    # 39 bytes -> readable
   ```

4. Decrypt and restore the CA state with that value (see section 5 for the PTY pattern):

   ```bash
   age -d camera-system-ca-initial-2026-08-31.tar.gz.age | tar -xz -C <target dir>
   ```

Losing `~/.gnupg` plus the exported key at the same time is unrecoverable even if all backup
files survive — hence the export.

## Pitfalls and notes

- **`pass init` needs an explicit key ID** on this box; it failed to auto-detect the GPG key.
- **This pass version uses per-entry `.gpg` files**, not one `store.gpg`. Backups must include
  the whole directory (including the hidden `.gpg-id`).
- **`age -p` / `age -d` read the passphrase from a terminal** (`/dev/tty`). In agent contexts
  this only works where a PTY exists; the stdin-fed `script ... | script -qec` pattern in
  section 5 is the reliable route. Foreground one-shot `script` wrappers hang (60 s timeout).
- The GPG key's user ID says "Temp keystore" — it was created ad hoc for this purpose but now
  permanently guards the vault and CA passphrases; treat it as long-lived infrastructure.
- If root access is ever convenient, `sudo apt install pass` (candidate 1.7.4-8) yields the
  same thing with a system PATH; the `~/.local/bin` copy works fine either way.
