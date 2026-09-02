# Keycloak Authentication for Camera Apps and WebRTC Streams

## Purpose

This runbook adds browser-session authorization to camera applications and
WebRTC signaling while preserving the MCP server's independent OAuth bearer-
token flow.

The implementation uses:

- Keycloak as the OpenID Connect provider
- oauth2-proxy for Authorization Code flow with PKCE and encrypted sessions
- Nginx `auth_request` for route enforcement
- The existing MediaMTX service for WebRTC signaling and encrypted media
- The existing MCP resource-server JWT validation for Hermes
- The existing snapshot service for static images

Protected browser routes:

```text
/cameras/
/multiview/
/outputs/
/webrtc/
/snapshot/
```

Routes that must remain independent and must not receive browser
`auth_request` protection:

```text
/auth/
/oauth2/
/mcp
/.well-known/oauth-protected-resource/mcp
```

## Values provided by Agent

| Symbol | Meaning |
|---|---|
| `{{SERVER_FQDN}}` | Public DNS name shared by Nginx, Keycloak, and MCP |
| `{{SERVER_IP}}` | Address on which Nginx accepts public HTTPS |

These values are required for operation. Stop and prompt the user if they are not provided.

## Symbolic deployment values

Replace every symbolic value with the target environment's actual value.

| Symbol | Default | Meaning |
|---|---|---|
| `{{LOOPBACK_IP}}` | 127.0.0.1 | Host loopback address used for private listeners |
| `{{MCP_REALM}}` | mcp | Keycloak realm |
| `{{MCP_LOGIN_USER}}` | mcp-user | Browser login user |
| `{{BROWSER_CLIENT_ID}}` | camera-web | Confidential browser client, normally |
| `{{CONTAINER_BIND_IP}}` | 0.0.0.0 | In-container wildcard address used by oauth2-proxy |
| `{{KEYCLOAK_PORT}}` | 8080 | Loopback Keycloak HTTP port |
| `{{OAUTH2_PROXY_PORT}}` | 4180 | Loopback oauth2-proxy port, normally |
| `{{MCP_HTTP_PORT}}` | 8001 | Loopback MCP HTTP port, normally |
| `{{MEDIAMTX_WEBRTC_PORT}}` | 8889 | Loopback MediaMTX signaling port, normally |
| `{{MEDIAMTX_ICE_PORT}}` | 8189 | MediaMTX UDP ICE/media port, normally |
| `{{SNAPSHOT_PORT}}` | 8891 | Snapshot media port, normally |
| `{{COMPOSE_DIR}}` | /opt/keycloak | Keycloak Compose project directory |
| `{{ACTIVE_SITE_LINK}}` | camera-apps | Enabled Nginx site symlink name |
| `{{NGINX_SITE}}` | /etc/nginx/sites-enabled/camera-apps | Active Nginx site |
| `{{PRIVATE_CA_FILE}}` | /etc/nginx/tls/camera-system-root-ca.crt.pem | Public private-CA root certificate on the server |
| `{{HERMES_SERVER_NAME}}` | camera-new | Existing Hermes MCP entry used for regression testing (resolve via `hermes mcp list`: the entry whose transport is `https://{{SERVER_FQDN}}/mcp`) |

Derived URLs:

```text
Public origin:  https://{{SERVER_FQDN}}
Issuer:         https://{{SERVER_FQDN}}/auth/realms/{{MCP_REALM}}
Browser client: {{BROWSER_CLIENT_ID}}
Callback:       https://{{SERVER_FQDN}}/oauth2/callback
Home:           https://{{SERVER_FQDN}}/cameras/
MCP resource:   https://{{SERVER_FQDN}}/mcp
```

## Architecture

```text
Browser
  |
  | HTTPS request plus encrypted session cookie
  v
Nginx on {{SERVER_FQDN}}
  |
  |-- /oauth2/* ----------------------> oauth2-proxy
  |                                         |
  |                                         | OIDC + PKCE
  |                                         v
  |                                     Keycloak
  |
  |-- /cameras/, /multiview/, /outputs/
  |       `-- auth_request /oauth2/auth, then static content
  |
  `-- /webrtc/
          `-- auth_request /oauth2/auth, then MediaMTX signaling

