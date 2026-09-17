### Keycloak OAuth server

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/KEYCLOAK.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{SERVER_IP}}`: `10.1.1.5`
- `{{REPO_PATH}}`: `/home/stephen`
- `{{SERVER_USER}}`: `stephen`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Deployment constants (KEYCLOAK.md §1, non-secret):

- Realm `mcp`, scope `mcp:tools`, login user `mcp-user`, admin `keycloak-admin`
- Images pinned: `postgres:17-alpine`, `quay.io/keycloak/keycloak:26.7.0`
- Docker 29.1.3, Docker Compose 2.40.3 (Ubuntu `docker.io` + `docker-compose-v2`)

Backup folder (actual, 2026-09-16):

- `{{BACKUP_PATH}}/keycloak-20260916-175524`

NOTE: the pre-change archives in this folder were staged at stage close (the
folder is created after the work per §15b): pre-change conf.d is the
runbook-mandated `.pre-keycloak` copy; pre-change sites/systemd are live trees
with this stage's additions removed. The previous build's keycloak entry in
this log (old UUIDs `51738624-…`/`c7bc563d-…`) was a laboratory artifact of an
earlier build — all IDs below are from THIS deployment.

Backed up data:

- `pre-change-state.txt` — hostname/DNS/IP, docker absent, nginx, listener table (80/443 nginx, 8001 MCP loopback, 8080 free), `/opt/keycloak` absent.
- `etc-nginx-conf.d.tar` / `etc-nginx-sites-available.tar` / `etc-nginx-sites-enabled.tar` — pre-change nginx configs (no `/auth/` locations).
- `etc-systemd-system.tar` — pre-change systemd tree (no keycloak backup unit, no MCP oauth drop-in).
- `post-change-state.txt` — variable mapping, file modes, container state, pinned image IDs, realm settings, realm users, client scope + mapper JSON, DCR policy component configs, active Hermes DCR client_id, nginx `server_name` count, listener table, MCP OAuth env (drop-in lines only, non-secret), endpoint verification results, regression checks, dump listing, restore-test evidence, CA trust file, Hermes token file modes (contents never recorded).
- `final-opt-keycloak.tar` — final `/opt/keycloak/` (root `keycloak/`, restore with `-C /opt`) including `compose.yaml`, `.env`, `admin.pass`, `mcp-user.pass`. Sensitive: contains the PostgreSQL password and both account passwords in root-only files; restore must re-apply mode 750 dir / 600 secrets. Contains NO token files.
- `final-var-backups-keycloak-postgres.tar` — the dump set (root `keycloak-postgres-backups/`): `keycloak-20260916T215030Z.dump` (custom format, zstd, 520 catalog entries). Sensitive: contains password hashes, the DCR registration access token, and the active Hermes client registration. This is the database restore source.
- `final-usr-local-sbin-backup-keycloak-postgres.tar` — backup script (mode 750).
- `final-etc-systemd-system.tar` — complete `/etc/systemd/system` tree including `keycloak-postgres-backup.service` and `onvif-mcp-http.service.d/oauth.conf`. Newest complete systemd set — restore last.
- `final-etc-nginx-conf.d.tar` / `-sites-available.tar` / `-sites-enabled.tar` — final nginx configs with `/auth/` and `/.well-known/oauth-protected-resource/mcp`; newest complete nginx set — restore last among config-stage backups. conf.d is UNPINNED (`listen 443 ssl;` — the 2026-09-12-set pinned-listener problem does not recur from this archive).
- `final-etc-nginx-backups.tar` — `/etc/nginx/backups/` including the runbook-mandated `gmktec.home.arpa.conf.pre-keycloak` copy.
- `final-docs-KEYCLOAK.md`, `final-docs-BACKUP.md` — runbook + this log.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Installed `docker.io` 29.1.3 + `docker-compose-v2` 2.40.3+ds1.
- Deployed `/opt/keycloak/compose.yaml`: postgres:17-alpine (named volume `keycloak_keycloak_postgres_data`, not published) + keycloak 26.7.0 bound `127.0.0.1:8080`, relative path `/auth`, hostname `https://gmktec.home.arpa/auth`, xforwarded proxies, health endpoint.
- Permanent admin `keycloak-admin` (master, realm-level `admin` role, password in `/opt/keycloak/admin.pass` 600 root); bootstrap `admin` user deleted (id resolved before delete) and both `KC_BOOTSTRAP_ADMIN_*` variables removed from `.env` and `compose.yaml`; keycloak container force-recreated; CLI config re-established afterward.
- Realm `mcp`: ssoSessionIdle 28800, ssoSessionMax 604800, client sessions inherited (0), accessToken 300, `revokeRefreshToken=true`, `refreshTokenMaxReuse=0`; login user `mcp-user` (password in `/opt/keycloak/mcp-user.pass` 600 root).
- Client scope `mcp:tools` (uuid `172bba24-bd7c-44d0-b3b4-45b268d33f4e`) with all three attributes true; audience mapper `mcp-server-audience` (uuid `b375c484-f298-47d9-99da-ef3b7b76404f`) → `https://gmktec.home.arpa/mcp` (access+introspection claims, no id token).
- Anonymous DCR components (realm `mcp`): allowed-client-templates `d2f995ed-6db5-40ac-bdb4-c8aedc3a2df0` (`mcp:tools` + default scopes), trusted-hosts `eaea6b9f-9d50-4e02-a8e9-6c9e2e568161` (`localhost, 127.0.0.1, 172.18.0.1 (compose gateway), 10.1.1.5 (server LAN IP)`, both matching controls true), max-clients `dd100a3e-49ae-425e-bbc8-5209bd26e6a1` (20); consent-required `81b3ce31-44ff-4ee5-a1ea-881b030c288f` and scope (Full Scope Disabled) `c21cc43e-4612-4956-b776-26df797e09d0` present.
- nginx HTTPS vhost `/etc/nginx/conf.d/gmktec.home.arpa.conf` extended with `= /auth` 301, `/auth/` proxy to `127.0.0.1:8080/auth/`, and `= /.well-known/oauth-protected-resource/mcp` proxy to `127.0.0.1:8001`; existing `/mcp` proxy and HTTPS `/mcp/` redirect retained.
- Private CA installed to `/usr/local/share/ca-certificates/camera-system-root-ca.crt` (CA:TRUE verified); all endpoint checks without `-k`.
- MCP OAuth drop-in `/etc/systemd/system/onvif-mcp-http.service.d/oauth.conf` (issuer, resource URL, loopback HTTP JWKS).
- DCR smoke test passed (HTTP 201, scope `mcp:tools`); test client `temporary-dcr-verification` (`2ad904ca-30a3-46cd-b551-db871d5bc113`) verified by name then deleted; credential-bearing response file removed.
- Hermes `camera-new` OAuth client registered via isolated-home headless login (`HERMES_HOME=/tmp/hermes-login-home`, display vars unset, single flow, listener 127.0.0.1:27890; `scripts/kc-headless-login-driver.py` delivered the `?code=&state=` callback). Entry was first written under the name `camera-https` and renamed to `camera-new` (with its three token files) to match the downstream runbooks' `{{HERMES_SERVER_NAME}}`; `mcp.auto_reload_on_config_change=false` set; entry `enabled: true` after test. Token files at `~/.hermes/mcp-tokens/camera-new.*` (mode 600, never archived).
- PostgreSQL backup script + `keycloak-postgres-backup.service` (manual one-shot, 14-day retention); first dump `keycloak-20260916T215030Z.dump` (250148 bytes) taken after the real Hermes DCR client existed; isolated restore test into `keycloak_restore_test_20260916` passed (`realms=2 users=2 clients=14`) and test DB dropped.

