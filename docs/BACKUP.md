# Server Backup and Restore

The system is designed such that it can be recovered from backup in the event of server failure. The integrated backup mechanism stores recovery points under `{{BACKUP_PATH}}`, which may be a shared folder served by another machine (SMB), a mounted external drive, or a local filesystem folder. A runbook is included for setting up the shared Linux SMB server with corresponding client configuration on the camera host; whichever storage type is used, the location must enforce the same permission model the SMB mount enforced (mode 0700 owner-only, files 0600, no extra ACL entries).

## Backup Path

  The system requires a backup storage location in the form of a file system path during installation. The path can be a local filesystem path, a mounted external storage drive or a network SMB shared directory. Which one you choose will depend on your system requirements and the importance of the backup strategy. 

  * Local file system path

    This backup storage provides very little protection against a system crash, as it resides on the same file system as the installation itself. It is also very low effort to implement, involving only creating a folder in your file system to hold the backup files. 

    ```
    mkdir $HOME/camera-backup
    sudo chmod 700 $HOME/camera-backup
    sudo chown $USER:$USER $HOME/camera-backup
    ```

  * Mounted external drive

    This backup storage provides good protection against a system crash, as it resides on a removable storage device that will be unaffected by a system crash. It has the added advantage that it can be stored off-site in the event of a catastrophic site event, the system can still be recovered. One disadvantage is that the drive must be mounted previous to making any system changes, such as adding a new user or a new camera so that the backup can be stored. An example of using a USB drive for this purpose, assuming you have previously formatted the drive with the appropriate file system, usually ext4.

    Find the name of the mounted drive using `lsblk`, then run the following commands, replacing {{drive_name}} with the name of the mounted drive, e.g. `sdb1`

    ```
    sudo mkdir /mnt/usb
    sudo mount /dev/{{drive_name}} /mnt/usb
    sudo mkdir /mnt/usb/camera-backup
    sudo chmod 700 /mnt/usb/camera-backup
    sudo chown $USER:$USER /mnt/usb/camera-backup

  * SMB shared directory

    By far the most complex setup, but it has the advantage of being always on and available. Excellent protection from a server crash with instant accessibility for restoration. It will most likely reside on a local network within the same physical location, so a catastrophic site event poses a threat in the absence of physically removable media. This strategy requires configuration of a SMB server host in addition to the camera server. There are runbooks that will perform most of the configuration. Some preparatory work is required on the SMB server host before starting the runbooks.

    The system is designed to accommodate a SMB server on Ubuntu or Cachy OS. The SMB server must first enable SSH access.

    Ubuntu
    ```
    sudo apt install openssh-server -y
    sudo systemctl enable --now ssh
    ```

    Cachy OS
    ```
    sudo pacman -S openssh
    sudo systemctl enable --now sshd
    ```

    Enable passwordless sudo on the SMB server
    ```
    sudo env USER="$USER" bash -c '
    set -euo pipefail
    u="${USER:?USER environment variable is not set}"
    [[ "$u" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { echo "Invalid USER value: $u" >&2; exit 1; }
    f="$(mktemp)"
    trap "rm -f \"$f\"" EXIT
    printf "%s ALL=(ALL) NOPASSWD: ALL\n" "$u" > "$f"
    chmod 0440 "$f"
    visudo -cf "$f"
    install -o root -g root -m 0440 "$f" "/etc/sudoers.d/${u}-nopasswd"
    echo "Created /etc/sudoers.d/${u}-nopasswd"
    '
    ```

    This permission can be revoked after the SMB share has been setup by deleting the file that is created in the `/etc/sudoers.d` folder named after the user as ${USER}-nopasswd.

    The rest of the configuration can be run from the camera host using Hermes. The agent will use SSH to log into the SMB server and configure the shared drive, then mount it from the camera host with proper permissions.

    Required Values 

    | Name | Description |
    |---|---|
    | `{{SSH_SERVER_FQDN}}` | FQDN of the machine being logged in to |
    | `{{SSH_USERNAME}}` | User on that machine |
    | `{{REPO_PATH}}` | Full path to this repository |
    | `{{SMB_SERVER_FQDN}}` | FQDN of the machine hosting the Samba share |
    | `{{SMB_USERNAME}}` | Existing Linux account on the SMB host that exclusively owns this share |
    | `{{SMB_MOUNT}}` | Mount point on the camera host |


    Runbooks

    ```
    [SSH_LOGIN.md](docs/SSH_LOGIN.md)
    [SMB_SERVE.md](docs/SMB_SERVE.md)
    ```

## Recovery Procedure

1. ### Build out the HTTP Services 

  The HTTP Services are not restored from backup file, rather they are built out as new. This is a relatively lightweight activity for the agent and removes ambiguity that might otherwise cause confusion with respect to camera IP settings changed from previous iterations of DHCP assignment. From the main README.md of the repository, `Building the Server`, follow Steps 1 and 2. This will construct the system core upon which Encryption and Authentication layers can be added.

2. ### Recover GPG key

    Follow the instructions in GPG_KEY.md `Recovery` section.

3. ### Recover CA Certificate

    Follow the instructions in CREATE_CA_CERT.md `Recovery` section.

4. ### Generate Site Certificate

    Execute the full runbooks SITE_CERT.md and CA_DISTRIBUTE to re-create the nginx configuration using a newly signed site certificate.

5. ### Restore the Authorization Server

    Follow the instructions in KEYCLOAK_BACKUP `Restore from checkpoint` section to complete the recovery.
