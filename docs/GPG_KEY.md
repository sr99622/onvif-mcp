# GPG Key and Password Store Creation/Backup Runbook

## Purpose

Create the one GPG key that will protect the `pass` password store, initialize
that store, add the camera-system passwords that are known at build time, and
back up both the GPG secret key and the password store.

Run the commands below as the account that will own the password store, in a
real terminal or an SSH session with a TTY. The user enters the GPG passphrase
in the terminal; it must never be put in a command, file, or agent transcript.

Follow the Recovery procedure at the end of this document to restore the key to
a new machine.

## Required Values

| Name | Description |
|---|---|
| `{{BACKUP_PATH}}` | Pre-mounted backup location (SMB shared folder, mounted external drive, or any directory on the system drive) |
| `{{REPO_PATH}}` | Full path to this repository on the camera host |
| `{{GPG_FINGERPRINT}}` | Full fingerprint copied from the step 2 `sec` output |
| `{{TIMESTAMP}}` | generated timestamp at capture time with `date -u +%Y%m%d%H%M%SZ` |

The exported secret key is stored at
`{{BACKUP_PATH}}/Camera-CA-Backups/ca-vault-gpg.key.gpg`. The `.gpg` extension is
the established backup filename; the file contents are ASCII armored OpenPGP.

The password-store backup is stored at
`{{BACKUP_PATH}}/Camera-CA-Backups/password-store-backup-{{TIMESTAMP}}.tar.gz`, where
`{{TIMESTAMP}}` is the current timestamp. Never overwrite an older password-store
backup; create a new timestamped copy after any password-store manipulation.

The backup location must already be mounted or created before this runbook is
executed; this runbook does not mount anything. Do not create backup files under
an unmounted local directory by mistake. If `{{BACKUP_PATH}}` does not exist or
is not writable, stop and warn the user; do not continue with the runbook.

## Agent Presentation Rules

This document is a script for the agent. The user should only see concrete,
copy-pasteable commands.

Before presenting any USER-run command or executing any AGENT-run command, replace
every double-curly placeholder with the real site value. Do not ask the user to
type or edit placeholders such as `{{BACKUP_PATH}}`, `{{REPO_PATH}}`, or
`{{GPG_FINGERPRINT}}`. If a value is not known, ask for that value before showing
or running the command.

When a USER-run command must be executed from the repository, include
`cd {{REPO_PATH}}` as the first line of the copy-paste block after resolving
`{{REPO_PATH}}` to the real path. The user should not need to know where the
repository is or modify the command.

After step 2, extract the full fingerprint from the `sec` block and use it to
replace `{{GPG_FINGERPRINT}}` in later commands. Preserve the fingerprint exactly,
including spaces, and quote it in shell commands.

## Key Generation

1. ### Configure terminal pinentry (AGENT-run)

      The agent performs this setup before handing the terminal to the user. It
      requires no GPG passphrase or interactive terminal. The helper script is
      the source of truth for the executable setup commands. Run it from the
      repository root:

      ```bash
      cd {{REPO_PATH}}
      scripts/GPG_KEY/gpg_key_runbook.sh agent-prep
      scripts/GPG_KEY/gpg_key_runbook.sh status --backup-path {{BACKUP_PATH}}
      ```

      The `agent-prep` command installs missing Debian/Ubuntu packages when
      `apt-get` is available, configures terminal pinentry, and leaves secret
      entry to the user. The `status` command prints non-secret state only,
      including whether `{{BACKUP_PATH}}` exists and is reachable. It is
      safe for the agent to run before the user creates the GPG key and again
      after each later stage. Do not replace the scripted workflow with ad hoc
      fragments.

      Do not run `gpg --full-gen-key` or enter a passphrase in the agent session.
      The user performs the next step in their own terminal.

2. ### Generate and identify the key (USER-run)

      Prompt the user to open another terminal session and run the helper script
      in that terminal. Display the command to the user offset from other text in
      the prompt so that the intent is clear. Do not clutter up the prompt with
      meaningless explanations irrelevant to the task at hand.

      ```bash
      cd {{REPO_PATH}}
      scripts/GPG_KEY/gpg_key_runbook.sh generate-key
      ```

      Tell the user to run the command accepting the default settings, then paste
      the result in the prompt window for your evaluation. Wait for the user to
      finish. They may have questions, so be prepared to respond in that event.

      Record the **full fingerprint** displayed below `sec`; use it to select the key
      for export and later for `pass init`. `gpg --list-keys` without an argument can
      also list the public keys and their `uid` names. A name or email is not needed
      to discover the key.

      Stop if the new key or its encryption subkey is missing. Do not create a second
      key just to retry the backup.

