# Site Certificate + HTTPS Deployment Runbook

## Purpose

Create and deploy the nginx TLS site certificate for the camera system, sign it
with the local private CA, back up the changed CA state, move nginx camera
endpoints to HTTPS, and update downstream URL producers/registries from HTTP to
HTTPS.

The executable workflow lives in:

```bash
scripts/SITE_CERT/site_cert_runbook.sh
```

That script is the single source of truth for executable actions. Do not replace
it with ad hoc shell fragments from this document. This document is the agent
script: it defines sequencing, user/agent boundaries, safety checks, and the
copy-paste prompts that must be shown when interactive user action is required.

## Required Values

| Name | Meaning |
|---|---|
| `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name |
| `{{SERVER_IP}}` | Server IP address used by clients for HTTPS |
| `{{SERVER_USER}}` | Account name for the agent and service ownership |
| `{{CA_ROOT_PATH}}` | Private CA root directory |
| `{{BACKUP_PATH}}` | Mounted SMB share path |
| `{{REPO_PATH}}` | Full path to this repository |
| `{{TIMESTAMP}}` | generated UTC timestamp, `YYYYMMDDhhmmssZ` |

Passphrases are not supplied as variables and must never be pasted into chat.
The script consumes the CA key passphrase from `pass` entry
`camera-ca/root-key-passphrase`. For the post-issuance CA archive, it creates a
new `camera-ca/age-archive-{{TIMESTAMP}}` entry if needed, backs up the password
store, and then creates the encrypted CA-state archive.

## Prerequisites

Complete `CREATE_CA_CERT.md` first. The local CA must exist on this same host:

```text
{{CA_ROOT_PATH}}/camera-system-ca/certs/camera-system-root-ca.crt.pem
{{CA_ROOT_PATH}}/camera-system-ca/private/camera-system-root-ca.key.pem
{{CA_ROOT_PATH}}/camera-system-ca/openssl.cnf
```

The backup path must be a real mounted CIFS filesystem, not just a local
directory or autofs placeholder. The script refuses to write CA backups unless a
concrete CIFS row exists for `{{BACKUP_PATH}}`.

## Agent Presentation Rules

Before presenting any USER-run command or executing any AGENT-run command,
replace every double-curly placeholder with the real site value. Do not ask the
user to type or edit placeholders such as `{{SERVER_FQDN}}`, `{{SERVER_IP}}`,
`{{CA_ROOT_PATH}}`, or `{{REPO_PATH}}`.

When a USER-run command invokes a repository script, include `cd {{REPO_PATH}}`
as the first line after resolving it to the real repository path. The user must
be able to copy and paste the prompt without modification.

The script never accepts passwords or passphrases as command-line arguments.
If GPG needs a passphrase, the user primes the GPG agent from their own terminal
using the scripted command in step 1.

## Security model and hard rules

1. The CA private key passphrase must come only from `pass`; do not type it into
   chat, command arguments, or files.
2. The nginx leaf key is unencrypted so nginx can start unattended. It is stored
   root-owned under `/etc/nginx/tls` with mode `600`.
3. The CA private key remains in the CA tree and is backed up only inside the
   encrypted CA-state archive.
4. Every certificate issuance changes CA state (`index.txt`, `serial`, and
   `newcerts/`) and therefore requires a fresh encrypted CA archive.
5. Keep public CA distribution separate from private-key handling. The script
   exposes only the public CA certificate under `/ca/camera-system-root-ca.crt.pem`
   on HTTP for client bootstrap.

## 1. Prime the GPG cache if interactive unlock is required (USER-run)

If the agent-side `apply` command cannot decrypt or write password-store entries
because GPG needs a pinentry prompt, stop and show the user this exact resolved
copy-paste block:

```bash
cd {{REPO_PATH}}
scripts/SITE_CERT/site_cert_runbook.sh prime-gpg-cache
```

Tell the user to enter the GPG passphrase in their terminal if prompted, and to
report when the command prints `prime-gpg-cache-ok`. Do not ask the user to paste
any passphrase or password into chat.

## 2. Issue and deploy the site certificate (AGENT-run)

Run the script with resolved values. Omit `--timestamp` unless continuing a known
attempt that already reserved a timestamp; otherwise the script generates one.

```bash
cd {{REPO_PATH}}
scripts/SITE_CERT/site_cert_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}} \
  --server-user {{SERVER_USER}} \
  --ca-root {{CA_ROOT_PATH}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

The `apply` command performs the full workflow:

- verifies packages, CA artifacts, password-store access, and the CIFS backup
  mount;
- creates `/etc/nginx/tls` root-owned mode `700`;
- generates `/etc/nginx/tls/{{SERVER_FQDN}}.key.pem` if missing;
- creates and verifies `/etc/nginx/tls/{{SERVER_FQDN}}.csr.pem` with SAN
  `DNS:{{SERVER_FQDN}}`;
- stages the CSR and reviewed extension file into the CA `csr/` directory;
- signs the CSR with the private CA and verifies chain, purpose, hostname, and
  key/certificate match;
- creates `camera-ca/age-archive-{{TIMESTAMP}}` if needed, backs up the password
  store, and creates an encrypted CA-state archive named
  `camera-system-ca-after-<server>-cert-{{TIMESTAMP}}.tar.gz.age`;
- installs the leaf, CA, and chain certificate files into `/etc/nginx/tls`;
- writes one HTTPS nginx server block in `/etc/nginx/conf.d/{{SERVER_FQDN}}.conf`;
- rewrites `/etc/nginx/sites-available/camera` to a port-80 redirect block while
  keeping HTTP public-CA download endpoints;
- reloads nginx and verifies port 443 is listening;
- updates `/etc/onvif-mcp/camera_registry.json` URLs to HTTPS;
- updates `/etc/onvif-mcp-http.env` `STREAM_SERVER_URL=https://{{SERVER_FQDN}}`
  and restarts `onvif-mcp-http` if that service is deployed;
- validates HTTPS endpoints with explicit `--resolve` and the private CA file.

Record the timestamp printed by `apply-ok timestamp=...`; later backup, restore,
and renewal references need it.

## 3. Verify final state (AGENT-run)

Run verification with the exact timestamp printed by `apply`:

```bash
cd {{REPO_PATH}}
scripts/SITE_CERT/site_cert_runbook.sh verify \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}} \
  --server-user {{SERVER_USER}} \
  --ca-root {{CA_ROOT_PATH}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}} \
  --timestamp {{TIMESTAMP}}
```

Then inspect non-secret status:

```bash
cd {{REPO_PATH}}
scripts/SITE_CERT/site_cert_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}} \
  --ca-root {{CA_ROOT_PATH}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

A complete run leaves these key artifacts:

```text
/etc/nginx/tls/{{SERVER_FQDN}}.key.pem
/etc/nginx/tls/{{SERVER_FQDN}}.csr.pem
/etc/nginx/tls/{{SERVER_FQDN}}.crt.pem
/etc/nginx/tls/{{SERVER_FQDN}}.chain.pem
/etc/nginx/tls/camera-system-root-ca.crt.pem
/etc/nginx/conf.d/{{SERVER_FQDN}}.conf
{{CA_ROOT_PATH}}/camera-system-ca/issued/{{SERVER_FQDN}}.crt.pem
{{CA_ROOT_PATH}}/camera-system-ca/csr/{{SERVER_FQDN}}.csr.pem
{{CA_ROOT_PATH}}/camera-system-ca/csr/{{SERVER_FQDN}}.ext.cnf
{{BACKUP_PATH}}/Camera-CA-Backups/camera-system-ca-after-<server>-cert-{{TIMESTAMP}}.tar.gz.age
{{BACKUP_PATH}}/Camera-CA-Backups/password-store-backup-{{TIMESTAMP}}-site-cert-passphrase.tar.gz
```

## Validation expectations

The script requires these checks to pass before reporting success:

- `openssl verify -purpose sslserver -verify_hostname {{SERVER_FQDN}}` returns OK.
- The nginx key and issued certificate have matching public-key hashes.
- The encrypted post-issuance CA archive decrypts and contains the issued
  certificate, CSR, extension file, `index.txt`, and `serial`.
- `nginx -t` succeeds.
- Exactly two `server_name {{SERVER_FQDN}}` declarations exist: HTTP redirect and
  HTTPS service block.
- Port 443 is listening.
- `curl --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} --cacert ...` succeeds for
  `/cameras/`, `/multiview/`, and `/outputs/camera_registry.json`.
- HTTP `/cameras/` returns a 301 redirect to HTTPS.
- `openssl s_client` verifies the served certificate against the private CA.

## Renewal procedure

At renewal time, rerun the same script. If the existing nginx key remains secure,
keep it and issue a new certificate from a new CSR. If rotating keys, remove or
archive the old `/etc/nginx/tls/{{SERVER_FQDN}}.key.pem` first, then rerun
`apply`. After renewal, run this runbook's `verify` command and then the nginx
backup/checkpoint runbook so the new public certificate and CA backup reference
are captured.

## Pitfalls and notes

- Do not pin nginx `listen` to `{{SERVER_IP}}:443`; use `listen 443 ssl;` so
  nginx does not race interface address assignment at boot.
- Do not duplicate executable OpenSSL, age, or nginx snippets in this runbook.
  Update `scripts/SITE_CERT/site_cert_runbook.sh` instead.
- Keep `/ca/camera-system-root-ca.crt.pem` available over HTTP for client trust
  bootstrap. Do not expose private keys or encrypted archives through nginx.
- If GPG-agent cache expires mid-run, use the scripted USER-run
  `prime-gpg-cache` command and resume with the same timestamp rather than
  creating a new partial issuance.
