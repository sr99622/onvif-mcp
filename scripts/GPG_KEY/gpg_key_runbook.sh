#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  gpg_key_runbook.sh agent-prep
  gpg_key_runbook.sh generate-key
  gpg_key_runbook.sh status --backup-path PATH
  gpg_key_runbook.sh export-key --fingerprint FPR
  gpg_key_runbook.sh verify-export --fingerprint FPR
  gpg_key_runbook.sh init-store --fingerprint FPR
  gpg_key_runbook.sh insert-passwords
  gpg_key_runbook.sh verify-passwords
  gpg_key_runbook.sh backup --backup-path PATH [--label LABEL]
  gpg_key_runbook.sh import-key --key-file PATH
  gpg_key_runbook.sh restore-store --backup-file PATH

This script implements docs/GPG_KEY.md with site-specific values as arguments.
It never accepts passwords as arguments. GPG/pass prompts remain interactive.
The backup path is a pre-mounted location (SMB share, external drive, or any
directory on the system drive) that must already exist and be writable.
Whatever storage type is used, the location must enforce the SMB-mount
permission model: mode 0700 owned by the runbook user, no extra ACL entries.
USAGE
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage
  exit 64
fi
if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

fingerprint=""
backup_path=""
local_user="${USER}"
label=""
key_file=""
backup_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --fingerprint)
    fingerprint="${2:?missing --fingerprint value}"
    shift 2
    ;;
  --backup-path)
    backup_path="${2:?missing --backup-path value}"
    shift 2
    ;;
  --local-user)
    local_user="${2:?missing --local-user value}"
    shift 2
    ;;
  --label)
    label="${2:?missing --label value}"
    shift 2
    ;;
  --key-file)
    key_file="${2:?missing --key-file value}"
    shift 2
    ;;
  --backup-file)
    backup_file="${2:?missing --backup-file value}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 64
    ;;
  esac
done

require_arg() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "Missing required argument: $name" >&2
    exit 64
  fi
}

require_backup_location() {
  local target="${backup_path%/}"
  [[ -d "$target" ]] || { echo "$target does not exist; the backup location must already be mounted or created before running the runbook." >&2; exit 1; }
  [[ -w "$target" ]] || { echo "$target is not writable by $(id -un)" >&2; exit 1; }
  # Storage type is free (SMB share, mounted external drive, or local folder),
  # but the SMB-mount permission model is enforced on all of them: owner-only
  # 0700 directory, no ACL entries beyond the base owner-only set.
  local mode owner extra_acl
  mode="$(stat -c '%a' "$target")"
  owner="$(stat -c '%U:%G' "$target")"
  [[ "$mode" == "700" ]] || { echo "$target is mode $mode, not 0700; refusing to write backups into a group- or world-readable location." >&2; exit 1; }
  [[ "$owner" == "$(id -un):$(id -gn)" ]] || { echo "$target is owned by $owner, not $(id -un):$(id -gn); refusing." >&2; exit 1; }
  if command -v getfacl >/dev/null; then
    extra_acl="$(getfacl -p "$target" 2>/dev/null | grep -v '^#' | grep -v '^$' | grep -v -E '^(user::rw-?x?|group::---|other::---)$' || true)"
    [[ -z "$extra_acl" ]] || { echo "FAIL: unexpected ACL entry on the backup location:"; echo "$extra_acl" >&2; exit 1; }
  else
    echo "note: getfacl not installed; ACL check skipped (install acl for full enforcement)." >&2
  fi
}

case "$cmd" in
agent-prep)
  missing_packages=()
  command -v gpg >/dev/null 2>&1 || missing_packages+=(gnupg)
  command -v pass >/dev/null 2>&1 || missing_packages+=(pass)
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
    printf '%s\n' 'pinentry-program /usr/bin/pinentry-curses' >>"$conf"
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
  require_arg --backup-path "$backup_path"
  echo "user=$(id -un) uid=$(id -u) gid=$(id -g)"
  command -v gpg >/dev/null && gpg --version | sed -n '1p'
  command -v pass >/dev/null && pass --version || echo "pass missing"
  test -x /usr/bin/pinentry-curses && echo "pinentry-curses present" || echo "pinentry-curses missing"
  gpg --list-secret-keys --fingerprint || true
  if [[ -f "$HOME/.password-store/.gpg-id" ]]; then
    printf 'password-store-gpg-id='
    tr -d '\n' <"$HOME/.password-store/.gpg-id"
    printf '\n'
  else
    echo "password-store not initialized"
  fi
  if [[ -f "$HOME/ca-vault-gpg.key.gpg" ]]; then
    stat -c 'local-export=%s bytes mode=%a owner=%U:%G path=%n' "$HOME/ca-vault-gpg.key.gpg"
  else
    echo "local export missing"
  fi
  if [[ -d "$backup_path" ]]; then
    stat -c 'backup-path mode=%a owner=%U:%G path=%n' "$backup_path"
    findmnt -rn -T "$backup_path" -o TARGET,SOURCE,FSTYPE,OPTIONS || true
  else
    echo "backup path missing; the backup location must already be mounted/created before running the runbook"
  fi
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
  test "$(tr -d '\n' <"$HOME/.password-store/.gpg-id")" = "$fingerprint"
  chmod 700 "$HOME/.password-store"
  echo "init-store-ok"
  ;;

insert-passwords)
  pass insert camera
  echo "insert-passwords-ok"
  ;;

verify-passwords)
  pass show camera >/dev/null
  find "$HOME/.password-store" -maxdepth 2 -type f -name '*.gpg' -print
  echo "verify-passwords-ok"
  ;;

backup)
  require_arg --backup-path "$backup_path"
  require_backup_location
  if [[ -z "$label" ]]; then
    label="$(date -u +%Y%m%d%H%M%SZ)-initial"
  fi
  umask 077
  backup_dir="$backup_path/Camera-CA-Backups"
  local_export="$HOME/ca-vault-gpg.key.gpg"
  backup_export="$backup_dir/ca-vault-gpg.key.gpg"
  test -s "$local_export"
  install -d -m 0700 "$backup_dir"
  if [[ ! -e "$backup_export" ]]; then
    install -m 600 "$local_export" "$backup_export"
  else
    cmp -s "$local_export" "$backup_export" || {
      echo "$backup_export exists but differs from local export; stop." >&2
      exit 1
    }
  fi
  cmp -s "$local_export" "$backup_export"
  gpg --list-packets "$backup_export" | sed -n '/secret key packet/p;/secret sub key packet/p'
  backup_file="$backup_dir/password-store-backup-$label.tar.gz"
  test ! -e "$backup_file"
  tar -C "$HOME" -czf "$backup_file" .password-store
  test -s "$backup_file"
  chmod 600 "$backup_file"
  tr -d '\n' <"$HOME/.password-store/.gpg-id" >"$backup_dir/pass-gpg-id.txt"
  printf '\n' >>"$backup_dir/pass-gpg-id.txt"
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
  echo "restore-store-ok"
  ;;

*)
  echo "Unknown command: $cmd" >&2
  usage >&2
  exit 64
  ;;
esac