Verification performed:

- Discovery 200 with exact issuer `https://gmktec.home.arpa/auth/realms/mcp`; `S256` in `code_challenge_methods_supported`; `mcp:tools` published; registration endpoint present.
- Unauthenticated `/mcp` → 401 with `resource_metadata=https://gmktec.home.arpa/.well-known/oauth-protected-resource/mcp`; protected-resource metadata JSON exact.
- DCR policies re-read per component ID (collection view collapses config to `{}`).
- `/cameras/`, `/multiview/`, registry, snapshot JPEG (1920×1080), WebRTC player regression all 200 over TLS; `server_name` count 2; unpinned-listener check 1 unpinned / 0 pinned.
- Postgres healthy; `pg_restore --list` catalog readable (520 entries); restore test row counts nonzero; dump archived to this folder.
- `hermes mcp test camera-new`: connects with saved state, 29 tools; no orphan DCR clients in realm `mcp` (active client `f3f20dfa-24ad-4929-9134-6caff61dc340` "Hermes Agent").
- `post-change-state.txt` scanned for secret leakage — one initial leak (base-unit camera credentials in the MCP env line) caught and removed before close; final file holds key names and non-secret values only.
- Backup checksums all passed (`sha256sum -c` clean; regenerated once after the state-file fix).

## Reconstructing the Keycloak OAuth server from backup

