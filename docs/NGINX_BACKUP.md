# Nginx backup and restore

This is the shared procedure for nginx configuration checkpoints. All runbooks
that change nginx use this history, including MEDIAMTX, SNAPSHOT, APPS,
MCP_HTTP, SITE_CERT, CA_DISTRIBUTE, KEYCLOAK, and STREAM_AUTH. Resolve
`{{BACKUP_PATH}}` from the installation's supplied values, not a historical log.

Only the `Create a checkpoint` workflow is currently implemented as a script:

```bash
scripts/NGINX_BACKUP/nginx_backup_runbook.sh
```

That script is the single source of truth for executable checkpoint actions. The
restore procedure remains documented guidance until a restore script is added.

## Required Values

| Symbol | Description |
|---|---|
| `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server |
| `{{BACKUP_PATH}}` | Mounted backup root |

## Layout and scope

```text
{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/
    nginx.tar
    metadata.txt
    SHA256SUMS
```

Generate the UTC capture timestamp with `date -u +%Y%m%d%H%M%SZ`. Each directory
is one complete configuration snapshot, not a delta or one runbook's edits. Keep
completed checkpoints unchanged. Serialize captures and refuse an existing name;
retry with a fresh timestamp rather than replacing an earlier checkpoint.

`nginx.tar` has paths relative to `/`, rooted at `etc/nginx/`, plus any
`etc/systemd/system/nginx.service` override and
`etc/systemd/system/nginx.service.d/` drop-ins that exist. It includes active
configuration, conf.d, both sites directories, snippets, module configuration,
MIME/parameter files, public TLS certificates/chain/CA/CSR, and required external
configuration inputs that nginx references.

Private TLS keys are never archived. The checkpoint excludes private keys,
`/etc/nginx/backups/`, default sites, rollback files, runbook copies, logs, and
temporary inspection directories. Treat the backup as sensitive even though TLS
private keys are excluded: nginx configuration may contain authentication data.

## Create a checkpoint (AGENT-run)

Run with resolved values:

```bash
cd {{REPO_PATH}}
scripts/NGINX_BACKUP/nginx_backup_runbook.sh create-checkpoint \
  --server-fqdn {{SERVER_FQDN}} \
  --backup-path {{BACKUP_PATH}} \
  --trigger KEYCLOAK.md
```

When a coordinated Keycloak checkpoint path is already known, pass it explicitly
so metadata records the compatible pair:

```bash
cd {{REPO_PATH}}
scripts/NGINX_BACKUP/nginx_backup_runbook.sh create-checkpoint \
  --server-fqdn {{SERVER_FQDN}} \
  --backup-path {{BACKUP_PATH}} \
  --trigger KEYCLOAK.md \
  --compatible-keycloak-checkpoint /mnt/camera-backup/keycloak/YYYYMMDDHHMMSSZ
```

The script performs the checkpoint workflow:

- verifies `nginx -t`, active HTTPS listener evidence, enabled-site inventory,
  and nginx unit override state;
- refuses a checkpoint when the default site is enabled, a rollback/backup file
  is loaded, or no `listen 443 ssl;` route is active;
- confirms the backup path is mounted and writable;
- creates a unique hidden staging directory under `{{BACKUP_PATH}}/nginx/`;
- builds a reviewed manifest of root-relative files and symlinks rather than
  archiving `/etc/nginx` as a recursive directory operand;
- includes public TLS material, active nginx files, nginx-specific systemd
  overrides, `/etc/onvif-mcp` JSON files, and `/srv/camera-pki/public` files
  where present;
- rejects private keys, default sites, rollback files, and `/etc/nginx/backups/`;
- archives the exact manifest into `nginx.tar` and verifies the archive member
  list matches the manifest exactly;
- scans archive contents for unsafe paths and private-key material;
- writes no-secret `metadata.txt` with package/version data, service-user and
  unit-override state, active vhost evidence, public certificate details,
  exclusions, external dependency notes, and compatible Keycloak checkpoint
  references;
- writes and verifies `SHA256SUMS`;
- atomically renames the hidden staging directory to the final UTC timestamp
  directory.

Failed staging directories are not recovery points. If metadata is wrong or the
archive contains an excluded file, create a newer checkpoint; do not edit a
completed one in place.

## Inspect checkpoint status (AGENT-run)

```bash
cd {{REPO_PATH}}
scripts/NGINX_BACKUP/nginx_backup_runbook.sh status \
  --backup-path {{BACKUP_PATH}}
```

## Restore from checkpoint

Restore is not yet scripted. If recovery is required, add a restore subcommand
before doing production recovery. The restore workflow must preserve these
principles:

1. Select one completed checkpoint directory matching exactly fourteen digits
   followed by `Z`; ignore hidden staging directories.
2. Require `nginx.tar`, `metadata.txt`, and `SHA256SUMS`, and require
   `sha256sum -c SHA256SUMS` to pass.
3. Inspect metadata, archive member paths, symlinks, and private-key exclusion
   before touching `/etc/nginx`.
4. Prepare compatible nginx packages/modules, the configured service user,
   application web roots, `/etc/onvif-mcp` JSON files, `/srv/camera-pki/public`,
   upstream services, Keycloak, and oauth2-proxy where applicable.
5. Recover or reissue the live TLS private key/certificate pair through
   SITE_CERT.md before restoring nginx. Private keys are not in `nginx.tar`.
6. Preserve the current `/etc/nginx`, nginx-specific systemd overrides, and live
   TLS material in protected rollback storage before an authorized restore.
7. Restore into a clean `/etc/nginx` tree, not over stale files. Remove nginx-
   specific local unit overrides if the archive records their absence.
8. Reinstall matching live TLS material after extraction so archived public
   certificates do not overwrite a newly reissued matching pair.
9. Validate nginx before start, start nginx, verify public Keycloak discovery,
   then start oauth2-proxy if present.
10. Run final route and access-control checks for `/auth/`, `/ca/`, protected
    web routes, snapshots/WebRTC, and `/mcp` according to the selected
    checkpoint's auth state.
11. Create a fresh checkpoint after any recovery-time adaptation.

## Pitfalls and notes

- Do not capture private keys, even if they are hidden, renamed, or referenced
  indirectly by an active configuration.
- Do not feed directory operands to tar for this workflow; directory recursion
  can re-add excluded files.
- No rollback or backup file should be loaded by nginx at checkpoint time.
- Do not create `final-etc-nginx-*.tar` artifacts in procedure-named folders;
  the shared checkpoint history is `{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/`.
