#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ssh_login_runbook.sh apply  --server-fqdn HOST --username USER [--alias NAME]
  ssh_login_runbook.sh revoke --server-fqdn HOST --username USER [--alias NAME]
  ssh_login_runbook.sh status --server-fqdn HOST --username USER [--alias NAME]
  ssh_login_runbook.sh verify --server-fqdn HOST --username USER [--alias NAME]

Implements docs/SSH_LOGIN.md. Manages key-based automated SSH login for one
server in ~/.ssh/config plus the user's authorized_keys on that server.

apply  : creates the key (if missing), the config entry, and installs the
         public key on the server. Refuses if a configuration for this server
         already exists. Prompts for the server password exactly once.
revoke : removes only this server's config entry and only this runbook's key
         from the server's authorized_keys. Other entries are left intact.
verify : checks the entry, the key, and a BatchMode login.
status : prints the current entry and key state without changing anything.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true

server_fqdn=""; username=""; alias_name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-fqdn) server_fqdn="${2:?missing --server-fqdn value}"; shift 2 ;;
    --username) username="${2:?missing --username value}"; shift 2 ;;
    --alias) alias_name="${2:?missing --alias value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
require_all() {
  require_arg --server-fqdn "$server_fqdn"
  require_arg --username "$username"
  [[ "$server_fqdn" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid --server-fqdn: $server_fqdn" >&2; exit 64; }
  [[ "$username" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo "Invalid --username: $username" >&2; exit 64; }
  [[ -n "$alias_name" ]] || alias_name="${server_fqdn%%.*}"
  [[ "$alias_name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid --alias: $alias_name" >&2; exit 64; }
}

ssh_dir="$HOME/.ssh"
config="$ssh_dir/config"
key="$ssh_dir/id_ed25519"
pubkey="$key.pub"

config_block_present() {
  [[ -f "$config" ]] || return 1
  awk -v alias="$alias_name" -v fqdn="$server_fqdn" '
    tolower($1) == "host" {
      for (i = 2; i <= NF; i++)
        if ($i == alias || $i == fqdn) { found = 1; exit }
    }
    END { exit !found }
  ' "$config"
}

create_key_if_missing() {
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  if [[ -f "$key" ]]; then
    [[ -f "$pubkey" ]] || { echo "Private key exists but public key $pubkey is missing." >&2; exit 1; }
  else
    ssh-keygen -t ed25519 -f "$key" -N "" -C "$(whoami)@$(hostname)"
  fi
  chmod 600 "$key" "$pubkey"
}

append_config_entry() {
  cat >> "$config" <<EOF
Host $alias_name
    HostName $server_fqdn
    User $username
    IdentityFile $key
    BatchMode yes
EOF
  chmod 600 "$config"
}

remove_config_entry() {
  awk -v alias="$alias_name" -v fqdn="$server_fqdn" '
    tolower($1) == "host" {
      is_block = 0
      for (i = 2; i <= NF; i++)
        if ($i == alias || $i == fqdn) is_block = 1
    }
    !is_block { print }
  ' "$config" > "$config.new"
  mv "$config.new" "$config"
  chmod 600 "$config"
}

ensure_host_key() {
  # BatchMode refuses to accept an unknown host key, so every remote check
  # fails until the host key is in known_hosts. Fetch it once if missing.
  ssh-keygen -F "$server_fqdn" -f "$ssh_dir/known_hosts" >/dev/null 2>&1 && return 0
  mkdir -p "$ssh_dir"; chmod 700 "$ssh_dir"
  ssh-keyscan -T 10 "$server_fqdn" >> "$ssh_dir/known_hosts"
}

remote_authorized_keys_match_count() {
  ensure_host_key
  local count
  count="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$username@$server_fqdn" \
    "awk -v k=\"$(cat "$pubkey" | tr -d '\n')\" 'BEGIN{c=0} { line=\$0; gsub(/^[ \t]+|[ \t]+$/, \"\", line); if (line == k) c++ } END { print c }' \"\$HOME/.ssh/authorized_keys\" 2>/dev/null || echo 0")"
  [[ -n "$count" ]] || count=0
  printf '%s' "$count"
}

test_login() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$username@$server_fqdn" 'echo login-ok'
}

case "$cmd" in
  apply)
    require_all
    if config_block_present; then
      echo "Guard: a config entry for '$alias_name' ($server_fqdn) already exists in $config. Refusing to overwrite. Use status to inspect or revoke first." >&2
      exit 1
    fi
    create_key_if_missing
    if [[ "$(remote_authorized_keys_match_count)" != "0" ]]; then
      echo "Guard: the public key is already present in $username@$server_fqdn:~/.ssh/authorized_keys. Refusing to run over an existing configuration." >&2
      exit 1
    fi
    # Install the key on the server BEFORE writing the config entry, so a
    # failed apply (wrong password, refused connection) leaves no half-state.
    # Password prompt happens exactly once here; this step is USER-run in the user's own terminal.
    ssh-copy-id -i "$pubkey" "$username@$server_fqdn"
    append_config_entry
    test_login
    echo "apply-ok alias=$alias_name server=$server_fqdn user=$username"
    ;;
  revoke)
    require_all
    if ! config_block_present; then
      echo "Guard: no config entry for '$alias_name' ($server_fqdn) in $config. Nothing to revoke." >&2
      exit 1
    fi
    [[ -f "$pubkey" ]] || { echo "Public key $pubkey is missing; cannot identify this runbook's authorized_keys entry." >&2; exit 1; }
    matches="$(remote_authorized_keys_match_count)"
    if [[ "$matches" == "0" ]]; then
      echo "Note: this runbook's key is not present on the server (nothing to remove there); skipping the authorized_keys rewrite." >&2
    elif [[ "$matches" != "1" ]]; then
      echo "Guard: $matches duplicate copies of this runbook's key found on the server. Refusing to rewrite authorized_keys; remove duplicates manually." >&2
      exit 1
    else
      # Remove only this runbook's key line; every other line is preserved verbatim.
      # grep -v exits 1 when the result is empty (key was the only line), which
      # pipefail would treat as failure — tolerate it explicitly.
      grep -v -x -F "$(cat "$pubkey")" < <(ssh -o BatchMode=yes -o ConnectTimeout=10 "$username@$server_fqdn" "cat \"\$HOME/.ssh/authorized_keys\"") > "$pubkey.revoked.tmp" || [[ $? == 1 ]]
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$username@$server_fqdn" \
        "umask 077; mkdir -p \"\$HOME/.ssh\"; cat > \"\$HOME/.ssh/authorized_keys\"" < "$pubkey.revoked.tmp"
      rm -f "$pubkey.revoked.tmp"
    fi
    remove_config_entry
    ssh-keygen -F "$server_fqdn" -f "$ssh_dir/known_hosts" >/dev/null 2>&1 && ssh-keygen -R "$server_fqdn" -f "$ssh_dir/known_hosts"
    echo "revoke-ok alias=$alias_name server=$server_fqdn user=$username (other config and authorized_keys entries left intact)"
    ;;
  verify)
    require_all
    config_block_present || { echo "FAIL: no config entry for '$alias_name' in $config" >&2; exit 1; }
    [[ -f "$key" && -f "$pubkey" ]] || { echo "FAIL: key pair missing" >&2; exit 1; }
    [[ "$(stat -c '%a' "$config")" == "600" ]] || { echo "FAIL: $config permissions are not 600" >&2; exit 1; }
    [[ "$(remote_authorized_keys_match_count)" == "1" ]] || { echo "FAIL: key not installed exactly once on server" >&2; exit 1; }
    test_login
    echo "verify-ok"
    ;;
  status)
    require_all
    echo "== Config entry =="
    if config_block_present; then
      awk -v alias="$alias_name" -v fqdn="$server_fqdn" '
        tolower($1) == "host" {
          is_block = 0
          for (i = 2; i <= NF; i++)
            if ($i == alias || $i == fqdn) is_block = 1
        }
        is_block { print }
      ' "$config"
    else
      echo "none"
    fi
    echo "== Key =="
    if [[ -f "$key" ]]; then
      ssh-keygen -lf "$pubkey"
    else
      echo "no key pair"
    fi
    echo "== Server authorized_keys =="
    if [[ -f "$pubkey" ]]; then
      echo "this runbook's key matches: $(remote_authorized_keys_match_count)"
    else
      echo "no public key to check"
    fi
    ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