3. ### Export the secret key locally (USER-run)

      Replace `{{GPG_FINGERPRINT}}` with the full fingerprint from step 2. The
      fingerprint is the string under the sec line from `gpg --list-secret-keys --fingerprint`
      surrounded by double quotes to escape the spaces. For example, if the output
      is

      ```
      --------------------------------
      sec   ed25519 2026-09-18 [SC]
            AC3C 1053 FEFE 526E 26BD  3895 7247 25B2 87EE 7E5D
      uid           [ultimate] Stephen Rhodes <sr99622@gmail.com>
      ssb   cv25519 2026-09-18 [E]
      ```

      Then `{{GPG_FINGERPRINT}}` is "AC3C 1053 FEFE 526E 26BD  3895 7247 25B2 87EE 7E5D".

      Export the secret key to a protected local file now; copy it to
      `{{BACKUP_PATH}}` in the backup step. A failure must stop the sequence
      rather than leaving a false backup.

      GPG may ask for the key's passphrase through `pinentry-curses`. The exported
      file is sensitive even though the key is passphrase protected. Do not print,
      paste, email, or commit it. Do not use `sudo` for GPG: that would select root's
      key store instead of the user's.

      Run the script in the same terminal where `GPG_TTY` was set. Replace
      `{{GPG_FINGERPRINT}}` with the full fingerprint from step 2, preserving
      spaces and quoting:

      ```bash
      cd {{REPO_PATH}}
      scripts/GPG_KEY/gpg_key_runbook.sh export-key --fingerprint "{{GPG_FINGERPRINT}}"
      ```

4. ### Verify the local export before password-store creation

      The export must be nonempty and readable as a secret-key export. These
      checks display metadata, not the private key bytes. Use the script as the
      source of truth for the verification commands:

      ```bash
      cd {{REPO_PATH}}
      scripts/GPG_KEY/gpg_key_runbook.sh verify-export --fingerprint "{{GPG_FINGERPRINT}}"
      ```

      The packet listing must show a secret primary key and a secret subkey. Keep the
      GPG passphrase independently memorable or recoverable: losing both the live
      key and this export, or forgetting its passphrase, prevents recovery of the
      future `pass` store. Once verified, initialize the password store and back up
      both the GPG export and password store to `{{BACKUP_PATH}}`.

5. ### Initialize the password store (USER-run)

      Install `pass` if it is missing, then initialize the store with the same full
      fingerprint used for the GPG key backup. Bare `pass init` can select the wrong
      key or fail on some systems, so use the explicit fingerprint through the
      helper script. Run this after `pass` is installed:

      ```bash
      cd {{REPO_PATH}}
      scripts/GPG_KEY/gpg_key_runbook.sh init-store --fingerprint "{{GPG_FINGERPRINT}}"
      ```

6. ### Add camera password (USER-run)

      Add the operational password that other build procedures consume. It is
      entered interactively in the terminal so it does not appear in shell history,
      an agent transcript, or a committed runbook.

      ```bash
      cd {{REPO_PATH}}
      scripts/GPG_KEY/gpg_key_runbook.sh insert-passwords
      ```

      `camera` is the shared camera password used in RTSP/ONVIF camera access.
      Use the first line of the entry as the password. If the entry needs notes,
      use `pass edit camera` after the password is stored, keeping the password on
      line 1.

      Verify only that the entry exists and decrypts; do not paste the password into
      the agent chat or logs:

      ```bash
      cd {{REPO_PATH}}
      scripts/GPG_KEY/gpg_key_runbook.sh verify-passwords
      ```

7. ### Back up the password store (USER-run)

      First copy the local GPG secret-key export to `{{BACKUP_PATH}}` and
      verify the copy.

      Back up the whole password store immediately after adding or changing any
      password. This `pass` version stores per-entry `.gpg` files plus the hidden
      `.gpg-id`; the backup must include the entire store, not just one entry.

      Any later `pass insert`, `pass edit`, `pass rm`, generated CA passphrase, or
      camera password rotation must be followed by another password-store backup
      with a new `{{TIMESTAMP}}`/label. Do not continue a build or restore after
      changing the store until the new backup exists.

      Run the script only after `{{BACKUP_PATH}}` is confirmed to exist and be
      writable (the backup location must already be mounted or created). Omit
      `--label` to let the script generate
      `$(date -u +%Y%m%d%H%M%SZ)-initial`; pass a site-specific label for later
      backups such as `20260929021726Z-camera-rotation`:

      The agent must resolve `{{BACKUP_PATH}}` before presenting or running this
      command. Do not ask the user to type the double-curly-brace value literally.

      ```bash
      cd {{REPO_PATH}}
      scripts/GPG_KEY/gpg_key_runbook.sh backup --backup-path {{BACKUP_PATH}}
      ```

      The backup command refuses to write into a missing or unwritable location,
      copies `ca-vault-gpg.key.gpg` without overwriting a different existing
      export, creates `password-store-backup-<label>.tar.gz`, writes
      `pass-gpg-id.txt`, and prints non-secret verification metadata.

## Recovery

Copy `{{BACKUP_PATH}}/Camera-CA-Backups/ca-vault-gpg.key.gpg` unchanged to the new machine.
Configure terminal pinentry as in step 1, then import the key as the intended user.
The agent must resolve `{{REPO_PATH}}` and any backup file path before presenting
these commands:

```bash
cd {{REPO_PATH}}
scripts/GPG_KEY/gpg_key_runbook.sh import-key --key-file ca-vault-gpg.key.gpg
```

The export alone does not restore the password store. Restore its separate
backup after importing the key:

```bash
cd {{REPO_PATH}}
scripts/GPG_KEY/gpg_key_runbook.sh restore-store --backup-file password-store-backup-{{TIMESTAMP}}.tar.gz
```

If the backup was created with an older procedure that archived only selected
entries, inspect it first with `tar -tzf password-store-backup-{{TIMESTAMP}}.tar.gz`
and restore the listed paths into `~/.password-store` without overwriting newer
entries unintentionally.
