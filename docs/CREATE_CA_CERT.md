# Private CA Creation Runbook

## Purpose

This runbook documents the tested process used to:

- Create a private root Certificate Authority on a trusted Mac.
- Protect and back up the complete CA state to an SMB share.

## Values supplied by the Agent

| Name | Meaning |
|---|---|
| `{{CA_ROOT_PATH}}` | Private CA root directory (e.g. `/home/stephen/Private-CA`) |
| `{{SMB_PATH}}` | Mounted SMB share path (e.g. `/mnt/taurus`) |

## Platform notes

Tested on macOS and on Debian Linux. Differences handled in this runbook:

- Hash verification: use `sha256sum` on Linux; `shasum -a 256` on macOS.
- Install `age`: `sudo apt install age` (Debian/Ubuntu) or `brew install age` (macOS).

## Site-specific values

| Purpose | Value |
|---|---|
| Root CA name | `Camera System Root CA` |
| CA working directory | `{{CA_ROOT_PATH}}/camera-system-ca` |
| Local encrypted backups | `{{CA_ROOT_PATH}}/backups` |
| SMB encrypted backups | `{{SMB_PATH}}Camera-CA-Backups` |

## Security model

- The CA private key remains on the host.
- The CA private key is encrypted with AES-256 and protected by a strong passphrase.
- The root CA certificate and signed site certificate are public and may be distributed.
- The complete CA state is archived using authenticated `age` encryption.
- Archive credentials and the CA-key passphrase are stored separately from the files.
- The CA is backed up after every issuance or revocation operation.

## 1. Prepare the CA workstation

Verify OpenSSL:

```bash
openssl version -a
```

Create the protected CA directory structure:

```bash
install -d -m 700 "{{CA_ROOT_PATH}}"
install -d -m 700 "{{CA_ROOT_PATH}}/camera-system-ca"
install -d -m 700 "{{CA_ROOT_PATH}}/camera-system-ca/private"
install -d -m 700 \
  "{{CA_ROOT_PATH}}/camera-system-ca/certs" \
  "{{CA_ROOT_PATH}}/camera-system-ca/csr" \
  "{{CA_ROOT_PATH}}/camera-system-ca/crl" \
  "{{CA_ROOT_PATH}}/camera-system-ca/issued" \
  "{{CA_ROOT_PATH}}/camera-system-ca/newcerts"
```

Verify permissions:

```bash
ls -ld "{{CA_ROOT_PATH}}/camera-system-ca" \
  "{{CA_ROOT_PATH}}/camera-system-ca"/*
```

All directories were set to mode `700`.

## 2. Initialize CA state

Create the empty certificate database:

```bash
touch "{{CA_ROOT_PATH}}/camera-system-ca/index.txt"
chmod 600 "{{CA_ROOT_PATH}}/camera-system-ca/index.txt"
```

Initialize the certificate serial counter:

```bash
printf '1000\n' > "{{CA_ROOT_PATH}}/camera-system-ca/serial"
chmod 600 "{{CA_ROOT_PATH}}/camera-system-ca/serial"
```

Initialize the CRL counter:

```bash
printf '1000\n' > "{{CA_ROOT_PATH}}/camera-system-ca/crlnumber"
chmod 600 "{{CA_ROOT_PATH}}/camera-system-ca/crlnumber"
```

The counters use hexadecimal values. The first issued site certificate therefore received serial `0x1000`.

## 3. Create the OpenSSL CA configuration

Create `{{CA_ROOT_PATH}}/camera-system-ca/openssl.cnf` with mode `600`:

```ini
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = {{CA_ROOT_PATH}}/camera-system-ca
certs             = $dir/certs
crl_dir           = $dir/crl
new_certs_dir     = $dir/newcerts
database          = $dir/index.txt
serial            = $dir/serial
crlnumber         = $dir/crlnumber
certificate       = $dir/certs/camera-system-root-ca.crt.pem
private_key       = $dir/private/camera-system-root-ca.key.pem
crl               = $dir/crl/camera-system-root-ca.crl.pem

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
```

`copy_extensions = none` prevents a CSR from injecting unreviewed extensions. A separate reviewed extension file controls each issued certificate.

## 4. Generate the encrypted CA private key

Generate a 4096-bit RSA key encrypted with AES-256:

```bash
openssl genpkey \
  -algorithm RSA \
  -aes-256-cbc \
  -pkeyopt rsa_keygen_bits:4096 \
  -out "{{CA_ROOT_PATH}}/camera-system-ca/private/camera-system-root-ca.key.pem"
```

