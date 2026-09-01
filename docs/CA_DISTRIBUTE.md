# Camera CA Client Distribution Runbook

## Purpose

This runbook documents the tested procedure for distributing the public `Camera System Root CA` certificate from `{{SERVER_FQDN}}` to client computers on the private LAN.

The distribution endpoint is intentionally HTTP because a new client cannot trust the camera server's HTTPS certificate until it first obtains and installs the private root CA.

Only the public CA certificate is distributed. No private key, CA database, server key, or encrypted CA archive is exposed.

## Final layout

```text
Authoritative CA workstation
└── {{CA_ROOT_PATH}}/camera-system-ca/
    ├── private/                         Encrypted CA private key
    ├── certs/                           Authoritative public CA certificate
    ├── issued/                          Issued certificates
    ├── index.txt                        CA database
    └── serial                           Issuance state

{{SERVER_FQDN}} operational TLS files
└── /etc/nginx/tls/
    ├── {{SERVER_FQDN}}.key.pem         Nginx private key
    ├── {{SERVER_FQDN}}.crt.pem         Nginx site certificate
    └── root-ca.crt.pem                  Public CA verification copy (SITE_CERT.md §8)

{{SERVER_FQDN}} client distribution files
└── /srv/camera-pki/public/
    ├── camera-system-root-ca.crt.pem
    ├── camera-system-root-ca.crt.pem.sha256
    └── README.txt
```

The copy under `/srv/camera-pki/public` is the deliberately managed client-distribution
copy. The authoritative CA state remains at `{{CA_ROOT_PATH}}` and in its encrypted backups.

## Site-specific values

| Purpose | Value |
|---|---|
| Distribution server | `{{SERVER_FQDN}}` |
| Distribution server address | `{{SERVER_IP}}` |
| DNS name | `{{SERVER_FQDN}}` |
| Wired client network | `10.1.1.0/24` |
| Wireless client network | `192.168.68.0/22` |
| Distribution directory | `/srv/camera-pki/public` |
| Certificate URL | `http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem` |
| Checksum URL | `http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem.sha256` |
| Instructions URL | `http://{{SERVER_FQDN}}/ca/README.txt` |

Replace every symbolic value before using this runbook:

| Symbol | Required value |
|---|---|
| `{{SERVER_FQDN}}` | Canonical DNS name used by clients and the TLS certificate |
| `{{SERVER_IP}}` | Server IP address hosting the distribution endpoint |

Generated documents must not contain any unresolved `{{...}}` symbols.

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

Install the already verified public CA certificate from the Nginx TLS directory (SITE_CERT.md §8 installs it under this name):

```bash
sudo install \
  -o root \
  -g root \
  -m 644 \
  /etc/nginx/tls/root-ca.crt.pem \
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
sha256 Fingerprint={{GENERATED VALUE}}
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
{{GENERATED VALUE}}
  camera-system-root-ca.crt.pem
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
http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem

PEM checksum file:
http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem.sha256

PEM file SHA-256:
{{GENERATED VALUE}}

Certificate SHA-256 fingerprint:
{{GENERATED VALUE}}

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

On a deployment where `{{SERVER_FQDN}}` already has an HTTP server block that redirected
every request to HTTPS:

```nginx
server {
    listen 80;
    server_name {{SERVER_FQDN}};

    return 301 https://{{SERVER_FQDN}}$request_uri;
}
```

change it to allow `/ca/` over HTTP while redirecting all other paths. On a fresh box no
such block exists — create it instead, e.g. `/etc/nginx/conf.d/{{SERVER_FQDN}}-ca-dist.conf`:

```nginx
server {
    listen 80;
    server_name {{SERVER_FQDN}};

    location /ca/ {
        alias /srv/camera-pki/public/;
        autoindex off;

        allow 10.1.1.0/24;
        allow 192.168.68.0/22;
        deny all;
    }

    location / {
        return 301 https://{{SERVER_FQDN}}$request_uri;
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

## 6. Test locally on {{SERVER_FQDN}}

Reload propagates to the existing workers asynchronously; a request fired in the same
instant as `systemctl reload` can still be answered by an old worker (it briefly returns
404 before the new config takes hold). If you see a one-off 404, wait a second and retry —
do not assume the configuration is broken.

Test the certificate endpoint:

```bash
curl \
  --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} \
  --head \
  http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem
```

Expected:

```text
HTTP/1.1 200 OK
Content-Type: application/x-x509-ca-cert
```

Test the checksum endpoint:

```bash
curl \
  --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} \
  --silent \
  --show-error \
  http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem.sha256
```

Test the instructions endpoint:

```bash
curl \
  --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} \
  --silent \
  --show-error \
  http://{{SERVER_FQDN}}/ca/README.txt
```

## Operational maintenance

When the root CA certificate changes:

1. Verify the new public certificate against the authoritative CA workspace at `{{CA_ROOT_PATH}}`.
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
