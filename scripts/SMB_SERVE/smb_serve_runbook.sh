#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  smb_serve_runbook.sh apply  --server-fqdn HOST --username USER --mount PATH [--test-account NAME] [--allow-install]
  smb_serve_runbook.sh verify --server-fqdn HOST --username USER --mount PATH [--test-account NAME]
  smb_serve_runbook.sh status --server-fqdn HOST --username USER --mount PATH

Implements docs/SMB_SERVE.md. Creates a private Samba share on the SMB server
and mounts it on the camera host with enforced 0600/0700 server-side modes.

apply  : runs the server-side stage (private directory, Samba password, share
         block, reload) and the client-side stage (credentials file, fstab
         entry, automount), then the harmless-file probe test. Refuses to
         overwrite existing state; reruns re-verify instead of recreating.
verify : checks both sides against the acceptance criteria without changing
         anything, including the negative access test when --test-account is
         given.
status : prints current server and client state without changing anything.

The Samba password is prompted interactively without echo (`read -s`)
inside the script only; it is never printed, logged, or written to disk.
apply and verify must run in a terminal (TTY) so the prompt can read the
password; they fail cleanly if no TTY is available.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true

server_fqdn=""; username=""; mount=""; test_account=""; allow_install=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --username) username="${2:?missing --username value}"; shift 2 ;;
    --mount) mount="${2:?missing --mount value}"; shift 2 ;;
    --test-account) test_account="${2:?missing --test-account value}"; shift 2 ;;
    --allow-install) allow_install=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
