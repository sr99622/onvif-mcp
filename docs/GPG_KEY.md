# GPG Key and Password Store Creation/Backup Runbook

## Purpose

Create the one GPG key that will protect the `pass` password store, initialize
that store, add the camera-system passwords that are known at build time, and
back up both the GPG secret key and the password store **before** starting
`CREATE_CA_CERT.md`. The CA private key and CA backup archives are still created
by their own procedures.

Run the commands below as the account that will own the password store, in a
real terminal or an SSH session with a TTY. The user enters the GPG passphrase
in the terminal; it must never be put in a command, file, or agent transcript.

Follow the Recovery procedure at the end of this document to restore the key to
a new machine.

## Required Values

| Name | Description |
|---|---|
| `{{SMB_SERVER_FQDN}}` | SMB server Fully Qualified Domain Name |
| `{{SMB_MOUNT}}` | Mounted SMB shared folder |
| `{{SMB_USERNAME}}` | Samba username for the private camera CA backup share |
| `{{TIMESTAMP}}` | generated timestamp at capture time with `date -u +%Y%m%d%H%M%SZ` |

The exported secret key is stored at
`{{SMB_MOUNT}}/Camera-CA-Backups/ca-vault-gpg.key.gpg`. The `.gpg` extension is
the established backup filename; the file contents are ASCII armored OpenPGP.

The password-store backup is stored at
`{{SMB_MOUNT}}/Camera-CA-Backups/password-store-backup-{{TIMESTAMP}}.tar.gz`, where
`{{TIMESTAMP}}` is the current timestamp. Never overwrite an older password-store
backup; create a new timestamped copy after any password-store manipulation.

The backup mount may not exist until the SMB client mount step is complete. Do not
create backup files under an unmounted local directory by mistake; after step 7,
`{{SMB_MOUNT}}` should resolve contain the mounted private Samba share. If you are 
unable to mount or create the full backup path, stop and warn the user; do not 
continue with the runbook.

## Key Generation

1. ### Configure terminal pinentry (AGENT-run)

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

2. ### Generate and identify the key (USER-run)

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

3. ### Export the secret key locally (USER-run)

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

      The SMB share cannot be mounted until the `smb` password is available in
      step 6. Export the secret key to a protected local file now; copy it to SMB
      after the client mount is configured in step 7. A failure must stop the
      sequence rather than leaving a false backup.

      ```bash
      set -e
      umask 077
      fpr="YOUR_FULL_FINGERPRINT"
      local_export="$HOME/ca-vault-gpg.key.gpg"

      test ! -e "$local_export"
      gpg --armor --output "$local_export" --export-secret-keys "$fpr"
      test -s "$local_export"
      chmod 600 "$local_export"
      ```


      GPG may ask for the key's passphrase through `pinentry-curses`. The exported
      file is sensitive even though the key is passphrase protected. Do not print,
      paste, email, or commit it. Do not use `sudo` for GPG: that would select root's
      key store instead of the user's.

4. ### Verify the local export before password-store creation

      The export must be nonempty and readable as a secret-key export. These
      commands display metadata, not the private key bytes:

      ```bash
      fpr="YOUR_FULL_FINGERPRINT"
      local_export="$HOME/ca-vault-gpg.key.gpg"
      ls -l "$local_export"                 # mode 600
      gpg --list-packets "$local_export" | sed -n '/secret key packet/p;/secret sub key packet/p'
      gpg --list-secret-keys "$fpr"         # primary key and encryption subkey
      ```

      The packet listing must show a secret primary key and a secret subkey. Keep the
      GPG passphrase independently memorable or recoverable: losing both the live
      key and this export, or forgetting its passphrase, prevents recovery of the
      future `pass` store. Once verified, initialize the password store, mount the
      SMB share, and back up both the GPG export and password store before
      proceeding to `CREATE_CA_CERT.md`.

5. ### Initialize the password store (USER-run)

      Install `pass` if it is missing, then initialize the store with the same full
      fingerprint used for the GPG key backup. Bare `pass init` can select the wrong
      key or fail on some systems, so use the explicit fingerprint.

      ```bash
      set -e
      pass --version
      fpr="YOUR_FULL_FINGERPRINT"
      pass init "$fpr"
      test "$(cat ~/.password-store/.gpg-id)" = "$fpr"
      chmod 700 ~/.password-store
      ```

      If `pass` is not installed on Debian/Ubuntu:

      ```bash
      sudo apt install pass
      ```

