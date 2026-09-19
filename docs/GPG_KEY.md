# GPG Vault Key Creation and Backup Runbook

## Purpose

Create the one GPG key that will protect the `pass` password store, then back up
its secret key **before** starting `CREATE_CA_CERT.md`. This procedure covers
GPG only. The CA private key, `pass` entries, and `age` archives are created by
their own procedures.

Run the commands below as the account that will own the password store, in a
real terminal or an SSH session with a TTY. The user enters the GPG passphrase
in the terminal; it must never be put in a command, file, or agent transcript.

## Values supplied by the Agent

| Name | Meaning |
|---|---|
| `{{BACKUP_PATH}}` | Mounted SMB backup root (for this host, `/mnt/taurus/Camera-System-Backup`) |

The exported secret key is stored at
`{{BACKUP_PATH}}/Camera-CA-Backups/ca-vault-gpg.key.gpg`. The `.gpg` extension is
the established backup filename; the file contents are ASCII armored OpenPGP.

The backup path may not have been created yet. If the backup does not exist, 
attempt to create it using `mkdir -p`. If you are unable to find or create the
full backup path, stop and warn the user, do not continue with the runbook.

## 1. Configure terminal pinentry (AGENT-run)

The agent performs this setup before handing the terminal to the user. It
requires no GPG passphrase or interactive terminal. Verify GPG and terminal
pinentry are installed:

```bash
gpg --version
test -x /usr/bin/pinentry-curses
```

On Debian/Ubuntu, install a missing terminal pinentry with
`sudo apt install pinentry-curses`. Ensure `~/.gnupg/gpg-agent.conf` contains
the following line, preserving unrelated settings and replacing any existing
`pinentry-program` line that selects a GUI:

```ini
pinentry-program /usr/bin/pinentry-curses
```

Reload the agent and check the configuration file:

```bash
gpgconf --reload gpg-agent
grep -Fx 'pinentry-program /usr/bin/pinentry-curses' ~/.gnupg/gpg-agent.conf
```

Verify that the ca-vault-gpg.key.gpg does not already exist.

Do not run `gpg --full-gen-key` or enter a passphrase in the agent session.
The user performs the next step in their own terminal.

## 2. Generate and identify the key (USER-run)

Prompt the user to open another terminal session and run this command set
in that terminal. Display the command set to the user offset from other text 
in the prompt so that the intent is clear. Do not clutter up the prompt with 
meaningless explanations irrelevant to the task at hand.

```bash
tty
export GPG_TTY=$(tty)
gpg-connect-agent updatestartuptty /bye
gpg --full-gen-key
gpg --list-secret-keys --fingerprint
```

Tell the user to run these commands accepting the default settings, then paste 
the result in the prompt window for your evaluation. Wait for the user to 
finish. They may have questions, so be prepared to respond in that event.

Record the **full fingerprint** displayed below `sec`; use it to select the key
for export and later for `pass init`. `gpg --list-keys` without an argument can
also list the public keys and their `uid` names. A name or email is not needed
to discover the key.

Stop if the new key or its encryption subkey is missing. Do not create a second
key just to retry the backup.

## 3. Export and back up the secret key (USER-run)

Replace `YOUR_FULL_FINGERPRINT` with the full fingerprint from step 2. The 
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

Then YOUR_FULL_FINGERPRINT is "AC3C 1053 FEFE 526E 26BD  3895 7247 25B2 87EE 7E5D".

Resolve`{{BACKUP_PATH}}` before running the commands; do not type the braces 
literally. Check that the backup share is mounted and the destination does not 
already exist. A failure must stop the sequence rather than leaving a false backup.

```bash
set -e
umask 077
fpr=YOUR_FULL_FINGERPRINT
backup_dir="{{BACKUP_PATH}}/Camera-CA-Backups"
local_export="$HOME/ca-vault-gpg.key.gpg"
backup_export="$backup_dir/ca-vault-gpg.key.gpg"

test ! -e "$local_export"
test ! -e "$backup_export"
mkdir -p "$backup_dir"
gpg --armor --output "$local_export" --export-secret-keys "$fpr"
test -s "$local_export"
chmod 600 "$local_export"
install -m 600 "$local_export" "$backup_export"
cmp -s "$local_export" "$backup_export"
```


GPG may ask for the key's passphrase through `pinentry-curses`. The exported
file is sensitive even though the key is passphrase protected. Do not print,
paste, email, or commit it. Do not use `sudo` for GPG: that would select root's
key store instead of the user's.

## 4. Verify the backup before CA creation

The export and backup must be nonempty, byte-identical, and readable as a
secret-key export. These commands display metadata, not the private key bytes:

```bash
ls -l "$local_export" "$backup_export"    # both mode 600
cmp -s "$local_export" "$backup_export"     # exit status 0
gpg --list-packets "$backup_export" | sed -n '/secret key packet/p;/secret sub key packet/p'
gpg --list-secret-keys "$fpr"                # primary key and encryption subkey
```

The packet listing must show a secret primary key and a secret subkey. Keep the
GPG passphrase independently memorable or recoverable: losing both the live
key and this export, or forgetting its passphrase, prevents recovery of the
future `pass` store. Once verified, proceed to `CREATE_CA_CERT.md` to initialize
`pass` and create the CA.

## Recovery note

Copy `ca-vault-gpg.key.gpg` unchanged to the new machine. Have the agent
configure terminal pinentry as in step 1, then import the key as the intended
user in a real terminal with `GPG_TTY` set as in step 2:

```bash
chmod 600 ca-vault-gpg.key.gpg
gpg --import ca-vault-gpg.key.gpg
gpg --list-secret-keys
```

The export alone does not restore the password store. Restore its separate
backup after importing the key, following `CREATE_CA_CERT.md`'s recovery
procedure.
