# Private SMB backup share on taurus.home.arpa

## Goal

Create a **new** Samba share on `taurus.home.arpa` and mount it on the camera host at `/mnt/taurus-camera-ca`. Use `/mnt/taurus-camera-ca/Camera-CA-Backups` as the new `{{BACKUP_PATH}}/Camera-CA-Backups`. Leave the existing `/mnt/taurus` mount and its files untouched during setup.

This procedure requires root or sudo access on both hosts and a dedicated Samba login. Run server commands on **taurus** and client commands on the **camera host**. Replace `BACKUP_ACCOUNT` with an existing Linux account on taurus that will exclusively own this share. Do not put passwords in commands, chat, or the runbook.

The acceptance standard is: new files are `0600` on the **server's filesystem**, directories are `0700`, the client reports `0600` and `0700`, and an unrelated Samba account cannot open the share. Client mode alone is insufficient: without negotiated POSIX extensions, `file_mode` and `dir_mode` are display and local access settings, and `chmod` can appear to succeed without changing server permissions. [mount.cifs documentation](https://man7.org/linux/man-pages/man8/mount.cifs.8.html)

## 1. Prepare the server (taurus)

Choose the existing Linux account that should own the backup. Confirm that it is the intended account, and verify that the new directory does not already contain data:

```bash
getent passwd BACKUP_ACCOUNT
sudo test ! -e /srv/samba/camera-ca-private
```

Create a private directory. If `/srv/samba` does not exist, create it first using the server's normal directory layout; do not change permissions on any existing parent directory or share.

```bash
sudo install -d -o BACKUP_ACCOUNT -g BACKUP_ACCOUNT -m 0700 /srv/samba/camera-ca-private
sudo stat -c '%a %U:%G %n' /srv/samba/camera-ca-private
```

Confirm that `BACKUP_ACCOUNT` has a Samba password. If it does not, run `sudo smbpasswd -a BACKUP_ACCOUNT` interactively on taurus. Use a dedicated strong password. Do not reuse or print it. The account must have no unrelated access that would undermine the share boundary.

Back up the Samba configuration, then add this share to `/etc/samba/smb.conf` using `sudoedit`. If the account name contains unusual characters, verify Samba's exact account syntax before proceeding.

```ini
[camera-ca-private]
    path = /srv/samba/camera-ca-private
    valid users = BACKUP_ACCOUNT
    guest ok = no
    read only = no
    browseable = no
    create mask = 0600
    force create mode = 0600
    directory mask = 0700
    force directory mode = 0700
```

