# Private CA Creation and Backup Runbook

## Purpose

Create the private root Certificate Authority used by the camera system, store the
CA unlock secrets in the existing local `pass` + GPG vault, and back up the
complete CA state to the backup location.

The executable workflow lives in:

```bash
scripts/CREATE_CA_CERT/create_ca_cert_runbook.sh
```

That script is the single source of truth for executable actions. Do not replace
it with ad hoc shell fragments from this document. This document is the agent
script: it defines sequencing, user/agent boundaries, safety checks, and the
copy-paste prompts that must be shown when interactive user action is required.

## Required Values

| Name | Meaning |
|---|---|
| `{{CA_ROOT_PATH}}` | Private CA root directory |
| `{{BACKUP_PATH}}` | Backup location (SMB shared folder, mounted external drive, or local folder); must already exist and enforce the SMB-mount permission model (mode 0700 owner-only, no extra ACL entries) |
| `{{REPO_PATH}}` | Full path to this repository on the camera host |
| `{{TIMESTAMP}}` | generated UTC timestamp, `YYYYMMDDhhmmssZ` |

For the current implementation, the CA working directory is
`{{CA_ROOT_PATH}}/camera-system-ca`, local encrypted backups are written under
`{{CA_ROOT_PATH}}/backups`, and encrypted backups are written under
`{{BACKUP_PATH}}/Camera-CA-Backups`.

## Prerequisites

Complete `GPG_KEY.md` before starting this runbook. The backup location must
already exist and be writable, and it must enforce the SMB-mount permission
model: mode 0700 owned by the runbook user, no extra ACL entries. The storage
type is free (SMB share, mounted external drive, or local folder); the
permission model is not. The password store must already contain `camera`.
The backup folder must already contain the GPG secret-key export created by
`GPG_KEY.md`:

```text
{{BACKUP_PATH}}/Camera-CA-Backups/ca-vault-gpg.key.gpg
```

Passphrases are not supplied as variables and must never be pasted into chat.
The script generates these vault entries with a CSPRNG and stores them with
`pass`:

| Vault entry | Protects |
|---|---|
| `camera-ca/root-key-passphrase` | The CA private key used for signing |
| `camera-ca/age-archive-{{TIMESTAMP}}` | The encrypted CA-state archive from this run |

## Agent Presentation Rules

Before presenting any USER-run command or executing any AGENT-run command,
replace every double-curly placeholder with the real site value. Do not ask the
user to type or edit placeholders such as `{{CA_ROOT_PATH}}`, `{{BACKUP_PATH}}`,
or `{{REPO_PATH}}`.

When a USER-run command invokes a repository script, include `cd {{REPO_PATH}}`
as the first line after resolving it to the real repository path. The user must
be able to copy and paste the prompt without modification.

The script never accepts passwords or passphrases as command-line arguments.
If GPG needs a passphrase, the user primes the GPG agent from their own terminal
using the scripted command in step 2.

## Security model and hard rules

1. The GPG key and password store are created and backed up first, following
   `GPG_KEY.md`. Do not run `pass init` here.
2. The CA private key remains on the host and is encrypted with AES-256.
3. The root CA certificate is public and may be distributed; the private key must
   never leave the host except inside the encrypted CA-state archive.
4. Back up the password store immediately after the script creates the CA
   passphrase entries and again immediately before the CA archive is created.
5. Secrets are verified by consumers (`openssl pkey -check`, `age -d` and
   `tar -tzf`), never by printing secret values.
6. Do not write backups into `{{BACKUP_PATH}}` unless it is verified to exist,
   be writable by the runbook user, and enforce the SMB-mount permission model
   (mode 0700 owner-only, no extra ACL entries).

## 1. Prepare the CA workstation (AGENT-run)

Install required packages, configure safe GPG-agent cache settings, and print
non-secret state:

```bash
cd {{REPO_PATH}}
scripts/CREATE_CA_CERT/create_ca_cert_runbook.sh agent-prep
scripts/CREATE_CA_CERT/create_ca_cert_runbook.sh status \
  --ca-root {{CA_ROOT_PATH}} \
  --backup-path {{BACKUP_PATH}}
```

`agent-prep` may install `openssl`, `pass`, `gnupg`, `age`, and `util-linux` on
Debian/Ubuntu hosts. It also removes the invalid `cache-ttl` GPG-agent directive
if present and sets `default-cache-ttl 7200` plus `max-cache-ttl 7200`.

## 2. Prime the GPG cache if interactive unlock is required (USER-run)

If the agent-side `apply` command cannot decrypt or write password-store entries
because GPG needs a pinentry prompt, stop and show the user this exact resolved
copy-paste block:

```bash
cd {{REPO_PATH}}
scripts/CREATE_CA_CERT/create_ca_cert_runbook.sh prime-gpg-cache
```

Tell the user to enter the GPG passphrase in their terminal if prompted, and to
report when the command prints `prime-gpg-cache-ok`. Do not ask the user to paste
any passphrase or password into chat.

## 3. Create and back up the CA (AGENT-run)

Run the script with resolved paths. Omit `--timestamp` unless continuing a known
attempt that already reserved a timestamp; otherwise the script generates one.

