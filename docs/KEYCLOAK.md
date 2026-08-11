# Keycloak Authorization for the ONVIF MCP Server

## Purpose

This runbook documents the installation and configuration of Keycloak as the OAuth 2.1/OpenID Connect authorization server for the ONVIF MCP server hosted on `gmktec.home.arpa`.

The finished deployment provides:

- HTTPS using the existing private certificate authority.
- Keycloak 26.7.0 backed by PostgreSQL 17.
- OAuth protected-resource discovery for the MCP server.
- Dynamic Client Registration (DCR) for Hermes Agent.
- Authorization Code flow with PKCE (`S256`).
- Five-minute JWT access tokens.
- Exact issuer, audience, signature, expiry, and scope validation.
- Rotating refresh tokens.
- Manual, restore-tested PostgreSQL backups.

## Final architecture

```text
Hermes Agent on macOS
    |
    | HTTPS, OAuth discovery, DCR, PKCE
    v
Nginx on gmktec.home.arpa:443
    |-- /auth/ --------------------------------> Keycloak on 127.0.0.1:8080
    |                                               |
    |                                               v
    |                                           PostgreSQL
    |
    |-- /.well-known/oauth-protected-resource/mcp -> MCP server on 127.0.0.1:8001
    |
    `-- /mcp -------------------------------------> MCP server on 127.0.0.1:8001
```

## Important identifiers

| Item | Value |
|---|---|
| Public host | `gmktec.home.arpa` |
| MCP resource URL | `https://gmktec.home.arpa/mcp` |
| Keycloak base path | `https://gmktec.home.arpa/auth/` |
| Keycloak realm | `mcp` |
| Issuer | `https://gmktec.home.arpa/auth/realms/mcp` |
| Required MCP scope | `mcp:tools` |
| MCP service | `onvif-mcp-http.service` |
| MCP internal listener | `127.0.0.1:8001` |
| Keycloak internal listener | `127.0.0.1:8080` |
| Keycloak deployment directory | `/opt/keycloak` |
| Backup directory | `/var/backups/keycloak-postgres` |

## 1. Install Docker and Compose

Refresh Ubuntu package metadata:

```bash
sudo apt update
```

Install Docker:

```bash
sudo apt install -y docker.io
```

Verify the Docker daemon:

```bash
sudo systemctl is-active docker
sudo docker version
```

Install and verify Docker Compose:

```bash
sudo apt install -y docker-compose-v2
sudo docker compose version
```

## 2. Prepare the Keycloak deployment

Create a protected deployment directory:

```bash
sudo install -d -m 750 -o root -g root /opt/keycloak
```

Generate a PostgreSQL password without displaying it:

```bash
sudo sh -c 'umask 077; printf "POSTGRES_PASSWORD=%s\n" "$(openssl rand -hex 32)" > /opt/keycloak/.env'
```

Confirm that the file is root-only:

```bash
sudo stat -c '%A %U %G %n' /opt/keycloak/.env
```

Expected mode:

```text
-rw------- root root /opt/keycloak/.env
```

Create `/opt/keycloak/compose.yaml`:

```yaml
services:
  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - keycloak_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak -d keycloak"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  keycloak:
    image: quay.io/keycloak/keycloak:26.7.0
    restart: unless-stopped
    command: start
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${POSTGRES_PASSWORD}
      KC_HTTP_ENABLED: "true"
      KC_HTTP_RELATIVE_PATH: /auth
      KC_HOSTNAME: https://gmktec.home.arpa/auth
      KC_PROXY_HEADERS: xforwarded
      KC_HEALTH_ENABLED: "true"
    ports:
      - "127.0.0.1:8080:8080"

volumes:
  keycloak_postgres_data:
```

The initial installation temporarily used `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD`. Those variables were removed after a permanent administrator was created and verified. Do not add them back to the steady-state configuration.

Validate and start the deployment:

```bash
sudo docker compose --project-directory /opt/keycloak config --quiet
sudo docker compose --project-directory /opt/keycloak pull
sudo docker compose --project-directory /opt/keycloak up -d
sudo docker compose --project-directory /opt/keycloak ps
```

Test Keycloak locally:

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code} redirect=%{redirect_url}\n' \
  http://127.0.0.1:8080/auth/