Hermes
  `-- /mcp ----------------------------> MCP JWT validation
```

Nginx protects WebRTC HTTP signaling. MediaMTX's UDP ICE/DTLS/SRTP path
remains a separate network flow. Keep the signaling listener on loopback and
restrict the UDP port to the intended LAN or VPN networks with the firewall.

## Agent execution rules

Perform one bounded phase at a time:

1. Read-only preflight.
2. Exact target resolution.
3. Guarded mutation.
4. Direct verification.
5. Report and stop.

Do not continue after a failed guard. Do not display:

- `/opt/keycloak/.env` values
- Keycloak client secrets
- oauth2-proxy cookie secrets
- browser session cookies
- OAuth codes, state, or PKCE values
- passwords, JWTs, or refresh tokens
- private keys

Use direct live API queries to resolve installation-specific UUIDs. Never copy
UUIDs from another realm or deployment.

Admin REST token (all phases). Keycloak 26 disables password grants for most
built-in clients, and kcadm in the container cannot prompt without a console;
some docker builds also lack `-T`/`--no-tty`. The reliable pattern is
`admin-cli` with the permanent administrator user from one root-controlled
process, using a root-only temporary body file so the credential never appears
on a command line or in an untrusted environment:

```bash
pass="$(sudo cat /opt/keycloak/admin.pass)"
umask 077
body="/opt/keycloak/.kctmp.$$"
printf 'grant_type=password&client_id=admin-cli&username=keycloak-admin&password=%s' "$pass" > "$body"
tok=$(curl -sS -X POST --data @"$body" \
  http://127.0.0.1:{{KEYCLOAK_PORT}}/auth/realms/master/protocol/openid-connect/token \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
rm -f "$body"; unset pass   # keep tok until its last use, then unset it
```

kcadm alternative (verified non-interactive via stdin when the docker build
lacks `-T`): `docker exec -i keycloak-keycloak-1 sh -c '/opt/keycloak/bin/kcadm.sh get realms --server http://127.0.0.1:{{KEYCLOAK_PORT}}/auth --realm master --user keycloak-admin --password "$(cat /dev/stdin)"' < passfile`.
Note that kcadm persists its session to `/opt/keycloak/.keycloak/kcadm.config`;
remove that file after use.

## 1. Preflight

Confirm the existing services and ports before making changes:

```bash
sudo docker compose --project-directory "{{COMPOSE_DIR}}" ps
sudo systemctl is-active nginx mediamtx onvif-mcp-http.service

sudo ss -ltnp | grep -E \
  ':({{OAUTH2_PROXY_PORT}}|{{MCP_HTTP_PORT}}|{{KEYCLOAK_PORT}}|{{MEDIAMTX_WEBRTC_PORT}})\b' || true

sudo ss -lunp | grep ':{{MEDIAMTX_ICE_PORT}}\b' || true
```

Require:

- Keycloak and PostgreSQL running
- PostgreSQL healthy
- Nginx, MediaMTX, and MCP active
- oauth2-proxy port free
- MediaMTX WebRTC signaling bound to loopback
- MCP and Keycloak HTTP bound to loopback

Inspect only deployment metadata and `.env` key names:

```bash
sudo stat -c '%A %U %G %n' \
  "{{COMPOSE_DIR}}" \
  "{{COMPOSE_DIR}}/.env" \
  "{{COMPOSE_DIR}}/compose.yaml"

sudo sed -n 's/=.*//p' "{{COMPOSE_DIR}}/.env"

sudo docker compose --project-directory "{{COMPOSE_DIR}}" config --services
```

Never run expanded Compose configuration in shared output because it resolves
secret variables.

Resolve the active Nginx site and inspect it before assuming its filename:

```bash
sudo ls -l /etc/nginx/sites-enabled
sudo readlink -f /etc/nginx/sites-enabled/{{ACTIVE_SITE_LINK}}
sudo nginx -t
sudo nl -ba "{{NGINX_SITE}}"
```

