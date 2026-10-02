#!/usr/bin/env bash
set -Eeuo pipefail

backup_dir="/var/backups/keycloak-postgres"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final_file="${backup_dir}/keycloak-${timestamp}.dump"
temp_file="$(mktemp "${backup_dir}/.keycloak-${timestamp}.XXXXXX.dump")"

cleanup() {
    rm -f -- "${temp_file}"
}
trap cleanup EXIT

docker compose --project-directory /opt/keycloak exec -i postgres \
    pg_dump \
    --username=keycloak \
    --dbname=keycloak \
    --format=custom \
    --compress=zstd:9 \
    --no-owner \
    --no-acl \
    > "${temp_file}"

chmod 600 "${temp_file}"
mv -- "${temp_file}" "${final_file}"
trap - EXIT

find "${backup_dir}" \
    -maxdepth 1 \
    -type f \
    -name 'keycloak-*.dump' \
    -mtime +14 \
    -delete

printf '%s\n' "${final_file}"
