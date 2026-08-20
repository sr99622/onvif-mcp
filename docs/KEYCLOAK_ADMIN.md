# Keycloak CLI Deployment for the ONVIF MCP Server

## Purpose

This runbook creates a Keycloak OAuth 2.1/OpenID Connect deployment for an
ONVIF MCP server without using the Keycloak Admin Console. It is designed for
an agent or administrator starting with the same baseline used during the
verified `gmktec.home.arpa` deployment:

- Ubuntu Server with sudo access.
- Nginx already serving the MCP application over HTTPS.
- The MCP HTTP service listening on `127.0.0.1:8001`.
- A server certificate issued by a private CA.
- Docker and Keycloak not yet installed.
- A client such as Hermes Agent that supports DCR, Authorization Code flow,
  PKCE, and rotating refresh tokens.

The procedure was verified with Ubuntu 26.04, Docker 29.1.3, Docker Compose
2.40.3, Keycloak 26.7.0, PostgreSQL 17, Nginx 1.28.3, and Hermes Agent 0.20.0.

Do not copy identifiers from the example deployment. Realm, user, client
scope, mapper, and component UUIDs are installation-specific and must be
captured from the target Keycloak instance.

## Resulting architecture

```text
OAuth client
    |
    | HTTPS, discovery, DCR, Authorization Code + PKCE
    v
Nginx on PUBLIC_HOST:443
    |-- /auth/ --------------------------------> Keycloak 127.0.0.1:8080
    |                                               |
    |                                               v
    |                                           PostgreSQL
    |
    |-- /.well-known/oauth-protected-resource/mcp -> MCP 127.0.0.1:8001
    |
    `-- /mcp -------------------------------------> MCP 127.0.0.1:8001
```

The finished access token must contain claims equivalent to:

```json
{
  "iss": "https://PUBLIC_HOST/auth/realms/mcp",
  "aud": "https://PUBLIC_HOST/mcp",
  "scope": "mcp:tools",
  "typ": "Bearer"
}
```

## Security rules

- Never paste passwords, `.env` contents, JWTs, refresh tokens, DCR
  registration access tokens, or Hermes token files into logs or chat.
- Never use `curl -k`. Install and trust the issuing CA instead.
- Keep Keycloak and PostgreSQL bound to loopback or their private Compose
  network. Do not publish PostgreSQL.
- Generate secrets with a restrictive umask.
- Use a permanent Keycloak administrator and remove the bootstrap account and
  bootstrap environment variables after verifying it.
- Treat DCR response files as secrets even when the client is disposable.
- Back up Nginx configuration outside `sites-enabled`.
- Resolve and verify exact object IDs before deleting anything.

## 1. Set deployment values

Set these for the target installation. Re-export them after opening a new SSH
session.

```bash
export PUBLIC_HOST="gmktec.home.arpa"
export MCP_REALM="mcp"
export MCP_SCOPE="mcp:tools"
export MCP_LOGIN_USER="mcp-user"
export KEYCLOAK_ADMIN_USER="keycloak-admin"
export MCP_RESOURCE_URL="https://${PUBLIC_HOST}/mcp"
export KEYCLOAK_PUBLIC_URL="https://${PUBLIC_HOST}/auth"
export MCP_ISSUER="${KEYCLOAK_PUBLIC_URL}/realms/${MCP_REALM}"
```

Confirm identity and DNS before making changes:

```bash
hostname --fqdn
cat /etc/os-release
getent ahostsv4 "${PUBLIC_HOST}"
hostname -I
```

The public hostname must resolve to the target server. A short local hostname
is acceptable as long as `PUBLIC_HOST` resolves correctly and is covered by
the HTTPS certificate.

Inventory the current services and ports:

```bash
docker --version 2>/dev/null || echo "Docker not installed"
docker compose version 2>/dev/null || echo "Docker Compose not installed"
nginx -v 2>&1 || echo "Nginx not installed"
systemctl is-active docker nginx
sudo ss -ltnp | grep -E ':(80|443|8001|8080)\b' || true
```

Expected baseline:

- Nginx owns ports 80 and 443.
- The MCP service owns `127.0.0.1:8001`.
- Port 8080 is available.

Stop if 8080 is already occupied by an unrelated process.

## 2. Install Docker and Compose

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2

sudo systemctl is-active docker
sudo docker version --format 'Server: {{.Server.Version}}'
sudo docker compose version
```

## 3. Create the Keycloak deployment