6. ### Add camera and SMB passwords (USER-run)

      Add the operational passwords that other build procedures consume. These are
      entered interactively in the terminal so they do not appear in shell history,
      an agent transcript, or a committed runbook.

      ```bash
      pass insert camera
      pass insert smb
      ```

      `camera` is the shared camera password used in RTSP/ONVIF camera access.
      `smb` is the SMB password used by the camera-system backup/share workflow.
      Use the first line of each entry as the password. If the entry needs notes,
      use `pass edit <entry>` after the password is stored, keeping the password on
      line 1.

      Verify only that the entries exist and decrypt; do not paste the password into
      the agent chat or logs:

      ```bash
      pass show camera >/dev/null
      pass show smb >/dev/null
      find ~/.password-store -maxdepth 2 -type f -name '*.gpg' -print
      ```

7. ### Mount the private SMB backup share on the camera host (USER-run)

      The `smb` password is needed before the password store itself can be backed
      up to the SMB share. After step 6, configure the camera host's separate CIFS
      mount for the private CA backup share. This is the client-mount portion of
      `SMB_SERVE.md`; the Samba server-side share must already exist on {{SMB_SERVER_FQDN}}.

      Required values for this step:

      | Name | Description |
      |---|---|
      | `{{SMB_SERVER_FQDN}}` | SMB host Fully Qualified Domain Name |
      | `{{SMB_USERNAME}}` | Username as recognized on the SMB server |
      | `pass show smb` | Password as recognized on the SMB server |

      Install the CIFS mount helper and verify {{SMB_SERVER_FQDN}} resolves before continuing:

      ```bash
      sudo apt install cifs-utils
      getent ahosts {{SMB_SERVER_FQDN}}
      ```

      Confirm `{{SMB_MOUNT}}` and
      `/etc/cifs-utils/credentials/camera-backup` are not already used for a
      different purpose. For a partially completed setup, reuse and correct the
      existing configuration instead of creating a duplicate.

      Create the credentials file from the password store without putting the SMB
      password in shell history, command arguments, chat, or logs:

      ```bash
      set -e
      umask 077
      tmp_creds="$(mktemp "$HOME/.smb-creds.XXXXXX")"
      {
        printf 'username=%s\n' '{{SMB_USERNAME}}'
        printf 'password='
        pass show smb | head -n 1
      } > "$tmp_creds"
      sudo install -d -m 0700 /etc/cifs-utils/credentials
      sudo install -o root -g root -m 0600 "$tmp_creds" /etc/cifs-utils/credentials/camera-backup
      shred -u "$tmp_creds"
      sudo test -s /etc/cifs-utils/credentials/camera-backup
      ```

      Add `domain=...` to `/etc/cifs-utils/credentials/camera-backup` only if
      this Samba server requires it. Do not copy the old mount's credentials
      without confirming they belong to the new share account.

      Create the mount point if needed, get the local numeric UID/GID for the user
      who owns the build files, then edit `/etc/fstab`:

      ```bash
      if [ ! -d {{SMB_MOUNT}} ]; then
          sudo install -d -m 0700 {{SMB_MOUNT}}
      fi
      id -u stephen
      id -g stephen
      sudoedit /etc/fstab
      ```

      Add this line, replacing `LOCAL_UID` and `LOCAL_GID` with those numeric IDs.
      If an entry for `{{SMB_MOUNT}}` already exists, correct that entry
      instead of adding a duplicate:

      ```fstab
      //{{SMB_SERVER_FQDN}}/camera-ca-private {{SMB_MOUNT}} cifs credentials=/etc/cifs-utils/credentials/camera-backup,vers=3.1.1,uid=LOCAL_UID,gid=LOCAL_GID,file_mode=0600,dir_mode=0700,nosuid,nodev,noexec,_netdev,noauto,x-systemd.automount 0 0
      ```

      Validate fstab and resolve any errors before continuing:

      ```bash
      sudo findmnt --verify --fstab
      ```

      Reload systemd, clear any failed mount attempt from a partial setup, start
      the automount, and access the directory to trigger the CIFS mount:

      ```bash
      sudo systemctl daemon-reload
      sudo systemctl reset-failed 'mnt-camera-backup\x2dcamera\x2dca.mount'
      sudo systemctl start 'mnt-camera-backup\x2dcamera\x2dca.automount'
      ls -la {{SMB_MOUNT}}/
      findmnt -rn -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS
      ```

      Require a `cifs` row for `{{SMB_MOUNT}}` naming
      `//{{SMB_SERVER_FQDN}}/camera-ca-private`, with `rw`, the intended numeric
      UID/GID, and `file_mode=0600,dir_mode=0700`. An `autofs` mount alone is not
      success.

      If mounting fails, inspect the current error before changing settings:

      ```bash
      sudo journalctl -b -u 'mnt-camera-backup\x2dcamera\x2dca.mount' --no-pager -n 30
      ```

      A `Password for root@...` prompt means the saved login is not being supplied.
      Check that the credentials file has correctly formatted nonempty `username=`
      and `password=` lines and that fstab references that file. If the intended
      login gets permission denied, verify the Samba credentials and share access
      on {{SMB_SERVER_FQDN}}.

      Create the backup directory on the mounted share before continuing:

      ```bash
      install -d -m 0700 {{SMB_MOUNT}}/Camera-CA-Backups
      stat -c '%a %U:%G %n' {{SMB_MOUNT}} {{SMB_MOUNT}}/Camera-CA-Backups
      ```

