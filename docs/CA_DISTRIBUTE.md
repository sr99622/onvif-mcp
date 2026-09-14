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
    └── camera-system-root-ca.crt.pem    Public CA verification copy (SITE_CERT.md §8)

{{SERVER_FQDN}} client distribution files
└── /srv/camera-pki/public/
    ├── camera-system-root-ca.crt.pem
    ├── camera-system-root-ca.crt.pem.sha256
    ├── camera-system-root-ca.crt
    ├── camera-system-root-ca.crt.sha256
    └── README.txt
```

The copy under `/srv/camera-pki/public` is the deliberately managed client-distribution
copy. The authoritative CA state remains at `{{CA_ROOT_PATH}}` and in its encrypted backups.

## Values supplied by the Agent

| Symbol | Required value |
|---|---|
| `{{SERVER_FQDN}}` | Canonical DNS name used by clients and the TLS certificate |
| `{{SERVER_IP}}` | Server IP address hosting the distribution endpoint |

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
| Certificate URL (.crt alias) | `http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt` |
| Checksum URL | `http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem.sha256` |
| Checksum URL (.crt alias) | `http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.sha256` |
| Instructions URL | `http://{{SERVER_FQDN}}/ca/README.txt` |

Replace every symbolic value before using this runbook:

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
  /etc/nginx/tls/camera-system-root-ca.crt.pem \
  /srv/camera-pki/public/camera-system-root-ca.crt.pem

sudo install \
  -o root \
  -g root \
  -m 644 \
  /etc/nginx/tls/camera-system-root-ca.crt.pem \
  /srv/camera-pki/public/camera-system-root-ca.crt
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

cmp -s \
  /srv/camera-pki/public/camera-system-root-ca.crt.pem \
  /srv/camera-pki/public/camera-system-root-ca.crt
```

Tested result:

```text
subject=CN=Camera System Root CA
issuer=CN=Camera System Root CA
sha256 Fingerprint={{GENERATED VALUE}}
```

## 3. Create and verify both certificate file checksums

Create checksums for the exact bytes of both distributed certificate filenames. The `.crt` file is the same PEM-encoded certificate bytes as the `.crt.pem` file, exposed under the shorter extension for clients/tools that expect it:

```bash
cd /srv/camera-pki/public &&
sha256sum camera-system-root-ca.crt.pem |
sudo tee camera-system-root-ca.crt.pem.sha256

cd /srv/camera-pki/public &&
sha256sum camera-system-root-ca.crt |
sudo tee camera-system-root-ca.crt.sha256
```

Tested file checksums:

```text
{{GENERATED VALUE}}
  camera-system-root-ca.crt.pem
{{SAME GENERATED VALUE}}
  camera-system-root-ca.crt
```

Verify both checksum files:

```bash
cd /srv/camera-pki/public &&
sha256sum --check camera-system-root-ca.crt.pem.sha256

cd /srv/camera-pki/public &&
sha256sum --check camera-system-root-ca.crt.sha256
```

Expected:

```text
camera-system-root-ca.crt.pem: OK
camera-system-root-ca.crt: OK
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
http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt

Checksum files:
http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem.sha256
http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.sha256

File SHA-256 for both certificate downloads:
{{GENERATED VALUE}}

Certificate SHA-256 fingerprint:
{{GENERATED VALUE}}

Verify the downloaded PEM file:

macOS:
  shasum -a 256 camera-system-root-ca.crt.pem
  shasum -a 256 camera-system-root-ca.crt

Linux:
  sha256sum camera-system-root-ca.crt.pem
  sha256sum camera-system-root-ca.crt

Windows:
  certutil -hashfile camera-system-root-ca.crt.pem SHA256
  certutil -hashfile camera-system-root-ca.crt SHA256

Inspect the certificate fingerprint with OpenSSL:
  openssl x509 -in camera-system-root-ca.crt.pem \
    -noout -fingerprint -sha256
  openssl x509 -in camera-system-root-ca.crt \
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

Test the `.crt` alias endpoint:

```bash
curl \
  --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} \
  --head \
  http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt
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

Test the `.crt` checksum endpoint:

```bash
curl \
  --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} \
  --silent \
  --show-error \
  http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.sha256
```

Test the instructions endpoint:

```bash
curl \
  --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} \
  --silent \
  --show-error \
  http://{{SERVER_FQDN}}/ca/README.txt
