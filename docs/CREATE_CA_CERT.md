# Private CA and HTTPS Runbook for Nginx and MediaMTX

## Purpose

This runbook documents the tested process used to:

- Create a private root Certificate Authority on a trusted Mac.
- Protect and back up the complete CA state.
- Generate the Nginx site key directly on the server.
- Issue a certificate for `{{SERVER_FQDN}}`.
- Configure Nginx HTTPS.
- Trust the private CA in macOS and Firefox.
- Proxy MediaMTX WebRTC signaling through Nginx HTTPS.
- Replace obsolete, insecure WebRTC player URLs.

The final browser-facing architecture is:

```text
Browser
   |
   | https://{{SERVER_FQDN}}
   v
Nginx at {{SERVER_IP}}:443
   |-- /cameras/   -> static camera application
   |-- /multiview/ -> static multiview application
   |-- /outputs/   -> generated application data
   `-- /webrtc/    -> MediaMTX at 127.0.0.1:8889
                            |
                            `-> encrypted WebRTC media
```

## Site-specific values

| Purpose | Value |
|---|---|
| Nginx/MediaMTX server | `{{SERVER_FQDN}}` |
| Server address | `{{SERVER_IP}}` |
| Canonical DNS name | `{{SERVER_FQDN}}` |
| Root CA name | `Camera System Root CA` |
| CA workstation | Mac at `10.1.1.1` |
| CA working directory | `/Users/stephen/Private-CA/camera-system-ca` |
| Local encrypted backups | `/Users/stephen/Private-CA/backups` |
| SMB encrypted backups | `/Volumes/Users/sr996/Camera-CA-Backups` |
| Nginx TLS directory | `/etc/nginx/tls` |
| Static application root | `/home/{{SERVER_USER}}/Projects/onvif-mcp/packages/stdio/apps` |
| MediaMTX WebRTC HTTP port | `8889` |

Replace every symbolic value before using this runbook:

| Symbol | Required value |
|---|---|
| `{{SERVER_FQDN}}` | Canonical DNS name used by clients and the TLS certificate |
| `{{SERVER_IP}}` | Server IP address on which Nginx accepts HTTPS connections |
| `{{SERVER_USER}}` | Login account used for SSH and server-side files under `/home` |

Use `{{SERVER_FQDN}}` consistently for the certificate common name, DNS subject alternative name, Nginx `server_name`, URLs, and certificate filenames. Generated documents must not contain any unresolved `{{...}}` symbols.

## Security model

- The CA private key remains on the trusted Mac and is never transferred to `{{SERVER_FQDN}}`.
- The CA private key is encrypted with AES-256 and protected by a strong passphrase.
- The Nginx site key is generated directly on `{{SERVER_FQDN}}` and never leaves it.
- The Nginx site key is not passphrase-protected so Nginx can start unattended; root-only filesystem permissions protect it.
- The root CA certificate and signed site certificate are public and may be distributed.
- The complete CA state is archived using authenticated `age` encryption.
- Archive credentials and the CA-key passphrase are stored separately from the files.
- The CA is backed up after every issuance or revocation operation.

## 1. Inspect the existing Nginx installation

Check the version:

```bash
nginx -v
```

The tested system used:

```text
nginx/1.28.3 (Ubuntu)
```

List enabled sites:

```bash
sudo ls -la /etc/nginx/sites-enabled
```

Inspect relevant site files before editing:

```bash
sudo nl -ba /etc/nginx/sites-available/camera-apps
sudo nl -ba /etc/nginx/sites-available/default
```

The initial configuration used plain HTTP on port `8181`; the Ubuntu default site occupied port `80`, and port `443` was unused.

## 2. Prepare the CA workstation

Verify OpenSSL:

```bash
openssl version -a
```

The tested Mac used Homebrew OpenSSL 3.6.3.

Confirm that FileVault protects the working disk:

```bash
fdesetup status
```

Expected:

```text
FileVault is On.
```

Create the protected CA directory structure:

```bash
install -d -m 700 "$HOME/Private-CA"
install -d -m 700 "$HOME/Private-CA/camera-system-ca"
install -d -m 700 "$HOME/Private-CA/camera-system-ca/private"
install -d -m 700 \
  "$HOME/Private-CA/camera-system-ca/certs" \
  "$HOME/Private-CA/camera-system-ca/csr" \
  "$HOME/Private-CA/camera-system-ca/crl" \
  "$HOME/Private-CA/camera-system-ca/issued" \
  "$HOME/Private-CA/camera-system-ca/newcerts"
```

Verify permissions:

```bash
ls -ld "$HOME/Private-CA/camera-system-ca" \
  "$HOME/Private-CA/camera-system-ca"/*
```

All directories were set to mode `700`.

## 3. Initialize CA state

Create the empty certificate database:

```bash
touch "$HOME/Private-CA/camera-system-ca/index.txt"
chmod 600 "$HOME/Private-CA/camera-system-ca/index.txt"
```