First ensure the target does not contain an existing deployment:

```bash
sudo ls -la /opt/keycloak 2>/dev/null || echo "/opt/keycloak does not exist yet"
```

Do not overwrite an existing directory without inspecting and backing it up.

Create the deployment directory, PostgreSQL secret, and permanent admin secret:

```bash
sudo install -d -m 750 -o root -g root /opt/keycloak
sudo sh -c 'umask 077; printf "POSTGRES_PASSWORD=%s\n" "$(openssl rand -hex 32)" > /opt/keycloak/.env'
sudo sh -c 'umask 077; printf "%s" "$(openssl rand -hex 32)" > /opt/keycloak/admin.pass'
sudo stat -c '%A %U %G %n' /opt/keycloak /opt/keycloak/.env /opt/keycloak/admin.pass
```

Expected modes are `drwxr-x---` for the directory and `-rw-------` for both
`.env` and `admin.pass`. The permanent admin password is stored in
`/opt/keycloak/admin.pass` (root:root, 0600). It is recoverable at any time
via `sudo cat /opt/keycloak/admin.pass`.

Create `/opt/keycloak/compose.yaml`. Replace `PUBLIC_HOST` in this file with
the actual hostname; do not leave the placeholder in place.

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
      KC_HOSTNAME: https://PUBLIC_HOST/auth
      KC_PROXY_HEADERS: xforwarded
      KC_HEALTH_ENABLED: "true"
    ports:
      - "127.0.0.1:8080:8080"

volumes:
  keycloak_postgres_data:
```

Protect and validate it. Do not run the non-quiet expanded configuration in a
shared log because it resolves the database password.

```bash
sudo chmod 640 /opt/keycloak/compose.yaml
sudo docker compose --project-directory /opt/keycloak config --quiet
```

## 4. Create a temporary bootstrap administrator

Generate temporary bootstrap credentials without displaying them:

```bash
sudo sh -c 'umask 077; printf "KC_BOOTSTRAP_ADMIN_USERNAME=admin\nKC_BOOTSTRAP_ADMIN_PASSWORD=%s\n" "$(openssl rand -hex 32)" >> /opt/keycloak/.env'
```

Temporarily add these two keys under the Keycloak service's `environment:`
section:

```yaml
      KC_BOOTSTRAP_ADMIN_USERNAME: ${KC_BOOTSTRAP_ADMIN_USERNAME}
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KC_BOOTSTRAP_ADMIN_PASSWORD}
```

Validate, pull, and start:

```bash
sudo docker compose --project-directory /opt/keycloak config --quiet
sudo docker compose --project-directory /opt/keycloak pull
sudo docker compose --project-directory /opt/keycloak up -d
sudo docker compose --project-directory /opt/keycloak ps
```

Wait for readiness:

```bash
curl --fail --retry 12 --retry-all-errors --retry-delay 5 \
  -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  http://127.0.0.1:8080/auth/realms/master/.well-known/openid-configuration
```

Expected result: `HTTP 200`.

Authenticate `kcadm.sh`. Expanding the secret inside the container avoids
printing it or placing its value in the host command line:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  sh -c '/opt/keycloak/bin/kcadm.sh config credentials \
    --config /tmp/kcadm.config \
    --server http://127.0.0.1:8080/auth \
    --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"'
```

## 5. Create and verify the permanent administrator

Create the user in Keycloak's database using the bootstrap credentials:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh create users \
  --config /tmp/kcadm.config \
  -r master \
  -s username="${KEYCLOAK_ADMIN_USER}" \
  -s enabled=true
```

Set the password from the root-owned secret file (generated in Section 3):

```bash
sudo cat /opt/keycloak/admin.pass |
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    sh -c 'IFS= read -r new_password
      /opt/keycloak/bin/kcadm.sh set-password \
        --config /tmp/kcadm.config \
        -r master \
        --username keycloak-admin \
        --new-password "$new_password"'
```

If a different administrator username was selected, replace
`keycloak-admin` in the inner command because exported host variables are not
automatically available inside the container.

Grant the realm-level `admin` role in `master`. This is the full server
administrator role, not the delegated `realm-management/realm-admin` client
role:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh add-roles \
  --config /tmp/kcadm.config \
  -r master \
  --uusername "${KEYCLOAK_ADMIN_USER}" \
  --rolename admin
```

Verify a separate login using a new CLI configuration file, reading the password
from the root-owned secret:

