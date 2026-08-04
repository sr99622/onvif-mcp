# Camera CA Client Distribution Runbook

## Purpose

This runbook documents the tested procedure for distributing the public `Camera System Root CA` certificate from `trigkey` to client computers on the private LAN.

The distribution endpoint is intentionally HTTP because a new client cannot trust the camera server's HTTPS certificate until it first obtains and installs the private root CA.

Only the public CA certificate is distributed. No private key, CA database, server key, or encrypted CA archive is exposed.

## Final layout

```text
Authoritative CA workstation (Mac)
└── /Users/stephen/Private-CA/camera-system-ca/
    ├── private/                         Encrypted CA private key
    ├── certs/                           Authoritative public CA certificate
    ├── issued/                          Issued certificates
    ├── index.txt                        CA database
    └── serial                           Issuance state

trigkey operational TLS files
└── /etc/nginx/tls/
    ├── camera.home.arpa.key.pem         Nginx private key
    ├── camera.home.arpa.crt.pem         Nginx site certificate
    └── camera-system-root-ca.crt.pem    Public CA verification copy

trigkey client distribution files
└── /srv/camera-pki/public/
    ├── camera-system-root-ca.crt.pem
    ├── camera-system-root-ca.crt.pem.sha256
    └── README.txt
```

The copy under `/srv/camera-pki/public` is the deliberately managed client-distribution copy. The authoritative CA state remains on the Mac and in its encrypted backups.

## Site-specific values

| Purpose | Value |
|---|---|
| Distribution server | `trigkey` |
| Distribution server address | `10.1.1.3` |
| DNS name | `camera.home.arpa` |
| Wired client network | `10.1.1.0/24` |
| Wireless client network | `192.168.68.0/22` |
| Distribution directory | `/srv/camera-pki/public` |
| Certificate URL | `http://camera.home.arpa/ca/camera-system-root-ca.crt.pem` |
| Checksum URL | `http://camera.home.arpa/ca/camera-system-root-ca.crt.pem.sha256` |
| Instructions URL | `http://camera.home.arpa/ca/README.txt` |

Replace these values deliberately when adapting the procedure to another network.

## 1. Create the distribution directory

Check that the target does not already exist:

```bash
sudo ls -ld /srv/camera-pki/public 2>&1
```

Create it as a root-owned, publicly readable directory:

```bash
sudo install -d \
  -o root \
  -g root \
  -m 755 \
  /srv/camera-pki/public
```

Verify:

```bash
sudo ls -ld /srv/camera-pki/public
```

Expected mode and owner:

```text
drwxr-xr-x root root
```

## 2. Install the public CA certificate

Install the already verified public CA certificate from the Nginx TLS directory:

```bash
sudo install \
  -o root \
  -g root \
  -m 644 \
  /etc/nginx/tls/camera-system-root-ca.crt.pem \
  /srv/camera-pki/public/camera-system-root-ca.crt.pem
```

Verify its subject, issuer, and certificate fingerprint:

```bash
openssl x509 \
  -in /srv/camera-pki/public/camera-system-root-ca.crt.pem \
  -noout \
  -subject \
  -issuer \
  -fingerprint \
  -sha256
```

Tested result:

```text
subject=CN=Camera System Root CA
issuer=CN=Camera System Root CA
sha256 Fingerprint=48:68:BF:06:D5:8F:DC:10:1F:07:D5:64:90:D4:1D:44:73:EC:17:46:09:69:42:F5:90:B8:BA:FC:BC:B4:3F:1D
```

## 3. Create and verify the PEM file checksum

Create a checksum for the exact bytes of the distributed PEM file:

```bash
cd /srv/camera-pki/public &&
sha256sum camera-system-root-ca.crt.pem |
sudo tee camera-system-root-ca.crt.pem.sha256
```

Tested file checksum:

```text
136f1293417e8a2b9399cfd07519e88d651adc0e8913266714c3d1dec80f25b0  camera-system-root-ca.crt.pem
```

Verify the checksum file:

```bash
cd /srv/camera-pki/public &&
sha256sum --check camera-system-root-ca.crt.pem.sha256
```

Expected:

```text
camera-system-root-ca.crt.pem: OK
```

## File checksum versus certificate fingerprint

These are different values:

- The **PEM file checksum** hashes the exact file bytes, including PEM encoding and line endings.
- The **certificate fingerprint** hashes the certificate's DER representation.

The PEM checksum confirms an exact file transfer. The certificate fingerprint identifies the certificate independently of its PEM encoding.

Since the certificate and `.sha256` file are delivered through the same HTTP endpoint, the checksum file detects accidental corruption but does not independently authenticate the download. Clients should compare the certificate fingerprint with a separately trusted copy supplied by the administrator.

## 4. Create client instructions

Create `/srv/camera-pki/public/README.txt` containing:

