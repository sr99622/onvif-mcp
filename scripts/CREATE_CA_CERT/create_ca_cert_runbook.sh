#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  create_ca_cert_runbook.sh agent-prep
  create_ca_cert_runbook.sh prime-gpg-cache
  create_ca_cert_runbook.sh apply --ca-root PATH --backup-path PATH [--timestamp TS]
  create_ca_cert_runbook.sh status --ca-root PATH --backup-path PATH [--timestamp TS]
  create_ca_cert_runbook.sh verify --ca-root PATH --backup-path PATH --timestamp TS

Implements docs/CREATE_CA_CERT.md. Site-specific paths are passed as arguments.
The script never prints CA or archive passphrases. If GPG requires interactive
unlocking, run prime-gpg-cache in a real terminal before apply.
USAGE
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then usage; exit 64; fi
if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then usage; exit 0; fi
shift || true

ca_root=""
backup_path=""
timestamp=""
root_cn="Camera System Root CA"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ca-root) ca_root="${2:?missing --ca-root value}"; shift 2 ;;
    --backup-path) backup_path="${2:?missing --backup-path value}"; shift 2 ;;
    --timestamp) timestamp="${2:?missing --timestamp value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require_arg() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then echo "Missing required argument: $name" >&2; exit 64; fi
}

require_paths() {
  require_arg --ca-root "$ca_root"
  require_arg --backup-path "$backup_path"
}

ca_dir() { printf '%s/camera-system-ca' "$ca_root"; }
local_backup_dir() { printf '%s/backups' "$ca_root"; }
smb_backup_dir() { printf '%s/Camera-CA-Backups' "$backup_path"; }

ensure_timestamp() {
  if [[ -z "$timestamp" ]]; then
    timestamp="$(date -u +%Y%m%d%H%M%SZ)"
  fi
  if [[ ! "$timestamp" =~ ^[0-9]{14}Z$ ]]; then
    echo "Timestamp must be UTC form YYYYMMDDhhmmssZ; got: $timestamp" >&2
    exit 64
  fi
}

require_cifs_backup() {
  local target="$backup_path"
  if ! findmnt -rn -t cifs -o TARGET | grep -Fx "$target" >/dev/null; then
    echo "$target is not a mounted CIFS filesystem; refusing to write CA backups into a local directory." >&2
    findmnt -rn -T "$target" -o TARGET,SOURCE,FSTYPE,OPTIONS >&2 || true
    exit 1
  fi
}