Require one HTTPS server containing the target static, MediaMTX, Keycloak, MCP,
and protected-resource metadata locations.

Record current unauthenticated behavior:

```bash
for path in /cameras/ /multiview/ /outputs/ /webrtc/; do
  curl -sS -o /dev/null \
    -w "${path} HTTP %{http_code} redirect=%{redirect_url}\n" \
    "https://{{SERVER_FQDN}}${path}"
done

curl -sS -D - -o /dev/null "https://{{SERVER_FQDN}}/mcp"
```

A `404` at the bare `/outputs/` and `/webrtc/` root paths is an acceptable
baseline before protection exists: content in those families lives at deeper
paths, and Phase 7's location-level `auth_request` covers all of them
regardless.

## 2. Prepare the browser login user

Resolve `{{MCP_LOGIN_USER}}` by exact username in `{{MCP_REALM}}`. Require
exactly one enabled user with a nonempty email address. Resolve via the list
query (`/admin/realms/{realm}/users?username=...`) and filter for an exact
username match locally; there is no by-name direct lookup — fetch the full
user representation by the resolved UUID, never by name.

oauth2-proxy requests the `email` scope. Require:

```text
emailVerified = true
requiredActions = []
```

If the address was verified outside Keycloak but the flag is false, update
only `emailVerified=true` and retrieve the user directly afterward. Do not
change the password, email, enabled state, or required actions.

To update `emailVerified`, use PUT, not PATCH. Partial updates via
`PATCH /auth/admin/realms/{realm}/users/{uuid}` are rejected with HTTP 405 on
Keycloak 26 even though OPTIONS on the same endpoint returns 200. PUT is the
accepted mutation verb and carries replace semantics, so it must be performed
against the current live representation — never a hand-built or stale body.

Within one root-controlled process, using the admin token from the pattern
above (`{uuid}` = internal UUID resolved by the Phase 2 list query, not the
username):

```bash
umask 077
curl -sS -H "Authorization: Bearer ***" \
  "http://127.0.0.1:{{KEYCLOAK_PORT}}/auth/admin/realms/{{MCP_REALM}}/users/{uuid}" > /tmp/.kcuser.$$
# Change exactly one field in the retrieved JSON object: emailVerified -> true.
# Touch no other field and discard the result of any other source.
python3 -c "import json; u = json.load(open(\"/tmp/.kcuser.$$\")); u[\"emailVerified\"] = True; json.dump(u, open(\"/tmp/.kcpayload.tmp\", \"w\"))"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -X PUT \
  -H "Authorization: Bearer ***" -H "Content-Type: application/json" \
  --data @/tmp/.kcuser.$$ \
  "http://127.0.0.1:{{KEYCLOAK_PORT}}/auth/admin/realms/{{MCP_REALM}}/users/{uuid}"
```

Require HTTP 204, then re-retrieve directly by UUID and re-verify every Phase 2
invariant: exact username, enabled=true, nonempty email, emailVerified=true,
requiredActions=[]. Delete `/tmp/.kcuser.$$` and `/tmp/.kcpayload.tmp`
afterward. A successful PUT alone does not prove unchanged fields survived;
the re-retrieval is what closes this step. Do not set `emailVerified` to
false under any circumstances: with it false, every browser login fails at
`/oauth2/callback` (HTTP 500 from oauth2-proxy) before any session exists.

## 3. Create the confidential browser client

Require zero clients with exact client ID `{{BROWSER_CLIENT_ID}}`, then create
one OpenID Connect client with:

| Setting | Value |
|---|---|
| Client ID | `{{BROWSER_CLIENT_ID}}` |
| Enabled | `true` |
| Public client | `false` |
| Authenticator | `client-secret` |
| Standard flow | `true` |
| Implicit flow | `false` |
| Direct access grants | `false` |
| Service accounts | `false` |
| Authorization services | `false` |
| Consent required | `false` |
| Root URL | `https://{{SERVER_FQDN}}/` |
| Home URL | `https://{{SERVER_FQDN}}/cameras/` |
| Redirect URI | `https://{{SERVER_FQDN}}/oauth2/callback` |
| Post-logout redirect URI | `https://{{SERVER_FQDN}}/cameras/` |
| Web origin | `https://{{SERVER_FQDN}}` |
| PKCE method | `S256` |

