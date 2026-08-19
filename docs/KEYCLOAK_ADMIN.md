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

Create the deployment directory and PostgreSQL secret:

```bash
sudo install -d -m 750 -o root -g root /opt/keycloak
sudo sh -c 'umask 077; printf "POSTGRES_PASSWORD=%s\n" "$(openssl rand -hex 32)" > /opt/keycloak/.env'
sudo stat -c '%A %U %G %n' /opt/keycloak /opt/keycloak/.env
```

Expected modes are `drwxr-x---` and `-rw-------`.

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

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh create users \
  --config /tmp/kcadm.config \
  -r master \
  -s username="${KEYCLOAK_ADMIN_USER}" \
  -s enabled=true
```

Set a strong password without echoing it or storing it in shell history:

```bash
sudo -v
read -rsp "Enter a strong password for ${KEYCLOAK_ADMIN_USER}: " KC_ADMIN_PASSWORD
echo
printf '%s\n' "$KC_ADMIN_PASSWORD" |
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    sh -c 'IFS= read -r new_password
      /opt/keycloak/bin/kcadm.sh set-password \
        --config /tmp/kcadm.config \
        -r master \
        --username keycloak-admin \
        --new-password "$new_password"'
unset KC_ADMIN_PASSWORD
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

Verify a separate login using a new CLI configuration file:

```bash
sudo -v
read -rsp "Password for ${KEYCLOAK_ADMIN_USER}: " KC_ADMIN_PASSWORD
echo
printf '%s\n' "$KC_ADMIN_PASSWORD" |
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    sh -c 'IFS= read -r admin_password
      /opt/keycloak/bin/kcadm.sh config credentials \
        --config /tmp/kcadm-permanent.config \
        --server http://127.0.0.1:8080/auth \
        --realm master \
        --user keycloak-admin \
        --password "$admin_password"'
unset KC_ADMIN_PASSWORD
```

Verify its administrative access:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get realms \
  --config /tmp/kcadm-permanent.config \
  --fields realm,enabled
```

