# Keycloak backup and restore

This is the shared procedure for Keycloak recovery points. KEYCLOAK.md,
STREAM_AUTH.md, ADD_USER.md and ADD_CLIENT_ON_SERVER.md identify when to run
it and which changes must be included. Resolve `{{BACKUP_PATH}}` from the
installation inputs, not historical logs.

Install the generic backup script and one-shot service using KEYCLOAK.md §14.
The service creates a local database dump only; archiving and publication to
the backup share below are also required. Initial installation must pass
KEYCLOAK.md §15's isolated restore test before its post-login checkpoint.

## Layout and scope

Store all Keycloak recovery points in one history, independent of the
runbook that triggered them:

```text
{{BACKUP_PATH}}/keycloak/YYYYMMDDHHMMSSZ/
    keycloak.tar
    keycloak-postgres.tar
    metadata.txt
    SHA256SUMS
```

Generate the directory timestamp at capture time with `date -u +%Y%m%d%H%M%SZ`.
It is UTC and includes seconds. Never reuse a runbook-start timestamp or
overwrite an existing checkpoint. Serialize checkpoint operations; if the
name already exists, stop and retry with a new timestamp. Do not mutate
Keycloak or its configuration during capture.

This document defines the Keycloak backup layout. Historical BACKUP.md
entries are inventory evidence, not backup or restore instructions. Do not
write these two archives into `keycloak-*`, `stream-auth-*`, `add-user-*`, or
`add-client-on-server-*` folders, and do not archive runbook copies.

## Create a checkpoint

1. Verify that the intended backup share is mounted and writable. Create
   `{{BACKUP_PATH}}/keycloak/` if needed. Prepare a uniquely named hidden
   staging directory under that parent; never use a final timestamp directory
   for an incomplete backup. Restrict access because both archives contain
   secrets. Record the existing local dump filenames before starting.
2. Invoke the installed one-shot service:

   ```bash
   sudo systemctl start keycloak-postgres-backup.service
   sudo systemctl show keycloak-postgres-backup.service -p Result -p ExecMainStatus
   ```

   Require success and exactly one new, nonempty dump under
   `/var/backups/keycloak-postgres/`, mode 0600, root:root. Identify the new
   file by comparison with the pre-run listing; do not silently use an older
   dump when this invocation fails. No timer is required. The service only
   creates the local dump; the remaining steps are mandatory.
3. Archive `/opt/keycloak/` as `keycloak.tar`, with archive paths rooted at
   `keycloak/` (create with `-C /opt keycloak`). Include Compose configuration,
   `.env`, and account `.pass` files; preserve ownership, modes, ACLs and
   xattrs. Verify secret files are mode 0600 and Compose configuration mode
   0640 before capture. Exclude token files; never copy tokens from client
   caches. Do not print secret contents.
4. Archive **only the new dump** as `keycloak-postgres.tar`, with a single
   file at `keycloak-postgres-backups/<dump-basename>.dump`. Preserve its
   root ownership and 0600 mode. Use a protected temporary directory or an
   explicit tar path transform to produce this archive root. Do not archive
   the complete local dump history again. Each checkpoint is a full snapshot
   and requires no earlier checkpoint to restore its database.
5. Write `metadata.txt` with the UTC capture time, triggering runbook or
   maintenance operation, exact dump basename, Keycloak/PostgreSQL image
   versions (including oauth2-proxy when present), and verification results. Record configuration changes and
   references to applicable nginx/systemd backups. Passwords, tokens, `.env`
   values, and database contents must not appear in metadata or logs.
6. Verify both archived files can be listed and contain the required members.
   Read the dump back from the staged archive into a protected temporary file
   and require successful `pg_restore --list` with catalog output suppressed
   (use the PostgreSQL container if necessary). Propagate failure and remove
   temporary files. Do not treat a catalog check as a full restore test;
   retain KEYCLOAK.md §15's isolated restore test requirement for initial
   installation.
7. Generate `SHA256SUMS` covering `keycloak.tar`, `keycloak-postgres.tar`, and
   `metadata.txt`, and run `sha256sum -c SHA256SUMS` against the files on the
   share. Only after all checks pass, rename the staging directory to its
   final UTC timestamp, within the same parent and without replacing an
   existing destination. Failed staging directories are not recovery points.
   Preserve completed checkpoints unchanged; local dump pruning must not
   prune this off-host history.

