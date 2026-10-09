# Camera CA Client Distribution Runbook

## Purpose

Distribute the public `Camera System Root CA` certificate from the camera server
to client computers on the private LAN.

The distribution endpoint is intentionally HTTP because a new client cannot trust
the camera server's HTTPS certificate until it first obtains and installs the
private root CA.

Only the public CA certificate is distributed. No private key, CA database,
server key, password-store backup, or encrypted CA archive is exposed.

The executable workflow lives in:

```bash
scripts/CA_DISTRIBUTE/ca_distribute_runbook.sh
```

That script is the single source of truth for executable actions. Do not replace
it with ad hoc shell fragments from this document. This document is the agent
script: it defines sequencing, safety checks, expected outputs, and how to invoke
the script with resolved site values.

## Required Values

| Symbol | Required value |
|---|---|
| `{{SERVER_FQDN}}` | Canonical DNS name used by clients and the TLS certificate |
| `{{SERVER_IP}}` | Server IP address hosting the distribution endpoint |
| `{{ALLOWED_SUBNETS}}` | **Optional** comma separated list of allowed subnets, e.g. `10.1.1.0/24,192.168.68.0/22` |

## Final layout

```text
/etc/nginx/tls/
└── camera-system-root-ca.crt.pem       Public CA verification copy from SITE_CERT.md

/srv/camera-pki/public/
├── camera-system-root-ca.crt.pem       Public CA certificate, PEM filename
├── camera-system-root-ca.crt.pem.sha256
├── camera-system-root-ca.crt           Same PEM bytes with shorter client-friendly extension
├── camera-system-root-ca.crt.sha256
└── README.txt                          Client download and verification instructions
```

The copy under `/srv/camera-pki/public` is the deliberately managed
client-distribution copy. The authoritative CA state remains under the private CA
workspace and in encrypted backups created by earlier runbooks.

## Agent Presentation Rules

Before presenting or executing any command, replace every double-curly placeholder
with the real site value. Do not ask the user to type or edit placeholders such
as `{{SERVER_FQDN}}` or `{{SERVER_IP}}`.

When a USER-run command invokes a repository script, include `cd <repo>/onvif-mcp`
as the first line after resolving the repository path. This runbook normally has
no interactive user-run steps.

## Security model and hard rules

1. Distribute only `/etc/nginx/tls/camera-system-root-ca.crt.pem`.
2. Never copy private keys, CA database files, CSRs, serial files, encrypted
   archives, password-store backups, passwords, or passphrases into
   `/srv/camera-pki/public`.
3. Keep `/ca/` available over HTTP for bootstrap, but redirect all other HTTP
   paths to HTTPS.
4. Disable directory browsing.
5. If `{{ALLOWED_SUBNETS}}` is set, restrict `/ca/` to only those comma-separated
   client subnets. If `{{ALLOWED_SUBNETS}}` is omitted or empty, leave `/ca/`
   reachable from any subnet.

## 1. Publish the public CA certificate (AGENT-run)

Run the script with resolved values:

```bash
cd {{REPO_PATH}}
scripts/CA_DISTRIBUTE/ca_distribute_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}} \
  --allowed-subnets {{ALLOWED_SUBNETS}}
```

Omit the `--allowed-subnets` line when `{{ALLOWED_SUBNETS}}` is empty.

The `apply` command performs the full workflow:

- verifies required tools;
- creates `/srv/camera-pki/public` as root-owned mode `755`;
- installs the public CA certificate as both
  `camera-system-root-ca.crt.pem` and `camera-system-root-ca.crt`;
- verifies both distributed certificate filenames contain identical bytes;
- creates and verifies `.sha256` files for both filenames;
- writes `README.txt` with concrete download URLs, file SHA-256, and certificate
  SHA-256 fingerprint;
- rewrites the port-80 nginx camera server block so `/ca/` serves only
  `/srv/camera-pki/public/`, directory listing stays disabled, and all other
  HTTP paths redirect to HTTPS;
- runs `nginx -t`, reloads nginx, verifies the distribution files, and tests all
  HTTP endpoints with explicit `--resolve`.

## 2. Verify final state (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/CA_DISTRIBUTE/ca_distribute_runbook.sh verify \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}}
```

Then inspect non-secret status:

```bash
cd {{REPO_PATH}}
scripts/CA_DISTRIBUTE/ca_distribute_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --server-ip {{SERVER_IP}}
```

Expected endpoint results:

```text
/ca/camera-system-root-ca.crt.pem          200
/ca/camera-system-root-ca.crt              200
/ca/camera-system-root-ca.crt.pem.sha256   200
/ca/camera-system-root-ca.crt.sha256       200
/ca/README.txt                             200
/cameras/                                  301
```

The `/cameras/` check confirms non-CA HTTP still redirects to HTTPS.

## Client URLs

After a successful run, clients can download the public CA and checksums from:

```text
http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem
http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt
http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem.sha256
http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.sha256
http://{{SERVER_FQDN}}/ca/README.txt
```

Clients should compare the certificate fingerprint in `README.txt` with a
separately trusted value supplied by the administrator before trusting the root
certificate.

## Maintenance

When the root CA certificate changes, rerun `apply` and then `verify`. The script
reinstalls the public CA copy, regenerates both checksum files, rewrites
`README.txt`, validates nginx, and retests all distribution endpoints.

## Pitfalls and notes

- The certificate and checksum are delivered over the same HTTP connection. The
  checksum detects accidental corruption but does not independently authenticate
  the certificate.
- Do not expose `/etc/nginx/tls` directly. Serve only the curated public files in
  `/srv/camera-pki/public`.
- If another runbook edits the port-80 camera server block, rerun this runbook so
  `/ca/` remains available while non-CA HTTP requests continue redirecting to
  HTTPS.