Use these instructions with `{{BACKUP_PATH}}/keycloak-{{DATETIME_STAMP}}`. This backup holds the newest complete nginx configs (restore them last among config-stage backups) and the only copy of the Keycloak secrets and database.

1. Install Docker and Compose, then restore the deployment directory (secrets included):

   ```bash
   sudo apt-get update
   sudo apt-get install -y docker.io docker-compose-v2
   BACKUP_DIR="{{BACKUP_PATH}}/keycloak-{{DATETIME_STAMP}}"
   # NOTE (2026-09-13 restore verification): the archive root is `keycloak/`, NOT `opt/...`.
   # Extract into /opt directly (`-C / opt` fails with "Not found in archive"):
   sudo mkdir -p /opt
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-opt-keycloak.tar" -C /opt
   sudo chown -R root:root /opt/keycloak
   sudo chmod 750 /opt/keycloak
   sudo chmod 600 /opt/keycloak/.env /opt/keycloak/admin.pass /opt/keycloak/mcp-user.pass
   sudo chmod 640 /opt/keycloak/compose.yaml
   ```

2. Start the stack (the compose file pins image tags; `up -d` pulls them) and wait for readiness:

   ```bash
   sudo docker compose --project-directory /opt/keycloak up -d
   curl --fail --retry 24 --retry-all-errors --retry-delay 5 \
     -sS -o /dev/null -w 'HTTP %{http_code}\n' \
     http://127.0.0.1:8080/auth/realms/master/.well-known/openid-configuration
   ```

   Note: the postgres data volume starts empty on a fresh host. Before or after first
   start, restore the database from the archived dump into it:

   ```bash
   # stop keycloak first if it already started against an empty DB
   sudo docker compose --project-directory /opt/keycloak stop keycloak
   sudo docker compose --project-directory /opt/keycloak exec -i postgres \
     createdb --username=keycloak keycloak 2>/dev/null || true
   sudo sh -c 'tar -xOf "$0" var/backups/keycloak-postgres/$(tar -tf "$0" | grep -o "keycloak-[^/]*\.dump$" | head -1 | xargs basename) 2>/dev/null | docker compose --project-directory /opt/keycloak exec -i postgres pg_restore --username=keycloak --dbname=keycloak --exit-on-error' "$BACKUP_DIR/final-var-backups-keycloak-postgres.tar"
   sudo docker compose --project-directory /opt/keycloak up -d keycloak
   ```

   Simpler alternative on a fresh host (RECOMMENDED — verified 2026-09-13): the dump tar's
   root is `keycloak-postgres-backups/`, not `var/backups/keycloak-postgres/`, and dumps are
   mode 600 root, so a plain `< file` redirect from an agent shell fails with permission
   denied. Extract, move into the canonical path, then pipe via sudo:

   ```bash
   sudo tar -xf "$BACKUP_DIR/final-var-backups-keycloak-postgres.tar" -C /var/backups
   sudo mkdir -p /var/backups/keycloak-postgres
   sudo mv -n /var/backups/keycloak-postgres-backups/*.dump /var/backups/keycloak-postgres/
   sudo rmdir /var/backups/keycloak-postgres-backups
   sudo chmod 700 /var/backups/keycloak-postgres
   # fresh postgres init already creates and owns the keycloak DB; drop+recreate for a
   # clean restore:
   sudo docker compose --project-directory /opt/keycloak exec -T postgres \
     psql --username=keycloak --dbname=postgres -c "DROP DATABASE keycloak;"
   sudo docker compose --project-directory /opt/keycloak exec -T postgres \
     createdb --username=keycloak --owner=keycloak keycloak
   sudo cat /var/backups/keycloak-postgres/<newest>.dump | \
     sudo docker compose --project-directory /opt/keycloak exec -i postgres \
     pg_restore --username=keycloak --dbname=keycloak --exit-on-error
   sudo docker compose --project-directory /opt/keycloak up -d keycloak
   ```

   The one-line tar-pipe idiom above it has NOT been verified on restore; prefer the
   explicit sequence.