Initialize the certificate serial counter:

```bash
printf '1000\n' > "$HOME/Private-CA/camera-system-ca/serial"
chmod 600 "$HOME/Private-CA/camera-system-ca/serial"
```

Initialize the CRL counter:

```bash
printf '1000\n' > "$HOME/Private-CA/camera-system-ca/crlnumber"
chmod 600 "$HOME/Private-CA/camera-system-ca/crlnumber"
```

The counters use hexadecimal values. The first issued site certificate therefore received serial `0x1000`.

## 4. Create the OpenSSL CA configuration

Create `/Users/stephen/Private-CA/camera-system-ca/openssl.cnf` with mode `600`:

```ini
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = /Users/stephen/Private-CA/camera-system-ca
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

## 5. Generate the encrypted CA private key

Generate a 4096-bit RSA key encrypted with AES-256:

```bash
openssl genpkey \
  -algorithm RSA \
  -aes-256-cbc \
  -pkeyopt rsa_keygen_bits:4096 \
  -out "$HOME/Private-CA/camera-system-ca/private/camera-system-root-ca.key.pem"
```

OpenSSL prompts twice for the passphrase. Do not place it in a command, script, configuration file, repository, or backup directory.

Verify the header and mode:

```bash
ls -l "$HOME/Private-CA/camera-system-ca/private/camera-system-root-ca.key.pem"
sed -n '1p' "$HOME/Private-CA/camera-system-ca/private/camera-system-root-ca.key.pem"
```

Expected header:

```text
-----BEGIN ENCRYPTED PRIVATE KEY-----
```

Validate the key:

```bash
openssl pkey \
  -in "$HOME/Private-CA/camera-system-ca/private/camera-system-root-ca.key.pem" \
  -check -noout
```

Expected:

```text
Key is valid
```

## 6. Create the root CA certificate

Create a ten-year self-signed root:

```bash
openssl req \
  -config "$HOME/Private-CA/camera-system-ca/openssl.cnf" \
  -key "$HOME/Private-CA/camera-system-ca/private/camera-system-root-ca.key.pem" \
  -new \
  -x509 \
  -days 3650 \
  -sha256 \
  -extensions v3_ca \
  -subj "/CN=Camera System Root CA" \
  -out "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem"
```

Inspect it:

```bash
openssl x509 \
  -in "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  -noout -subject -issuer -dates -serial
```

Verify its self-signature:

```bash
openssl verify \
  -CAfile "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem"
```

Expected:

```text
camera-system-root-ca.crt.pem: OK
```

Inspect extensions:

```bash
openssl x509 \
  -in "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  -noout -text |
sed -n '/X509v3 extensions:/,/Signature Algorithm/p'
```

Required properties include:

- `CA:TRUE, pathlen:0`
- `Certificate Sign`
- `CRL Sign`
- Critical basic constraints and key usage

## 7. Create and verify an encrypted CA backup

Install `age` with Homebrew:

```bash
brew install age
age --version
```

The tested version was `v1.3.1`.

Create a protected staging directory:

```bash
install -d -m 700 "$HOME/Private-CA/backups"
```

Create an authenticated, passphrase-encrypted archive:

```bash
(
  set -o pipefail
  tar -C "$HOME/Private-CA" -czf - camera-system-ca |
    age -p -o "$HOME/Private-CA/backups/camera-system-ca-initial-2026-08-03.tar.gz.age"
)
```

Set mode `600`:

```bash
chmod 600 "$HOME/Private-CA/backups/camera-system-ca-initial-2026-08-03.tar.gz.age"
```

Verify decryption without extracting:

```bash
(
  set -o pipefail
  age -d "$HOME/Private-CA/backups/camera-system-ca-initial-2026-08-03.tar.gz.age" |
    tar -tzf -
)
```

This must list the encrypted CA key, public CA certificate, configuration, database, and counters.

## 8. Copy the encrypted backup to SMB

Finder-mounted SMB shares appear under `/Volumes`. The tested Windows share was writable under the SMB account's profile directory:

```text
/Volumes/Users/sr996
```

Create the backup directory:

```bash
mkdir "/Volumes/Users/sr996/Camera-CA-Backups"
```

Copy without overwriting:

```bash
cp -n \
  "$HOME/Private-CA/backups/camera-system-ca-initial-2026-08-03.tar.gz.age" \
  "/Volumes/Users/sr996/Camera-CA-Backups/"
```

Verify the copy bit-for-bit:

```bash
shasum -a 256 \
  "$HOME/Private-CA/backups/camera-system-ca-initial-2026-08-03.tar.gz.age" \
  "/Volumes/Users/sr996/Camera-CA-Backups/camera-system-ca-initial-2026-08-03.tar.gz.age"
```

The two hashes must match exactly.

SMB permissions produced an executable-bit artifact on the encrypted archive. This did not affect its encrypted contents.