require_all() {
  require_arg --server-fqdn "$server_fqdn"
  require_arg --username "$username"
  require_arg --mount "$mount"
  [[ "$server_fqdn" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid --server-fqdn: $server_fqdn" >&2; exit 64; }
  [[ "$username" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo "Invalid --username: $username" >&2; exit 64; }
  [[ "$mount" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "Invalid --mount: $mount" >&2; exit 64; }
  if [[ -n "$test_account" ]]; then
    [[ "$test_account" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo "Invalid --test-account: $test_account" >&2; exit 64; }
    [[ "$test_account" != "$username" ]] || { echo "Guard: --test-account must be an account unrelated to the share owner ($username)." >&2; exit 64; }
  fi
}

share_name="camera-ca-private"
server_dir="/srv/samba/$share_name"
creds_file="/etc/cifs-utils/credentials/camera-backup"
alias_name="${server_fqdn%%.*}"
mount_unit="${mount#/}"; mount_unit="${mount_unit//\//-}"; mount_unit="${mount_unit//-/\\x2d}"

rssh() {
  # Remote login shell is fish on some hosts; force POSIX sh for every remote
  # command. Escape only shell-active characters (printf '%q' also escapes = [ ]
  # -, which the remote sh treats literally).
  local q; q="${*//\\/\\\\}"; q="${q//\"/\\\"}"; q="${q//\$/\\$}"; q="${q//\`/\\\`}"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$username@$server_fqdn" "sh -c \"$q\""
}

get_password() {
  # Prompt interactively without echo. The prompt goes to stderr and the
  # password is read from the TTY, so the function works even when stdin is
  # redirected; only the password itself reaches stdout via printf.
  local pw
  read -r -s -p "Samba password for $username@$server_fqdn: " pw </dev/tty \
    || { echo "Guard: password prompt failed (no TTY available; run in your own terminal)." >&2; exit 1; }
  echo >&2
  [[ -n "$pw" ]] || { echo "Guard: no password entered." >&2; exit 1; }
  printf '%s' "$pw"
}

# ---------- server-side stage ----------

server_stage() {
  local pw="$1"
  rssh 'sudo -n true' || { echo "Guard: passwordless sudo is required on $server_fqdn for this runbook." >&2; exit 1; }

  if ! rssh 'command -v testparm >/dev/null'; then
    if [[ "$allow_install" == "1" ]]; then
      echo "Installing samba on $server_fqdn..."
      if rssh 'command -v apt-get >/dev/null'; then
        rssh 'sudo apt-get update >/dev/null && sudo apt-get install -y samba'
      elif rssh 'command -v pacman >/dev/null'; then
        # cachyos-samba-settings supplies the default smb.conf and enables the
        # smb/nmb services; plain samba on Arch ships neither.
        rssh 'sudo pacman -Sy --noconfirm --needed samba cachyos-samba-settings'
      else
        echo "Guard: no supported package manager (apt-get or pacman) found on $server_fqdn; install samba manually." >&2
        exit 1
      fi
    else
      echo "Guard: samba is not installed on $server_fqdn. Rerun apply with --allow-install to install it, or install it manually first." >&2
      exit 1
    fi
  fi

  rssh "getent passwd $username >/dev/null" || { echo "Guard: account $username does not exist on $server_fqdn." >&2; exit 1; }

  # Guard: never touch a share directory this runbook does not own. Content
  # created by this runbook itself (the Camera-CA-Backups subdirectory) is
  # tolerated on reruns; any other content means the directory predates it.
  if rssh "sudo test -e $server_dir"; then
    foreign="$(rssh "sudo find $server_dir -mindepth 1 -maxdepth 1 ! -name Camera-CA-Backups -print -quit" || true)"
    [[ -z "$foreign" ]] || { echo "Guard: $server_dir already exists and contains data not created by this runbook. Inspect with status; do not reuse a directory with existing content." >&2; exit 1; }
    rssh "sudo test \"\$(sudo stat -c '%a %U:%G' $server_dir)\" = '700 $username:$username'" \
      || { echo "Guard: $server_dir exists with unexpected ownership or mode. Refusing to change it." >&2; exit 1; }
  else
    rssh "sudo install -d -o $username -g $username -m 0700 $server_dir"
  fi

  # Samba password: create the entry only when none exists; never overwrite an
  # existing one. Password travels via stdin only, never on a command line.
  if rssh "sudo test -e \$(sudo testparm -TsG 2>/dev/null | sed -n 's/^tdbdump path = //p')/smbpasswd.tdb"; then
    echo "server: existing samba password entry for $username left untouched"
  else
    printf '%s\n%s\n' "$pw" "$pw" | rssh "sudo smbpasswd -s -a $username" >/dev/null
    echo "server: samba password for $username created on $server_fqdn"
  fi

  # Share block: append only if absent; never rewrite existing config.
  if rssh "sudo grep -q '^\[$share_name\]' /etc/samba/smb.conf" 2>/dev/null; then
    echo "server: share block [$share_name] already present, left verbatim"
  else
    rssh "sudo test -f /etc/samba/smb.conf && sudo cp -p /etc/samba/smb.conf /etc/samba/smb.conf.runbook.bak || true"
    rssh "sudo tee -a /etc/samba/smb.conf >/dev/null" <<EOF
[$share_name]
    path = $server_dir
    valid users = $username
    guest ok = no
    read only = no
    browseable = no
    create mask = 0600
    force create mode = 0600
    directory mask = 0700
    force directory mode = 0700
EOF
    echo "server: share block [$share_name] appended (backup at /etc/samba/smb.conf.runbook.bak)"
  fi

  # Effective configuration must match the required enforcement exactly.
  # testparm emits tab-indented entries; normalize whitespace before comparing.
  local effective expected
  effective="$(rssh "sudo testparm -s 2>/dev/null | awk -v s=\"[$share_name]\" 'index(\$0,s)==1{f=1;print;next} /^\[/{f=0} f' | sed 's/^[[:space:]]*//' | sort")"
  expected="$(printf '%s\n' "browseable = No" "create mask = 0600" "directory mask = 0700" "force create mode = 0600" "force directory mode = 0700" "path = $server_dir" "read only = No" "valid users = $username" "[$share_name]" | sort)"
  [[ "$effective" == "$expected" ]] || { echo "FAIL: effective testparm share config differs from the required enforcement:"; echo "$effective" >&2; exit 1; }

  # Daemon unit name varies by distribution (smbd.service on Debian/Ubuntu,
  # smb.service on Arch-family). Detect it; reload if live, start otherwise.
  # `if` form: `systemctl is-active` exits 3 for inactive units, which would
  # abort the subshell under set -e in an `&&` chain.
  local unit
  unit="$(rssh 'for u in smbd smb; do if systemctl is-active "$u" >/dev/null 2>&1; then echo "$u"; break; fi; done' | head -1)"
  if [[ -n "$unit" ]]; then
    rssh "sudo systemctl reload $unit"
  else
    rssh 'pgrep -x smbd >/dev/null || sudo systemctl start smb'
  fi
  rssh 'pgrep -x smbd >/dev/null' || { echo "FAIL: smbd is not running on $server_fqdn." >&2; exit 1; }

  # Effective check: the stored password must authenticate against the live
  # share. Use server-side smbclient when present (the Ubuntu `samba` package
  # does not ship it; `samba-client` does). Otherwise the client-stage mount
  # is the effective proof — mounting fails if the password is wrong.
  if rssh 'command -v smbclient >/dev/null'; then
    printf '%s\n' "$pw" | rssh "smbclient -L //localhost/$share_name -U $username >/dev/null" 2>&1 \
      || { echo "FAIL: the prompted password does not authenticate as $username on $server_fqdn. Resolve manually; the script will not overwrite the entry." >&2; exit 1; }
    echo "server: prompted password authenticates against the live share"
  else
    echo "server: smbclient not on $server_fqdn; password authentication will be proven by the client mount"
  fi
}

# ---------- client-side stage ----------

client_stage() {
  local pw="$1"
  command -v mount.cifs >/dev/null || { echo "Guard: cifs-utils (mount.cifs) is not installed on the camera host. Install it first (sudo apt install cifs-utils)." >&2; exit 1; }

  getent ahosts "$server_fqdn" >/dev/null || { echo "FAIL: $server_fqdn does not resolve on the camera host." >&2; exit 1; }

  # Credentials file: create only if absent; never erase an existing one.
  sudo install -d -m 0700 /etc/cifs-utils/credentials
  if sudo test -e "$creds_file"; then
    sudo test "$(sudo stat -c '%a %U:%G' "$creds_file")" = '600 root:root' \
      || { echo "Guard: $creds_file exists with unexpected ownership or mode. Inspect before proceeding." >&2; exit 1; }
    sudo test -s "$creds_file" || { echo "Guard: $creds_file exists but is empty. Fill it in your own editor; the script will not overwrite it." >&2; exit 1; }
    existing="$(sudo cat "$creds_file")"
    [[ "$existing" == "username=$username
password=$pw" ]] \
      || { echo "Guard: $creds_file content does not match the prompted password for $username. Inspect before proceeding." >&2; exit 1; }
    echo "client: credentials file verified, left verbatim"
  else
    sudo install -d -m 0700 /etc/cifs-utils/credentials
    # No `sudo umask 077` here: umask is a shell builtin, not an executable,
    # so sudo cannot run it. The explicit chmod below enforces the mode.
    printf 'username=%s\npassword=%s\n' "$username" "$pw" | sudo tee "$creds_file" >/dev/null
    sudo chmod 0600 "$creds_file"
    echo "client: credentials file created from the prompted password (mode 0600 root:root)"
  fi

  # Mount point.
  if [[ -d "$mount" ]]; then
    echo "client: mount point $mount already exists, left as-is"
  else
    sudo install -d -m 0700 "$mount"
    echo "client: mount point $mount created (mode 0700)"
  fi

  # fstab entry: add only if absent; never duplicate.
  local uid gid line
  uid="$(id -u $USER)"; gid="$(id -g $USER)"
  line="//$server_fqdn/$share_name $mount cifs credentials=$creds_file,vers=3.1.1,uid=$uid,gid=$gid,file_mode=0600,dir_mode=0700,nosuid,nodev,noexec,_netdev,noauto,x-systemd.automount 0 0"
  if grep -q "^[^ ]* $mount " /etc/fstab; then
    grep -Fxq "$line" /etc/fstab || { echo "Guard: an fstab entry for $mount exists but differs from the required line. Correct it manually; the script will not rewrite fstab." >&2; exit 1; }
    echo "client: fstab entry verified, left verbatim"
  else
    printf '%s\n' "$line" | sudo tee -a /etc/fstab >/dev/null
    echo "client: fstab entry added"
  fi

  sudo findmnt --verify --fstab >/dev/null || { echo "FAIL: fstab verification reported errors." >&2; exit 1; }

  # Automount activation. daemon-reload may fail in non-interactive sessions;
  # treat that as a warning when the mount is already live.
  sudo systemctl daemon-reload 2>/dev/null || echo "Note: daemon-reload failed (non-interactive auth); continuing." >&2
  sudo systemctl reset-failed "mnt-$mount_unit.mount" 2>/dev/null || true
  sudo systemctl start "mnt-$mount_unit.automount" 2>/dev/null || true
  # Reading contents triggers the CIFS mount; the automount upcall is async, so
  # retry the trigger and the check together before declaring failure.
  local ok=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ls -la "$mount/" >/dev/null 2>&1 || true
    findmnt -rn -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS | grep -q "^$mount " && { ok=1; break; }
    sleep 1
  done
  [[ "$ok" == "1" ]] || { echo "FAIL: no live cifs mount row for $mount (an autofs row alone is not success)." >&2; exit 1; }
  echo "client: cifs mount live for $mount"
}

# ---------- probe test ----------

probe_test() {
  umask 077
  local backup_dir="$mount/Camera-CA-Backups"
  if [[ -e "$backup_dir" ]]; then
    echo "probe: $backup_dir already exists, inspecting instead of creating"
  else
    mkdir -m 0700 "$backup_dir"
  fi
  # Global so the EXIT trap can still see it after this function returns.
  probe="$(mktemp "$backup_dir/.permission-probe.XXXXXX")" || { echo "FAIL: probe creation failed." >&2; exit 1; }
  trap 'rm -f -- "$probe"' EXIT
  chmod 600 "$probe"

  local base="${probe##*/}"
  local client_dir client_file server_dir_mode server_file_mode
  client_dir="$(stat -c '%a %U:%G' "$backup_dir")"
  client_file="$(stat -c '%a %U:%G' "$probe")"
  server_dir_mode="$(rssh "sudo stat -c '%a %U:%G' $server_dir/Camera-CA-Backups")"
  server_file_mode="$(rssh "sudo stat -c '%a %U:%G' $server_dir/Camera-CA-Backups/$base")"

  echo "probe: client dir   $client_dir"
  echo "probe: client file  $client_file"
  echo "probe: server dir   $server_dir_mode"
  echo "probe: server file  $server_file_mode"

  [[ "$client_dir" == "700 $USER:$USER" && "$client_file" == "600 $USER:$USER" ]] \
    || { echo "FAIL: client-side modes are not 0700/0600 as $USER." >&2; exit 1; }
  [[ "$server_dir_mode" == "700 $username:$username" && "$server_file_mode" == "600 $username:$username" ]] \
    || { echo "FAIL: server-side modes are broader than 0700/0600 — client display alone is not enforcement." >&2; exit 1; }

  # Base ACL entries (user::, group::---, other::---) are the plain-mode
  # representation; only named-user/named-group entries would grant extra access.
  extra_acl="$(rssh "sudo getfacl -p $server_dir $server_dir/Camera-CA-Backups $server_dir/Camera-CA-Backups/$base" \
    | grep -v '^#' | grep -v '^$' | grep -v -E '^(user::rw-?x?|group::---|other::---)$' || true)"
  [[ -z "$extra_acl" ]] || { echo "FAIL: unexpected ACL entry on the server share:"; echo "$extra_acl" >&2; exit 1; }
  echo "probe: server ACLs clean (owner-only)"
}

negative_test() {
  if [[ -z "$test_account" ]]; then
    echo "note: remote access test incomplete — no unrelated test account supplied (--test-account)." >&2
    return 0
  fi
  command -v smbclient >/dev/null || { echo "note: smbclient not installed on the camera host; remote access test incomplete." >&2; return 0; }
  rssh "getent passwd $test_account >/dev/null" || { echo "note: test account $test_account does not exist on $server_fqdn; remote access test incomplete." >&2; return 0; }
  # The test account's password is not known to the script, so denial can
  # only be proven via a null session here. A full negative test with the
  # account's real password is USER-run interactively (smbclient prompts).
  if smbclient "//$server_fqdn/$share_name" -U "$test_account" -N -c ls >/dev/null 2>&1; then
    echo "FAIL: unrelated account $test_account opened the share with a null session." >&2
    exit 1
  fi
  echo "negative test: $test_account denied (null session); run 'smbclient //$server_fqdn/$share_name -U $test_account -c ls' interactively for the full check"
}

case "$cmd" in
  apply)
    require_all
    pw="$(get_password)"
    server_stage "$pw"
    client_stage "$pw"
    probe_test
    negative_test
    echo "apply-ok server=$server_fqdn share=$share_name mount=$mount user=$username"
    ;;
  verify)
    require_all
    pw="$(get_password)"
    rssh "sudo test \"\$(sudo stat -c '%a %U:%G' $server_dir)\" = '700 $username:$username'" || { echo "FAIL: server share directory is not 0700 $username:$username" >&2; exit 1; }
    rssh "sudo grep -q '^\[$share_name\]' /etc/samba/smb.conf" || { echo "FAIL: share block missing on server" >&2; exit 1; }
    rssh "pgrep -x smbd >/dev/null" || { echo "FAIL: smbd not running on server" >&2; exit 1; }
    [[ "$(sudo stat -c '%a %U:%G' "$creds_file")" == "600 root:root" ]] || { echo "FAIL: credentials file permissions are not 0600 root:root" >&2; exit 1; }
    grep -q "^[^ ]* $mount " /etc/fstab || { echo "FAIL: no fstab entry for $mount" >&2; exit 1; }
    findmnt -rn -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS | grep -q "^$mount " || { echo "FAIL: $mount is not a live cifs mount (autofs row alone is not success)" >&2; exit 1; }
    findmnt -rn -t cifs -o OPTIONS "$mount" | grep -q 'file_mode=0600,dir_mode=0700' || { echo "FAIL: mount options lack file_mode=0600,dir_mode=0700" >&2; exit 1; }
    probe_test
    negative_test
    echo "verify-ok server=$server_fqdn share=$share_name mount=$mount user=$username"
    ;;
  status)
    require_all
    echo "== Server ($server_fqdn) =="
    rssh "sudo stat -c '%a %U:%G %n' $server_dir" 2>/dev/null || echo "share directory absent"
    rssh "sudo test -f /etc/samba/smb.conf && sudo grep -A9 '^\[$share_name\]' /etc/samba/smb.conf" 2>/dev/null || echo "share block absent"
    rssh 'pgrep -x smbd >/dev/null && echo "smbd running" || echo "smbd not running"' 2>/dev/null || true
    echo "== Client =="
    echo "credentials: $(sudo stat -c '%a %U:%G %n' "$creds_file" 2>/dev/null || echo 'absent')"
    grep "^[^ ]* $mount " /etc/fstab || echo "no fstab entry for $mount"
    findmnt -rn -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS "$mount" 2>/dev/null || echo "no live cifs mount for $mount"
    ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