3. Restore the CA trust, backup script, systemd units, and nginx config:

   ```bash
   sudo install -m 644 /etc/nginx/tls/camera-system-root-ca.crt.pem \
     /usr/local/share/ca-certificates/camera-system-root-ca.crt 2>/dev/null || true
   sudo update-ca-certificates
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-usr-local-sbin-backup-keycloak-postgres.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-systemd-system.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-conf.d.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-available.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-enabled.tar" -C /
   ```

   Note: restoring the whole `/etc/systemd/system` and nginx dirs brings every
   stage's units/config forward at once — this folder is the newest complete set;
   do not restore older stage folders after it.

4. Reload services:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart onvif-mcp-http
   sudo nginx -t && sudo systemctl restart nginx
   ```

5. Verify reconstruction:

   ```bash
   sudo docker compose --project-directory /opt/keycloak ps       # both up, postgres healthy
   curl -sS -o /dev/null -w '%{http_code}\n' \
     https://{{SERVER_FQDN}}/auth/realms/mcp/.well-known/openid-configuration   # 200
   curl -sS -D - -o /dev/null https://{{SERVER_FQDN}}/mcp 2>&1 | grep -E '^HTTP|www-authenticate'  # 401 + resource_metadata
   curl -sS https://{{SERVER_FQDN}}/.well-known/oauth-protected-resource/mcp    # exact metadata JSON
   sudo ss -ltnp | grep ':8080'                                   # 127.0.0.1:8080 only
   ```

   Then re-authenticate `kcadm.sh` per KEYCLOAK.md §4 (password from
   `/opt/keycloak/admin.pass`) and confirm the realm, scope, and DCR policy
   components match `post-change-state.txt`. The archived database already
   contains the active Hermes DCR client; existing Hermes token files on clients
   remain valid only while the Keycloak signing keys are unchanged — a fresh
   database restored from this dump includes the original keys. If the OAuth
   client's tokens fail, re-run the KEYCLOAK.md §13 login.

   NOTE (2026-09-13 restore verification): for the Hermes-side login (KEYCLOAK.md §13),
   the `ssl_verify` path must be `/etc/ssl/certs/camera-system-root-ca.pem` —
   `update-ca-certificates` installs the `.crt` source under a `.pem` link in
   `/etc/ssl/certs`; the literal `<ca-name>.pem` placeholder in §13.1 resolves there.
   Verified working flow: write the config entry (`enabled: false`), run the login under
   `HERMES_HOME=<isolated-dir>` with `env -u DISPLAY -u WAYLAND_DISPLAY`, complete the
   browser step with `scripts/kc-headless-login-driver.py <auth-url>`, copy the three
   token files to `~/.hermes/mcp-tokens/` (mode 600), shred the isolated copies,
   `hermes mcp test <name>` (expect 29 tools), then set `enabled: true`.

Expected restored state matches `post-change-state.txt`: discovery 200, 401 with
correct metadata, 29 tools for `camera-new`, regression endpoints 200 over TLS,
Keycloak bound to loopback only.
