# Keycloak CLI Deployment for the ONVIF MCP Server

## Values supplied by agent

| Name | Description |
|------|-------------|
| `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name e.g. camera.home.arpa |

## Purpose

This runbook creates a Keycloak OAuth 2.1/OpenID Connect deployment for an
ONVIF MCP server without using the Keycloak Admin Console. It is designed for
an agent or administrator starting with the same baseline used during the
verified `{{SERVER_FQDN}}` deployment:

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
Nginx on {{SERVER_FQDN}}:443
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
  "iss": "https://{{SERVER_FQDN}}/auth/realms/mcp",
  "aud": "https://{{SERVER_FQDN}}/mcp",
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
export MCP_REALM="mcp"
export MCP_SCOPE="mcp:tools"
export MCP_LOGIN_USER="mcp-user"
export KEYCLOAK_ADMIN_USER="keycloak-admin"
export MCP_RESOURCE_URL="https://{{SERVER_FQDN}}/mcp"
export KEYCLOAK_PUBLIC_URL="https://{{SERVER_FQDN}}/auth"
export MCP_ISSUER="${KEYCLOAK_PUBLIC_URL}/realms/${MCP_REALM}"
```

Confirm identity and DNS before making changes:

```bash
hostname --fqdn
cat /etc/os-release
getent ahostsv4 "{{SERVER_FQDN}}"
hostname -I
```

The public hostname must resolve to the target server. A short local hostname
is acceptable as long as `{{SERVER_FQDN}}` resolves correctly and is covered by
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

Create `/opt/keycloak/compose.yaml`. Replace `{{SERVER_FQDN}}` in this file with
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
      KC_HOSTNAME: https://{{SERVER_FQDN}}/auth
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

If this docker build lacks `-T`/`--no-tty` (check `docker exec --help`; some
builds remove both), the pipe idiom used later in this document
(`sudo cat FILE | sudo docker compose ... exec -T keycloak sh -c 'IFS= read -r ...'`)
is not available as written: substitute `-i` for `-T`. Piped stdin still feeds
the inner `IFS= read`, and TTY allocation is not required for a non-interactive
read. The host-side Admin REST token pattern in STREAM_AUTH.md is the other
supported path.

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
  --username "${KEYCLOAK_ADMIN_USER}" \
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

## 6. Create the MCP realm and login user

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh create realms \
  --config /tmp/kcadm.config \
  -s realm="${MCP_REALM}" \
  -s enabled=true
```

Configure sessions and tokens. Keycloak expresses these durations in seconds:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh update "realms/${MCP_REALM}" \
  --config /tmp/kcadm.config \
  -s ssoSessionIdleTimeout=28800 \
  -s ssoSessionMaxLifespan=604800 \
  -s clientSessionIdleTimeout=0 \
  -s clientSessionMaxLifespan=0 \
  -s accessTokenLifespan=300 \
  -s revokeRefreshToken=true \
  -s refreshTokenMaxReuse=0
```

This produces an 8-hour idle session, 7-day maximum session, inherited client
session limits, five-minute access tokens, and single-use rotating refresh
tokens.

Create the login user:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh create users \
  --config /tmp/kcadm.config \
  -r "${MCP_REALM}" \
  -s username="${MCP_LOGIN_USER}" \
  -s enabled=true
```

Generate the login user password and store it in a root-owned secret file:

```bash
sudo sh -c 'umask 077; printf "%s" "$(openssl rand -hex 32)" > /opt/keycloak/mcp-user.pass'
sudo stat -c '%A %U %G %n' /opt/keycloak/mcp-user.pass
```

Expected mode is `-rw-------`. The password is recoverable via `sudo cat /opt/keycloak/mcp-user.pass`.

Set its password from the root-owned secret file:

```bash
sudo cat /opt/keycloak/mcp-user.pass |
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    sh -c 'IFS= read -r user_password
      /opt/keycloak/bin/kcadm.sh set-password \
        --config /tmp/kcadm.config \
        -r ${MCP_REALM} \
        --username ${MCP_LOGIN_USER} \
        --new-password "$user_password"'