```

## 3. Configure Nginx

The existing HTTPS virtual host is:

```text
/etc/nginx/sites-enabled/camera-apps-https
```

Backups of Nginx configuration must be stored outside `sites-enabled`; otherwise Nginx may load the backup as a second virtual host.

Example backup:

```bash
sudo install -d -m 750 /etc/nginx/backups
sudo cp --update=none \
  /etc/nginx/sites-enabled/camera-apps-https \
  /etc/nginx/backups/camera-apps-https.pre-keycloak
```

Add the Keycloak proxy locations inside the HTTPS `server` block:

```nginx
location = /auth {
    return 301 /auth/;
}

location /auth/ {
    proxy_pass http://127.0.0.1:8080/auth/;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

Add the protected-resource metadata route:

```nginx
location = /.well-known/oauth-protected-resource/mcp {
    proxy_pass http://127.0.0.1:8001;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

The existing `/mcp` proxy remains:

```nginx
location /mcp {
    proxy_pass http://127.0.0.1:8001/mcp;
    proxy_redirect off;

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
```

Validate and reload Nginx:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 4. Trust the private certificate authority

The server certificate is issued by `Camera System Root CA`.

Verify the CA certificate:

```bash
sudo openssl x509 \
  -in /etc/nginx/tls/camera-system-root-ca.crt.pem \
  -noout -subject -issuer -ext basicConstraints
```

Install it into Ubuntu's trust store:

```bash
sudo install -m 644 \
  /etc/nginx/tls/camera-system-root-ca.crt.pem \
  /usr/local/share/ca-certificates/camera-system-root-ca.crt

sudo update-ca-certificates
```

Verify HTTPS without using `-k`:

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code} redirect=%{redirect_url}\n' \
  https://gmktec.home.arpa/auth/
```

Hermes uses its Python TLS stack, so its configuration explicitly references the CA file on the Mac:

```yaml
ssl_verify: /Users/stephen/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem
```

## 5. Create and configure the Keycloak realm

In the Keycloak Admin Console:

1. Create a realm named `mcp`.
2. Create the MCP login user `mcp-user`.
3. Set a strong, non-temporary password for `mcp-user`.

### Permanent administrator

The initial bootstrap administrator was replaced with a permanent administrator:

1. Switch to the `master` realm.
2. Create `keycloak-admin`.
3. Set a strong, non-temporary password.
4. Assign the realm-level `admin` role in the `master` realm.
5. Verify the account in a new private browser session.
6. Remove the temporary `admin` account.
7. Remove the bootstrap-admin variables and secret from Compose and `/opt/keycloak/.env`.

The realm-level `admin` role in `master` is the full server-administrator role. It is not the `realm-admin` client role used for delegated administration of ordinary realms.

## 6. Configure the MCP client scope and audience

Create an optional OpenID Connect client scope named:

```text
mcp:tools
```

Set:

- **Display on consent screen:** On
- **Include in token scope:** On
- **Include in OpenID Provider Metadata:** On

`Include in token scope` is essential. If it is off, Keycloak applies the scope's audience mapper but emits an empty `scope` claim, causing the MCP server to return `403 Forbidden`.

Add an **Audience** protocol mapper:

| Setting | Value |
|---|---|
| Name | `mcp-server-audience` |
| Included Client Audience | Empty |
| Included Custom Audience | `https://gmktec.home.arpa/mcp` |
| Add to access token | On |

A valid access token then contains:

```json
{
  "iss": "https://gmktec.home.arpa/auth/realms/mcp",
  "aud": "https://gmktec.home.arpa/mcp",
  "scope": "mcp:tools",
  "typ": "Bearer"
}
```

Keycloak 26.7 does not natively implement RFC 8707 Resource Indicators. The MCP client still sends the `resource` parameter, while the `mcp:tools` scope and audience mapper bind the resulting access token to the MCP resource.

## 7. Configure Dynamic Client Registration

Navigate to:

```text
Clients -> Client registration -> Anonymous access policies
```

Final relevant policy configuration:

### Allowed Client Scopes

- Allowed scope: `mcp:tools`
- Allow Default Scopes: On

Keycloak automatically assigns realm-default scopes to new clients. Disabling **Allow Default Scopes** caused DCR to fail with `insufficient_scope`.

### Trusted Hosts

Allowed entries:

```text
10.1.1.1
localhost
127.0.0.1
```

Both controls remain enabled:

- Host Sending Client Registration Request Must Match
- Client URIs Must Match

`10.1.1.1` is how the Mac appears to the Ubuntu host. Hermes uses a loopback callback such as `http://127.0.0.1:<port>/callback`.

### Other policies

- Consent Required: enabled
- Full Scope Disabled: enabled
- Max Clients Limit: `20`

Hermes may create a replacement DCR client after credentials or authorization sessions become unusable. Periodically remove obsolete Hermes registrations while retaining the client ID stored in:

```text
~/.hermes/mcp-tokens/camera.client.json
```

Do not display token files. To show only the active client ID safely:

```bash
python3 -c 'import json; d=json.load(open("/Users/stephen/.hermes/mcp-tokens/camera.client.json")); print(d.get("client_id"))'
```

## 8. Configure Keycloak token and session policies

In the `mcp` realm:

### Sessions

| Setting | Value |
|---|---|
| SSO Session Idle | 8 hours |
| SSO Session Max | 7 days |
| Client Session Idle | 0 (inherit) |
| Client Session Max | 0 (inherit) |

### Tokens

| Setting | Value |
|---|---|
| Access Token Lifespan | 5 minutes |
| Revoke Refresh Token | Enabled |
| Refresh Token Max Reuse | 0 |

With these settings:

- Expired JWT access tokens are rejected by the MCP server.
- Hermes silently exchanges a valid refresh token for a new access token.
- Refresh tokens rotate on each use and cannot be reused.
- Browser authorization is required again after the session idle or maximum lifetime expires, logout, revocation, or client deletion.

## 9. Configure MCP JWT validation

The HTTP MCP application lives at:

```text
/home/stephen/Projects/onvif-mcp/packages/http/src/onvif_mcp_http/
```

The JWT verifier was generalized from an Authelia-specific verifier to `JWTVerifier`. It:

- Retrieves Keycloak signing keys from JWKS.
- Accepts only `RS256`.
- Validates the exact issuer.
- Validates the exact audience.
- Requires `exp`, `iat`, `iss`, and `sub`.
- Extracts `client_id` or `azp`.
- Extracts the granted scopes.

The MCP OAuth settings are environment-configurable:

```python
MCP_OAUTH_ISSUER = os.environ.get(
    "MCP_OAUTH_ISSUER",
    "https://gmktec.home.arpa/auth/realms/mcp",
)
MCP_RESOURCE_URL = os.environ.get(
    "MCP_RESOURCE_URL",
    "https://gmktec.home.arpa/mcp",
)
MCP_OAUTH_JWKS_URL = os.environ.get(
    "MCP_OAUTH_JWKS_URL",
    "http://127.0.0.1:8080/auth/realms/mcp/protocol/openid-connect/certs",
)
```

FastMCP authentication requires:

```python
AuthSettings(
    issuer_url=AnyHttpUrl(MCP_OAUTH_ISSUER),
    resource_server_url=AnyHttpUrl(MCP_RESOURCE_URL),
    required_scopes=["mcp:tools"],
)
```

The internal JWKS URL uses loopback HTTP because Keycloak is on the same host and port 8080 is bound only to `127.0.0.1`.

## 10. Enable OAuth in systemd

Create:

```text
/etc/systemd/system/onvif-mcp-http.service.d/oauth.conf
```

Contents:

```ini
[Service]
Environment=MCP_OAUTH_ENABLED=true
Environment=MCP_OAUTH_ISSUER=https://gmktec.home.arpa/auth/realms/mcp
Environment=MCP_RESOURCE_URL=https://gmktec.home.arpa/mcp
Environment=MCP_OAUTH_JWKS_URL=http://127.0.0.1:8080/auth/realms/mcp/protocol/openid-connect/certs
```

Load and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart onvif-mcp-http
sudo systemctl status onvif-mcp-http --no-pager
```

An unauthenticated MCP request must return `401 Unauthorized`:

```bash
curl -sS -D - -o /dev/null https://gmktec.home.arpa/mcp
```

The response includes:

```http
WWW-Authenticate: Bearer error="invalid_token", resource_metadata="https://gmktec.home.arpa/.well-known/oauth-protected-resource/mcp"
```

Protected-resource metadata:

```bash
curl -sS https://gmktec.home.arpa/.well-known/oauth-protected-resource/mcp \
  | python3 -m json.tool
```

Expected document:

```json
{
  "resource": "https://gmktec.home.arpa/mcp",
  "authorization_servers": [
    "https://gmktec.home.arpa/auth/realms/mcp"
  ],
  "scopes_supported": [
    "mcp:tools"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

## 11. Configure Hermes Agent

Hermes configuration in `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  camera:
    url: https://gmktec.home.arpa/mcp
    ssl_verify: /Users/stephen/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem
    connect_timeout: 30.0
    auth: oauth
    enabled: true
```

Add the server through the CLI when starting from scratch:

```bash
hermes mcp add camera \
  --url https://gmktec.home.arpa/mcp \
  --auth oauth \
  --connect-timeout 30
```

If the initial discovery probe times out, save the configuration anyway, ensure it is enabled in `config.yaml`, add `ssl_verify`, and use the dedicated login command:

```bash
hermes mcp login camera
```

Log in as:

```text
mcp-user
```

Never document the password.

Verify the authenticated connection:

```bash
hermes mcp test camera
```

Successful result:

```text
Connected
Tools discovered: 28
```

Hermes stores registration and token state under:

```text
~/.hermes/mcp-tokens/
```

These files must remain mode `0600` and must never be pasted into logs or documentation.

## 12. Application verification and source control

Run the complete project test suite:

```bash
cd /home/stephen/Projects/onvif-mcp
uv run --with pytest pytest packages/core/tests packages/http/tests
```

Verified result:

```text
19 passed
```

The streaming test was corrected so `STREAM_SERVER_URL` represents the origin only:

```text
STREAM_SERVER_URL=gmktec.home.arpa
```

The application owns the `/webrtc/` path.

The OAuth implementation was committed as:

```text
be603e6 Add Keycloak OAuth authorization to HTTP MCP server
```

## 13. PostgreSQL backups

### Backup characteristics

- Manual only; no timer or recurring schedule is configured.
- PostgreSQL custom archive format.
- Zstandard compression level 9.
- Root-only backup directory and files.
- Retention cleanup runs whenever a manual backup is created.
- Dumps older than 14 days are deleted.
- A full isolated restore test was completed successfully.

### Backup directory

```text
/var/backups/keycloak-postgres
```

Permissions:

```text
drwx------ root root /var/backups/keycloak-postgres
```

### Backup script

Script path:

```text
/usr/local/sbin/backup-keycloak-postgres
```

Contents:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

backup_dir="/var/backups/keycloak-postgres"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final_file="${backup_dir}/keycloak-${timestamp}.dump"
temp_file="$(mktemp "${backup_dir}/.keycloak-${timestamp}.XXXXXX.dump")"

cleanup() {
    rm -f -- "${temp_file}"
}
trap cleanup EXIT

docker compose --project-directory /opt/keycloak exec -T postgres \
    pg_dump \
    --username=keycloak \
    --dbname=keycloak \
    --format=custom \
    --compress=zstd:9 \
    --no-owner \
    --no-acl \
    > "${temp_file}"

chmod 600 "${temp_file}"
mv -- "${temp_file}" "${final_file}"
trap - EXIT

find "${backup_dir}" \
    -maxdepth 1 \
    -type f \
    -name 'keycloak-*.dump' \
    -mtime +14 \
    -delete

printf '%s\n' "${final_file}"
```

Script permissions:

```text
-rwxr-x--- root root /usr/local/sbin/backup-keycloak-postgres
```

### Manual systemd service

Unit path:

```text
/etc/systemd/system/keycloak-postgres-backup.service
```

Contents:

```ini
[Unit]
Description=Back up the Keycloak PostgreSQL database
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/backup-keycloak-postgres
```

No `.timer` unit exists.

### Create a backup

Preferred command:

```bash
sudo systemctl start keycloak-postgres-backup.service
```

Check the result:

```bash
sudo systemctl status keycloak-postgres-backup.service --no-pager
sudo ls -lh /var/backups/keycloak-postgres
```

The service is `inactive (dead)` after a successful run because it is a one-shot service. The status must show `status=0/SUCCESS` or `Deactivated successfully`.

The script may also be invoked directly:

```bash
sudo /usr/local/sbin/backup-keycloak-postgres
```

### Validate an archive catalog

Replace the filename with the selected backup:

```bash
sudo sh -c 'docker compose --project-directory /opt/keycloak exec -T postgres pg_restore --list < /var/backups/keycloak-postgres/keycloak-YYYYMMDDTHHMMSSZ.dump'
```

This is read-only and does not restore data.

### Perform an isolated restore test

Choose a unique test database name:

```bash
restore_db="keycloak_restore_test_YYYYMMDD"
```

Confirm it does not exist:

```bash
sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  psql --username=keycloak --dbname=postgres --tuples-only --no-align \
  --command="SELECT datname FROM pg_database WHERE datname = '${restore_db}';"
```

Create the isolated database:

```bash
sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  createdb --username=keycloak "${restore_db}"
```

Restore the archive into the isolated database:

```bash
sudo sh -c "docker compose --project-directory /opt/keycloak exec -T postgres pg_restore --username=keycloak --dbname=${restore_db} --exit-on-error < /var/backups/keycloak-postgres/keycloak-YYYYMMDDTHHMMSSZ.dump"
```

Validate important row counts:

```bash
sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  psql --username=keycloak --dbname="${restore_db}" \
  --tuples-only --no-align \
  --command="SELECT 'realms=' || count(*) FROM realm UNION ALL SELECT 'users=' || count(*) FROM user_entity UNION ALL SELECT 'clients=' || count(*) FROM client;"
```

Remove only the test database after validation:

```bash
sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  dropdb --username=keycloak "${restore_db}"
```

Always verify the variable value before running `dropdb`. Never use the live database name `keycloak` as the restore-test target.

### Disaster restore outline

For an actual disaster recovery operation:

1. Stop Keycloak so it cannot write during restoration.
2. Preserve or separately back up the damaged database before replacing it.
3. Create a clean target database.
4. Restore with `pg_restore --exit-on-error`.
5. Start Keycloak.
6. Verify the permanent administrator, `mcp` realm, client scope, and Hermes login.

Do not restore over the live database without a separately verified recovery plan and an additional copy of the current state.

## 14. Routine operations

### Deployment status

```bash
sudo docker compose --project-directory /opt/keycloak ps
sudo systemctl status onvif-mcp-http --no-pager
```

### Restart Keycloak

```bash
sudo docker compose --project-directory /opt/keycloak up -d keycloak
```

### View Keycloak logs

```bash
sudo docker compose --project-directory /opt/keycloak logs --tail=200 keycloak
```

### View MCP logs

```bash
sudo journalctl -u onvif-mcp-http --since "30 minutes ago" --no-pager
```

### Verify OAuth discovery

```bash
curl -sS https://gmktec.home.arpa/auth/realms/mcp/.well-known/openid-configuration \
  | python3 -m json.tool
```

Confirm the document contains:

- Correct issuer.
- Authorization endpoint.
- Token endpoint.
- Registration endpoint.
- `S256` in `code_challenge_methods_supported`.

### Verify Hermes

```bash
hermes mcp test camera
```

Expected result: a silent connection and 28 discovered tools. A browser login is expected only when the authorization session or refresh token is no longer usable.

## 15. Security notes and remaining work

- Never use `curl -k` for operational checks.
- Never paste JWTs, refresh tokens, DCR registration access tokens, passwords, or `.env` contents into logs or documentation.
- Validate JWT issuer and audience in addition to the signature.
- Never forward the MCP access token to downstream camera services.
- Keep Keycloak, PostgreSQL, Docker, and Ubuntu security updates current.
- Review DCR clients periodically and remove obsolete registrations.
- Backups stored only on the same host do not protect against disk or host loss. Copy important backups to a separately protected system when needed.
- The camera credential was historically stored directly in the MCP systemd unit. Rotate it and move it into a root-protected environment or credential file if this has not already been completed.