```text
Camera System Root CA
=====================

Certificate download:
http://camera.home.arpa/ca/camera-system-root-ca.crt.pem

PEM checksum file:
http://camera.home.arpa/ca/camera-system-root-ca.crt.pem.sha256

PEM file SHA-256:
136f1293417e8a2b9399cfd07519e88d651adc0e8913266714c3d1dec80f25b0

Certificate SHA-256 fingerprint:
48:68:BF:06:D5:8F:DC:10:1F:07:D5:64:90:D4:1D:44:
73:EC:17:46:09:69:42:F5:90:B8:BA:FC:BC:B4:3F:1D

Verify the downloaded PEM file:

macOS:
  shasum -a 256 camera-system-root-ca.crt.pem

Linux:
  sha256sum camera-system-root-ca.crt.pem

Windows:
  certutil -hashfile camera-system-root-ca.crt.pem SHA256

Inspect the certificate fingerprint with OpenSSL:
  openssl x509 -in camera-system-root-ca.crt.pem \
    -noout -fingerprint -sha256

Install this certificate only as a trusted root for websites.
Never install or request a private-key file.

Important:
The certificate and checksum are delivered over the same HTTP connection.
Compare the certificate fingerprint with a separately trusted copy supplied
by the camera-system administrator before trusting the certificate.
```

Verify its mode and contents:

```bash
sudo ls -l /srv/camera-pki/public/README.txt
sudo sed -n '1,80p' /srv/camera-pki/public/README.txt
```

Expected owner and mode:

```text
root root 644
```

## 5. Configure the restricted Nginx HTTP endpoint

The existing `camera.home.arpa` HTTP server originally redirected every request to HTTPS:

```nginx
server {
    listen 80;
    server_name camera.home.arpa;

    return 301 https://camera.home.arpa$request_uri;
}
```

It was changed to allow `/ca/` over HTTP while redirecting all other paths:

```nginx
server {
    listen 80;
    server_name camera.home.arpa;

    location /ca/ {
        alias /srv/camera-pki/public/;
        autoindex off;

        allow 10.1.1.0/24;
        allow 192.168.68.0/22;
        deny all;
    }

    location / {
        return 301 https://camera.home.arpa$request_uri;
    }
}
```

Important properties:

- Directory browsing is disabled.
- Only the wired and wireless client networks are allowed.
- The isolated `10.2.2.0/24` camera network is not allowed.
- All non-CA HTTP requests continue to redirect to HTTPS.

Validate before reloading:

```bash
sudo nginx -t
```

Then reload:

```bash
sudo systemctl reload nginx.service
```

## 6. Test locally on trigkey

Test the certificate endpoint:

```bash
curl \
  --resolve camera.home.arpa:80:10.1.1.3 \
  --head \
  http://camera.home.arpa/ca/camera-system-root-ca.crt.pem
```

Expected:

```text
HTTP/1.1 200 OK
Content-Type: application/x-x509-ca-cert
```

Test the checksum endpoint:

```bash
curl \
  --resolve camera.home.arpa:80:10.1.1.3 \
  --silent \
  --show-error \
  http://camera.home.arpa/ca/camera-system-root-ca.crt.pem.sha256
```

Test the instructions endpoint:

```bash
curl \
  --resolve camera.home.arpa:80:10.1.1.3 \
  --silent \
  --show-error \
  http://camera.home.arpa/ca/README.txt
```

## 7. Test from a client computer

Open:

```text
http://camera.home.arpa/ca/README.txt
```

Confirm that it displays without redirecting to HTTPS.

Then open:

```text
http://camera.home.arpa/ca/camera-system-root-ca.crt.pem
```

The tested Windows client downloaded the certificate successfully.

Before installing it, verify the PEM file checksum on Windows:

```cmd
certutil -hashfile camera-system-root-ca.crt.pem SHA256
```

Expected file checksum:

```text
136f1293417e8a2b9399cfd07519e88d651adc0e8913266714c3d1dec80f25b0
```

The certificate must be installed only into the trusted-root store used by the intended browser or operating system.

Firefox may maintain its own authority store. If it does not use the operating-system trust store, import the public CA through:

```text
Settings -> Privacy & Security -> Certificates -> View Certificates -> Authorities
```

Enable only:

```text
Trust this CA to identify websites
```

Never bypass certificate warnings with **Accept the Risk and Continue**.

## 8. Remove incidental transfer files

The original certificate workflow temporarily staged these public files in `/home/stephen` on `trigkey`:

```text
/home/stephen/camera.home.arpa.csr.pem
/home/stephen/camera.home.arpa.crt.pem
/home/stephen/camera-system-root-ca.crt.pem
```

After verifying the installed Nginx copies, CA workspace, encrypted backups, and `/srv` distribution copy, move only those staging files to recoverable trash:

```bash
gio trash \
  /home/stephen/camera.home.arpa.csr.pem \
  /home/stephen/camera.home.arpa.crt.pem \
  /home/stephen/camera-system-root-ca.crt.pem
```

Verify that no matching files remain:

```bash
find /home/stephen -maxdepth 1 -type f \
  \( -name 'camera.home.arpa.csr.pem' \
     -o -name 'camera.home.arpa.crt.pem' \
     -o -name 'camera-system-root-ca.crt.pem' \) \
  -print
```

No output is expected.

## Operational maintenance

When the root CA certificate changes:

1. Verify the new public certificate against the authoritative Mac CA workspace.
2. Install the new public certificate under `/srv/camera-pki/public`.
3. Recalculate the PEM file checksum.
4. Update `README.txt` with both the new file checksum and certificate fingerprint.
5. Run `nginx -t` if the URL or Nginx mapping changes.
6. Test all three HTTP endpoints locally.
7. Test download and verification from Windows, macOS, and Linux clients as applicable.

Do not place any of the following under `/srv/camera-pki/public`:

- CA private keys
- Nginx private keys
- CA database or serial files
- CSRs unless deliberately needed
- Encrypted or decrypted CA archives
- Passwords, passphrases, or recovery credentials