```

The secret file `/opt/keycloak/mcp-user.pass` (root:root, 0600) was created in Section 1 and contains the login user password. It is recoverable via `sudo cat /opt/keycloak/mcp-user.pass`.

## 7. Create the MCP client scope and audience mapper

Create the optional OpenID Connect client scope:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh create client-scopes \
  --config /tmp/kcadm.config \
  -r "${MCP_REALM}" \
  -s "name=${MCP_SCOPE}" \
  -s protocol=openid-connect \
  -s 'attributes={"display.on.consent.screen":"true","include.in.token.scope":"true","include.in.openid.provider.metadata":"true"}'
```

Capture the client-scope UUID from `Created new client-scope with id ...`:

```bash
export MCP_SCOPE_UUID="UUID_RETURNED_BY_KEYCLOAK"
```

Add the exact audience mapper:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh create \
  "client-scopes/${MCP_SCOPE_UUID}/protocol-mappers/models" \
  --config /tmp/kcadm.config \
  -r "${MCP_REALM}" \
  -s name=mcp-server-audience \
  -s protocol=openid-connect \
  -s protocolMapper=oidc-audience-mapper \
  -s consentRequired=false \
  -s "config={\"included.custom.audience\":\"${MCP_RESOURCE_URL}\",\"access.token.claim\":\"true\",\"id.token.claim\":\"false\",\"introspection.token.claim\":\"true\"}"
```

Verify both objects directly:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get "client-scopes/${MCP_SCOPE_UUID}" \
  --config /tmp/kcadm.config -r "${MCP_REALM}"

sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get \
  "client-scopes/${MCP_SCOPE_UUID}/protocol-mappers/models" \
  --config /tmp/kcadm.config -r "${MCP_REALM}"
```

Confirm all three scope attributes are `true` and the audience is exactly
`MCP_RESOURCE_URL`. `include.in.token.scope` is essential: without it, the
audience mapper can run while the token's `scope` claim remains empty, causing
the MCP server to return `403 Forbidden`.

## 8. Configure anonymous Dynamic Client Registration

Keycloak 26.7 exposes only provider metadata at
`client-registration-policy/providers`. Configured policies are realm
components. The older `client-registration-policy/anonymous` Admin REST path
returns 404 and must not be used.

List the installed policy providers and their exact configuration schemas:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get client-registration-policy/providers \
  --config /tmp/kcadm.config -r "${MCP_REALM}"
```

List configured policies and distinguish anonymous from authenticated entries
using `subType`:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get components \
  --config /tmp/kcadm.config \
  -r "${MCP_REALM}" \
  -q type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy \
  --fields id,name,providerId,subType,config
```

Capture the UUIDs whose `subType` is `anonymous` for:

- Allowed Client Scopes (`providerId: allowed-client-templates`)
- Trusted Hosts (`providerId: trusted-hosts`)
- Max Clients Limit (`providerId: max-clients`)

Also confirm that anonymous Consent Required (`consent-required`) and Full
Scope Disabled (`scope`) components exist. These are presence-based policies
and need no configuration update.

```bash
export ALLOWED_SCOPES_POLICY_UUID="TARGET_UUID"
export TRUSTED_HOSTS_POLICY_UUID="TARGET_UUID"
export MAX_CLIENTS_POLICY_UUID="TARGET_UUID"
```

Configure the allowed scope and permit automatically assigned realm-default
scopes:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh update \
  "components/${ALLOWED_SCOPES_POLICY_UUID}" \
  --config /tmp/kcadm.config \
  -r "${MCP_REALM}" \
  -s "config={\"allowed-client-scopes\":[\"${MCP_SCOPE}\"],\"allow-default-scopes\":[\"true\"]}"
```

Choose trusted hosts based on actual network topology. In the verified setup,
the OAuth client appeared to the server as `10.1.1.1`, and Hermes used a
loopback callback. Replace `CLIENT_SOURCE_IP` accordingly:

```bash
export CLIENT_SOURCE_IP="10.1.1.1"

sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh update \
  "components/${TRUSTED_HOSTS_POLICY_UUID}" \
  --config /tmp/kcadm.config \
  -r "${MCP_REALM}" \
  -s "config={\"trusted-hosts\":[\"${CLIENT_SOURCE_IP}\",\"localhost\",\"127.0.0.1\"],\"host-sending-registration-request-must-match\":[\"true\"],\"client-uris-must-match\":[\"true\"]}"
```

Limit anonymous registrations:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh update \
  "components/${MAX_CLIENTS_POLICY_UUID}" \
  --config /tmp/kcadm.config \
  -r "${MCP_REALM}" \
  -s 'config={"max-clients":["20"]}'
```

Collection views can collapse component configuration to `{}`. Verify each
updated component directly:

```bash
for component_id in \
  "$ALLOWED_SCOPES_POLICY_UUID" \
  "$TRUSTED_HOSTS_POLICY_UUID" \
  "$MAX_CLIENTS_POLICY_UUID"
do
  sudo docker compose --project-directory /opt/keycloak exec keycloak \
    /opt/keycloak/bin/kcadm.sh get "components/${component_id}" \
    --config /tmp/kcadm.config -r "${MCP_REALM}"
done
```

Expected DCR policy state:

- Allowed scope: `mcp:tools`
- Allow default scopes: `true`
- Trusted source host plus `localhost` and `127.0.0.1`
- Both trusted-host matching controls: `true`
- Consent Required present
- Full Scope Disabled present
- Max Clients Limit: `20`

## 9. Configure Nginx

Identify the active HTTPS virtual host rather than assuming its filename:

```bash
sudo ls -l /etc/nginx/sites-enabled
sudo nginx -T 2>/dev/null | \
  grep -nE 'server_name|listen .*443|ssl_certificate|location (=? )?/mcp'
```

Inspect the selected site file, then create a backup outside `sites-enabled`:

```bash
export NGINX_SITE="/etc/nginx/sites-available/camera-mcp"
sudo install -d -m 750 -o root -g root /etc/nginx/backups
sudo cp --update=none "$NGINX_SITE" /etc/nginx/backups/camera-mcp.pre-keycloak
sudo chmod 640 /etc/nginx/backups/camera-mcp.pre-keycloak
```

Add these locations inside the HTTPS `server` block:

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

Retain the existing `/mcp` proxy to `127.0.0.1:8001`. If a trailing-slash
redirect exists, ensure it uses HTTPS, for example:

```nginx
location = /mcp/ {
    return 301 https://$host/mcp;
}
```

Validate before reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl is-active nginx
```

## 10. Trust the private CA

Locate the CA certificate and inspect the server certificate issuer:

```bash
sudo find /etc/nginx/tls -maxdepth 1 -type f -printf '%f\n' | sort
sudo openssl x509 -in "/etc/nginx/tls/{{SERVER_FQDN}}.crt.pem" \
  -noout -subject -issuer
```

Verify the root before installing it:

```bash
export PRIVATE_CA_FILE="/etc/nginx/tls/camera-system-root-ca.crt.pem"
sudo openssl x509 -in "$PRIVATE_CA_FILE" \
  -noout -subject -issuer -ext basicConstraints
```

It must show `CA:TRUE`. Install it:

```bash
sudo install -m 644 "$PRIVATE_CA_FILE" \
  /usr/local/share/ca-certificates/camera-system-root-ca.crt
sudo update-ca-certificates
```

Verify public HTTPS without `-k`:

```bash
curl -sS -o /dev/null \
  -w 'auth: HTTP %{http_code} redirect=%{redirect_url}\n' \
  "${KEYCLOAK_PUBLIC_URL}/"

curl -sS -o /dev/null \
  -w 'discovery: HTTP %{http_code}\n' \
  "${MCP_ISSUER}/.well-known/openid-configuration"
