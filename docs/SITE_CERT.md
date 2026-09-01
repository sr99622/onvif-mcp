# Site Certificate Runbook (single-host deployment)

## Purpose

This runbook documents the tested, end-to-end process for the nginx server certificate,
all **on the same host that runs nginx**:

- Generate the TLS server key.
- Create a CSR from it.
- Sign that CSR with the private CA and verify the issued certificate.
- Install leaf + CA for nginx and prove the pair works.
- Back up the updated CA state after issuance.

Prerequisite: the private CA exists on this same host per CREATE_CA_CERT.md (root cert at
`{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem`, its passphrase in
the `pass` vault). Because the CA and the web server live on one machine there are no
scp/ssh steps; the only cross-machine step is the encrypted backup copy to the SMB share
at `{{SMB_PATH}}/Camera-CA-Backups/`.

## Variables supplied by the Agent

| Name | Meaning |
|---|---|
| `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name (e.g. `nuc.home.arpa`) |
| `{{SERVER_USER}}` | `$USER` account name for the agent |
| `{{CA_ROOT_PATH}}` | Private CA root directory (e.g. `/home/stephen/Private-CA`) |
| `{{SMB_PATH}}` | Mounted SMB share path (e.g. `/mnt/taurus`) |
| `{{DATE}}` | Current date for archive names (e.g. `2026-09-01`; never reuse a hardcoded value) |

Passphrases are **not** supplied as variables and never echoed. Both live in the local
`pass` vault under the CA store's GPG key (see CREATE_CA_CERT.md §5):

| Vault entry | Protects |
|---|---|
| `camera-ca/root-key-passphrase` | The CA private key used for signing |
| `camera-ca/age-archive-<DATE>` | The age archive from that date (local + SMB copy) |

## 1. Generate the TLS server key on {{SERVER_FQDN}}

Create the TLS directory:

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
  -noout -text |
sed -n '/Requested Extensions:/,/Signature Algorithm/p'
```

Required SAN:

```text
DNS:{{SERVER_FQDN}}
```

The CSR stays at `/etc/nginx/tls/{{SERVER_FQDN}}.csr.pem` until installation completes —
it is never copied to an intermediate directory (§3 moves it into the CA tree). Note that
`/etc/nginx/tls` is root-owned mode 700 (§1), so **reading** files out of it requires sudo;
the agent user cannot `openssl ... -in /etc/nginx/tls/...` directly.

## 3. Pre-issuance review and import the CSR into the CA

Verify the CSR (sudo: root-owned directory):

```bash
sudo openssl req \
  -in /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem \
  -noout -verify -subject
```

Confirm the CSR matches the live nginx key you intend to certify — public-key hash of the
CSR versus the installed key (both lines must be identical):

```bash
sudo openssl req -in /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem -noout -pubkey | openssl sha256
sudo openssl pkey -in /etc/nginx/tls/{{SERVER_FQDN}}.key.pem -pubout | openssl sha256
```

Check pre-issuance state (read-only): `index.txt` (certs issued so far) and `serial`
(next serial to assign, e.g. `0x1000` on a fresh CA), at
`{{CA_ROOT_PATH}}/camera-system-ca/`.

Then move the CSR into the CA's `csr` directory, owned by the agent user (the signing
step runs as that user) and mode 600:

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

The SAN must contain every hostname clients will use. This deployment intentionally uses
only the canonical DNS name, not an IP SAN.

## 5. Sign the Nginx certificate with the CA

`openssl ca` prompts three times: once for the CA key passphrase (readable via piped
stdin), then "Sign?" and "commit?" which must be answered `y` **after** reviewing what it
prints. Feed them in order from the vault — the same two-line PTY pattern as
CREATE_CA_CERT.md §6:

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

Review the subject and extensions `openssl ca` displays before answering `y` to both
signing and database-commit prompts (on headless execution, review the captured
transcript immediately). Expected: serial from the `serial` file (`0x1000` on a fresh
CA), `CN={{SERVER_FQDN}}`, 397-day validity, extensions from the reviewed ext file.

## 6. Verify the issued certificate

Verify chain, purpose, and hostname:

```bash
openssl verify \
  -CAfile "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  -purpose sslserver \
  -verify_hostname {{SERVER_FQDN}} \
  "{{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem"
```

Expected result ends with `OK`.

## 7. Back up updated CA state after issuance

Issuance changes `index.txt` (plus `index.txt.old`) and advances `serial`
(`serial.old`). Create a new archive immediately, named
`camera-system-ca-after-<server>-cert-{{DATE}}.tar.gz.age` (replace `<server>` with a
short label for this server):

```bash
bash -lc 'pass show camera-ca/age-archive-{{DATE}}; pass show camera-ca/age-archive-{{DATE}}' \
  | script -qec "stty -echo 2>/dev/null; set -o pipefail; \
      tar -C {{CA_ROOT_PATH}} -czf - camera-system-ca | \
      age -p -o {{CA_ROOT_PATH}}/backups/camera-system-ca-after-<server>-cert-{{DATE}}.tar.gz.age" /dev/null
```

Set mode `600`, verify decryption by listing (one-line pattern), copy to
`{{SMB_PATH}}/Camera-CA-Backups/` without overwriting, and compare SHA-256 hashes —
exactly as CREATE_CA_CERT.md §10–11 prescribe. The archive must contain the encrypted CA
key, root cert, issued site certificate, CSR + ext file, `index.txt`/`index.txt.old`,
`serial`/`serial.old`, and `newcerts/<serial>.pem`.

## 8. Install the certificates for nginx (same host)

The public certificates are installed into `/etc/nginx/tls/`:

```bash
sudo install -m 644 \
  "{{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem" \
  /etc/nginx/tls/"{{SERVER_FQDN}}.crt.pem"
sudo install -m 644 \
  "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  /etc/nginx/tls/root-ca.crt.pem
```

The private key already lives at `/etc/nginx/tls/{{SERVER_FQDN}}.key.pem` (§1, mode 600
root). For `ssl_certificate` nginx needs the leaf **followed by** the CA:

```bash
sudo bash -c 'cat /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem \
  /etc/nginx/tls/root-ca.crt.pem > /etc/nginx/tls/{{SERVER_FQDN}}.chain.pem'
```

If no HTTPS server block for this FQDN exists yet (fresh box), create one, e.g.
`/etc/nginx/conf.d/{{SERVER_FQDN}}.conf`:

```nginx
server {
	listen 443 ssl default_server;
	listen [::]:443 ssl default_server;

	ssl_certificate /etc/nginx/tls/{{SERVER_FQDN}}.chain.pem;
	ssl_certificate_key /etc/nginx/tls/{{SERVER_FQDN}}.key.pem;

	server_name {{SERVER_FQDN}};

	root /var/www/html;
	index index.html index.htm;
}
```

Otherwise point the existing server block at `{{SERVER_FQDN}}.chain.pem` and
`{{SERVER_FQDN}}.key.pem`. Then prove the pair actually works:

```bash
sudo nginx -t
sudo systemctl reload nginx
curl --cacert "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  https://{{SERVER_FQDN}}/   # TLS must complete against our CA, not trust-store defaults
```

## 9. Client distribution

The root certificate (`/etc/nginx/tls/root-ca.crt.pem` or the copy in
`{{CA_ROOT_PATH}}/camera-system-ca/certs/`) is public and may be distributed to clients;
the private key never leaves this host, and the vault passphrases stay GPG-encrypted in
`~/.password-store`.
