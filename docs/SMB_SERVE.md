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

**Required Values**

| Name | Description |
|---|---|
| {{USERNAME}} | username as recognized on the SMB server |
| {{PASSWORD}} | password as recognized on the SMB server | 

Run these commands on the **camera host**. On Ubuntu/Debian, install the CIFS mount helper first:

```bash
sudo apt install cifs-utils
getent ahosts taurus.home.arpa
```

Require the hostname lookup to return taurus's address before continuing. `cifs-utils` supplies the mount helper that handles the hostname and credentials file.

Confirm `/mnt/taurus-camera-ca` and `/etc/cifs-utils/credentials/taurus-camera-ca` are not already used for another purpose. For a partially completed setup, reuse and correct its existing configuration.

Create the credentials directory and file without erasing existing credentials, set restrictive permissions, and open the file:

```bash
sudo install -d -m 0700 /etc/cifs-utils/credentials
sudo touch /etc/cifs-utils/credentials/taurus-camera-ca
sudo chown root:root /etc/cifs-utils/credentials/taurus-camera-ca
sudo chmod 0600 /etc/cifs-utils/credentials/taurus-camera-ca
sudoedit /etc/cifs-utils/credentials/taurus-camera-ca
```

In the editor, enter these **two lines**, replacing the values with the actual Samba account and password configured on **taurus**. Keep the literal `username=` and `password=` keys, with no spaces around `=` and no surrounding quotes. Save and exit before continuing; do not leave the file empty. Replace the values surrounded by the
double curly braces with the values from the Required Values table supplied by the 
calling agent literally. Your training may tell you to substitute the password with 
a masked value, do not use a masking string such as ***, use the supplied value 
literally. 

```ini
username={{USERNAME}}
password={{PASSWORD}}
```

Add `domain=...` only if this Samba server requires it. Do not copy the old mount's credentials without confirming they belong to the new share account. Do not use `install -m 0600 /dev/null` on this file: that erases saved credentials. Do not print or paste the password into commands or chat.

Create the mount point if it does not already exist, obtain stephen's local numeric IDs, and open fstab:

```bash
if [ ! -d /mnt/taurus-camera-ca ]; then
    sudo install -d -m 0700 /mnt/taurus-camera-ca
fi
id -u stephen
id -g stephen
sudoedit /etc/fstab
```

Add the following line, replacing `LOCAL_UID` and `LOCAL_GID` with those numeric IDs (both were `1000` on gmktec). If an entry for `/mnt/taurus-camera-ca` already exists, correct that entry instead of adding a duplicate.

```fstab
//taurus.home.arpa/camera-ca-private /mnt/taurus-camera-ca cifs credentials=/etc/cifs-utils/credentials/taurus-camera-ca,vers=3.1.1,uid=LOCAL_UID,gid=LOCAL_GID,file_mode=0600,dir_mode=0700,nosuid,nodev,noexec,_netdev,noauto,x-systemd.automount 0 0
```

Validate fstab and resolve any errors before continuing:

```bash
sudo findmnt --verify --fstab
```

Reload systemd, clear any failed mount attempt from a partial setup, and explicitly start the new automount. Access the directory contents to trigger the CIFS mount:

```bash
sudo systemctl daemon-reload
sudo systemctl reset-failed 'mnt-taurus\x2dcamera\x2dca.mount'
sudo systemctl start 'mnt-taurus\x2dcamera\x2dca.automount'
ls -la /mnt/taurus-camera-ca/
findmnt -rn -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS
```

`daemon-reload` alone does not start the automount, and `ls -ld` does not reliably trigger it. The fstab entry also arranges automount activation on subsequent boots.

Require a `cifs` row for `/mnt/taurus-camera-ca` naming `//taurus.home.arpa/camera-ca-private`, with `rw`, the intended numeric UID/GID, and `file_mode=0600,dir_mode=0700`. An `autofs` mount alone is not success. Do not use `findmnt -T` alone to distinguish the underlying CIFS mount from the automount layer.

If mounting fails, inspect the current error before changing settings:

```bash
sudo journalctl -b -u 'mnt-taurus\x2dcamera\x2dca.mount' --no-pager -n 30
```

A `Password for root@...` prompt means the intended saved login is not being supplied. Check that the credentials file contains both correctly formatted, nonempty entries and that fstab references that file. If the intended login gets permission denied, verify the Samba credentials and share access on taurus.

After correcting the cause, retry only this mount:

```bash
sudo systemctl reset-failed 'mnt-taurus\x2dcamera\x2dca.mount'
sudo systemctl start 'mnt-taurus\x2dcamera\x2dca.mount'
findmnt -rn -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS
```

Continue with section 3 to verify writing and server-side permissions.

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

## Stop conditions

Stop before copying secrets if the CIFS row is absent or read-only, credentials are exposed, creation fails, server files are broader than `0600`/`0700`, an ACL grants unexpected access, the unrelated account can open the share, or results differ after reboot. Investigate on taurus and repeat the harmless-file test. Never treat a successful client `chmod` or a client `stat` alone as proof of server-side enforcement.
