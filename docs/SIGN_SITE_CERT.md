
## 1. Get Site Key

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

## 2. Define reviewed site-certificate extensions

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

## 3. Sign the Nginx certificate

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

## 5. Transfer public certificates to trigkey

From the Mac:

```bash
scp \
  "$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem" \
  "$HOME/Private-CA/camera-system-ca/issued/camera.home.arpa.crt.pem" \
  stephen@10.1.1.3:/home/stephen/
```
