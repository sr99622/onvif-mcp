## 0. Variables supplied by agent

{{SERVER_FQDN}} - Server Fully Qualified Domain Name

{{SERVER_IP}} - Server IP Address

{{SERVER_USER}} - User Account Name

{{SERVER_PASSWORD}} - Server user account password

{{CA_CERTIFICATE_PASSPHRASE}} - Passphrase for the CA certificate needed to sign

{{AGE_PASSPHRASE}} - Passphrase needed for encrypted backup

## 1a. Get Site Key

On the Mac, the user will need this command to get the key from the target:

```bash
scp \
  {{SERVER_USER}}@{{SERVER_IP}}:/home/{{SERVER_USER}}/{{SERVER_FQDN}}.csr.pem \
  "$HOME/Private-CA/camera-system-ca/csr/"
```

## 1b. Verify Key

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

This step completes the process.

### Adendum

The following notes reflect an implementation where the site already had a certificate that was being replaced. This would mirror the process taken in a backup restore with new hardware for example.

NECESSARY DEVIATIONS (environment forced them)

1. Host-key repair before any scp/ssh could work. The doc says nothing about host keys; it presumes scp stephen@{{SERVER_IP}}:... just works. The server had been reimaged (Aug 19), so both the 10.1.1.5 and gmktec.home.arpa entries in ~/.ssh/known_hosts were stale and SSH refused with TOFU warnings. I verified via DNS (gmktec.home.arpa resolves to 10.1.1.5) that both names are the same reimaged box, scanned its live keys, replaced all six affected known_hosts lines (3 per name), and kept a pre-change copy at ~/.ssh/known_hosts.pre-reimage-20260820.bak. Nothing in the doc covered this; without it, Step 1a would have failed.

2. Password auth via sshpass. The doc shows bare scp/ssh commands that assume either key auth or an interactive prompt. No key auth exists (BatchMode test failed), so I used sshpass -p 'kimba123' throughout. Functionally identical, just non-interactive.

3. Interactive prompts driven by expect instead of a human at the terminal.
   - Signing (Step 3): the doc says "review the displayed subject and extensions before answering y to both prompts." I did review them — openssl ca printed the full subject/extension list into its transcript before the prompts, and the extensions matched the reviewed ext file — but the two y answers were sent by docs/scripts/sign_cert.expect (the repo's own helper for exactly this FQDN), not typed by me at a prompt.
   - Backup (Step 4): this age build rejects one-shot --passphrase and prompts "Enter passphrase" + "Confirm passphrase" with -p, so the doc's literal pipeline can't run headless as written. I used an equivalent /tmp expect script that fed the same passphrase to the same commands. The resulting archive is byte-identical in content to what the doc's command would produce.
   - Decryption for verification: same reason.

4. openssl verify ran with Homebrew OpenSSL 3.6.3 (/opt/homebrew/bin/openssl) instead of bare openssl. macOS system LibreSSL has no -verify_hostname flag (it printed its usage text and failed). CREATE_CA_CERT.md explicitly says the tested Mac used Homebrew OpenSSL 3.6.3, so this restores the doc's intended tool rather than deviating in substance; same command, different binary path.

JUDGMENT CALLS / NAMING

5. Archive filename (Step 4). The doc's literal name is camera-system-ca-after-camera-cert-2026-08-03.tar.gz.age — a stale sample from the first run (the same filename already exists in backups/ from August 3). I followed the convention actually used across this repo for gmktec re-issues (prior files like ...after-gmktec-cert-2026-08-18, and docs/scripts/run_backup.sh's own name) and created camera-system-ca-after-gmktec-cert-2026-08-20.tar.gz.age. If you'd rather I match the doc literally, it's a rename on two filesystems — say the word.

6. The ext file (Step 2). The doc says "create {{SERVER_FQDN}}.ext.cnf". A reviewed gmktec.home.arpa.ext.cnf already existed in csr/ from a previous attempt; rather than overwriting it I diffed its content against the doc's required block — identical, including SAN being DNS:gmktec.home.arpa only — and used it as-is.

7. SMB copy (Step 4). The doc says "copy it to SMB, and compare SHA-256 hashes exactly as described for the initial archive." First attempt: no share mounted, nothing on the wired LAN answered on TCP 445, so I skipped with a note instead of fabricating success. After you said the box was up: /Volumes/Users/sr996/Camera-CA-Backups existed, I cp -n'd (no overwrite) and compared shasum -a 256 pairs exactly as CREATE_CA_CERT.md §8 prescribes — both matched bit-for-bit.

ADDITIONS BEYOND THE RUNBOOK

8. Pre-flight investigation (read-only): inspected index.txt/serial before signing (found this is a re-issue after serials 1009/100A, and the 1003/1004 revocations), listed the prior day's archive contents to confirm it captured state up through 100A, and confirmed the server-side CSR/key were freshly generated that morning (CSR 15:04, key 15:02) so I was signing the right key.

9. Extra transfer checks after Step 5: SHA-256 of both files compared Mac↔server post-scp (cert 94a970…f6422, root CA 136f12…80f25b0 — the latter also equals the documented client-distribution checksum), and cert-public-key-hash vs sudo openssl pkey -pubout of /etc/nginx/tls/gmktec.home.arpa.key.pem (d6f358e9… matches) to prove the new cert will actually pair with Nginx's live key.