#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  gpg_key_runbook.sh agent-prep
  gpg_key_runbook.sh generate-key
  gpg_key_runbook.sh status --smb-mount PATH --smb-server-fqdn HOST --smb-username USER
  gpg_key_runbook.sh export-key --fingerprint FPR
  gpg_key_runbook.sh verify-export --fingerprint FPR
  gpg_key_runbook.sh init-store --fingerprint FPR
  gpg_key_runbook.sh insert-passwords
  gpg_key_runbook.sh verify-passwords
  gpg_key_runbook.sh mount-smb --smb-mount PATH --smb-server-fqdn HOST --smb-username USER [--local-user USER]
  gpg_key_runbook.sh backup --smb-mount PATH [--label LABEL]
  gpg_key_runbook.sh import-key --key-file PATH
  gpg_key_runbook.sh restore-store --backup-file PATH

This script implements docs/GPG_KEY.md with site-specific values as arguments.
It never accepts passwords as arguments. GPG/pass prompts remain interactive;
the SMB password is read from `pass show smb` when creating CIFS credentials.
USAGE
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then usage; exit 64; fi
if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then usage; exit 0; fi
shift || true

fingerprint=""
smb_mount=""
smb_server_fqdn=""
smb_username=""
local_user="${USER:-stephen}"
label=""
key_file=""
backup_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fingerprint) fingerprint="${2:?missing --fingerprint value}"; shift 2 ;;
    --smb-mount) smb_mount="${2:?missing --smb-mount value}"; shift 2 ;;
    --smb-server-fqdn) smb_server_fqdn="${2:?missing --smb-server-fqdn value}"; shift 2 ;;
    --smb-username) smb_username="${2:?missing --smb-username value}"; shift 2 ;;
    --local-user) local_user="${2:?missing --local-user value}"; shift 2 ;;
    --label) label="${2:?missing --label value}"; shift 2 ;;
    --key-file) key_file="${2:?missing --key-file value}"; shift 2 ;;
    --backup-file) backup_file="${2:?missing --backup-file value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then echo "Missing required argument: $name" >&2; exit 64; fi
}

mount_unit_for() {
  local path="$1"
  if command -v systemd-escape >/dev/null 2>&1; then
    systemd-escape --path --suffix=mount "$path"
  else
    echo "mnt-camera\x2dbackup.mount"
  fi
}

automount_unit_for() {
  local path="$1"
  if command -v systemd-escape >/dev/null 2>&1; then
    systemd-escape --path --suffix=automount "$path"
  else
    echo "mnt-camera\x2dbackup.automount"
  fi
}

case "$cmd" in
  agent-prep)
    missing_packages=()
    command -v gpg >/dev/null 2>&1 || missing_packages+=(gnupg)
    command -v pass >/dev/null 2>&1 || missing_packages+=(pass)
    command -v mount.cifs >/dev/null 2>&1 || missing_packages+=(cifs-utils)
    [[ -x /usr/bin/pinentry-curses ]] || missing_packages+=(pinentry-curses)
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
      else
        printf 'Missing required packages: %s\n' "${missing_packages[*]}" >&2
        echo "Install them with the host package manager, then rerun agent-prep." >&2
        exit 1
      fi
    fi
    gpg --version >/dev/null
    test -x /usr/bin/pinentry-curses
    install -d -m 0700 "$HOME/.gnupg"
    conf="$HOME/.gnupg/gpg-agent.conf"
    touch "$conf"
    chmod 600 "$conf"
    if grep -qE '^pinentry-program ' "$conf"; then
      python3 - "$conf" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines()
out = []
for line in lines:
    if line.startswith('pinentry-program '):
        if 'pinentry-program /usr/bin/pinentry-curses' not in out:
            out.append('pinentry-program /usr/bin/pinentry-curses')
    else:
        out.append(line)