```bash
sudo cat /opt/keycloak/admin.pass |
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    sh -c 'IFS= read -r admin_password
      /opt/keycloak/bin/kcadm.sh config credentials \
        --config /tmp/kcadm-permanent.config \
        --server http://127.0.0.1:8080/auth \
        --realm master \
        --user keycloak-admin \
        --password "$admin_password"'
```

Verify its administrative access:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get realms \
  --config /tmp/kcadm-permanent.config \
  --fields realm,enabled
```

Resolve the bootstrap account ID before deletion:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get users \
  --config /tmp/kcadm-permanent.config \
  -r master -q exact=true -q username=admin \
  --fields id,username
```

Delete only the returned bootstrap user ID:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh delete users/BOOTSTRAP_USER_UUID \
  --config /tmp/kcadm-permanent.config \
  -r master
```

Remove both `KC_BOOTSTRAP_ADMIN_*` lines from `/opt/keycloak/.env` and the
Keycloak service environment:

```bash
sudo sed -i \
  '/^KC_BOOTSTRAP_ADMIN_USERNAME=/d; /^KC_BOOTSTRAP_ADMIN_PASSWORD=/d' \
  /opt/keycloak/.env

sudo sed -i \
  '/^[[:space:]]*KC_BOOTSTRAP_ADMIN_USERNAME:/d; /^[[:space:]]*KC_BOOTSTRAP_ADMIN_PASSWORD:/d' \
  /opt/keycloak/compose.yaml

sudo docker compose --project-directory /opt/keycloak config --quiet
sudo sh -c '
  if grep -q "^KC_BOOTSTRAP_ADMIN_" /opt/keycloak/.env ||
     grep -q "KC_BOOTSTRAP_ADMIN_" /opt/keycloak/compose.yaml; then
    echo "ERROR: bootstrap entries remain"
    exit 1
  else
    echo "Bootstrap entries removed"
  fi
'
```

Recreate Keycloak so those variables leave the container environment:

```bash
sudo docker compose --project-directory /opt/keycloak up -d --force-recreate keycloak
sudo docker compose --project-directory /opt/keycloak ps
```

Wait for `HTTP 200` again, then recreate the CLI configuration, reading the password from `/opt/keycloak/admin.pass`. Container recreation deletes files under `/tmp`, so this command must re-establish it:

```bash
sudo cat /opt/keycloak/admin.pass |
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    sh -c 'IFS= read -r admin_password
      /opt/keycloak/bin/kcadm.sh config credentials \
        --config /tmp/kcadm.config \
        --server http://127.0.0.1:8080/auth \
        --realm master \
        --user keycloak-admin \
        --password "$admin_password"'
```
## Agent Summary Following Deployment

```
Deployment complete. Here's a summary of everything that was done and the answer to your key question:

Permanent Admin Password Location:

The permanent admin password is stored in /opt/keycloak/admin.pass — a root-owned file with permissions 0600. Anyone with sudo can recover it at any time by running:

bash
sudo cat /opt/keycloak/admin.pass


This was created in Section 3 of the runbook using openssl rand -hex 32 with umask 077, just like the PostgreSQL password goes into /opt/keycloak/.env. Unlike the original document (which only used interactive read -rsp), the password now has persistent, recoverable storage.

What was deployed:
- Docker 29.1.3 installed and running
- PostgreSQL 17 container (healthy) — data volume: keycloak_postgres_data
- Keycloak 26.7.0 container — listening on 127.0.0.1:8080
- Bootstrap user admin deleted from the master realm
- Permanent admin user keycloak-admin created with realm-level admin role in master

Files created:
File: /opt/keycloak/.env
Purpose: PostgreSQL password + (now removed) bootstrap credentials
Permissions: -rw------- root:root
────────────────────────────────────────
File: /opt/keycloak/admin.pass
Purpose: Permanent admin password
Permissions: -rw------- root:root
────────────────────────────────────────
File: /opt/keycloak/compose.yaml
Purpose: Container definition
Permissions: -rw-r----- root:root

Document patch summary: I rewrote KEYCLOAK_ADMIN.md with three key fixes to the permanent admin password handling:
1. Admin password is now generated via openssl rand -hex 32 and stored in /opt/keycloak/admin.pass (root-owned, 0600)
2. All password-setting and credential-verification commands read from the file instead of requiring interactive input
3. After Keycloak container recreation (which wipes /tmp), the CLI config is re-established using the same root-owned secret
```