
## 1. Get Site Key

On the Mac:

```bash
scp \
  {{SERVER_USER}}@{{SERVER_IP}}:/home/{{SERVER_USER}}/{{SERVER_FQDN}}.csr.pem \
  "$HOME/Private-CA/camera-system-ca/csr/"
```

Verify the transferred CSR again:

```bash
openssl req \
  -in "$HOME/Private-CA/camera-system-ca/csr/{{SERVER_FQDN}}.csr.pem" \
  -noout -verify -subject
```

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

The SAN must contain every hostname clients will use. This deployment intentionally uses only the canonical DNS name, not an IP SAN.

## 3. Sign the Nginx certificate

```bash
openssl ca \
  -config "$HOME/Private-CA/camera-system-ca/openssl.cnf" \
  -extfile "$HOME/Private-CA/camera-system-ca/csr/{{SERVER_FQDN}}.ext.cnf" \
  -extensions server_cert \
  -days 397 \
  -md sha256 \
  -notext \
  -in "$HOME/Private-CA/camera-system-ca/csr/{{SERVER_FQDN}}.csr.pem" \
  -out "$HOME/Private-CA/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem"
```

Review the displayed subject and extensions before answering `y` to both signing and database-commit prompts.

The tested certificate included:

- Serial `0x1000`
- `CN={{SERVER_FQDN}}`
- SAN `DNS:{{SERVER_FQDN}}`
- `CA:FALSE`
- TLS Web Server Authentication
- 397-day validity

Verify chain, purpose, and hostname:

```bash
openssl verify \
  -CAfile "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  -purpose sslserver \
  -verify_hostname {{SERVER_FQDN}} \
  "$HOME/Private-CA/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem"
```

Expected result ends with `OK`.

## 4. Back up updated CA state after issuance

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

## 5. Transfer public certificates to {{SERVER_FQDN}}

From the Mac:

```bash
scp \
  "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  "$HOME/Private-CA/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem" \
  {{SERVER_USER}}@{{SERVER_IP}}:/home/{{SERVER_USER}}/
```