install_packages() {
  missing=()
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v pass >/dev/null 2>&1 || missing+=(pass)
  command -v gpg >/dev/null 2>&1 || missing+=(gnupg)
  command -v age >/dev/null 2>&1 || missing+=(age)
  command -v script >/dev/null 2>&1 || missing+=(util-linux)
  if [[ ${#missing[@]} -gt 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    else
      printf 'Missing required packages: %s\n' "${missing[*]}" >&2
      exit 1
    fi
  fi
}

configure_gpg_agent_cache() {
  install -d -m 0700 "$HOME/.gnupg"
  local conf="$HOME/.gnupg/gpg-agent.conf"
  touch "$conf"
  chmod 600 "$conf"
  python3 - "$conf" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines() if p.exists() else []
out = []
seen = set()
for line in lines:
    if line.startswith('cache-ttl'):
        continue
    key = line.split(maxsplit=1)[0] if line.strip() and not line.lstrip().startswith('#') else None
    if key in {'default-cache-ttl', 'max-cache-ttl'}:
        continue
    out.append(line)
out.append('default-cache-ttl 7200')
out.append('max-cache-ttl 7200')
p.write_text('\n'.join(out) + '\n')
PY
  gpgconf --reload gpg-agent || true
}

prime_gpg_cache() {
  if ! tty_path="$(tty)" || [[ "$tty_path" == "not a tty" ]]; then
    echo "prime-gpg-cache must be run in a real terminal or SSH session with a TTY." >&2
    exit 1
  fi
  export GPG_TTY="$tty_path"
  gpg-connect-agent updatestartuptty /bye >/dev/null || true
  pass show camera >/dev/null
  pass show smb >/dev/null
  printf 'prime-gpg-cache-ok\n'
}

verify_pass_store_prereqs() {
  test -s "$HOME/.password-store/.gpg-id"
  pass show camera >/dev/null
  pass show smb >/dev/null
  test -n "$(find "$HOME/.password-store" -maxdepth 2 -type f -name '*.gpg' -print -quit)"
  test -s "$(smb_backup_dir)/ca-vault-gpg.key.gpg"
  compgen -G "$(smb_backup_dir)/password-store-backup-*.tar.gz" >/dev/null
}

create_ca_layout() {
  install -d -m 700 "$ca_root"
  install -d -m 700 "$(ca_dir)"
  install -d -m 700 "$(ca_dir)/private"
  install -d -m 700 "$(ca_dir)/certs" "$(ca_dir)/csr" "$(ca_dir)/crl" "$(ca_dir)/issued" "$(ca_dir)/newcerts"
  install -d -m 700 "$(local_backup_dir)"
  find "$(ca_dir)" -type d -exec chmod 700 {} +
}

init_ca_database() {
  [[ -e "$(ca_dir)/index.txt" ]] || : > "$(ca_dir)/index.txt"
  chmod 600 "$(ca_dir)/index.txt"
  [[ -e "$(ca_dir)/serial" ]] || printf '1000\n' > "$(ca_dir)/serial"
  chmod 600 "$(ca_dir)/serial"
  [[ -e "$(ca_dir)/crlnumber" ]] || printf '1000\n' > "$(ca_dir)/crlnumber"
  chmod 600 "$(ca_dir)/crlnumber"
}

write_openssl_config() {
  umask 077
  cat > "$(ca_dir)/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = $(ca_dir)
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
certificate       = \$dir/certs/camera-system-root-ca.crt.pem
private_key       = \$dir/private/camera-system-root-ca.key.pem
crl               = \$dir/crl/camera-system-root-ca.crl.pem

default_md        = sha256
default_days      = 397
default_crl_days  = 30
policy            = policy_loose
unique_subject    = no
copy_extensions   = none
preserve          = no

name_opt          = ca_default
cert_opt          = ca_default

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 4096
default_md          = sha256
string_mask         = utf8only
distinguished_name = req_distinguished_name
x509_extensions     = v3_ca
prompt              = yes

[ req_distinguished_name ]
commonName = Common Name

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true, pathlen:0
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign

[ server_cert ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
EOF
  chmod 600 "$(ca_dir)/openssl.cnf"
}

insert_generated_passphrases() {
  local root_entry="camera-ca/root-key-passphrase"
  local age_entry="camera-ca/age-archive-$timestamp"
  if [[ -e "$HOME/.password-store/${root_entry}.gpg" && -e "$HOME/.password-store/${age_entry}.gpg" ]]; then
    pass show "$root_entry" >/dev/null
    pass show "$age_entry" >/dev/null
    return 0
  fi
  if [[ -e "$HOME/.password-store/${root_entry}.gpg" || -e "$HOME/.password-store/${age_entry}.gpg" ]]; then
    echo "Only one target pass entry exists; refusing ambiguous resume: $root_entry $age_entry" >&2
    exit 1
  fi
  umask 077
  local tmpdir root_tmp age_tmp
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/create-ca-cert.XXXXXX")"
  chmod 700 "$tmpdir"
  root_tmp="$tmpdir/root-key-passphrase"
  age_tmp="$tmpdir/age-archive-passphrase"
  cleanup() { shred -u "$root_tmp" "$age_tmp" 2>/dev/null || true; rmdir "$tmpdir" 2>/dev/null || true; }
  trap cleanup RETURN
  openssl rand -base64 24 | tr -d '=+/' | cut -c1-28 > "$root_tmp"
  openssl rand -base64 24 | tr -d '=+/' | cut -c1-28 > "$age_tmp"
  pass insert -m "$root_entry" < "$root_tmp"
  pass insert -m "$age_entry" < "$age_tmp"
  test -s "$HOME/.password-store/${root_entry}.gpg"
  test -s "$HOME/.password-store/${age_entry}.gpg"
}

backup_password_store() {
  local label="$1"
  local local_file="$(local_backup_dir)/password-store-backup-$label.tar.gz"
  local smb_file="$(smb_backup_dir)/password-store-backup-$label.tar.gz"
  mkdir -p "$(smb_backup_dir)"
  if [[ ! -e "$local_file" ]]; then
    tar -C "$HOME" -czf "$local_file" .password-store
    chmod 600 "$local_file"
  fi
  test -s "$local_file"
  if [[ ! -e "$smb_file" ]]; then
    cp --update=none "$local_file" "$(smb_backup_dir)/"
  fi
  cmp -s "$local_file" "$smb_file"
  tr -d '\n' < "$HOME/.password-store/.gpg-id" > "$(smb_backup_dir)/pass-gpg-id.txt"
  printf '\n' >> "$(smb_backup_dir)/pass-gpg-id.txt"
  tar -tzf "$smb_file" | grep -Fx '.password-store/.gpg-id' >/dev/null
  tar -tzf "$smb_file" | grep -Fx '.password-store/camera-ca/root-key-passphrase.gpg' >/dev/null
}

generate_ca_key() {
  local key="$(ca_dir)/private/camera-system-root-ca.key.pem"
  if [[ ! -e "$key" ]]; then
    bash -lc 'pass show camera-ca/root-key-passphrase; pass show camera-ca/root-key-passphrase' \
      | script -qec "stty -echo 2>/dev/null; openssl genpkey -algorithm RSA -aes-256-cbc -pkeyopt rsa_keygen_bits:4096 -out '$key'" /dev/null
    chmod 600 "$key"
  fi
  grep -Fx -- '-----BEGIN ENCRYPTED PRIVATE KEY-----' <(sed -n '1p' "$key") >/dev/null
}

verify_ca_key() {
  pass show camera-ca/root-key-passphrase | openssl pkey -in "$(ca_dir)/private/camera-system-root-ca.key.pem" -check -noout
}

create_root_certificate() {
  local crt="$(ca_dir)/certs/camera-system-root-ca.crt.pem"
  if [[ ! -e "$crt" ]]; then
    pass show camera-ca/root-key-passphrase | \
      openssl req -config "$(ca_dir)/openssl.cnf" \
        -key "$(ca_dir)/private/camera-system-root-ca.key.pem" \
        -new -x509 -days 3650 -sha256 -extensions v3_ca \
        -subj "/CN=$root_cn" \
        -out "$crt"
    chmod 644 "$crt"
  fi
}

verify_root_certificate() {
  local crt="$(ca_dir)/certs/camera-system-root-ca.crt.pem"
  openssl x509 -in "$crt" -noout -subject -issuer -dates -serial
  openssl verify -CAfile "$crt" "$crt"
  openssl x509 -in "$crt" -noout -text | grep -A8 'X509v3 extensions:' | grep -E 'CA:TRUE, pathlen:0|Certificate Sign|CRL Sign' >/dev/null
}

create_age_archive() {
  local archive="$(local_backup_dir)/camera-system-ca-initial-$timestamp.tar.gz.age"
  [[ -e "$archive" ]] && return 0
  find "$(ca_dir)" -type d -exec chmod 700 {} +
  find "$(ca_dir)" -type d -exec stat -c '%a %n' {} \; | awk '$1 != "700" { bad=1; print } END { exit bad }'
  bash -lc "pass show camera-ca/age-archive-$timestamp; pass show camera-ca/age-archive-$timestamp" \
    | script -qec "stty -echo 2>/dev/null; set -o pipefail; tar -C '$ca_root' -czf - camera-system-ca | age -p -o '$archive'" /dev/null
  chmod 600 "$archive"
}

verify_age_archive() {
  local archive="$(local_backup_dir)/camera-system-ca-initial-$timestamp.tar.gz.age"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/ca-decrypted.XXXXXX.tgz")"
  chmod 600 "$tmp"
  cleanup_archive_verify() { shred -u "$tmp" 2>/dev/null || true; }
  trap cleanup_archive_verify RETURN
  bash -lc "pass show camera-ca/age-archive-$timestamp" \
    | script -qec "stty -echo 2>/dev/null; age -d '$archive' > '$tmp'" /dev/null
  tar -tzf "$tmp" | grep -Fx 'camera-system-ca/private/camera-system-root-ca.key.pem' >/dev/null
  tar -tzf "$tmp" | grep -Fx 'camera-system-ca/certs/camera-system-root-ca.crt.pem' >/dev/null
  tar -tzf "$tmp" | grep -Fx 'camera-system-ca/openssl.cnf' >/dev/null
  tar -tzf "$tmp" | grep -Fx 'camera-system-ca/index.txt' >/dev/null
  tar -tzf "$tmp" | grep -Fx 'camera-system-ca/serial' >/dev/null
  tar -tzf "$tmp" | grep -Fx 'camera-system-ca/crlnumber' >/dev/null
}

copy_age_archive_to_smb() {
  local local_archive="$(local_backup_dir)/camera-system-ca-initial-$timestamp.tar.gz.age"
  local smb_archive="$(smb_backup_dir)/camera-system-ca-initial-$timestamp.tar.gz.age"
  if [[ ! -e "$smb_archive" ]]; then
    cp --update=none "$local_archive" "$(smb_backup_dir)/"
  fi
  cmp -s "$local_archive" "$smb_archive"
  sha256sum "$local_archive" "$smb_archive"
}

print_status() {
  require_paths
  echo "== Tools =="
  command -v openssl >/dev/null && openssl version | sed -n '1p' || echo "openssl missing"
  command -v age >/dev/null && age --version || echo "age missing"
  command -v pass >/dev/null && pass --version || echo "pass missing"
  echo "== Backup mount =="
  findmnt -rn -T "$backup_path" -o TARGET,SOURCE,FSTYPE,OPTIONS || true
  findmnt -rn -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS || true
  echo "== Password store =="
  test -s "$HOME/.password-store/.gpg-id" && stat -c '%a %U:%G %s %n' "$HOME/.password-store/.gpg-id" || echo "password-store .gpg-id missing"
  find "$HOME/.password-store" -maxdepth 3 -type f -name '*.gpg' -printf '%p\n' 2>/dev/null | sort || true
  echo "== CA files =="
  [[ -d "$(ca_dir)" ]] && find "$(ca_dir)" -maxdepth 3 -printf '%m %u:%g %p\n' | sort || echo "CA directory missing"
  echo "== Backup files =="
  [[ -d "$(smb_backup_dir)" ]] && find "$(smb_backup_dir)" -maxdepth 1 -type f -printf '%m %u:%g %s %p\n' | sort || echo "SMB backup directory missing"
}

case "$cmd" in
  agent-prep)
    install_packages
    configure_gpg_agent_cache
    echo "agent-prep-ok"
    ;;
  prime-gpg-cache)
    prime_gpg_cache
    ;;
  apply)
    require_paths
    ensure_timestamp
    install_packages
    require_cifs_backup
    mkdir -p "$(smb_backup_dir)"
    verify_pass_store_prereqs
    create_ca_layout
    init_ca_database
    write_openssl_config
    insert_generated_passphrases
    backup_password_store "$timestamp-ca-passphrases"
    generate_ca_key
    verify_ca_key
    create_root_certificate
    verify_root_certificate
    backup_password_store "$timestamp-pre-ca-archive"
    create_age_archive
    verify_age_archive
    copy_age_archive_to_smb
    test -s "$(smb_backup_dir)/ca-vault-gpg.key.gpg"
    echo "apply-ok timestamp=$timestamp"
    ;;
  verify)
    require_paths
    require_arg --timestamp "$timestamp"
    require_cifs_backup
    verify_pass_store_prereqs
    verify_ca_key
    verify_root_certificate
    verify_age_archive
    cmp -s "$(local_backup_dir)/camera-system-ca-initial-$timestamp.tar.gz.age" "$(smb_backup_dir)/camera-system-ca-initial-$timestamp.tar.gz.age"
    test -s "$(smb_backup_dir)/ca-vault-gpg.key.gpg"
    test -s "$(smb_backup_dir)/password-store-backup-$timestamp-ca-passphrases.tar.gz"
    test -s "$(smb_backup_dir)/password-store-backup-$timestamp-pre-ca-archive.tar.gz"
    echo "verify-ok timestamp=$timestamp"
    ;;
  status)
    print_status
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 64
    ;;
esac