```bash
cd {{REPO_PATH}}
scripts/CREATE_CA_CERT/create_ca_cert_runbook.sh apply \
  --ca-root {{CA_ROOT_PATH}} \
  --backup-path {{BACKUP_PATH}}
```

The `apply` command performs the full workflow:

- verifies the backup location: exists, writable, mode 0700 owned by the
  runbook user, no extra ACL entries;
- verifies the existing password store, the `camera` entry, prior
  password-store backup, and `ca-vault-gpg.key.gpg`;
- creates the protected CA directory tree and OpenSSL CA database;
- writes `openssl.cnf` with `copy_extensions = none` and the root/server
  certificate profiles;
- generates the CA-key and archive passphrases into protected temporary files,
  stores them in `pass`, and shreds the temporary files;
- backs up the whole password store as
  `password-store-backup-{{TIMESTAMP}}-ca-passphrases.tar.gz`;
- creates the encrypted RSA root CA key and verifies it with OpenSSL;
- creates and verifies the ten-year self-signed root CA certificate named
  `camera-system-root-ca.crt.pem` with subject `CN=Camera System Root CA`;
- backs up the whole password store again as
  `password-store-backup-{{TIMESTAMP}}-pre-ca-archive.tar.gz`;
- creates and verifies the authenticated `age` archive
  `camera-system-ca-initial-{{TIMESTAMP}}.tar.gz.age`;
- copies the age archive to the backup location without overwriting an existing
  archive and verifies the local and backup copies match.

Record the timestamp printed by `apply-ok timestamp=...`; later runbooks need it
for recovery and audit references.

## 4. Verify final state (AGENT-run)

Run verification with the exact timestamp printed by `apply`:

```bash
cd {{REPO_PATH}}
scripts/CREATE_CA_CERT/create_ca_cert_runbook.sh verify \
  --ca-root {{CA_ROOT_PATH}} \
  --backup-path {{BACKUP_PATH}} \
  --timestamp {{TIMESTAMP}}
```

Then inspect non-secret status:

```bash
cd {{REPO_PATH}}
scripts/CREATE_CA_CERT/create_ca_cert_runbook.sh status \
  --ca-root {{CA_ROOT_PATH}} \
  --backup-path {{BACKUP_PATH}}
```

A complete run leaves these key artifacts:

```text
{{CA_ROOT_PATH}}/camera-system-ca/private/camera-system-root-ca.key.pem
{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem
{{CA_ROOT_PATH}}/camera-system-ca/openssl.cnf
{{CA_ROOT_PATH}}/backups/camera-system-ca-initial-{{TIMESTAMP}}.tar.gz.age
{{BACKUP_PATH}}/Camera-CA-Backups/camera-system-ca-initial-{{TIMESTAMP}}.tar.gz.age
{{BACKUP_PATH}}/Camera-CA-Backups/password-store-backup-{{TIMESTAMP}}-ca-passphrases.tar.gz
{{BACKUP_PATH}}/Camera-CA-Backups/password-store-backup-{{TIMESTAMP}}-pre-ca-archive.tar.gz
{{BACKUP_PATH}}/Camera-CA-Backups/pass-gpg-id.txt
{{BACKUP_PATH}}/Camera-CA-Backups/ca-vault-gpg.key.gpg
```

## Recovery

Recovery still depends on the GPG key export and password-store backups created
by `GPG_KEY.md` and this runbook. The user must import the GPG key from a real
terminal so pinentry can request the key passphrase. Resolve paths before showing
commands.

1. Copy the backed-up GPG export to the recovery host, then import it in the
   user's terminal:

   ```bash
   cd {{REPO_PATH}}
   scripts/GPG_KEY/gpg_key_runbook.sh import-key --key-file ca-vault-gpg.key.gpg
   ```

2. Restore the password store backup that corresponds to the CA archive:

   ```bash
   cd {{REPO_PATH}}
   scripts/GPG_KEY/gpg_key_runbook.sh restore-store --backup-file password-store-backup-{{TIMESTAMP}}-pre-ca-archive.tar.gz
   ```

3. Decrypt the CA-state archive using the restored vault entry. Prefer adding a
   restore subcommand to `scripts/CREATE_CA_CERT/create_ca_cert_runbook.sh` before
   performing a production recovery so this document does not become a second
   executable source of truth.

## Pitfalls and notes

- Do not create a second origin for the CA private-key passphrase. The scripted
  `pass insert` step is the only origin.
- Do not initialize or recreate the password store here. If the store is missing,
  return to `GPG_KEY.md`.
- The storage type is free (SMB share, mounted external drive, or local
  folder), but the permission model is not: the script refuses `{{BACKUP_PATH}}`
  unless it is mode 0700 owned by the runbook user with no extra ACL entries,
  the same enforcement the SMB mount provided.
- GPG-agent cache expiry can block headless `pass` operations. Use the scripted
  USER-run `prime-gpg-cache` command, not ad hoc `pass show` fragments.
- `age -p` and encrypted OpenSSL key generation need PTY handling on this host;
  the script contains the verified `script -qec` patterns. Do not duplicate or
  alter those patterns in the runbook.
- Never print passphrase values, decrypted archives, private-key material, or
  password-store contents in an agent transcript.