`create mask` removes group and other permission bits at creation; `force create mode` ensures owner read/write bits. The directory settings do the analogous work for new directories. [Samba smb.conf reference](https://www.samba.org/samba/docs/4.9/man-html/smb.conf.5.html)

Validate the **effective** share configuration, then reload Samba:

```bash
sudo testparm -s
sudo systemctl reload smbd
sudo systemctl is-active smbd
```

Stop if `testparm` reports an error or if the effective settings differ. Do not proceed by weakening the share or changing the old `storage` share.

## 2. Add a separate client mount (camera host)

Confirm the new mount point and credentials path do not already hold data or a different mount. Use a separate credentials file with mode `0600`. Enter its contents with `sudoedit`, interactively, in this form:

```ini
username=BACKUP_ACCOUNT
password=THE_PASSWORD_ENTERED_INTERACTIVELY
```

Add `domain=...` only if this Samba server requires it. Do not copy the old mount's credentials without confirming they belong to the new share account.

```bash
sudo install -d -m 0700 /etc/cifs-utils/credentials
sudo install -m 0600 /dev/null /etc/cifs-utils/credentials/taurus-camera-ca
sudoedit /etc/cifs-utils/credentials/taurus-camera-ca
sudo chown root:root /etc/cifs-utils/credentials/taurus-camera-ca
sudo chmod 0600 /etc/cifs-utils/credentials/taurus-camera-ca
sudo install -d -m 0700 /mnt/taurus-camera-ca
```

Add this **new** line to `/etc/fstab` using `sudoedit`. Replace `LOCAL_UID` and `LOCAL_GID` with the numeric output of `id -u stephen` and `id -g stephen` on the camera host.

```fstab
//taurus.home.arpa/camera-ca-private /mnt/taurus-camera-ca cifs credentials=/etc/cifs-utils/credentials/taurus-camera-ca,vers=3.1.1,uid=LOCAL_UID,gid=LOCAL_GID,file_mode=0600,dir_mode=0700,nosuid,nodev,noexec,_netdev,noauto,x-systemd.automount 0 0
```

Validate and activate only the new mount:

```bash
sudo findmnt --verify --fstab
sudo systemctl daemon-reload
ls -ld /mnt/taurus-camera-ca
findmnt /mnt/taurus-camera-ca -o TARGET,SOURCE,FSTYPE,OPTIONS
```

The output may show both `autofs` and `cifs` for the same mount point. Require the `cifs` row to name `//taurus.home.arpa/camera-ca-private`, have no `ro` option, and show `file_mode=0600,dir_mode=0700`. Do not use `findmnt -T` alone to distinguish the underlying CIFS mount from the automount layer.

## 3. Test with harmless files before moving any secrets

On the camera host, as `stephen`, create the backup directory and a temporary empty file. Keep the printed filename for the server-side check. The trap removes the probe at shell exit.

```bash
umask 077
backup_dir=/mnt/taurus-camera-ca/Camera-CA-Backups
mkdir -m 0700 "$backup_dir"
probe=$(mktemp "$backup_dir/.permission-probe.XXXXXX") || exit 1
trap 'rm -f -- "$probe"' EXIT
chmod 600 "$probe"
stat -c '%a %U:%G %n' "$backup_dir" "$probe"
printf 'Probe basename: %s\n' "${probe##*/}"
```

If `Camera-CA-Backups` already exists, inspect it rather than rerunning `mkdir`. Keep this shell open until the server checks are complete. On **taurus**, substitute the printed probe basename:

```bash
sudo stat -c '%a %U:%G %n' /srv/samba/camera-ca-private/Camera-CA-Backups
sudo stat -c '%a %U:%G %n' /srv/samba/camera-ca-private/Camera-CA-Backups/PROBE_BASENAME
sudo getfacl -p /srv/samba/camera-ca-private /srv/samba/camera-ca-private/Camera-CA-Backups /srv/samba/camera-ca-private/Camera-CA-Backups/PROBE_BASENAME
```

Require `0700` for both server directories and `0600` for the server probe file, with no ACL entry granting another user or group access. Require the same reported modes on the camera host. A mount that merely displays `0600` while the server stores broader permissions **fails**. If taurus uses a filesystem or Samba ACL module that presents different ACL semantics, resolve them and test effective access before accepting the share.

Use a separate, unrelated Samba account to attempt access to the new share. `smbclient` prompts for its password interactively:

```bash
smbclient //taurus.home.arpa/camera-ca-private -U OTHER_ACCOUNT -c ls
```

Require an access-denied result. Do not use the backup account for this negative test, and do not put either account's password on a command line. If no unrelated test account is available, record that the remote access test remains incomplete.

Return to the camera-host shell and exit it so the trap deletes the probe. Confirm on both hosts that the probe is gone. Repeat the harmless-file test after a reboot to confirm that the mount and server permissions persist.

## 4. Cut over the runbooks

Only after all acceptance checks pass, use `/mnt/taurus-camera-ca` as `{{BACKUP_PATH}}` in `GPG_KEY.md` and `CREATE_CA_CERT.md`. Update any written configuration or runbook values that still point to `/mnt/taurus/Camera-System-Backup`. Copy the existing secret-key export to the new path without overwriting an existing file; verify byte identity and inspect its server-side mode and ACL again. Keep the old backup until the complete CA backup set and a recovery test have been verified at the new location. Removing the old share or its files is a separate decision.

## Stop conditions

Stop before copying secrets if the CIFS row is absent or read-only, credentials are exposed, creation fails, server files are broader than `0600`/`0700`, an ACL grants unexpected access, the unrelated account can open the share, or results differ after reboot. Investigate on taurus and repeat the harmless-file test. Never treat a successful client `chmod` or a client `stat` alone as proof of server-side enforcement.
