#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  keycloak_backup_runbook.sh create-checkpoint --backup-path PATH [--trigger NAME] [--compatible-nginx-checkpoint PATH] [--host-unit-checkpoint PATH]
  keycloak_backup_runbook.sh status --backup-path PATH

Implements only the "Create a checkpoint" workflow from docs/KEYCLOAK_BACKUP.md.
USAGE
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 64; }
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
shift || true
backup_path=""; trigger="KEYCLOAK.md"; compatible_nginx_checkpoint="not recorded"; host_unit_checkpoint="not recorded"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --trigger) trigger="${2:?missing --trigger value}"; shift 2 ;;
    --compatible-nginx-checkpoint) compatible_nginx_checkpoint="${2:?missing --compatible-nginx-checkpoint value}"; shift 2 ;;
    --host-unit-checkpoint) host_unit_checkpoint="${2:?missing --host-unit-checkpoint value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() { local name="$1" value="$2"; [[ -n "$value" ]] || { echo "Missing required argument: $name" >&2; exit 64; }; }
backup_root() { printf '%s/keycloak' "${backup_path%/}"; }

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

preflight() {
  sudo docker compose --project-directory /opt/keycloak ps
  systemctl is-active docker >/dev/null
  sudo test -d /opt/keycloak
  sudo test -s /opt/keycloak/.env
  sudo test -s /opt/keycloak/compose.yaml
  sudo test "$(sudo stat -c '%a %U %G' /opt/keycloak/.env)" = '600 root root'
  sudo test "$(sudo stat -c '%a %U %G' /opt/keycloak/compose.yaml)" = '640 root root'
  while IFS= read -r -d '' f; do
    sudo test "$(sudo stat -c '%a %U %G' "$f")" = '600 root root'
  done < <(sudo find /opt/keycloak -maxdepth 1 -type f -name '*.pass' -print0)
  sudo test -x /usr/local/sbin/backup-keycloak-postgres.sh
  sudo systemd-analyze verify /etc/systemd/system/keycloak-postgres-backup.service >/dev/null
}

write_metadata() {
  local dest="$1" timestamp="$2" dump_name="$3"
  {
    echo "Trigger: $trigger"
    echo "Capture UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Checkpoint timestamp: $timestamp"
    echo "New dump basename: $dump_name"
    echo "Compatible nginx checkpoint: $compatible_nginx_checkpoint"
    echo "Host-unit checkpoint: $host_unit_checkpoint"
    echo "Captured by: $(id -un)@$(hostname)"
    echo
    echo "Configuration changes captured: current /opt/keycloak configuration, root-owned recovery secret files, and the PostgreSQL database dump created by this run. Secret values are intentionally archived but not printed."
    echo
    echo "== service result =="
    cat "$dest/service-result.txt"
    echo
    echo "== compose ps =="
    sudo docker compose --project-directory /opt/keycloak ps
    echo
    echo "== compose images =="
    sudo docker compose --project-directory /opt/keycloak images || true
    echo
    echo "== protected file modes =="
    sudo stat -c '%A %U %G %s %n' /opt/keycloak /opt/keycloak/.env /opt/keycloak/compose.yaml
    sudo find /opt/keycloak -maxdepth 1 -type f -name '*.pass' -printf '%M %u %g %s %p\n'
    echo
    echo "== archive verification =="
    echo "exactly_one_new_dump=yes"
    cat "$dest/new-dump-stat.txt"
    echo "keycloak.tar member root and token-cache checks passed"
    echo "keycloak-postgres.tar single dump member and mode checks passed"
    echo "archive path safety checks passed"
    echo "pg_restore --list passed"
    echo "checksum verified before publication"
  } > "$dest/metadata.txt"
  chmod 600 "$dest/metadata.txt"
}