8. ### Back up the password store (USER-run)

      First copy the local GPG secret-key export to the mounted SMB share and
      verify the copy. This is the first point where the SMB mount is available,
      because the SMB password was only added to `pass` in step 6.

      ```bash
      set -e
      umask 077
      backup_dir="{{SMB_MOUNT}}/Camera-CA-Backups"
      local_export="$HOME/ca-vault-gpg.key.gpg"
      backup_export="$backup_dir/ca-vault-gpg.key.gpg"

      test -s "$local_export"
      mkdir -p "$backup_dir"
      test ! -e "$backup_export"
      install -m 600 "$local_export" "$backup_export"
      cmp -s "$local_export" "$backup_export"
      gpg --list-packets "$backup_export" | sed -n '/secret key packet/p;/secret sub key packet/p'
      ```

      Back up the whole password store immediately after adding or changing any
      password. This `pass` version stores per-entry `.gpg` files plus the hidden
      `.gpg-id`; the backup must include the entire store, not just one entry.

      Resolve `{{SMB_MOUNT}}` and `{{TIMESTAMP}}` before running the commands; do not
      type the braces literally.

      ```bash
      set -e
      umask 077
      backup_dir="{{SMB_MOUNT}}/Camera-CA-Backups"
      backup_label="{{TIMESTAMP}}-initial"
      backup_file="$backup_dir/password-store-backup-$backup_label.tar.gz"
      mkdir -p "$backup_dir"
      test ! -e "$backup_file"
      tar -C "$HOME" -czf "$backup_file" .password-store
      test -s "$backup_file"
      chmod 600 "$backup_file"
      cat ~/.password-store/.gpg-id > "$backup_dir/pass-gpg-id.txt"
      tar -tzf "$backup_file" | sed -n '1,20p'
      ```

      Any later `pass insert`, `pass edit`, `pass rm`, generated CA passphrase, SMB
      password rotation, or camera password rotation must be followed by another
      password-store backup with a new `{{TIMESTAMP}}`/label. Do not continue a build or
      restore after changing the store until the new backup exists.

## Recovery

Copy `{{SMB_MOUNT}}/Camera-CA-Backups/ca-vault-gpg.key.gpg` unchanged to the new machine. 
Configure terminal pinentry as in step 1, then import the key as the intended user in a real 
terminal with `GPG_TTY` set as in step 2:

```bash
chmod 600 ca-vault-gpg.key.gpg
gpg --import ca-vault-gpg.key.gpg
gpg --list-secret-keys
```

The export alone does not restore the password store. Restore its separate
backup after importing the key:

```bash
mkdir -p ~/.password-store
tar -xzf password-store-backup-{{TIMESTAMP}}.tar.gz -C "$HOME"
pass show camera >/dev/null
pass show smb >/dev/null
```

If the backup was created with an older procedure that archived only selected
entries, inspect it first with `tar -tzf password-store-backup-{{TIMESTAMP}}.tar.gz`
and restore the listed paths into `~/.password-store` without overwriting newer
entries unintentionally.
