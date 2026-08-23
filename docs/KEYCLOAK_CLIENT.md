## 0. Set deployment values

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

The keycloak admin password lives in a root-owned, mode 0600 file (/opt/keycloak/admin.pass in this deployment). Create the token body and token stash with a restrictive umask so the credential never appears on a command line, in an environment variable, or in an untrusted location. Do not attempt to use the bootstrap admin credentials, they have been deleted at this point.

## 1. Create the MCP realm and login user

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

## 2. Create the MCP client scope and audience mapper

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

## 3. Configure anonymous Dynamic Client Registration

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

## 4. Configure Nginx

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

## 5. Trust the private CA

Locate the CA certificate and inspect the server certificate issuer:

```bash
sudo find /etc/nginx/tls -maxdepth 1 -type f -printf '%f\n' | sort
sudo openssl x509 -in "/etc/nginx/tls/${PUBLIC_HOST}.crt.pem" \
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

## 6. Enable OAuth in the MCP systemd service

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
Environment=MCP_OAUTH_ISSUER=https://PUBLIC_HOST/auth/realms/mcp
Environment=MCP_RESOURCE_URL=https://PUBLIC_HOST/mcp
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
https://PUBLIC_HOST/.well-known/oauth-protected-resource/mcp
```

Verify protected-resource metadata:

```bash
curl -sS \
  "https://${PUBLIC_HOST}/.well-known/oauth-protected-resource/mcp" |
python3 -m json.tool
```

Expected values:

```json
{
  "resource": "https://PUBLIC_HOST/mcp",
  "authorization_servers": [
    "https://PUBLIC_HOST/auth/realms/mcp"
  ],
  "scopes_supported": [
    "mcp:tools"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

## 7. Test DCR without exposing registration credentials

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

<b>
IMPORTANT: Stop here. Prompt the user to acknowledge that they will be expected 
to provide the username and password for the next step. Only proceed after the 
user has acknowledged.
</b>

## 8. Configure and verify Hermes Agent

On the Hermes host, verify Hermes and the CA file:

```bash
hermes --version
test -r /path/to/private-root-ca.crt.pem \
  && echo "CA file readable" \
  || echo "CA file missing"
```

Use a new server name during migration so an existing deployment is not
overwritten:

```bash
hermes mcp add camera-new \
  --url "https://PUBLIC_HOST/mcp" \
  --auth oauth \
  --connect-timeout 30
```

The first connection can fail before the private CA path is configured. Save
the entry if prompted. Edit `~/.hermes/config.yaml`, set the new entry to
enabled, and add:

```yaml
mcp_servers:
  camera-new:
    url: https://PUBLIC_HOST/mcp
    ssl_verify: /path/to/private-root-ca.crt.pem
    connect_timeout: 30.0
    auth: oauth
    enabled: true
```

Preserve unrelated server entries. Never display files under
`~/.hermes/mcp-tokens/`.

Start login:

```bash
hermes mcp login camera-new
```

Log in as the MCP login user and approve consent for `mcp:tools`. Then test
saved OAuth state:

```bash
hermes mcp test camera-new
```

Success means Hermes reconnects without another browser login and discovers
the expected MCP tools.

## 9. Configure manual PostgreSQL backups

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

## 10. Perform an isolated restore test

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

## 11. Final verification checklist

Run or confirm all of the following:

```bash
sudo docker compose --project-directory /opt/keycloak ps
sudo systemctl is-active nginx onvif-mcp-http.service

curl -sS -o /dev/null -w 'Keycloak discovery: %{http_code}\n' \
  "${MCP_ISSUER}/.well-known/openid-configuration"

curl -sS -D - -o /dev/null "${MCP_RESOURCE_URL}"

curl -sS \
  "https://${PUBLIC_HOST}/.well-known/oauth-protected-resource/mcp" |
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

## 12. Routine operations

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

## 13. Known pitfalls

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