```

## Stage-close backup (ca-distribute folder)

Archive this stage to `{{BACKUP_PATH}}/ca-distribute-{{DATETIME_STAMP}}` per
BACKUP.md's Procedure before any later stage runs.

Purpose and tier: `/srv/camera-pki/public` itself is regenerable (the cert is
byte-reproducible from the CA archive; checksums and README rebuild in one pass
each), so the stage is Tier 1.5. The load-bearing artifacts are the NGINX
archives: this folder's `final-etc-nginx-sites-available.tar`,
`-sites-enabled.tar`, and `final-etc-nginx-conf.d.tar` are, at this point in the
build, the NEWEST COMPLETE nginx configurations — BACKUP.md instructs restorers
to take the sites configs from this folder instead of site-cert's. An empty or
stale archive here silently breaks every later restore (D1/D6 failure classes).

Required contents — all PUBLIC material, no secret-scan duty (this is the one
backup folder safe to mirror anywhere):

- `post-change-state.txt` — the recorded fingerprint + PEM sha256, dir listing,
  checksum self-verify, all five endpoint checks, negative checks (camera-net
  403, listing 403), `server_name` count, nginx state.
- `final-srv-camera-pki.tar` — the distribution directory (cert ×2, checksums
  ×2, README).
- `final-etc-nginx-sites-available.tar` / `-sites-enabled.tar` /
  `final-etc-nginx-conf.d.tar` — configs WITH the `/ca/` location.
- `final-docs-CA_DISTRIBUTE.md`, `final-docs-BACKUP.md`, `SHA256SUMS`.

Unpinned-listener check (mandatory — this stage edits conf.d AFTER the
amendment and is exactly where the 2026-09-12 backup set reintroduced the
pinned `listen <SERVER_IP>:443;` line): before archiving,

```bash
grep -c 'listen 443 ssl;' /etc/nginx/conf.d/{{SERVER_FQDN}}.conf   # expect 1
grep -Ec 'listen [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:443' /etc/nginx/conf.d/{{SERVER_FQDN}}.conf   # expect 0
```

Verify the archives before closing:

```bash
for t in final-srv-camera-pki final-etc-nginx-conf.d final-etc-nginx-sites-available final-etc-nginx-sites-enabled; do
  tar -tf "{{BACKUP_PATH}}/ca-distribute-{{DATETIME_STAMP}}/$t.tar" | head -1 \
    || echo "FATAL: $t.tar empty/unreadable"
done
cd /srv/camera-pki/public && sha256sum --check *.sha256
openssl x509 -in /srv/camera-pki/public/camera-system-root-ca.crt.pem \
  -noout -fingerprint -sha256   # must equal the age-archived CA (single source of truth)
```

Supersession: supersedes site-cert's sites + conf.d archives; superseded for
sites by keycloak-* and for conf.d by stream-auth-* (each re-archives after
their own edits; the unpinned check above applies at EVERY re-archive).

Trust-anchor wording: the fingerprint recorded in `post-change-state.txt` is a
CONSISTENCY reference (detects corruption and generation drift across restores —
compare archive vs live vs age-archive CA), NOT the true out-of-band value: it
sits on the same share as the material it verifies, so it cannot detect
malicious edits to both together. The true anchor is the value the admin
compared at client-install time, out of band.

## Operational maintenance

When the root CA certificate changes:

1. Verify the new public certificate against the authoritative CA workspace at `{{CA_ROOT_PATH}}`.
2. Install the new public certificate under `/srv/camera-pki/public`.
3. Recreate both distributed filenames and verify their bytes match.
4. Recalculate both checksum files.
5. Update `README.txt` with both download URLs, both checksum URLs, the new file checksum, and certificate fingerprint.
6. Run `nginx -t` if the URL or Nginx mapping changes.
7. Test all five HTTP endpoints locally.
8. Test download and verification from Windows, macOS, and Linux clients as applicable.
9. Re-run the stage-close backup above — the archived folder is a snapshot; a
   CA re-root that skips this step leaves clients following the archived README
   toward a dead certificate.

Do not place any of the following under `/srv/camera-pki/public`:

- CA private keys
- Nginx private keys
- CA database or serial files
- CSRs unless deliberately needed
- Encrypted or decrypted CA archives
- Passwords, passphrases, or recovery credentials
