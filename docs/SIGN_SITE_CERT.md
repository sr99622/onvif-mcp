# Site Certificate Signing (single-host deployment)

## Purpose

Sign the nginx server certificate with the private CA **on the same host that runs nginx**.

This deployment changed since the original draft of this document: the CA and the web
server now live on one machine, so all scp/ssh transfer steps are gone. Files move only
within local filesystems; the only cross-machine step is the encrypted backup copy to
the SMB share at `/mnt/taurus/Camera-CA-Backups/`.

## 0. Variables supplied by agent

| Name | Meaning |
|---|---|
| `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name (e.g. `nuc.home.arpa`) |
| `{{SERVER_USER}}` | `$USER` account name for the agent |
| `{{CSR_PATH}}` | Path where the CSR transfer copy lives (see SITE_KEY.md §3) |
| `{{CA_ROOT_PATH}}` | Private CA root directory (e.g. `/home/stephen/Private-CA`) |
| `{{SMB_PATH}}` | Mounted SMB share path (e.g. `/mnt/taurus`) |

Passphrases are **not** supplied as variables. Both live in the local `pass` vault under
the CA store's GPG key (see CREATE_CA_CERT.md §5):

| Vault entry | Protects |
|---|---|
| `camera-ca/root-key-passphrase` | The CA private key used for signing |
| `camera-ca/age-archive-<DATE>` | The age archive from that date (local + SMB) |

## 1. Collect the CSR locally

The CSR was generated on this same machine (SITE_KEY.md §2) and its transfer copy is at
`{{CSR_PATH}}/{{SERVER_FQDN}}.csr.pem`. Move it into the CA's `csr` directory:

```bash
install -m 600 \
  "{{CSR_PATH}}/{{SERVER_FQDN}}.csr.pem" \
  "{{CA_ROOT_PATH}}/camera-system-ca/csr/{{SERVER_FQDN}}.csr.pem"
```

Verify it:

```bash
openssl req \
  -in "{{CA_ROOT_PATH}}/camera-system-ca/csr/{{SERVER_FQDN}}.csr.pem" \
  -noout -verify -subject
```

Before signing, also check pre-issuance state (read-only): `index.txt`, `serial`, and
confirm the CSR matches the server key you intend to certify (public-key hash of CSR vs
the live nginx key), so you sign the right key.

## 2. Define reviewed site-certificate extensions

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

## 3. Sign the Nginx certificate

`openssl ca` prompts three times: once for the CA key passphrase (readable via piped
stdin), then "Sign?" and "commit?" which must be answered `y` **after** reviewing what it
prints. Feed them in order from the vault — the same two-line PTY pattern as CREATE_CA_CERT.md §6:

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
transcript immediately). Expected: serial from `serial` file (`0x1000` on a fresh CA),
`CN={{SERVER_FQDN}}`, 397-day validity, extensions from the reviewed ext file.

Verify chain, purpose, and hostname:

```bash
openssl verify \
  -CAfile "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  -purpose sslserver \
  -verify_hostname {{SERVER_FQDN}} \
  "{{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem"
```

Expected result ends with `OK`.

## 4. Back up updated CA state after issuance

Issuance changes `index.txt` (plus `index.txt.old`) and advances `serial`
(`serial.old`). Create a new archive immediately, named
`camera-system-ca-after-<server>-cert-<DATE>.tar.gz.age`:

```bash
bash -lc 'pass show camera-ca/age-archive-<DATE>; pass show camera-ca/age-archive-<DATE>' \
  | script -qec "stty -echo 2>/dev/null; set -o pipefail; \
      tar -C {{CA_ROOT_PATH}} -czf - camera-system-ca | \
      age -p -o {{CA_ROOT_PATH}}/backups/camera-system-ca-after-<server>-cert-<DATE>.tar.gz.age" /dev/null
```

Set mode `600`, verify decryption by listing (one-line pattern), copy to
`{{SMB_PATH}}/Camera-CA-Backups/` without overwriting, and compare SHA-256 hashes —
exactly as CREATE_CA_CERT.md §10–11 prescribe. The archive must contain the encrypted CA
key, root cert, issued site certificate, CSR + ext file, `index.txt`/`index.txt.old`,
`serial`/`serial.old`, and `newcerts/<serial>.pem`.

## 5. Install the certificates for nginx (same host)

The public certificates are installed into `/etc/nginx/tls/` — no scp, no user-home copy:

```bash
sudo install -m 644 \
  "{{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem" \
  /etc/nginx/tls/"{{SERVER_FQDN}}.crt.pem"
sudo install -m 644 \
  "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  /etc/nginx/tls/root-ca.crt.pem
```

The private key already lives at `/etc/nginx/tls/{{SERVER_FQDN}}.key.pem` (SITE_KEY.md §1,
mode 600 root). For `ssl_certificate` nginx needs the leaf **followed by** the CA:

```bash
sudo bash -c 'cat /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem \
  /etc/nginx/tls/root-ca.crt.pem > /etc/nginx/tls/{{SERVER_FQDN}}.chain.pem'
```

Point the nginx server block at `{{SERVER_FQDN}}.chain.pem` and `{{SERVER_FQDN}}.key.pem`,
then prove the pair actually works:

```bash
sudo nginx -t
sudo systemctl reload nginx
curl --cacert "{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  https://{{SERVER_FQDN}}/   # TLS must complete against our CA, not trust-store defaults
```

Sanity check that the cert pairs with the live key (public-key hash match), as in the old
cross-machine verification:

```bash
openssl x509 -in "{{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem" \
  -noout -pubkey | openssl sha256
sudo openssl pkey -in /etc/nginx/tls/{{SERVER_FQDN}}.key.pem -pubout | openssl sha256
```

## 6. Client distribution

The root certificate (`/etc/nginx/tls/root-ca.crt.pem` or the copy in
`{{CA_ROOT_PATH}}/camera-system-ca/certs/`) is public and may be distributed to clients;
the private key never leaves this host, and the vault passphrases stay GPG-encrypted in
`~/.password-store`.