Keycloak 26 Admin API field mapping. The table above uses console labels;
these are the representation fields (top-level `postLogoutRedirectUris` is
rejected with HTTP 400):

| Setting | Representation field |
|---|---|
| Root URL | `baseUrl` |
| Home URL | `attributes.frontend_url` |
| Post-logout redirect URI | `attributes["post.logout.redirect.uris"]` (string, comma-separated) |
| PKCE method | `attributes["pkce.code.challenge.method"]` |

Minimal accepted payload:

```json
{
  "clientId": "{{BROWSER_CLIENT_ID}}",
  "enabled": true,
  "publicClient": false,
  "clientAuthenticatorType": "client-secret",
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "consentRequired": false,
  "baseUrl": "https://{{SERVER_FQDN}}/",
  "attributes": {
    "frontend_url": "https://{{SERVER_FQDN}}/cameras/",
    "post.logout.redirect.uris": "https://{{SERVER_FQDN}}/cameras/",
    "pkce.code.challenge.method": "S256"
  },
  "redirectUris": ["https://{{SERVER_FQDN}}/oauth2/callback"],
  "webOrigins": ["https://{{SERVER_FQDN}}"]
}
```

Resolve the created client by exact client ID, require one match, capture its
live internal UUID, retrieve it directly, and verify every setting. Resolve via
the list query `/admin/realms/{realm}/clients?clientId={{BROWSER_CLIENT_ID}}`
and filter for an exact match: `/client-by-id/{X}` takes the *internal UUID*,
not the client name, and returns 404 with an error body for a client ID string
— do not parse that body as the representation.

Keycloak may omit optional boolean fields whose value is the default `false`.
During verification, treat an omitted optional boolean as false only when the
Keycloak representation documents that behavior. Do not broadly normalize
missing values without checking the field.

### Keycloak 26 client-creation compatibility

In the verified environment:

- `kcadm.sh create clients` with a JSON body on stdin produced a server-side
  null representation and failed.
- The installed `kcadm.sh` did not accept the attempted `-i` input-file flag.
- Host-side Admin REST calls to the loopback Keycloak listener were reliable.
- In the verified deployment, host-side REST using the admin-token pattern
  above was the consistent path: it avoided kcadm's prompting/TTY issues and
  its null-representation create failure in a single technique.

If the CLI creation path fails, use the Keycloak Admin REST API from the host.
Read the administrator password inside one root-controlled process, obtain an
admin token, create the client, and discard the token without printing it.
Never put the password or token in the command line or environment of an
untrusted process.

## 4. Store oauth2-proxy secrets

The protected file `{{COMPOSE_DIR}}/.env` must remain root-owned and mode
`0600`.

Before mutation:

1. Require no `OAUTH2_PROXY_*` keys.
2. Create `{{COMPOSE_DIR}}/.env.pre-oauth2-proxy` as root-owned mode `0600`.
3. Re-resolve the browser client UUID.

Within one root-controlled process:

1. Retrieve the generated client secret without printing it.
2. Append `OAUTH2_PROXY_CLIENT_SECRET=<value>`.
3. Generate 32 random bytes.
4. Encode them as URL-safe Base64.
5. Append `OAUTH2_PROXY_COOKIE_SECRET=<value>`.

Verify internally:

- `POSTGRES_PASSWORD`, `OAUTH2_PROXY_CLIENT_SECRET`, and
  `OAUTH2_PROXY_COOKIE_SECRET` each occur exactly once.
- Every value is nonempty.
- The stored client secret equals the live Keycloak client secret.
- The cookie secret decodes to exactly 32 bytes.
- File mode and ownership remain correct.

Keep separate data structures for key counts and secret values. A verification
script in the original experiment reused a count dictionary as a value
dictionary, crashed after mutation, and required restoring the backup before a
clean retry.