OpenSSL prompts twice for the passphrase. Do not place it in a command, script, configuration file, repository, or backup directory.

Verify the header and mode:

```bash
ls -l "{{CA_ROOT_PATH}}/camera-system-ca/private/camera-system-root-ca.key.pem"
sed -n '1p' "{{CA_ROOT_PATH}}/camera-system-ca/private/camera-system-root-ca.key.pem"
```

Expected header:

```text
-----BEGIN ENCRYPTED PRIVATE KEY-----
```

Validate the key:

```bash
openssl pkey \
  -in "{{CA_ROOT_PATH}}/camera-system-ca/private/camera-system-root-ca.key.pem" \
  -check -noout
```

Expected:

```text
Key is valid
```

## 5. Create the root CA certificate

Create a ten-year self-signed root:

```bash
openssl req \
  -config "{{CA_ROOT_PATH}}/camera-system-ca/openssl.cnf" \
  -key "{{CA_ROOT_PATH}}/camera-system-ca/private/camera-system-root-ca.key.pem" \
  -new \
  -x509 \
  -days 3650 \
  -sha256 \
  -extensions v3_ca \
  -subj "/CN=Camera System Root CA" \
  -out "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem"
```

Inspect it:

```bash
openssl x509 \
  -in "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  -noout -subject -issuer -dates -serial
```

Verify its self-signature:

```bash
openssl verify \
  -CAfile "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem"
```

Expected:

```text
camera-system-root-ca.crt.pem: OK
```

Inspect extensions:

```bash
openssl x509 \
  -in "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  -noout -text |
sed -n '/X509v3 extensions:/,/Signature Algorithm/p'
```

Required properties include:

- `CA:TRUE, pathlen:0`
- `Certificate Sign`
- `CRL Sign`
- Critical basic constraints and key usage

## 6. Create and verify an encrypted CA backup

Install `age` with apt:

```bash
sudo apt install age
age --version
```

The tested versions were macOS `v1.3.1` and Debian Linux `v1.2.1`. Note: in interactive use, `age -p` prompts twice ("Enter passphrase" + "Confirm passphrase") — this is expected behavior, not an error. `age -p` reads the passphrase from a terminal; it cannot read one from a non-tty stdin in a pipe context on some builds, so run it where a TTY prompt is available (e.g. a PTY session).

Create a protected staging directory:

```bash
install -d -m 700 "{{CA_ROOT_PATH}}/backups"
```

Create an authenticated, passphrase-encrypted archive (replace `{{DATE}}` with the current date, e.g. `2026-08-31`; do not reuse a hardcoded date):

```bash
(
  set -o pipefail
  tar -C "{{CA_ROOT_PATH}}" -czf - camera-system-ca |
    age -p -o "{{CA_ROOT_PATH}}/backups/camera-system-ca-initial-{{DATE}}.tar.gz.age"
)
```

Set mode `600`:

```bash
chmod 600 "{{CA_ROOT_PATH}}/backups/camera-system-ca-initial-{{DATE}}.tar.gz.age"
```

Verify decryption without extracting:

```bash
(
  set -o pipefail
  age -d "{{CA_ROOT_PATH}}/backups/camera-system-ca-initial-{{DATE}}.tar.gz.age" |
    tar -tzf -
)
```

This must list the encrypted CA key, public CA certificate, configuration, database, and counters.

## 7. Copy the encrypted backup to SMB

SMB shares appear under `{{SMB_PATH}}`. The tested share was writable under the SMB account's profile directory:

```text
{{SMB_PATH}}
```

Create the backup directory:

```bash
mkdir "{{SMB_PATH}}/Camera-CA-Backups"
```

Copy without overwriting (on GNU/Linux prefer `cp --update=none`; `-n` is non-portable there):

```bash
cp -n \
  "{{CA_ROOT_PATH}}/backups/camera-system-ca-initial-{{DATE}}.tar.gz.age" \
  "{{SMB_PATH}}/Camera-CA-Backups/"
```

Verify the copy bit-for-bit (`sha256sum` on Linux, `shasum -a 256` on macOS):

```bash
sha256sum \
  "{{CA_ROOT_PATH}}/backups/camera-system-ca-initial-{{DATE}}.tar.gz.age" \
  "{{SMB_PATH}}/Camera-CA-Backups/camera-system-ca-initial-{{DATE}}.tar.gz.age"
```

The two hashes must match exactly.
