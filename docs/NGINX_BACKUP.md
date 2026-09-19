# Nginx backup and restore

This is the shared procedure for nginx configuration checkpoints. All runbooks
that change nginx use this history, including MEDIAMTX, SNAPSHOT, APPS,
MCP_HTTP, SITE_CERT, CA_DISTRIBUTE, KEYCLOAK, and STREAM_AUTH. Resolve
`{{BACKUP_PATH}}` from the installation's supplied values, not a historical log.

## Layout and scope

```text
{{BACKUP_PATH}}/nginx/YYYYMMDDHHMMSSZ/
    nginx.tar
    metadata.txt
    SHA256SUMS
```

Generate the UTC capture timestamp with `date -u +%Y%m%d%H%M%SZ`. Each directory
is one complete configuration snapshot, not a delta or one runbook's edits.
Keep completed checkpoints unchanged. Serialize captures and refuse an existing
name; retry with a fresh timestamp rather than replacing an earlier checkpoint.

`nginx.tar` has paths relative to `/`, rooted at `etc/nginx/`, plus any
`etc/systemd/system/nginx.service` override and
`etc/systemd/system/nginx.service.d/` drop-ins that exist. It includes the main
configuration, conf.d, both sites directories, snippets, module configuration,
MIME/parameter files, and public TLS certificates/chain/CA/CSR. Preserve
ownership, permissions, ACLs, xattrs, and symlinks without dereferencing them.
Record the absence of nginx-specific unit overrides as well as their presence.
Do not capture unrelated systemd units or rely on a prior checkpoint for them.

**Private TLS keys are never archived.** Inventory all `ssl_certificate_key`
paths and inspect the proposed archive inputs for key copies, including hidden
files, renamed keys, and old configuration backups. Use an explicit reviewed
file manifest; a `*.key` filename exclusion alone is not sufficient. Exclude
private keys and obsolete scratch/rollback copies such as `/etc/nginx/backups/`
from the manifest. If an active configuration depends on one of those files,
resolve that dependency before capture; do not silently omit active configuration.
Preserve public TLS material only. No runbook copies are included.

An nginx configuration can reference files outside `/etc/nginx`. Inventory
`include`, certificate, authentication-file, module, and symlink targets and
account for every external dependency in metadata. Required configuration
files outside the tree must be included in the archive at their original
root-relative paths, except private keys; review these files for secrets too.
Package-owned modules/binaries are reinstalled using the recorded package
versions, not bundled in the archive. Record external web roots, CA distribution
content, upstream services, and Keycloak checkpoint references separately.
An unaccounted dependency makes the checkpoint incomplete. Treat the backup as
sensitive even though TLS private keys are excluded: nginx configuration may
contain authentication data.

## Create a checkpoint

1. Complete the originating runbook's configuration and endpoint checks.
   Require `sudo nginx -t` success. Verify the default site is disabled and,
   for HTTPS stages, the intended unpinned HTTPS listener is present. Inspect
   active includes for accidental backup files or duplicate vhosts. Do not
   publish an unverified or partially configured state as a completed checkpoint.
2. Confirm the intended backup share is mounted and writable. Create a unique
   hidden staging directory under `{{BACKUP_PATH}}/nginx/`, with restricted
   access. Freeze nginx configuration changes during capture. Record the UTC
   capture time, triggering runbook/maintenance operation, nginx package and
   module versions, required service user, selected Keycloak checkpoint (if
   used), external dependencies, public certificate identities, and exclusions
   in `metadata.txt`. Do not record private keys, passwords, or token values.
3. Create `nginx.tar` using the reviewed manifest, `-C /`, and tar's ownership,
   permissions, ACL/xattr preservation options. Do not follow symlinks. Include
   all current configuration, even directories untouched by this runbook.
   Compare the archived members against the manifest and check symlink targets.
4. Read back the archive from the share into a protected temporary inspection
   directory. Verify archive paths are relative and contain no `..` traversal,
   expected files and modes are present, all private-key exclusions hold, and
   the archived configuration matches the captured source. Re-run `nginx -t`
   while the source remains unchanged. Do not run an extracted nginx config
   directly against the live host: absolute includes may test live files.
   A readable archive and syntax check are not an isolated restore test.
5. Generate `SHA256SUMS` for `nginx.tar` and `metadata.txt`; verify it on the
   share with `sha256sum -c SHA256SUMS`. Record validation results before
   generating checksums. Rename the staging directory to its final timestamp
   within the same parent only after success, without replacing any existing
   destination. Failures remain unpublished. Remove protected temporary files.

Take a fresh checkpoint after each later nginx configuration or public
certificate change, including certificate renewal. A pre-change rollback copy
may be kept locally outside nginx include paths, but is not a completed
post-change checkpoint. Do not create `final-etc-nginx-*.tar` artifacts in
procedure-named folders. Other backup targets retain their own procedures.

## Restore a checkpoint

1. Select the lexicographically newest completed directory matching exactly
   fourteen digits followed by `Z`. Ignore hidden staging directories. Verify
   both required files and `SHA256SUMS`; stop on failure. Choosing an older
   recovery point is an explicit recovery decision, not an automatic fallback.
   Restore one snapshot; do not merge nginx artifacts from procedure folders.
2. Inspect metadata and archive members in a protected temporary directory.
   Install compatible nginx packages/modules and create the required service
   user. Restore web content, CA distribution files, upstream services and any
   external dependencies using the recorded sources. Check compatibility with
   the chosen Keycloak checkpoint; newer independent histories need not describe
   a mutually compatible application state.
3. Recover TLS credentials through SITE_CERT.md: reuse a surviving private key
   only after verifying it matches the certificate, otherwise generate a new
   key and reissue through the restored CA. Private keys are not in nginx.tar.
   Keep recovered/reissued key and matching certificate files in protected
   staging until after installing the archived configuration.
4. During the authorized restore window, stop nginx and preserve the current
   `/etc/nginx` tree and nginx-specific systemd overrides in a protected local
   rollback location outside all include paths. Restore into a clean
   `/etc/nginx` tree, not over an existing tree: extraction alone cannot remove
   obsolete sites or package-created defaults. Restore the archived override
   set exactly, including recorded absence, without changing unrelated units.
   Handle inventoried external configuration files explicitly and preserve
   rollback copies. Validate member paths and symlinks before extraction; never
   let an archive symlink redirect extraction outside its intended destination.
5. Install the recovered/reissued TLS material at the configured paths, with
   keys root-owned mode 0600. A newly issued certificate replaces the archived
   public certificate; do not overwrite it with the old one afterward. Ensure
   external include and module targets exist and the default site is disabled.
   Verify the intended HTTPS listener is unpinned. Run `systemctl daemon-reload`
   if units were restored, then require `nginx -t` success before starting nginx.
6. Start nginx. If oauth2-proxy requires Keycloak discovery through nginx,
   make Keycloak ready first, start nginx to expose `/auth/`, then start
   oauth2-proxy and wait for health. Only then verify the routes and access
   controls recorded for this
   checkpoint: HTTP redirects, `/ca/`, TLS hostname/chain, and, where deployed,
   `/auth/`, `/oauth2/`, `/mcp`, camera pages and snapshots. Check both allowed
   requests and expected authentication/denial behavior. If verification fails,
   stop and diagnose or restore the preserved configuration and matching TLS
   material; never repair by layering older stage archives over this snapshot.

