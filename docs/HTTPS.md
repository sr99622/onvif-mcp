# Private CA and HTTPS Runbook for Nginx and MediaMTX

## Purpose

This runbook documents the tested process used to:

- Create a private root Certificate Authority on a trusted Mac.
- Protect and back up the complete CA state.
- Generate the Nginx site key directly on the server.
- Issue a certificate for `camera.home.arpa`.
- Configure Nginx HTTPS.
- Trust the private CA in macOS and Firefox.
- Proxy MediaMTX WebRTC signaling through Nginx HTTPS.
- Replace obsolete, insecure WebRTC player URLs.

The final browser-facing architecture is:

```text
Browser
   |
   | https://camera.home.arpa
   v
Nginx at 10.1.1.3:443
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
| Nginx/MediaMTX server | `trigkey` |
| Server address | `10.1.1.3` |
| Canonical DNS name | `camera.home.arpa` |
| Root CA name | `Camera System Root CA` |
| CA workstation | Mac at `10.1.1.1` |
| CA working directory | `/Users/stephen/Private-CA/camera-system-ca` |
| Local encrypted backups | `/Users/stephen/Private-CA/backups` |
| SMB encrypted backups | `/Volumes/Users/sr996/Camera-CA-Backups` |
| Nginx TLS directory | `/etc/nginx/tls` |
| Static application root | `/home/stephen/Projects/onvif-mcp/packages/stdio/apps` |
| MediaMTX WebRTC HTTP port | `8889` |

Replace these values when adapting this runbook to another installation.

## Security model

- The CA private key remains on the trusted Mac and is never transferred to `trigkey`.
- The CA private key is encrypted with AES-256 and protected by a strong passphrase.
- The Nginx site key is generated directly on `trigkey` and never leaves it.
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

## 9. Generate the Nginx site key on trigkey

Verify OpenSSL:

```bash
openssl version -a
```

Create the TLS directory:

```bash
sudo install -d -o root -g root -m 700 /etc/nginx/tls
```

Generate a 3072-bit RSA server key:

```bash
sudo openssl genpkey \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:3072 \
  -out /etc/nginx/tls/camera.home.arpa.key.pem
```

Verify mode, format, and integrity:

```bash
sudo ls -l /etc/nginx/tls/camera.home.arpa.key.pem
sudo sed -n '1p' /etc/nginx/tls/camera.home.arpa.key.pem
sudo openssl pkey \
  -in /etc/nginx/tls/camera.home.arpa.key.pem \
  -check -noout
```

Expected mode is `600`, owner `root`, with header:

```text
-----BEGIN PRIVATE KEY-----
```

## 10. Generate the CSR on trigkey

```bash
sudo openssl req \
  -new \
  -sha256 \
  -key /etc/nginx/tls/camera.home.arpa.key.pem \
  -out /etc/nginx/tls/camera.home.arpa.csr.pem \
  -subj "/CN=camera.home.arpa" \
  -addext "subjectAltName=DNS:camera.home.arpa" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"
```

Verify the signature and requested extensions:

```bash
sudo openssl req \
  -in /etc/nginx/tls/camera.home.arpa.csr.pem \
  -noout -verify -subject

sudo openssl req \
  -in /etc/nginx/tls/camera.home.arpa.csr.pem \
  -noout -text |
sed -n '/Requested Extensions:/,/Signature Algorithm/p'
```

Required SAN:

```text
DNS:camera.home.arpa
```

## 11. Transfer only the CSR to the CA workstation

Because `/etc/nginx/tls` is mode `700`, create a temporary user-owned transfer copy:

```bash
sudo install \
  -o stephen \
  -g stephen \
  -m 600 \
  /etc/nginx/tls/camera.home.arpa.csr.pem \
  /home/stephen/camera.home.arpa.csr.pem
```

On the Mac:

```bash
scp \
  stephen@10.1.1.3:/home/stephen/camera.home.arpa.csr.pem \
  "$HOME/Private-CA/camera-system-ca/csr/"
```

Verify the transferred CSR again:

```bash
openssl req \
  -in "$HOME/Private-CA/camera-system-ca/csr/camera.home.arpa.csr.pem" \
  -noout -verify -subject