## 5. Add oauth2-proxy to Compose

Back up `compose.yaml` outside the active Compose model. Before pulling or
starting, confirm two things directly: (a) the public chain — Nginx listens on
the public IP, not loopback — so use `openssl s_client -connect {{SERVER_IP}}:443 -servername {{SERVER_FQDN}}`, then verify the leaf against the CA file
with `openssl verify -CAfile {{PRIVATE_CA_FILE}} ...`; if it does not verify, apply the
troubleshooting-section fix rather than disabling verification. (b) which flags
this docker build's `exec` actually supports (`docker exec --help`) before any
later step relies on TTY or stdin patterns.

Then back up `compose.yaml` outside the active Compose model and add:

```yaml
services:
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.15.3
    command:
      - --provider-ca-file=/etc/oauth2-proxy/private-root-ca.crt.pem
      - --use-system-trust-store=true
    restart: unless-stopped
    depends_on:
      - keycloak
    environment:
      OAUTH2_PROXY_PROVIDER: keycloak-oidc
      OAUTH2_PROXY_CLIENT_ID: {{BROWSER_CLIENT_ID}}
      OAUTH2_PROXY_CLIENT_SECRET: ${OAUTH2_PROXY_CLIENT_SECRET}
      OAUTH2_PROXY_COOKIE_SECRET: ${OAUTH2_PROXY_COOKIE_SECRET}
      OAUTH2_PROXY_OIDC_ISSUER_URL: https://{{SERVER_FQDN}}/auth/realms/{{MCP_REALM}}
      OAUTH2_PROXY_REDIRECT_URL: https://{{SERVER_FQDN}}/oauth2/callback
      OAUTH2_PROXY_HTTP_ADDRESS: {{CONTAINER_BIND_IP}}:{{OAUTH2_PROXY_PORT}}
      OAUTH2_PROXY_UPSTREAMS: static://202
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      OAUTH2_PROXY_SCOPE: "openid profile email"
      OAUTH2_PROXY_CODE_CHALLENGE_METHOD: S256
      OAUTH2_PROXY_REVERSE_PROXY: "true"
      OAUTH2_PROXY_SET_XAUTHREQUEST: "true"
      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: "true"
      OAUTH2_PROXY_COOKIE_NAME: _camera_auth
      OAUTH2_PROXY_COOKIE_SECURE: "true"
      OAUTH2_PROXY_COOKIE_SAMESITE: lax
      OAUTH2_PROXY_COOKIE_EXPIRE: 8h
      OAUTH2_PROXY_COOKIE_REFRESH: 4m
    volumes:
      - {{PRIVATE_CA_FILE}}:/etc/oauth2-proxy/private-root-ca.crt.pem:ro
    ports:
      - {{LOOPBACK_IP}}:{{OAUTH2_PROXY_PORT}}:{{OAUTH2_PROXY_PORT}}
```

Parse the original and candidate YAML. Require the existing PostgreSQL,
Keycloak, and volume structures to compare equal as Python objects. Verify the
new service field by field. YAML formatting differences do not cause parsed
dictionary inequality; if parsed objects differ, locate the actual value or
type difference.

The service has 19 environment keys: 17 non-secret values and 2 literal
`${...}` references. Validate raw, unexpanded YAML and run only:

```bash
sudo docker compose --project-directory "{{COMPOSE_DIR}}" config --quiet
sudo docker compose --project-directory "{{COMPOSE_DIR}}" config --services
```

Pull and start only oauth2-proxy:

```bash
sudo docker compose --project-directory "{{COMPOSE_DIR}}" pull oauth2-proxy
sudo docker compose --project-directory "{{COMPOSE_DIR}}" up -d oauth2-proxy
```

Verify:

```bash
curl -sS -o /dev/null -w 'Ping: HTTP %{http_code}\n' \
  "http://{{LOOPBACK_IP}}:{{OAUTH2_PROXY_PORT}}/ping"

curl -sS -D - -o /dev/null \
  -H 'Host: {{SERVER_FQDN}}' \
  -H 'X-Forwarded-Proto: https' \
  "http://{{LOOPBACK_IP}}:{{OAUTH2_PROXY_PORT}}/oauth2/auth"
```

