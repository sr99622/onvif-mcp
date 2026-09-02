# Site Certificate + HTTPS Deployment Runbook (single-host)

This runbook documents the tested, end-to-end process for everything that makes
the camera web stack speak HTTPS, all **on the same host that runs nginx**:

1. Generate the TLS server key.
2. Create a CSR from it and review it before issuance.
3. Sign that CSR with the private CA (single-host: no scp/ssh — the CA lives here)
   and verify the issued certificate.
4. Back up the updated CA state after issuance.
5. Install leaf + CA for nginx and prove the pair works.
6. Configure nginx: an HTTPS server block on a **specific interface** plus a
   hostname-specific HTTP→HTTPS redirect.
7. Update downstream consumers (camera registry, `STREAM_SERVER_URL`) to HTTPS.
8. Validate every endpoint over TLS; distribute the public CA to clients.

Prerequisite: the private CA exists on this same host per CREATE_CA_CERT.md
(root cert at `{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem`,
its passphrase in the local `pass` vault as `camera-ca/root-key-passphrase`, and a
vault entry `camera-ca/age-archive-<DATE>` for the age archives).

## Variables supplied by the Agent

| Name | Meaning |
|---|---|
| `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name (e.g. `nuc.home.arpa`) |
| `{{SERVER_IP}}` | Server IP address of the interface that should publish HTTPS (e.g. `10.1.1.6`) |
| `{{SERVER_USER}}` | `$USER` account name for the agent (the CA owner) |
| `{{CA_ROOT_PATH}}` | Private CA root directory (e.g. `/home/stephen/Private-CA`) |
| `{{SMB_PATH}}` | Mounted SMB share path (e.g. `/mnt/taurus`) |
| `{{REPO_PATH}}` | Project repository location (the onvif-mcp repo lives at `{{REPO_PATH}}/onvif-mcp`) |
| `{{DATE}}` | Current date for archive names (e.g. `2026-09-01`; never reuse a hardcoded value) |

Passphrases are **not** supplied as variables and never echoed. Both live in the
local `pass` vault under the CA store's GPG key (see CREATE_CA_CERT.md §5).

## 1. Generate the TLS server key on {{SERVER_FQDN}}

Create the TLS directory (root-owned, mode 700 — **reading** files out of it
later requires sudo; the agent user cannot `openssl ... -in /etc/nginx/tls/...`):

```bash
sudo install -d -o root -g root -m 700 /etc/nginx/tls
```

Generate a 3072-bit RSA server key (unencrypted; nginx reads it directly):

```bash
sudo openssl genpkey \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:3072 \
  -out /etc/nginx/tls/{{SERVER_FQDN}}.key.pem
```

Verify mode, format, and integrity:

```bash
sudo ls -l /etc/nginx/tls/{{SERVER_FQDN}}.key.pem
sudo sed -n '1p' /etc/nginx/tls/{{SERVER_FQDN}}.key.pem
sudo openssl pkey \
  -in /etc/nginx/tls/{{SERVER_FQDN}}.key.pem \
  -check -noout
```

Expected mode is `600`, owner `root`, with header:

```text
-----BEGIN PRIVATE KEY-----
```

## 2. Generate the CSR on {{SERVER_FQDN}}

```bash
sudo openssl req \
  -new \
  -sha256 \
  -key /etc/nginx/tls/{{SERVER_FQDN}}.key.pem \
  -out /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem \
  -subj "/CN={{SERVER_FQDN}}" \
  -addext "subjectAltName=DNS:{{SERVER_FQDN}}" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"
```

Verify the signature and requested extensions:

```bash
sudo openssl req \
  -in /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem \
  -noout -verify -subject

sudo openssl req \
  -in /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem \
  -noout -text | sed -n '/Requested Extensions:/,/Signature Algorithm/p'