```

## 12. Define reviewed site-certificate extensions

Create `camera.home.arpa.ext.cnf` in the CA's `csr` directory:

```ini
[ server_cert ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = DNS:camera.home.arpa
```

The SAN must contain every hostname clients will use. This deployment intentionally uses only the canonical DNS name, not an IP SAN.

## 13. Sign the Nginx certificate

```bash
openssl ca \
  -config "$HOME/Private-CA/camera-system-ca/openssl.cnf" \
  -extfile "$HOME/Private-CA/camera-system-ca/csr/camera.home.arpa.ext.cnf" \
  -extensions server_cert \
  -days 397 \
  -md sha256 \
  -notext \
  -in "$HOME/Private-CA/camera-system-ca/csr/camera.home.arpa.csr.pem" \
  -out "$HOME/Private-CA/camera-system-ca/issued/camera.home.arpa.crt.pem"
```

Review the displayed subject and extensions before answering `y` to both signing and database-commit prompts.

The tested certificate included:

- Serial `0x1000`
- `CN=camera.home.arpa`
- SAN `DNS:camera.home.arpa`
- `CA:FALSE`
- TLS Web Server Authentication
- 397-day validity

Verify chain, purpose, and hostname:

```bash
openssl verify \
  -CAfile "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  -purpose sslserver \
  -verify_hostname camera.home.arpa \
  "$HOME/Private-CA/camera-system-ca/issued/camera.home.arpa.crt.pem"
```

Expected result ends with `OK`.

## 14. Back up updated CA state after issuance

Issuance changes `index.txt`, `serial`, and related prior-state files. Create a new archive immediately:

```bash
(
  set -o pipefail
  tar -C "$HOME/Private-CA" -czf - camera-system-ca |
    age -p -o "$HOME/Private-CA/backups/camera-system-ca-after-camera-cert-2026-08-03.tar.gz.age"
)
```

Set mode `600`, decrypt/list it, copy it to SMB, and compare SHA-256 hashes exactly as described for the initial archive.

The verified archive contained:

- Encrypted CA private key
- Root CA certificate
- Issued site certificate
- CSR and reviewed extension file
- `index.txt` and `index.txt.old`
- `serial` and `serial.old`
- `newcerts/1000.pem`

## 15. Transfer public certificates to trigkey

From the Mac:

```bash
scp \
  "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  "$HOME/Private-CA/camera-system-ca/issued/camera.home.arpa.crt.pem" \
  stephen@10.1.1.3:/home/stephen/
```

Verify on `trigkey`:

```bash
openssl verify \
  -CAfile /home/stephen/camera-system-root-ca.crt.pem \
  -purpose sslserver \
  -verify_hostname camera.home.arpa \
  /home/stephen/camera.home.arpa.crt.pem
```

Confirm the certificate matches the server key:

```bash
sudo sh -c '
openssl pkey -in /etc/nginx/tls/camera.home.arpa.key.pem -pubout |
  openssl sha256
openssl x509 -in /home/stephen/camera.home.arpa.crt.pem -pubkey -noout |
  openssl sha256
'
```

The hashes must be identical.

Install the certificates:

```bash
sudo install -o root -g root -m 644 \
  /home/stephen/camera.home.arpa.crt.pem \
  /etc/nginx/tls/camera.home.arpa.crt.pem

sudo install -o root -g root -m 644 \
  /home/stephen/camera-system-root-ca.crt.pem \
  /etc/nginx/tls/camera-system-root-ca.crt.pem
```

The final TLS directory should have:

- Site key: root-owned, mode `600`
- CSR: root-owned, mode `644`
- Site certificate: root-owned, mode `644`
- Public CA certificate: root-owned, mode `644`

## 16. Configure Nginx HTTPS

Back up the site configuration first:

```bash
sudo cp --update=none \
  /etc/nginx/sites-available/camera-apps \
  /etc/nginx/sites-available/camera-apps.backup-2026-08-03
```

The tested HTTPS server block was:

```nginx
server {
    listen 10.1.1.3:443 ssl;
    server_name camera.home.arpa;

    ssl_certificate     /etc/nginx/tls/camera.home.arpa.crt.pem;
    ssl_certificate_key /etc/nginx/tls/camera.home.arpa.key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:camera_tls:10m;
    ssl_session_timeout 1d;

    root /home/stephen/Projects/onvif-mcp/packages/stdio/apps;
    index index.html;

    location /cameras/ {
        try_files $uri $uri/ =404;
    }

    location /multiview/ {
        try_files $uri $uri/ =404;
    }

    location /outputs/ {
        try_files $uri $uri/ =404;
    }

    location /webrtc/ {
        proxy_pass http://127.0.0.1:8889/;
        proxy_redirect / /webrtc/;
    }
}
```

The explicit `10.1.1.3:443` listener avoids exposing HTTPS directly on the camera or Wi-Fi interfaces.

Add a hostname-specific port-80 redirect while retaining the Ubuntu default site:

```nginx
server {
    listen 80;
    server_name camera.home.arpa;

    return 301 https://camera.home.arpa$request_uri;
}
```

The old port-8181 service was temporarily retained during migration.

Validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx.service
systemctl --no-pager --full status nginx.service
```

Confirm the listener:

```bash
sudo ss -lntp 'sport = :443'
```

Expected listener:

```text
10.1.1.3:443
```

## 17. Validate HTTPS from trigkey

Because `trigkey` was not yet using its own dnsmasq service for host resolution, the initial test used an explicit mapping and CA file:

```bash
sudo curl \
  --resolve camera.home.arpa:443:10.1.1.3 \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  --head \
  https://camera.home.arpa/cameras/
```

Expected:

```text
HTTP/1.1 200 OK
```

## 18. Trust the CA in macOS

Check whether it is already installed:

```bash
security find-certificate \
  -c "Camera System Root CA" \
  /Library/Keychains/System.keychain
```

Install the public CA as a trusted root:

```bash
sudo security add-trusted-cert \
  -d \
  -r trustRoot \
  -k /Library/Keychains/System.keychain \
  "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem"
```

Verify identity and fingerprint:

```bash
security find-certificate \
  -c "Camera System Root CA" \
  -p /Library/Keychains/System.keychain |
openssl x509 -noout -subject -issuer -fingerprint -sha256
```

Test using normal DNS and macOS trust:

```bash
/usr/bin/curl --head https://camera.home.arpa/cameras/
```

Expected:

```text
HTTP/1.1 200 OK
```

## 19. Trust the CA in Firefox

Firefox did not automatically trust the CA installed in the macOS System keychain. Its warning correctly stated:

```text
Peer's Certificate issuer is not recognized.
```

Do not click **Accept the Risk and Continue** and do not create a site exception.

Instead:

1. Open Firefox **Settings**.
2. Select **Privacy & Security**.
3. Scroll to **Certificates**.
4. Click **View Certificates**.
5. Select **Authorities**.
6. Click **Import**.
7. Select `camera-system-root-ca.crt.pem`.
8. Enable only **Trust this CA to identify websites**.

The root then appeared as:

```text
Camera System Root CA — Software Security Device
```

After import, `https://camera.home.arpa/cameras/` loaded without a certificate warning.

## 20. Diagnose missing streams after enabling HTTPS

The page loaded securely, but streams were absent. Search the static application data:

```bash
sudo rg -n \
  'http://|ws://|whep|webrtc|mediamtx|8889' \
  /home/stephen/Projects/onvif-mcp/packages/stdio/apps
```

The registry still contained URLs such as:

```text
http://10.1.1.75:8889/stream-path
```

These had two problems:

- `10.1.1.75` was the obsolete DHCP address.
- An HTTPS page cannot embed active content from an insecure HTTP endpoint.

## 21. Verify MediaMTX behavior

Confirm its listener:

```bash
sudo ss -lntup 'sport = :8889'
```

MediaMTX listened on all addresses at `*:8889`.

A slashless player URL returned an absolute HTTP redirect:

```bash
curl --silent --output /dev/null \
  --write-out 'HTTP %{http_code}\nRedirect: %{redirect_url}\n' \
  http://127.0.0.1:8889/STREAM/PATH
```

A player URL ending in `/` returned `200 OK`. Its page used relative resources:

```text
./reader.js
whep
```

Therefore, the external proxied URLs were intentionally written with trailing slashes.

## 22. Proxy MediaMTX through Nginx

Add this inside the HTTPS server block:

```nginx
location /webrtc/ {
    proxy_pass http://127.0.0.1:8889/;
    proxy_redirect / /webrtc/;
}
```

The trailing slash on `proxy_pass` strips the external `/webrtc/` prefix before forwarding to MediaMTX. `proxy_redirect` adds it back to redirects.

Validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx.service
```

Test a player page through HTTPS:

```bash
sudo curl \
  --silent \
  --show-error \
  --output /dev/null \
  --write-out 'HTTP %{http_code}\nContent-Type: %{content_type}\n' \
  --resolve camera.home.arpa:443:10.1.1.3 \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  https://camera.home.arpa/webrtc/STREAM/PATH/
```

Expected:

```text
HTTP 200
Content-Type: text/html
```

## 23. Update the camera registry

Back it up:

```bash
sudo cp --update=none \
  /home/stephen/Projects/onvif-mcp/packages/stdio/apps/outputs/camera_registry.json \
  /home/stephen/Projects/onvif-mcp/packages/stdio/apps/outputs/camera_registry.json.backup-2026-08-03
```

Transform the obsolete player URLs:

```bash
sudo perl -pi -e \
  's#http://10\.1\.1\.75:8889/([^\"]+)#https://camera.home.arpa/webrtc/$1/#g' \
  /home/stephen/Projects/onvif-mcp/packages/stdio/apps/outputs/camera_registry.json
```

Validate JSON and inspect all transformed URLs:

```bash
python3 -m json.tool \
  /home/stephen/Projects/onvif-mcp/packages/stdio/apps/outputs/camera_registry.json \
  >/dev/null

rg -n 'player_url' \
  /home/stephen/Projects/onvif-mcp/packages/stdio/apps/outputs/camera_registry.json
```

Final URL pattern:

```text
https://camera.home.arpa/webrtc/STREAM/PATH/
```

After a Firefox hard refresh with Command-Shift-R, all camera streams appeared.

## Temporary files to clean up after final verification

The tested workflow created public transfer copies in `/home/stephen` on `trigkey`:

```text
/home/stephen/camera.home.arpa.csr.pem
/home/stephen/camera.home.arpa.crt.pem
/home/stephen/camera-system-root-ca.crt.pem
```

These contain no private CA key, but should be removed after confirming their installed copies and backups. Use a recoverable deletion method where available.

The authoritative installed files remain under:

```text
/etc/nginx/tls
```

## Renewal procedure

Before the 397-day site certificate expires:

1. Confirm the existing Nginx key remains secure and valid.
2. Generate a new CSR from it, or generate a new site key if rotating keys.
3. Transfer only the CSR to the CA workstation.
4. Review the SAN and extension file.
5. Sign through `openssl ca`.
6. Verify chain, purpose, hostname, and key match.
7. Create and verify a new encrypted CA archive.
8. Copy the archive to SMB and compare hashes.
9. Transfer and install the new public site certificate.
10. Run `nginx -t` and reload Nginx.
11. Verify the live certificate and streams.

## Useful operational commands

```bash
# Nginx
sudo nginx -t
systemctl --no-pager --full status nginx.service
sudo ss -lntp 'sport = :443'

# Certificate inspection
openssl x509 -in certificate.pem -noout -subject -issuer -dates -serial
openssl x509 -in certificate.pem -noout -text

# CA verification
openssl verify \
  -CAfile camera-system-root-ca.crt.pem \
  -purpose sslserver \
  -verify_hostname camera.home.arpa \
  camera.home.arpa.crt.pem

# HTTPS test
/usr/bin/curl --head https://camera.home.arpa/cameras/

# MediaMTX signaling listener
sudo ss -lntup 'sport = :8889'
```

## Install Certificate on Windows

The name of the server can be added to the Windows hosts file. This is the easiest
way to resolve the server host name without altering existing DNS configuration.
The Administrative prompt must be used for the following steps

```
notepad C:\Windows\System32\drivers\etc\hosts
```

Add the ip address and name of the server e.g.

```
10.1.1.3 camera.home.arpa
```

Download the public key certificate from the server using ssh

```
scp stephen@camera.home.arpa:/~/camera-system-root-ca.crt.pem "$env:USERPROFILE\Downloads\camera-system-root-ca.crt.pem"
```

Import the certificate 

```
certutil -addstore Root "$env:USERPROFILE\Downloads\camera-system-root-ca.crt.pem"
```

The browser should be able to load the camera livestreams at

```
https://camera.home.arpa/cameras
```

## Remaining hardening work

HTTPS is functional, but these tasks remain:

- Remove temporary transfer files.
- Restrict direct access to MediaMTX port `8889`.
- Add firewall rules for DNS, HTTPS, SSH, MediaMTX, and the isolated camera network.
- Decide whether to retire or redirect the old port-8181 HTTP service.
- Add authenticated access to the camera application and MediaMTX signaling paths.
- Create a second offline encrypted CA backup.
- Perform a full restore drill into a temporary directory.

When changing security-sensitive infrastructure, inspect the current state, make one change, verify it, and only then proceed.