create_checkpoint() {
  require_arg --backup-path "$backup_path"; require_backup_location; preflight
  local root timestamp staging final dump_name dump_path
  root="$(backup_root)"
  timestamp="$(date -u +%Y%m%d%H%M%SZ)"
  staging="$root/.$timestamp.staging.$$"
  final="$root/$timestamp"
  install -d -m 700 "$root"
  test ! -e "$final"
  test ! -e "$staging"
  install -d -m 700 "$staging"

  sudo find /var/backups/keycloak-postgres -maxdepth 1 -type f -name 'keycloak-*.dump' -printf '%f\n' | sort > "$staging/dumps.before" || true
  sudo systemctl start keycloak-postgres-backup.service
  sudo systemctl show keycloak-postgres-backup.service -p Result -p ExecMainStatus | tee "$staging/service-result.txt"
  grep -Fx 'Result=success' "$staging/service-result.txt"
  grep -Fx 'ExecMainStatus=0' "$staging/service-result.txt"
  sudo find /var/backups/keycloak-postgres -maxdepth 1 -type f -name 'keycloak-*.dump' -printf '%f\n' | sort > "$staging/dumps.after"
  comm -13 "$staging/dumps.before" "$staging/dumps.after" > "$staging/new-dump-name"
  test "$(wc -l < "$staging/new-dump-name")" -eq 1
  dump_name="$(cat "$staging/new-dump-name")"
  dump_path="/var/backups/keycloak-postgres/$dump_name"
  sudo stat -c '%A %U %G %s %n' "$dump_path" | tee "$staging/new-dump-stat.txt"
  sudo test -s "$dump_path"
  sudo test "$(sudo stat -c '%a %U %G' "$dump_path")" = '600 root root'

  sudo tar --owner=0 --group=0 --preserve-permissions --acls --xattrs -cf "$staging/keycloak.tar" -C /opt keycloak
  sudo tar -tf "$staging/keycloak.tar" > "$staging/keycloak.members"
  if grep -Ev '^(keycloak/?|keycloak/)' "$staging/keycloak.members"; then echo 'ERROR: keycloak.tar contains member outside keycloak/' >&2; exit 1; fi
  if grep -Ei '(mcp-tokens|kcadm\.config|\.kctok|\.kctmp|refresh_token|access_token|client-token|token-cache)' "$staging/keycloak.members"; then echo 'ERROR: token/cache artifact included in keycloak.tar' >&2; exit 1; fi

  install -d -m 700 "$staging/dumpstage/keycloak-postgres-backups"
  sudo install -o root -g root -m 600 "$dump_path" "$staging/dumpstage/keycloak-postgres-backups/$dump_name"
  sudo tar --owner=0 --group=0 --preserve-permissions --acls --xattrs -cf "$staging/keycloak-postgres.tar" -C "$staging/dumpstage" "keycloak-postgres-backups/$dump_name"
  sudo tar -tf "$staging/keycloak-postgres.tar" | tee "$staging/postgres.members"
  test "$(wc -l < "$staging/postgres.members")" -eq 1
  grep -Fx "keycloak-postgres-backups/$dump_name" "$staging/postgres.members"
  sudo tar -tvf "$staging/keycloak-postgres.tar" | tee "$staging/postgres.member-stat"
  grep -E '^-rw------- .* keycloak-postgres-backups/' "$staging/postgres.member-stat"

  python3 - "$staging" <<'PY'
import sys, tarfile
from pathlib import Path
staging = Path(sys.argv[1])
for name in ['keycloak.tar', 'keycloak-postgres.tar']:
    with tarfile.open(staging / name) as tf:
        for m in tf.getmembers():
            if m.name.startswith('/') or '..' in Path(m.name).parts:
                raise SystemExit(f'{name}: unsafe member path {m.name}')
print('archive path safety checks passed')
PY
  sudo install -d -m 700 "$staging/pgcheck"
  sudo tar -xf "$staging/keycloak-postgres.tar" -C "$staging/pgcheck"
  sudo sh -c "docker compose --project-directory /opt/keycloak exec -i postgres pg_restore --list < '$staging/pgcheck/keycloak-postgres-backups/$dump_name' >/dev/null"

  write_metadata "$staging" "$timestamp" "$dump_name"
  sudo rm -rf "$staging/dumpstage" "$staging/pgcheck"
  rm -f "$staging/dumps.before" "$staging/dumps.after" "$staging/new-dump-name" "$staging/new-dump-stat.txt" "$staging/service-result.txt" "$staging/keycloak.members" "$staging/postgres.members" "$staging/postgres.member-stat"
  (cd "$staging" && sha256sum keycloak.tar keycloak-postgres.tar metadata.txt > SHA256SUMS && sha256sum -c SHA256SUMS)
  chmod 600 "$staging/SHA256SUMS"
  mv -T "$staging" "$final"
  echo "create-checkpoint-ok $final"
}

status() {
  require_arg --backup-path "$backup_path"
  local root; root="$(backup_root)"
  echo "backup_root=$root"
  if [[ -d "$root" ]]; then
    find "$root" -maxdepth 2 -type f -printf '%m %u:%g %s %p\n' | sort
  else
    echo "missing"
  fi
}

case "$cmd" in
  create-checkpoint) create_checkpoint ;;
  status) status ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 64 ;;
esac