Expected results: ping `200`, authorization check `401`, and host listener
bound only to `{{LOOPBACK_IP}}`.

## 6. Add Nginx oauth2-proxy routes

Back up the active site outside `sites-enabled`. Every regular file beneath
`sites-enabled` can become active configuration.

Add these blocks inside the HTTPS server before protected application routes.
Canonical insertion anchor in the verified deployment: immediately before the
`location /cameras/ {` line — the first protected application route; verify
each new block sits after the `listen ... 443 ssl;` line and occurs exactly
once. Do not reload Nginx after this phase: the single reload happens in
Phase 7, after auth_request protection lands, so the site never runs with
half-wired protection.

```nginx
location = /oauth2/auth {
    proxy_pass http://{{LOOPBACK_IP}}:{{OAUTH2_PROXY_PORT}};
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location /oauth2/ {
    proxy_pass http://{{LOOPBACK_IP}}:{{OAUTH2_PROXY_PORT}};
    proxy_http_version 1.1;

    proxy_buffer_size 32k;
    proxy_buffers 8 32k;
    proxy_busy_buffers_size 64k;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location @oauth2_signin {
    return 302 /oauth2/start?rd=$request_uri;
}
```

The relative `rd=$request_uri` preserves the requested application path. The
larger buffers prevent successful callback responses from failing when session
cookie headers exceed Nginx defaults.

Validate before reload:

```bash
sudo nginx -t
```

## 7. Protect applications and WebRTC signaling

Add the following exactly once at the beginning of each `/cameras/`,
`/multiview/`, `/outputs/`, and `/webrtc/` location:

```nginx
auth_request /oauth2/auth;
error_page 401 = @oauth2_signin;
auth_request_set $auth_cookie $upstream_http_set_cookie;
add_header Set-Cookie $auth_cookie always;
```

Preserve all existing static-file, MediaMTX, WebSocket, redirect, proxy-header,
and timeout directives.

Do not add browser protection to Keycloak, oauth2-proxy, MCP, or protected-
resource metadata routes.

Show an incremental diff, require only the intended directive groups, then:

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl is-active nginx
```

## 8. Verify unauthenticated behavior

```bash
for path in /cameras/ /multiview/ /outputs/ /webrtc/; do
  curl -sS -o /dev/null \
    -w "${path} HTTP %{http_code} redirect=%{redirect_url}\n" \
    "https://{{SERVER_FQDN}}${path}"
done
```

Every route must return `302` to `/oauth2/start` with its original path in
`rd=`.

Also require:

- `/oauth2/ping` returns `200`.
- `/oauth2/start?rd=/cameras/` redirects to the Keycloak authorization path.
- The redirect includes client ID, callback, response type, scope, state, and
  S256 challenge parameter names. Do not print their values.
- Keycloak discovery still returns `200`.
- Unauthenticated `/mcp` still returns `401` with protected-resource metadata.
- All containers and services remain healthy.

## 9. Verify browser behavior

Use a private/incognito browser session (or the scripted headless
alternative given after step 6). Either way, confirm:

1. Open `https://{{SERVER_FQDN}}/cameras/`.
2. Authenticate as `{{MCP_LOGIN_USER}}`.
3. Confirm the requested page appears after callback.
4. Open `/multiview/` in the same browser session.
5. Open a known direct `/webrtc/.../` stream URL.
6. Confirm no second login is required and live video plays.

If the user password was generated by the deployment agent, read it only
inside one root-controlled process on the server (for example from
`/opt/keycloak/mcp-user.pass`). Do not copy it into chat, documentation, or a
command line; never persist browser cookies to disk in a scripted run — use an
in-memory cookie jar.