```

Discovery must return 200. Verify exact metadata:

```bash
curl -sS "${MCP_ISSUER}/.well-known/openid-configuration" |
python3 -c '
import json, sys
d = json.load(sys.stdin)
print("issuer:", d.get("issuer"))
print("registration_endpoint:", d.get("registration_endpoint"))
print("code_challenge_methods_supported:", d.get("code_challenge_methods_supported"))
print("mcp:tools published:", "mcp:tools" in d.get("scopes_supported", []))
'
```

Confirm the issuer is exact, a registration endpoint is present, `S256` is
supported, and `mcp:tools` is published.

## 11. Enable OAuth in the MCP systemd service

Inspect only drop-in paths so an existing unit's potentially sensitive
environment is not printed:

```bash
systemctl show onvif-mcp-http.service \
  --property=FragmentPath --property=DropInPaths

sudo find /etc/systemd/system/onvif-mcp-http.service.d \
  -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true
```

Do not overwrite an existing OAuth drop-in without reviewing it. Create
`/etc/systemd/system/onvif-mcp-http.service.d/oauth.conf` with target values:

```ini
[Service]
Environment=MCP_OAUTH_ENABLED=true
Environment=MCP_OAUTH_ISSUER=https://{{SERVER_FQDN}}/auth/realms/mcp
Environment=MCP_RESOURCE_URL=https://{{SERVER_FQDN}}/mcp
Environment=MCP_OAUTH_JWKS_URL=http://127.0.0.1:8080/auth/realms/mcp/protocol/openid-connect/certs
```

The internal JWKS URL deliberately uses loopback HTTP because Keycloak is on
the same host and 8080 is bound only to `127.0.0.1`.

Validate and restart:

```bash
sudo systemd-analyze verify onvif-mcp-http.service
sudo systemctl daemon-reload
sudo systemctl restart onvif-mcp-http.service
sudo systemctl is-active onvif-mcp-http.service
```

Verify unauthenticated rejection:

```bash
curl -sS -D - -o /dev/null "${MCP_RESOURCE_URL}"
```

Expected status is 401 with a `WWW-Authenticate` header whose
`resource_metadata` is:

```text
https://{{SERVER_FQDN}}/.well-known/oauth-protected-resource/mcp
```

Verify protected-resource metadata:

```bash
curl -sS \
  "https://{{SERVER_FQDN}}/.well-known/oauth-protected-resource/mcp" |