```

Required SAN:

```text
DNS:{{SERVER_FQDN}}
```

## 3. Pre-issuance review and import the CSR into the CA

Confirm the CSR matches the live nginx key you intend to certify — public-key
hash of the CSR versus the installed key (both lines must be identical):

```bash
sudo openssl req -in /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem -noout -pubkey | openssl sha256
sudo openssl pkey -in /etc/nginx/tls/{{SERVER_FQDN}}.key.pem -pubout | openssl sha256
```

Check pre-issuance state (read-only): `index.txt` (certs issued so far) and
`serial` (next serial to assign, e.g. `0x1000` on a fresh CA), at
`{{CA_ROOT_PATH}}/camera-system-ca/`.

Then move the CSR into the CA's `csr` directory, owned by the agent user (the
signing step runs as that user) and mode 600:

```bash
tmp=$(mktemp)
sudo cat /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem > "$tmp"
install -m 600 "$tmp" "{{CA_ROOT_PATH}}/camera-system-ca/csr/{{SERVER_FQDN}}.csr.pem"
shred -u "$tmp"
```

The original stays in `/etc/nginx/tls/`; the staged copy is wiped.

## 4. Define reviewed site-certificate extensions

Create `{{SERVER_FQDN}}.ext.cnf` in the CA's `csr` directory:

```ini
[ server_cert ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = DNS:{{SERVER_FQDN}}
```

The SAN must contain every hostname clients will use. This deployment
intentionally uses only the canonical DNS name, not an IP SAN (clients always
use `{{SERVER_FQDN}}`; the listener is pinned to `{{SERVER_IP}}` in §7).

## 5. Sign the Nginx certificate with the CA

`openssl ca` prompts three times: once for the CA key passphrase (readable via
piped stdin), then "Sign?" and "commit?" which must be answered `y` **after**
reviewing what it prints. Feed them in order from the vault — the same two-line
PTY pattern as CREATE_CA_CERT.md §6:

```bash
bash -lc 'pass show camera-ca/root-key-passphrase; echo y; echo y' \
  | script -qec "stty -echo 2>/dev/null; openssl ca \
      -config {{CA_ROOT_PATH}}/camera-system-ca/openssl.cnf \
      -extfile {{CA_ROOT_PATH}}/camera-system-ca/csr/{{SERVER_FQDN}}.ext.cnf \
      -extensions server_cert \
      -days 397 \
      -md sha256 \
      -notext \
      -in {{CA_ROOT_PATH}}/camera-system-ca/csr/{{SERVER_FQDN}}.csr.pem \
      -out {{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem" /dev/null
```

Review the subject and extensions `openssl ca` displays before answering `y` to
both signing and database-commit prompts (on headless execution, review the
captured transcript immediately). Expected: serial from the `serial` file
(`0x1000` on a fresh CA), `CN={{SERVER_FQDN}}`, 397-day validity, extensions
from the reviewed ext file.

## 6. Verify the issued certificate

Verify chain, purpose, and hostname:

```bash
openssl verify \
  -CAfile "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  -purpose sslserver \
  -verify_hostname {{SERVER_FQDN}} \
  "{{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem"
```

Expected result ends with `OK`. Also confirm the certificate matches the
installed nginx key (both lines identical):

```bash
sudo openssl pkey -in /etc/nginx/tls/{{SERVER_FQDN}}.key.pem -pubout | openssl sha256
openssl x509 -in "{{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem" -pubkey -noout | openssl sha256
```

## 7. Back up updated CA state after issuance

Issuance changes `index.txt` (plus `index.txt.old`) and advances `serial`
(`serial.old`). Create a new archive immediately, named
`camera-system-ca-after-<server>-cert-{{DATE}}.tar.gz.age` (replace `<server>`
with a short label for this server), exactly as CREATE_CA_CERT.md §10–11
prescribe:

```bash
# encrypt (two prompts)
bash -lc 'pass show camera-ca/age-archive-{{DATE}}; pass show camera-ca/age-archive-{{DATE}}' \
  | script -qec "stty -echo 2>/dev/null; set -o pipefail; \
      tar -C {{CA_ROOT_PATH}} -czf - camera-system-ca | \
      age -p -o {{CA_ROOT_PATH}}/backups/camera-system-ca-after-<server>-cert-{{DATE}}.tar.gz.age" /dev/null
chmod 600 "{{CA_ROOT_PATH}}/backups/camera-system-ca-after-<server>-cert-{{DATE}}.tar.gz.age"

# verify decryption without extracting (one prompt), then wipe the decrypted copy
bash -lc 'pass show camera-ca/age-archive-{{DATE}}' \
  | script -qec "stty -echo 2>/dev/null; age -d {{CA_ROOT_PATH}}/backups/camera-system-ca-after-<server>-cert-{{DATE}}.tar.gz.age > /tmp/.ca-decrypted.tgz" /dev/null
tar -tzf /tmp/.ca-decrypted.tgz    # must list key, certs, issued/, csr/, index.txt(.old), serial(.old), newcerts/
shred -u /tmp/.ca-decrypted.tgz

# copy without overwriting; hashes must match exactly
mkdir -p "{{SMB_PATH}}/Camera-CA-Backups"
cp --update=none \
  "{{CA_ROOT_PATH}}/backups/camera-system-ca-after-<server>-cert-{{DATE}}.tar.gz.age" \
  "{{SMB_PATH}}/Camera-CA-Backups/"
sha256sum \
  "{{CA_ROOT_PATH}}/backups/camera-system-ca-after-<server>-cert-{{DATE}}.tar.gz.age" \
  "{{SMB_PATH}}/Camera-CA-Backups/camera-system-ca-after-<server>-cert-{{DATE}}.tar.gz.age"
```

The archive must contain the encrypted CA key, root cert, issued site
certificate, CSR + ext file, `index.txt`/`index.txt.old`, `serial`/`serial.old`,
and `newcerts/<serial>.pem`.

## 8. Install the certificates for nginx (same host)

Install the public leaf and CA into `/etc/nginx/tls/`:

```bash
sudo install -m 644 \
  "{{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem" \
  /etc/nginx/tls/"{{SERVER_FQDN}}.crt.pem"
sudo install -m 644 \
  "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  /etc/nginx/tls/root-ca.crt.pem
```

The private key already lives at `/etc/nginx/tls/{{SERVER_FQDN}}.key.pem`
(§1, mode 600 root). For `ssl_certificate` nginx needs the leaf **followed by**
the CA:

```bash
sudo bash -c 'cat /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem \
  /etc/nginx/tls/root-ca.crt.pem > /etc/nginx/tls/{{SERVER_FQDN}}.chain.pem'
```

The final TLS directory should have:

- Site key: root-owned, mode `600`
- CSR: root-owned, mode `644` (kept for audit; never contains secrets)
- Site certificate: root-owned, mode `644`
- Public CA certificate: root-owned, mode `644`

## 9. Configure Nginx HTTPS

Back up the site configuration and `nginx.conf` first:

```bash
sudo cp --update=none /etc/nginx/sites-available/mediamtx \
  "/etc/nginx/sites-available/mediamtx.backup-$(date +%F)"
sudo cp --update=none /etc/nginx/nginx.conf \
  "/etc/nginx/nginx.conf.backup-$(date +%F)"
```

The camera stack on this host lives in the existing `server_name {{SERVER_FQDN}}`
block (the one created by docs/MEDIAMTX.md, docs/APPS.md and docs/SNAPSHOT.md —
it currently serves all locations over plain HTTP port 80). The HTTPS
deployment does two things:

1. **Move every location into a new HTTPS server block** bound to
   `{{SERVER_IP}}:443` only (not all interfaces — this keeps HTTPS off the
   camera/Wi-Fi subnets). If an HTTPS block for this FQDN already exists, extend
   that one; never enable two files declaring the same name.
2. **Add a hostname-specific port-80 redirect** so browsers are sent to TLS:

```nginx
server {
    listen 80;
    server_name {{SERVER_FQDN}};

    return 301 https://{{SERVER_FQDN}}$request_uri;
}
```

The HTTPS block (fresh deployment, at `/etc/nginx/conf.d/{{SERVER_FQDN}}.conf`
— keep `listen` and `server_name` out of the sites file so there is exactly one
declaration per port):

```nginx
server {
    listen {{SERVER_IP}}:443 ssl;
    server_name {{SERVER_FQDN}};

    ssl_certificate     /etc/nginx/tls/{{SERVER_FQDN}}.chain.pem;
    ssl_certificate_key /etc/nginx/tls/{{SERVER_FQDN}}.key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:camera_tls:10m;
    ssl_session_timeout 1d;

    # --- Camera applications (static, straight from the project folder) ---
    location = /cameras { return 301 /cameras/; }
    location = /multiview { return 301 /multiview/; }

    location /cameras/ {
        alias {{REPO_PATH}}/onvif-mcp/apps/cameras/;
    }

    location /multiview/ {
        alias {{REPO_PATH}}/onvif-mcp/apps/multiview/;
    }

    # Shared camera registry — both apps fetch it at this root-relative path
    location /outputs/ {
        alias {{REPO_PATH}}/onvif-mcp/apps/outputs/;
    }

    # --- MediaMTX WebRTC proxy (trailing slash REQUIRED, preserve /webrtc/) ---
    location /webrtc/ {
        proxy_pass http://127.0.0.1:8889/;
        proxy_redirect / /webrtc/;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # --- MCP HTTP server (loopback-only on 8001) ---
    location = /mcp {
        proxy_pass http://127.0.0.1:8001/mcp;
        proxy_redirect off;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location = /mcp/ {
        return 301 https://$host/mcp;
    }

    # --- Snapshot proxy (loopback-only on 8891) ---
    location /snapshot/ {
        proxy_pass http://127.0.0.1:8891/snapshot/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 30s;
        proxy_send_timeout 30s;

        proxy_no_cache on;
        proxy_cache_bypass on;
    }

    location = / {
        return 200 "MediaMTX server at {{SERVER_FQDN}} | apps: /cameras/ (switchboard), /multiview/ (four-camera view)\n";
        add_header Content-Type text/plain;
    }
}
```

Then strip the locations out of the plain-HTTP sites file, leaving it as a
redirect-only block for `{{SERVER_FQDN}}` (§9 item 2) so every camera URL has a
single canonical HTTPS form. Validate **before** touching the running server:

```bash
sudo nginx -t                    # must say "test is successful"
# verify there is exactly one declaration per (port, server_name) pair
sudo nginx -T | grep -c 'server_name {{SERVER_FQDN}}'   # 2 total: port-80 redirect + 443 block — and only those two files
sudo systemctl reload nginx.service
systemctl --no-pager --full status nginx.service
```

Confirm the listener is pinned to the right interface:

```bash
sudo ss -lntp 'sport = :443'     # expect exactly {{SERVER_IP}}:443, not *:443
```

Note on the port-80 redirect block: a `default_server` may still exist for other
hostnames — that is fine; nginx routes `Host: {{SERVER_FQDN}}` to the specific
block and everything else to the default.

## 10. Validate HTTPS end-to-end

Because `{{SERVER_FQDN}}` may not resolve via local DNS, use an explicit mapping
and CA file — TLS must complete against **our** CA, not any trust-store default:

```bash
sudo curl \
  --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/root-ca.crt.pem \
  --head https://{{SERVER_FQDN}}/cameras/
# expected: HTTP/1.1 200 OK

sudo curl -s \
  --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/root-ca.crt.pem \
  -o /tmp/e2e.jpg -w '%{http_code} %{content_type}\n' \
  https://{{SERVER_FQDN}}/snapshot/<serial>/<token>/     # real JPEG, not HTML

# every app/stream endpoint must work over TLS:
for u in /cameras/ /multiview/ /outputs/camera_registry.json \
         /webrtc/<SERIAL>/<TOKEN>/; do
  curl -s --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
    --cacert /etc/nginx/tls/root-ca.crt.pem \
    -o /dev/null -w "%-45s %s\n" "$u" "$(curl -s -o /dev/null -w '%{http_code}' --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} --cacert /etc/nginx/tls/root-ca.crt.pem https://{{SERVER_FQDN}}$u)"
done

# port-80 must bounce, not serve
curl -sI http://{{SERVER_IP}}/cameras/ | head -3    # expect 301 -> https://{{SERVER_FQDN}}/cameras/
```

Then open `https://{{SERVER_FQDN}}/cameras/` in a browser (it will accept the
self-issued CA via `/etc/nginx/tls/root-ca.crt.pem`) and confirm streams play.

## 11. Update downstream consumers to HTTPS

### Camera registry

Back it up, then flip the scheme on every player URL (keep the existing path and
trailing slash):

```bash
cp --update=none \
  {{REPO_PATH}}/onvif-mcp/apps/outputs/camera_registry.json \
  {{REPO_PATH}}/onvif-mcp/apps/outputs/camera_registry.json.backup-$(date +%F)
perl -pi -e 's#http://\Q{{SERVER_FQDN}}\E/webrtc/#https://{{SERVER_FQDN}}/webrtc/#g' \
  {{REPO_PATH}}/onvif-mcp/apps/outputs/camera_registry.json
python3 -m json.tool {{REPO_PATH}}/onvif-mcp/apps/outputs/camera_registry.json >/dev/null   # valid JSON
rg -n 'player_url' {{REPO_PATH}}/onvif-mcp/apps/outputs/camera_registry.json               # all https://, trailing slash
```

Final URL pattern:

```text
https://{{SERVER_FQDN}}/webrtc/<SERIAL>/<TOKEN>/
```

### ONVIF MCP HTTP server (if deployed)

If the MCP HTTP server was installed per `docs/MCP_HTTP.md`, its
`STREAM_SERVER_URL` environment variable still points at plain HTTP (it predates
this step). Left unchanged, every web-player URL it generates (`get_web_player_url`
and the streaming tools) points at port 80, which now only redirects.

Update the unit to the HTTPS base URL — the server appends
`/webrtc/<SERIAL>/<PROFILE>` and `/snapshot/<SERIAL>/<PROFILE>` to it (see
`packages/core/src/onvif_mcp_core/streaming.py`), so the value is scheme + host
only, with no path:

```bash
sudo sed -i 's#^Environment=STREAM_SERVER_URL=.*#Environment=STREAM_SERVER_URL=https://{{SERVER_FQDN}}#' \
  /etc/systemd/system/onvif-mcp-http.service
sudo systemctl daemon-reload
sudo systemctl restart onvif-mcp-http

systemctl show onvif-mcp-http --property=Environment | grep STREAM_SERVER_URL
# expected: Environment=...STREAM_SERVER_URL=https://{{SERVER_FQDN}}...
```

Then exercise `get_web_player_url` through the MCP endpoint (session handshake per
`docs/MCP_HTTP.md`) and confirm it returns a URL of the form

```text
https://{{SERVER_FQDN}}/webrtc/<SERIAL>/<PROFILE>/
```

### Client distribution

The root certificate (`/etc/nginx/tls/root-ca.crt.pem` or the copy in
`{{CA_ROOT_PATH}}/camera-system-ca/certs/`) is public and must be distributed to
clients that will consume the HTTPS endpoints; the private key never leaves this
host, and the vault passphrases stay GPG-encrypted in `~/.password-store`.

## 12. Renewal procedure (use only at renewal time)

Before the 397-day site certificate expires:

1. Confirm the existing Nginx key remains secure and valid.
2. Generate a new CSR from it, or generate a new site key if rotating keys.
3. Stage the CSR into the CA's `csr/` directory (single host: §3).
4. Review the SAN and extension file (§4).
5. Sign through `openssl ca` (§5).
6. Verify chain, purpose, hostname, and key match (§6).
7. Create and verify a new encrypted CA archive with the day's date (§7).
8. Copy the archive to SMB and compare hashes (§7).
9. Install the new public site certificate and rebuild the chain file (§8).
10. Run `nginx -t` and reload Nginx (§9).
11. Verify the live certificate and streams (§10) — clients do not need to
    re-trust anything; only the leaf changed.

## 13. Useful operational commands

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
  -CAfile /etc/nginx/tls/root-ca.crt.pem \
  -purpose sslserver \
  -verify_hostname {{SERVER_FQDN}} \
  /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem

# HTTPS test (explicit resolve + our CA)
curl --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/root-ca.crt.pem \
  --head https://{{SERVER_FQDN}}/cameras/

# MediaMTX signaling listener
sudo ss -lntup 'sport = :8889'
```