p.write_text('\n'.join(out) + ('\n' if out else ''))
PY
    else
      printf '%s\n' 'pinentry-program /usr/bin/pinentry-curses' >> "$conf"
    fi
    gpgconf --reload gpg-agent
    grep -Fx 'pinentry-program /usr/bin/pinentry-curses' "$conf" >/dev/null
    echo "agent-prep-ok"
    ;;

  generate-key)
    if ! tty_path="$(tty)" || [[ "$tty_path" == "not a tty" ]]; then
      echo "generate-key must be run in a real terminal or SSH session with a TTY." >&2
      exit 1
    fi
    export GPG_TTY="$tty_path"
    gpg-connect-agent updatestartuptty /bye
    gpg --full-gen-key
    gpg --list-secret-keys --fingerprint
    ;;

  status)
    require_arg --smb-mount "$smb_mount"
    require_arg --smb-server-fqdn "$smb_server_fqdn"
    require_arg --smb-username "$smb_username"
    echo "user=$(id -un) uid=$(id -u) gid=$(id -g)"
    command -v gpg >/dev/null && gpg --version | sed -n '1p'
    command -v pass >/dev/null && pass --version || echo "pass missing"
    test -x /usr/bin/pinentry-curses && echo "pinentry-curses present" || echo "pinentry-curses missing"
    command -v mount.cifs >/dev/null && echo "mount.cifs present" || echo "mount.cifs missing"
    getent ahosts "$smb_server_fqdn" || true
    gpg --list-secret-keys --fingerprint || true
    if [[ -f "$HOME/.password-store/.gpg-id" ]]; then
      printf 'password-store-gpg-id='
      tr -d '\n' < "$HOME/.password-store/.gpg-id"
      printf '\n'
    else
      echo "password-store not initialized"
    fi
    if [[ -f "$HOME/ca-vault-gpg.key.gpg" ]]; then
      stat -c 'local-export=%s bytes mode=%a owner=%U:%G path=%n' "$HOME/ca-vault-gpg.key.gpg"
    else
      echo "local export missing"
    fi
    if [[ -e /etc/cifs-utils/credentials/camera-backup ]]; then
      sudo stat -c 'credentials mode=%a owner=%U:%G path=%n' /etc/cifs-utils/credentials/camera-backup
    else
      echo "credentials file missing"
    fi
    if [[ -d "$smb_mount" ]]; then
      stat -c 'mountpoint mode=%a owner=%U:%G path=%n' "$smb_mount"
    else
      echo "mountpoint missing"
    fi
    findmnt -rn -T "$smb_mount" -o TARGET,SOURCE,FSTYPE,OPTIONS || true
    findmnt -rn -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS || true
    ;;

  export-key)
    require_arg --fingerprint "$fingerprint"
    umask 077
    local_export="$HOME/ca-vault-gpg.key.gpg"
    test ! -e "$local_export"
    gpg --armor --output "$local_export" --export-secret-keys "$fingerprint"
    test -s "$local_export"
    chmod 600 "$local_export"
    echo "export-key-ok $local_export"
    ;;

  verify-export)
    require_arg --fingerprint "$fingerprint"
    local_export="$HOME/ca-vault-gpg.key.gpg"
    test -s "$local_export"
    stat -c '%a %U:%G %s %n' "$local_export"
    gpg --list-packets "$local_export" | sed -n '/secret key packet/p;/secret sub key packet/p'
    gpg --list-secret-keys "$fingerprint"
    ;;

  init-store)
    require_arg --fingerprint "$fingerprint"
    pass --version >/dev/null
    pass init "$fingerprint"
    test "$(tr -d '\n' < "$HOME/.password-store/.gpg-id")" = "$fingerprint"
    chmod 700 "$HOME/.password-store"
    echo "init-store-ok"
    ;;

  insert-passwords)
    pass insert camera
    pass insert smb
    echo "insert-passwords-ok"
    ;;

  verify-passwords)
    pass show camera >/dev/null
    pass show smb >/dev/null
    find "$HOME/.password-store" -maxdepth 2 -type f -name '*.gpg' -print
    echo "verify-passwords-ok"
    ;;

  mount-smb)
    require_arg --smb-mount "$smb_mount"
    require_arg --smb-server-fqdn "$smb_server_fqdn"
    require_arg --smb-username "$smb_username"
    command -v mount.cifs >/dev/null || { echo "mount.cifs missing; install cifs-utils" >&2; exit 1; }
    getent ahosts "$smb_server_fqdn" >/dev/null
    pass show smb >/dev/null
    existing_fstypes="$(findmnt -rn -T "$smb_mount" -o FSTYPE 2>/dev/null || true)"
    if [[ -n "$existing_fstypes" ]] && ! printf '%s\n' "$existing_fstypes" | grep -qxE 'cifs|autofs'; then
      echo "$smb_mount is already mounted as a non-cifs filesystem; stop." >&2
      exit 1
    fi
    if [[ ! -d "$smb_mount" ]]; then
      sudo install -d -m 0700 "$smb_mount"
    fi
    umask 077
    tmp_creds="$HOME/.smb-creds.$$"
    {
      printf 'username=%s\n' "$smb_username"
      printf 'password='
      pass show smb | { IFS= read -r smb_password; printf '%s\n' "$smb_password"; }
    } > "$tmp_creds"
    sudo install -d -m 0700 /etc/cifs-utils/credentials
    sudo install -o root -g root -m 0600 "$tmp_creds" /etc/cifs-utils/credentials/camera-backup
    shred -u "$tmp_creds"
    sudo test -s /etc/cifs-utils/credentials/camera-backup
    uid="$(id -u "$local_user")"
    gid="$(id -g "$local_user")"
    fstab_line="//$smb_server_fqdn/camera-ca-private $smb_mount cifs credentials=/etc/cifs-utils/credentials/camera-backup,vers=3.1.1,uid=$uid,gid=$gid,file_mode=0600,dir_mode=0700,nosuid,nodev,noexec,_netdev,noauto,x-systemd.automount 0 0"
    sudo python3 - "$smb_mount" "$fstab_line" <<'PY'