python3 -m json.tool
```

Expected values:

```json
{
  "resource": "https://{{SERVER_FQDN}}/mcp",
  "authorization_servers": [
    "https://{{SERVER_FQDN}}/auth/realms/mcp"
  ],
  "scopes_supported": [
    "mcp:tools"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

## 12. Test DCR without exposing registration credentials

Run this test from a host allowed by the Trusted Hosts policy. A test executed
on the Keycloak server itself originates from loopback, which is allowed in
the configuration above.

Request only `mcp:tools`. Explicitly requesting `openid mcp:tools` causes the
Allowed Client Scopes policy to return `insufficient_scope` unless `openid`
is also explicitly whitelisted. Realm-default scopes are allowed
automatically and should not be included in this test request.

```bash
umask 077

curl -sS \
  -o /tmp/keycloak-dcr-test.json \
  -w 'HTTP %{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d "{
    \"client_name\": \"temporary-dcr-verification\",
    \"application_type\": \"native\",
    \"redirect_uris\": [\"http://127.0.0.1:8765/callback\"],
    \"grant_types\": [\"authorization_code\", \"refresh_token\"],
    \"response_types\": [\"code\"],
    \"token_endpoint_auth_method\": \"none\",
    \"scope\": \"${MCP_SCOPE}\"
  }" \
  "${MCP_ISSUER}/clients-registrations/openid-connect"

python3 -c '
import json
d=json.load(open("/tmp/keycloak-dcr-test.json"))
print("client_id:", d.get("client_id"))
print("scope:", d.get("scope"))
print("error:", d.get("error"))
print("error_description:", d.get("error_description"))
'
```

Expected status is 201. Never print the complete response; it contains a
registration access token. Capture the printed test client ID, resolve it
through the Admin API, and verify its name before deletion:

```bash
export DCR_TEST_CLIENT_ID="CLIENT_ID_FROM_RESPONSE"

sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get clients \
  --config /tmp/kcadm.config \
  -r "${MCP_REALM}" \
  -q "clientId=${DCR_TEST_CLIENT_ID}" \
  --fields id,clientId,name
```

Delete only the UUID whose name is `temporary-dcr-verification`, then remove
the credential-bearing response:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh delete "clients/${DCR_TEST_CLIENT_ID}" \
  --config /tmp/kcadm.config -r "${MCP_REALM}"

rm -f /tmp/keycloak-dcr-test.json
test ! -e /tmp/keycloak-dcr-test.json && echo "DCR test artifacts removed"
```

If Keycloak returns an internal UUID different from `clientId`, use the exact
returned internal `id` in the delete path.


## 13. Configure manual PostgreSQL backups

Create the protected backup directory:

```bash
sudo install -d -m 700 -o root -g root /var/backups/keycloak-postgres
```

Create `/usr/local/sbin/backup-keycloak-postgres`:

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

Protect it:

```bash
sudo chmod 750 /usr/local/sbin/backup-keycloak-postgres
sudo stat -c '%A %U %G %n' /usr/local/sbin/backup-keycloak-postgres
```

Create `/etc/systemd/system/keycloak-postgres-backup.service`:

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

Validate and run it manually:

```bash
sudo chmod 644 /etc/systemd/system/keycloak-postgres-backup.service
sudo systemctl daemon-reload
sudo systemd-analyze verify keycloak-postgres-backup.service
sudo systemctl start keycloak-postgres-backup.service
sudo systemctl status keycloak-postgres-backup.service --no-pager
```

A successful one-shot service becomes `inactive (dead)` and reports
`Deactivated successfully` or `status=0/SUCCESS`. No timer is installed.

Verify mode and archive catalog:

```bash
sudo find /var/backups/keycloak-postgres \
  -maxdepth 1 -type f -name 'keycloak-*.dump' \
  -printf '%M %u %g %s bytes %f\n'

backup_file="$(sudo find /var/backups/keycloak-postgres \
  -maxdepth 1 -type f -name 'keycloak-*.dump' \
  -printf '%f\n' | sort | tail -n 1)"

sudo sh -c \
  "docker compose --project-directory /opt/keycloak exec -T postgres \
   pg_restore --list \
   < '/var/backups/keycloak-postgres/${backup_file}' \
   >/dev/null"
```

The file must be non-empty and mode `-rw-------`.

## 14. Perform an isolated restore test

Choose a unique database name and confirm it is absent:

```bash
restore_db="keycloak_restore_test_YYYYMMDD"

sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  psql --username=keycloak --dbname=postgres \
  --tuples-only --no-align \
  --command="SELECT datname FROM pg_database WHERE datname = '${restore_db}';"
```

Stop if the command prints a database name. Create and restore only the test
database:

```bash
echo "restore target: ${restore_db}"
sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  createdb --username=keycloak "${restore_db}"

backup_file="$(sudo find /var/backups/keycloak-postgres \
  -maxdepth 1 -type f -name 'keycloak-*.dump' \
  -printf '%f\n' | sort | tail -n 1)"

sudo sh -c \
  "docker compose --project-directory /opt/keycloak exec -T postgres \
   pg_restore --username=keycloak --dbname='${restore_db}' --exit-on-error \
   < '/var/backups/keycloak-postgres/${backup_file}'"
```

Validate important row counts:

```bash
sudo docker compose --project-directory /opt/keycloak exec -T postgres \
  psql --username=keycloak --dbname="${restore_db}" \
  --tuples-only --no-align \
  --command="SELECT 'realms=' || count(*) FROM realm
             UNION ALL
             SELECT 'users=' || count(*) FROM user_entity
             UNION ALL
             SELECT 'clients=' || count(*) FROM client;"
```

All must be nonzero. Remove only the verified test target, using an explicit
guard:

```bash
if [[ "$restore_db" != keycloak_restore_test_* ]] ||
   [ "$restore_db" = "keycloak" ]; then
  echo "Refusing unsafe database target: $restore_db"
  exit 1
else
  echo "dropping restore-test database: $restore_db"
  sudo docker compose --project-directory /opt/keycloak exec -T postgres \
    dropdb --username=keycloak "$restore_db"
fi
```

After the real OAuth client completes DCR and login, create another manual
backup so the active client registration is included.

## 15. Final verification checklist

Run or confirm all of the following:

```bash
sudo docker compose --project-directory /opt/keycloak ps
sudo systemctl is-active nginx onvif-mcp-http.service

curl -sS -o /dev/null -w 'Keycloak discovery: %{http_code}\n' \
  "${MCP_ISSUER}/.well-known/openid-configuration"

curl -sS -D - -o /dev/null "${MCP_RESOURCE_URL}"

curl -sS \
  "https://{{SERVER_FQDN}}/.well-known/oauth-protected-resource/mcp" |
python3 -m json.tool
```

Required outcomes:

- PostgreSQL is healthy and Keycloak is running.
- Nginx and the MCP service are active.
- Public Keycloak discovery returns 200 with the exact issuer.
- `S256` appears in `code_challenge_methods_supported`.
- `mcp:tools` appears in `scopes_supported`.
- An unauthenticated MCP request returns 401.
- Protected-resource metadata contains the exact issuer and resource URL.
- Anonymous DCR succeeds for `mcp:tools` from an allowed host.
- Hermes completes browser authorization and reconnects using saved state.
- The MCP client discovers the expected tools.
- A post-login database backup exists, its catalog is readable, and an
  isolated restore test has succeeded.


# Addendum

## 1. Routine operations

Deployment status:

```bash
sudo docker compose --project-directory /opt/keycloak ps
sudo systemctl status onvif-mcp-http.service --no-pager
```

Restart Keycloak:

```bash
sudo docker compose --project-directory /opt/keycloak up -d keycloak
```

After container recreation, authenticate `kcadm.sh` again because
`/tmp/kcadm.config` is ephemeral.

Logs:

```bash
sudo docker compose --project-directory /opt/keycloak logs --tail=200 keycloak
sudo journalctl -u onvif-mcp-http.service --since "30 minutes ago" --no-pager
```

Manual backup:

```bash
sudo systemctl start keycloak-postgres-backup.service
sudo systemctl status keycloak-postgres-backup.service --no-pager
```

Hermes verification:

```bash
hermes mcp test camera-new
```

Review DCR clients periodically and remove obsolete registrations only after
matching their client IDs to the active ID stored by the OAuth client. Never
display the associated token file.

## 2. Known pitfalls

- `client-registration-policy/anonymous` returns 404 on Keycloak 26.7. Use
  realm components and select policies with `subType: anonymous`.
- Component UUIDs change on every realm installation. Never reuse example
  UUIDs.
- Component collection output can show `config: {}` even when configuration
  is stored. Retrieve each component by ID to verify it.
- An explicit DCR request for `openid mcp:tools` can fail with
  `insufficient_scope`. Request `mcp:tools`; allow realm-default scopes through
  `allow-default-scopes`.
- Omitting `include.in.token.scope=true` produces tokens whose audience may be
  correct but whose `scope` claim is empty.
- A redirect from `/mcp/` to `http://...` downgrades HTTPS and must be fixed.
- Saving a Hermes entry before setting `ssl_verify` can leave it disabled.
  Add the CA path and explicitly enable it before login.
- Never diagnose private-CA failures with `curl -k`; install the CA correctly.
- A Compose container recreation clears `/tmp/kcadm.config`; it does not erase
  PostgreSQL data stored in the named volume.
- Same-host backups do not protect against disk or host loss. Copy important
  archives to a separately protected system.

## 3. Verified deviations on the nuc.home.arpa deployment

The following were observed and resolved during the verified `nuc.home.arpa`
deployment (Ubuntu 26.04, Docker 29.1.3, Keycloak 26.7.0). They are deliberate
corrections to this runbook's example values or commands.

### 3.1 `kcadm.sh add-roles` uses `--uusername`, not `--username`

Keycloak 26.7 rejects the Section 5 command as written:

```text
Unknown options: '--username', 'keycloak-admin'
Possible solutions: --user
```

and `--user` is also not accepted for user targeting. The actual flag is
`--uusername` (see `kcadm.sh add-roles --help`, whose synopsis reads
`(--uusername USERNAME | --uid ID)`). Working form:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh add-roles \
  --config /tmp/kcadm.config \
  -r master \
  --uusername "${KEYCLOAK_ADMIN_USER}" \
  --rolename admin
```

### 3.2 Trusted-hosts must list the identities Keycloak actually sees, not assumed IPs

Two facts are not obvious from this machine alone:

- Docker compose port publishing rewrites loopback clients: a request to
  `http://127.0.0.1:8080` arrives at Keycloak as the compose bridge gateway
  IP (e.g. `172.18.0.1`), never as `127.0.0.1`. Read it from the network:

  ```bash
  sudo docker network inspect keycloak_default \
    --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
  ```

  (network name = compose project name + `_default`; the project name
  defaults to the base name of `--project-directory`, hence `keycloak` here).
  `localhost`/`127.0.0.1` alone therefore does not cover same-host DCR tests
  via the published port.
- A client running on the Keycloak host and connecting through the public
  HTTPS vhost (`https://<server-fqdn>/...`) arrives at Keycloak as the
  server's own LAN IP (e.g. `10.1.1.6`), because nginx sets
  `X-Real-IP $remote_addr` for connections from the host itself.

The runbook's example `CLIENT_SOURCE_IP=10.1.1.1` is installation-specific and
was wrong on this deployment. The final working trusted-hosts set was:

```json
"trusted-hosts": ["localhost", "127.0.0.1", "172.18.0.1", "10.1.1.6"]
```

To determine the identities Keycloak actually sees before trusting an entry,
either enable temporary `DEBUG` logging on
`org.keycloak.services.clientregistration` and read the
`KC-SERVICES0101: Failed to verify remote host : <ip>` lines, or watch the
container log during a deliberately failing DCR attempt
(`docker compose --project-directory /opt/keycloak logs --tail=20 keycloak`).

### 3.3 The HTTPS vhost may live in conf.d, not sites-available

Section 9's example `NGINX_SITE=/etc/nginx/sites-available/camera-mcp` did not
match this host: the only file under `sites-enabled/` was a port-80 redirect,
while the actual HTTPS server block was in `/etc/nginx/conf.d/nuc.home.arpa.conf`
(both includes are active: `conf.d/*.conf` and `sites-enabled/*`). The
Section 9 identification step (`sudo nginx -T | grep ...`) is what found it;
treat the example path as an illustration only.

### 3.4 Section 6 misses a Keycloak required-action trap on first login

Keycloak's profile policy marks `email` as *required*. The login user created
in Section 6 has no email, so its **first** browser login is interrupted by a
`VERIFY_PROFILE` required action (Email field, mandatory) that the runbook
never addresses. Headless verification proved this blocks every first login —
the actual client's authorization flow stalls on the profile form.

Fix applied before any client connects: set an email on the login user via
Admin API:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh update "users/<LOGIN_USER_UUID>" \
  --config /tmp/kcadm.config -r "${MCP_REALM}" \
  -s email="mcp-user@<server-fqdn-without-tld-prefix>"
```

Verified working flow after the fix: anonymous DCR (201) → browser login →
consent screen (`scope_consent` for `mcp:tools`) → authorization code with
S256 PKCE → token endpoint returns a Bearer access token whose claims are
exactly `iss=https://nuc.home.arpa/auth/realms/mcp`,
`aud=https://nuc.home.arpa/mcp`, `scope=mcp:tools`. An authenticated request
to `/mcp` then passes authentication (a bare GET without MCP protocol headers
returns 406, not 401 — the token is accepted).

Also note for headless testing: Keycloak's consent form action URL is
*relative* (`/auth/realms/...`), and after the final POST it redirects to the
loopback callback URI. A script must resolve the relative action against the
page URL and run a local listener on the redirect port (e.g. 8765) instead of
following that redirect itself.