The archive pair recovers `/opt/keycloak/` configuration and database state.
Host packages, external mounts, CA recovery, nginx, and other systemd units
remain separate prerequisites recorded in metadata. For coordinated nginx
and Keycloak changes, prepare both checkpoint paths before generating their
metadata/checksums and record the compatible pair; publish only after each
checkpoint's checks pass. Do not mutate a completed checkpoint to add links.

## Restore a checkpoint

1. Select the lexicographically newest completed directory whose name matches
   fourteen digits followed by `Z`. Ignore hidden staging directories. Verify
   `SHA256SUMS` and require both archives and metadata. A missing file or failed
   checksum stops recovery; selecting an older checkpoint is an explicit
   recovery decision. Use both archives from the same directory.
2. Inspect the selected archives in a protected temporary directory. Reject
   absolute paths, `..` traversal and symlinks that redirect extraction outside
   the intended destination. Require configuration paths rooted at `keycloak/`
   and exactly the dump named in metadata under `keycloak-postgres-backups/`.
   Check the dump catalog without printing its contents. Select compatible
   PostgreSQL and Keycloak image versions from metadata; recovery and software
   upgrades are separate operations. Account for Compose mounts and other
   external configuration dependencies before proceeding.
3. Prepare Docker/Compose, required service accounts, CA trust, and the
   non-nginx host units referenced in metadata. Nginx configuration, public TLS
   material, and nginx-specific unit overrides use NGINX_BACKUP.md. Recover or
   reissue the server private key through SITE_CERT.md; it is not in these
   archives. Check compatibility between the chosen nginx and Keycloak states.
4. On a replacement host, prepare a clean `/opt/keycloak/` destination. For
   an explicitly authorized in-place restore, first preserve the existing
   configuration and database and stop Keycloak and oauth2-proxy writers.
   Extract `keycloak.tar` with `/opt` as the base, rather than layering it over
   stale files. Verify root ownership, directory mode 0750, secrets mode 0600,
   and Compose configuration mode 0640. Never print `.env` or password files.
5. Start only PostgreSQL from the recovered Compose configuration and wait
   for health. Keep Keycloak and oauth2-proxy stopped. Confirm the exact
   database/volume selected for recovery and require an empty destination
   database owned by the configured database user. On a fresh host, PostgreSQL
   initialization may already create that database. Stop on unexpected data;
   do not ignore errors or blindly drop an existing database. Do not run
   Keycloak first to initialize the schema.
6. Extract the exact selected dump to protected temporary storage and restore
   it using the compatible PostgreSQL container's `pg_restore` with
   `--username=keycloak --dbname=keycloak --exit-on-error`. Read root-only files
   through a root shell or `sudo cat`; an unprivileged shell redirect cannot
   read them. Preserve pipeline failure status and stop on any restore error.
   Verify expected realms, users, clients and policies without exposing
   credentials. A successful catalog listing alone does not prove recovery.
   Remove temporary dump copies after validation.
7. Install the repository's `scripts/backup-keycloak-postgres` and recreate
   its one-shot service using KEYCLOAK.md §14. No archived script is required.
   Restore necessary non-nginx units from their recorded source; inspect
   archive roots and exclude nginx-specific overrides from any legacy whole-
   system unit archive. Reload systemd after installing units. The selected
   nginx checkpoint owns its exact override set, including recorded absence.
8. Start Keycloak and wait for internal readiness. Restore/start nginx through
   NGINX_BACKUP.md. If oauth2-proxy is configured, start it once Keycloak
   discovery through nginx's public `/auth/` origin works, then verify its
   health. This ordering avoids waiting for oauth2-proxy before nginx can
   expose the discovery endpoint it needs.
9. Verify the public issuer/discovery document, expected unauthenticated MCP
   response, and the restored users/clients/policies. If browser authentication
   is configured, run STREAM_AUTH.md's functional verification, checking login
   and denied/unauthenticated access. Reauthenticate client applications as
   needed; client token caches are not recovery inputs. Do not declare the
   system ready until the applicable authentication and service checks pass.
10. Record actual recovery results outside the immutable checkpoint. Changes
    made during recovery, including new registrations or certificates, require
    fresh checkpoints after verification. Preserve the selected recovery point.