import pathlib, sys
mount = sys.argv[1]
line = sys.argv[2]
p = pathlib.Path('/etc/fstab')
lines = p.read_text().splitlines()
out = []
replaced = False
for existing in lines:
    parts = existing.split()
    if len(parts) >= 2 and parts[1] == mount:
        if not replaced:
            out.append(line)
            replaced = True
        continue
    if existing.startswith('//') and '/camera-ca-private ' in existing and f' {mount} ' in existing:
        if not replaced:
            out.append(line)
            replaced = True
        continue
    out.append(existing)
if not replaced:
    out.append(line)
p.write_text('\n'.join(out) + '\n')
PY
    sudo findmnt --verify --fstab
    sudo systemctl daemon-reload
    mount_unit="$(mount_unit_for "$smb_mount")"
    automount_unit="$(automount_unit_for "$smb_mount")"
    sudo systemctl reset-failed "$mount_unit" || true
    sudo systemctl start "$automount_unit"
    # Trigger automount without printing share contents.
    stat "$smb_mount" >/dev/null
    if ! findmnt -rn -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS | awk -v target="$smb_mount" -v source="//$smb_server_fqdn/camera-ca-private" '$1 == target && $2 == source { found=1 } END { exit(found ? 0 : 1) }'; then
      echo "CIFS mount did not appear for $smb_mount" >&2
      sudo journalctl -b -u "$mount_unit" --no-pager -n 30 >&2 || true
      exit 1
    fi
    install -d -m 0700 "$smb_mount/Camera-CA-Backups"
    stat -c '%a %U:%G %n' "$smb_mount" "$smb_mount/Camera-CA-Backups"
    echo "mount-smb-ok"
    ;;

  backup)
    require_arg --smb-mount "$smb_mount"
    if [[ -z "$label" ]]; then
      label="$(date -u +%Y%m%d%H%M%SZ)-initial"
    fi
    if ! findmnt -rn -t cifs -o TARGET | grep -Fx "$smb_mount" >/dev/null; then
      echo "$smb_mount is not a mounted CIFS share; refusing to back up into a local directory." >&2
      exit 1
    fi
    umask 077
    backup_dir="$smb_mount/Camera-CA-Backups"
    local_export="$HOME/ca-vault-gpg.key.gpg"
    backup_export="$backup_dir/ca-vault-gpg.key.gpg"
    test -s "$local_export"
    mkdir -p "$backup_dir"
    if [[ ! -e "$backup_export" ]]; then
      install -m 600 "$local_export" "$backup_export"
    else
      cmp -s "$local_export" "$backup_export" || { echo "$backup_export exists but differs from local export; stop." >&2; exit 1; }
    fi
    cmp -s "$local_export" "$backup_export"
    gpg --list-packets "$backup_export" | sed -n '/secret key packet/p;/secret sub key packet/p'
    backup_file="$backup_dir/password-store-backup-$label.tar.gz"
    test ! -e "$backup_file"
    tar -C "$HOME" -czf "$backup_file" .password-store
    test -s "$backup_file"
    chmod 600 "$backup_file"
    tr -d '\n' < "$HOME/.password-store/.gpg-id" > "$backup_dir/pass-gpg-id.txt"
    printf '\n' >> "$backup_dir/pass-gpg-id.txt"
    tar -tzf "$backup_file" | sed -n '1,20p'
    stat -c '%a %U:%G %s %n' "$backup_export" "$backup_file" "$backup_dir/pass-gpg-id.txt"
    echo "backup-ok $backup_file"
    ;;

  import-key)
    require_arg --key-file "$key_file"
    chmod 600 "$key_file"
    gpg --import "$key_file"
    gpg --list-secret-keys
    ;;

  restore-store)
    require_arg --backup-file "$backup_file"
    test -s "$backup_file"
    mkdir -p "$HOME/.password-store"
    tar -xzf "$backup_file" -C "$HOME"
    pass show camera >/dev/null
    pass show smb >/dev/null
    echo "restore-store-ok"
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 64
    ;;
esac