Agent-executable alternative: a scripted headless flow with an in-memory
cookie jar verifies steps 1-4 and the WebRTC pass-through without a human.
Expected status sequence: unauthenticated `302` chain to the Keycloak
authorization endpoint (PKCE parameter names present), login form with fields
`credentialId`, `username`, `password`; after POST, callback parameters
`code`, `iss`, `session_state`, `state`; then a `302` landing exactly on the
requested path with HTTP 200 — not the site root. In oauth2-proxy 7.15.x an
authenticated `/oauth2/ping` answers HTTP 202 with body `Authenticated`;
unauthenticated it redirects to sign-in. The WebRTC check asserts that a
known direct stream URL under `/webrtc/.../` passes auth to MediaMTX without a
login bounce (any non-302-to-sign-in outcome such as 200 is the expected
signaling response). Live-video rendering remains a human confirmation only —
UDP ICE/DTLS/SRTP cannot be asserted over HTTP checks.

Finally verify Hermes MCP access remains independent:

```bash
hermes mcp test {{HERMES_SERVER_NAME}}
```

## 10. Backup checkpoint

After the browser client and successful login exist, run the manual Keycloak
backup service:

```bash
sudo systemctl start keycloak-postgres-backup.service
sudo systemctl status keycloak-postgres-backup.service --no-pager
```

Require:

- one new nonempty `keycloak-*.dump`
- mode `0600`, owner/group `root:root`
- safe basename without `/`
- successful `pg_restore --list` with detail output suppressed. The dump is
  root-owned mode `0600`, so the host shell must read it as root and stream it
  into the postgres container:

```bash
sudo bash -c 'cat /var/backups/keycloak-postgres/DUMP_FILE.dump | \
  docker exec -i keycloak-postgres-1 sh -c "cat > /tmp/.chk.dump && pg_restore --list /tmp/.chk.dump >/dev/null 2>&1; echo pg_restore_exit=\$?"'
```

  Require `pg_restore_exit=0`, then remove `/tmp/.chk.dump` from the container.
- no unintended timer creation
- all services healthy afterward

## Troubleshooting

### oauth2-proxy restarts with unknown CA

Mount the public private-CA root certificate and provide it using the explicit
`--provider-ca-file` command argument. Do not disable verification.

### Nginx returns 502 after successful login

Inspect the Nginx error log for `upstream sent too big header`. Verify the
32 KiB/64 KiB buffer settings in `/oauth2/`, reload Nginx, and retry from a new
private browser session.

### Login returns to the site root

Require:

```nginx
return 302 /oauth2/start?rd=$request_uri;
```

Do not replace it with an absolute redirect destination in this configuration.

### oauth2-proxy was configured but is absent

Do not infer that a prior agent ran the pull or start commands. Verify directly
with Compose, ping, and the host listener. Run pull and start as separate
bounded steps.

### Agent reports an unrelated task

Pause all mutations and reconcile direct system state. During the verified
deployment, an agent returned a stale Hermes OAuth cleanup report instead of
starting oauth2-proxy. Direct inspection showed that no image or container had
been created. Resume with one command per step until context is stable.

## Security notes

- Keep `.env` root-owned and mode `0600`.
- Keep oauth2-proxy bound to `{{LOOPBACK_IP}}`.
- Keep `Secure` and `SameSite=Lax` on the browser cookie.
- Use exact redirect URIs and web origins; do not use broad wildcards.
- Do not bypass the private CA.
- Browser cookies and Hermes MCP tokens are independent credentials.
- All authenticated browser users currently receive access to all four route
  families. Add Keycloak roles/groups and corresponding authorization policy
  if per-user or per-route access is required.
- Same-host backups do not protect against host or disk loss.

## Final checklist

- Confidential browser client exists with exact redirect and origin.
- Login user has a nonempty verified email.
- oauth2-proxy secrets are stored once and never printed.
- oauth2-proxy is bound only to loopback and returns ping `200`.
- Direct unauthenticated auth check returns `401`.
- Nginx oauth2 support routes are active.
- All four browser route families redirect unauthenticated users to login.
- Keycloak login returns users to the requested route.
- Static apps load after authentication.
- Direct WebRTC playback works after authentication.
- MCP continues to return `401` without a bearer token.
- Hermes reconnects independently with saved OAuth state.
- Post-configuration backup exists and has a valid archive catalog.
