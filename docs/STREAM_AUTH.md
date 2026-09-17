# Keycloak Authentication for Camera Apps, WebRTC Streams, and Snapshots

## Purpose

This runbook adds browser-session authorization to camera applications and
WebRTC signaling and live JPEG snapshots while preserving the MCP server's
independent OAuth bearer-token flow.

The implementation uses:

- Keycloak as the OpenID Connect provider
- oauth2-proxy for Authorization Code flow with PKCE and encrypted sessions
- Nginx `auth_request` for route enforcement
- The existing MediaMTX service for WebRTC signaling and encrypted media
- The existing MCP resource-server JWT validation for Hermes
- The existing snapshot proxy for live JPEG images

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
| `{{BACKUP_PATH}}` | Backup folder |


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
| `{{SNAPSHOT_PORT}}` | 8891 | Loopback snapshot proxy HTTP port |
| `{{COMPOSE_DIR}}` | /opt/keycloak | Keycloak Compose project directory |
| `{{ACTIVE_SITE_LINK}}` | — (no symlink; see preflight note) | Enabled Nginx site name; in this deployment the live config is a plain file in `/etc/nginx/conf.d/`, not a symlink |
| `{{NGINX_SITE}}` | /etc/nginx/conf.d/{{SERVER_FQDN}}.conf | Active Nginx site for this deployment |
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
  |-- /webrtc/
  |       `-- auth_request /oauth2/auth, then MediaMTX signaling
  |
  `-- /snapshot/
          `-- auth_request /oauth2/auth, then snapshot proxy 127.0.0.1:8891
                  `-- camera snapshot endpoint (Basic/Digest authentication)

Hermes
  `-- /mcp ----------------------------> MCP JWT validation
```

Nginx protects WebRTC HTTP signaling. MediaMTX's UDP ICE/DTLS/SRTP path
remains a separate network flow. Keep the signaling listener on loopback and
restrict the UDP port to the intended LAN or VPN networks with the firewall.

Snapshot JPEGs travel entirely through Nginx and the loopback snapshot proxy;
there is no separate UDP media path. Camera-side Basic/Digest authentication
remains the snapshot proxy's responsibility. See SNAPSHOT.md for installation
and camera/profile route coverage. This runbook adds the browser access gate
to that existing service.

The MCP `get_snapshot` tool uses the loopback snapshot proxy directly after
MCP authentication. Public `web_snapshot_url` links use the browser gate.
Hermes does not need a browser session cookie to call `get_snapshot`.

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
sudo systemctl is-active nginx mediamtx onvif-mcp-http.service snapshot-proxy.service

sudo ss -ltnp | grep -E \
  ':({{OAUTH2_PROXY_PORT}}|{{MCP_HTTP_PORT}}|{{KEYCLOAK_PORT}}|{{MEDIAMTX_WEBRTC_PORT}}|{{SNAPSHOT_PORT}})\b' || true

sudo ss -lunp | grep ':{{MEDIAMTX_ICE_PORT}}\b' || true
```

Require:

- Keycloak and PostgreSQL running
- PostgreSQL healthy
- Nginx, MediaMTX, MCP, and snapshot-proxy active
- oauth2-proxy port free
- MediaMTX WebRTC signaling bound to loopback
- MCP and Keycloak HTTP bound to loopback
- Snapshot proxy HTTP bound only to `{{LOOPBACK_IP}}:{{SNAPSHOT_PORT}}`

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

Resolve the active Nginx site and inspect it before assuming its filename.
Confirm whether `/etc/nginx/sites-enabled/` is empty; when it is, the live site
is normally a single file, `/etc/nginx/conf.d/{{SERVER_FQDN}}.conf`, included via
`include /etc/nginx/conf.d/*.conf;`. Confirm its HTTPS server's `listen`
directive and `server_name {{SERVER_FQDN}}` against the live file (`nginx -T`)
rather than assuming either, and confirm it contains all target locations
(static apps, `/webrtc/`, `/snapshot/`, `/auth/`, `= /mcp`,
`= /.well-known/oauth-protected-resource/mcp`). Inspect the port-80 server for
the same name: if it has no unprotected snapshot location and redirects every
path to `https://{{SERVER_FQDN}}$request_uri`, Phase 7's HTTP-to-HTTPS snapshot
redirect is already in place.

Note: `readlink -f` cannot fail on a nonexistent target — it returns the
argument itself. Do not use that command alone as an existence check.

```bash
sudo ls -l /etc/nginx/sites-enabled /etc/nginx/conf.d
sudo readlink -f /etc/nginx/sites-enabled/{{ACTIVE_SITE_LINK}}
sudo nginx -t
sudo nl -ba "{{NGINX_SITE}}"
```

Require one HTTPS server containing the target static, MediaMTX, snapshot,
Keycloak, MCP, and protected-resource metadata locations. Inspect the active
HTTP server too: record any snapshot route that still serves an unprotected
copy, and include its HTTPS redirect correction in Phase 7. In this
deployment the port-80 server redirects all paths to HTTPS, so no correction
is needed. If the snapshot location is absent from HTTPS,
use the location in SNAPSHOT.md Step 6 as the basis for the protected block
in Phase 7; do not reload an unprotected intermediate configuration.

Resolve a known working camera serial/profile pair from the existing snapshot
route table or camera registry. Use its exact spelling to set `SNAPSHOT_PATH`
in the shell used for subsequent checks (replace both placeholders). In this
deployment: `4B0013BPAABE264` / `MediaProfile000` also answers 200 alongside
`5CF2075C9F49/profile1` and `/profile2` (verified in the 2026-09-08 preflight).

```bash
export SNAPSHOT_PATH="/snapshot/4B0013BPAABE264/MediaProfile000/"
curl --fail --silent --show-error --max-time 65 \
  "http://{{LOOPBACK_IP}}:{{SNAPSHOT_PORT}}${SNAPSHOT_PATH}" \
  -o /dev/null -w 'Snapshot upstream: HTTP %{http_code} type=%{content_type}\n'
```

Require `200 image/jpeg` and validate the body as a JPEG using SNAPSHOT.md
Step 5 before proceeding. A missing or failing proxy is a prerequisite failure.
Confirm route coverage for the camera profiles referenced by the applications.
Record baseline public access for this same path in addition to the roots
below; a root-only check does not prove a real snapshot can be retrieved.

Record current unauthenticated behavior:

```bash
for path in /cameras/ /multiview/ /outputs/ /webrtc/ /snapshot/ "$SNAPSHOT_PATH"; do
  curl -sS -o /dev/null \
    -w "${path} HTTP %{http_code} redirect=%{redirect_url}\n" \
    "https://{{SERVER_FQDN}}${path}"
done

curl -sS -D - -o /dev/null "https://{{SERVER_FQDN}}/mcp"
```

A `404` at the bare `/outputs/` and `/webrtc/` root paths is an acceptable
baseline before protection exists: content in those families lives at deeper
paths, and Phase 7's location-level `auth_request` covers all of them
regardless. Observed preflight baseline (2026-09-08): `/cameras/` 200,
`/multiview/` 200, `/outputs/` **403** (no index file at the bare root),
`/webrtc/` 404, `/snapshot/` 400, the known snapshot path 200 with a JPEG
body, and `/mcp` 401.

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
If the emailVerified flag is false, stop and prompt the user to enter an email account.

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

client's top-level representation might not return `authorizationServicesEnabled`
That is the documented default-false omission; it is consistent
with the `false` sent at creation, so no action is required.

The client secret is carried in the top-level field **`secret`**, not
`clientSecret` (which is absent from this representation). Keycloak 26 also
exposes a dedicated endpoint:
`GET /auth/admin/realms/{realm}/clients/{uuid}/client-secret`, returning an
object with `type` and `value` keys. Fetch the secret via either path without
printing it.

A re-run of this phase must first find the existing client and stop — do not 
create a second.

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

1. Retrieve the generated client secret without printing it — from the
   representation's top-level `secret` field (not `clientSecret`, which is
   absent), or via the dedicated
   `/auth/admin/realms/{{MCP_REALM}}/clients/{uuid}/client-secret` endpoint
   (object with `type` and `value` keys). Compare for equality using a byte
   buffer, never string interpolation into a command line.
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

Back up `compose.yaml` before editing it. Purpose: the §5 edit mutates the live
Compose model in place, so the pre-change copy is the immediate-rollback path if
the new service breaks the stack, and the provenance record for future diffs.
Destination: `/opt/keycloak/compose.yaml.pre-oauth2-proxy` — a suffixed sibling
in the project directory is safe (verified: `docker compose` loads only
`compose.yaml`/`compose.override.yaml`; suffixed siblings never enter the model)
and keeps it inside the `/opt/keycloak` tree so the Section 10 tar captures it
into every downstream `final-opt-keycloak.tar` — no separate SMB copy needed.
Never name it `compose.override.yaml`: that name IS the active Compose model.

Before pulling or starting, confirm two things directly: (a) the public chain — Nginx listens on
the public IP, not loopback — so use `openssl s_client -connect {{SERVER_IP}}:443 -servername {{SERVER_FQDN}}`, then verify the leaf against the CA file
with `openssl verify -CAfile {{PRIVATE_CA_FILE}} ...`; if it does not verify, apply the
troubleshooting-section fix rather than disabling verification. (b) which flags
this docker build's `exec` actually supports (`docker exec --help`) before any
later step relies on TTY or stdin patterns.

```bash
sudo cp -a "{{COMPOSE_DIR}}/compose.yaml" "{{COMPOSE_DIR}}/compose.yaml.pre-oauth2-proxy"
```

Then add to `compose.yaml`:

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

Back up the active site before editing it. Purpose: this phase rewrites the live
HTTPS vhost in place; the pre-change copy is the rollback path if the oauth2
routes break TLS serving, and the provenance record for §7's auth_request edits.

Destination rules differ from §5's Compose backup: unlike Compose, nginx loads
EVERY regular file beneath `sites-enabled/` and `conf.d/`, so an in-place
suffixed sibling becomes a live duplicate `server_name` vhost. The backup must
live outside both directories. Required location (same retention rationale as
§5 — inside the tree that Section 10's tar sweeps into every downstream
`final-opt-keycloak.tar`):

```bash
sudo cp -a "{{NGINX_SITE}}" "{{COMPOSE_DIR}}/{{SERVER_FQDN}}.conf.pre-stream-auth"
```

Verify the backup exists and the live site is untouched before editing:

```bash
sudo cmp "{{NGINX_SITE}}" "{{COMPOSE_DIR}}/{{SERVER_FQDN}}.conf.pre-stream-auth"
```

Add these blocks inside the HTTPS server before protected application routes.
Canonical insertion anchor in this deployment: immediately before the
`location /cameras/ {` block in `/etc/nginx/conf.d/{{SERVER_FQDN}}.conf`
— the first protected application route. Locate the anchor by content:
`sudo grep -n 'location /cameras/ {' "{{NGINX_SITE}}"` — expect exactly one
match. Verify
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

## 7. Protect applications, WebRTC signaling, and snapshots

Add the following exactly once at the beginning of each `/cameras/`,
`/multiview/`, `/outputs/`, `/webrtc/`, and `/snapshot/` location:

```nginx
auth_request /oauth2/auth;
error_page 401 = @oauth2_signin;
auth_request_set $auth_cookie $upstream_http_set_cookie;
add_header Set-Cookie $auth_cookie always;
```

Preserve all existing static-file, MediaMTX, WebSocket, redirect, proxy-header,
and timeout directives. Preserve the snapshot location's existing proxy
headers, 30-second read/send timeouts, and cache controls. Its upstream must
retain the snapshot path, as in SNAPSHOT.md:

```nginx
proxy_pass http://{{LOOPBACK_IP}}:{{SNAPSHOT_PORT}}/snapshot/;
proxy_read_timeout 30s;
proxy_send_timeout 30s;
proxy_no_cache on;
proxy_cache_bypass on;
```

During this phase, change any HTTP snapshot route identified in preflight to
redirect to the same path on the public HTTPS origin. Preserve query strings.
In this deployment the port-80 server already redirects all paths to HTTPS, so
no new redirect is required — verify that behavior instead of editing it.

Keep these inside the protected `location /snapshot/` block; do not create a
second competing location. Preserve the proxy's `Cache-Control: no-store`
response header. The camera credentials and route table need no changes.

Confirm `STREAM_SERVER_URL` on the MCP HTTP service is
`https://{{SERVER_FQDN}}`, and that browser-facing snapshot links in the
application registry use HTTPS on the same origin. If a value still uses HTTP,
update its authoritative configuration and regenerate affected links before
verification. Restart the MCP HTTP service only if its environment changed.
Inspect only the relevant non-secret setting, not the complete environment.

Do not add browser protection to Keycloak, oauth2-proxy, MCP, or protected-
resource metadata routes.

Show an incremental diff, require only the intended authentication directives
and any necessary snapshot routing, HTTPS redirect, or URL corrections, then:

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl is-active nginx
```

## 8. Verify unauthenticated behavior

```bash
for path in /cameras/ /multiview/ /outputs/ /webrtc/ /snapshot/ "$SNAPSHOT_PATH"; do
  curl -sS -o /dev/null \
    -w "${path} HTTP %{http_code} redirect=%{redirect_url}\n" \
    "https://{{SERVER_FQDN}}${path}"
done
```

Every route must return `302` to `/oauth2/start` with its original path in
`rd=`. Test with no session cookie and do not follow the HTTPS login redirect.
The known snapshot path must not return image content without authentication.
Also check the old HTTP entry point:

```bash
curl -sS -o /dev/null \
  -w 'Snapshot HTTP: %{http_code} redirect=%{redirect_url}\n' \
  "http://{{SERVER_FQDN}}${SNAPSHOT_PATH}"
```

Require a redirect to the same path on `https://{{SERVER_FQDN}}`; follow that
destination separately without cookies and require the login redirect above.
No active HTTP virtual host or alternate snapshot location may serve an
unprotected JPEG. Confirm the loopback proxy port is not publicly exposed.

Also require:

- Unauthenticated `/oauth2/ping` redirects to sign-in; an authenticated session answers HTTP `202` with body `Authenticated` (oauth2-proxy 7.15.x semantics — see the Phase 9 note below).
- `/oauth2/start?rd=/cameras/` redirects to the Keycloak authorization path.
- The redirect includes client ID, callback, response type, scope, state, and
  S256 challenge parameter names. Do not print their values.
- Keycloak discovery still returns `200`.
- Unauthenticated `/mcp` still returns `401` with protected-resource metadata.
- All containers and services remain healthy.

## 9. Verify browser behavior

This phase is agent-driven: there is no manual browser step. The scripted
headless driver `scripts/stream_auth_step9_driver.py` performs the whole flow in
one process using in-memory cookie jars (never persisted to disk) and asserts
status codes, parameter *names* only, and landing paths — never values.

Run it from the repository root:

```bash
python3 scripts/stream_auth_step9_driver.py --origin "https://{{SERVER_FQDN}}"
```

All deployment-specific values are CLI parameters (`--origin`, `--target`,
`--second-route`, `--snapshot-path`, `--webrtc-url`, `--realm`, `--username`,
`--password-file`). `--origin` is mandatory: an inherited example hostname can
send this deployment's password to another server. Other arguments retain example
defaults; resolve the camera/profile paths locally and override them as needed.
The driver verifies TLS using the system CA store; install the private root CA
rather than disabling certificate or hostname verification.

The driver reads `{{MCP_LOGIN_USER}}`'s password by itself, inside that one
root-capable process (default source `/opt/keycloak/mcp-user.pass`). The
password must not be copied into chat, documentation, or a command line.
Driver implementation notes that a re-run must preserve:

- Hidden form inputs without a `value` attribute exist in the login form;
  parsers must default them to an empty string (naive group fallbacks crash
  on the first one).
- All cookie jars stay in memory; do not add any file-backed jar.
- Snapshot image checks use GET: the snapshot proxy implements GET, not HEAD.

Assertions performed (all must pass):

1. Unauthenticated `https://{{SERVER_FQDN}}/cameras/` returns `302` to
   `/oauth2/start?rd=/cameras/`, preserving the requested path.
2. One hop from `/oauth2/start` reaches the Keycloak authorization endpoint
   (`/auth/realms/{{MCP_REALM}}/protocol/openid-connect/auth`) carrying the
   parameter names `client_id`, `redirect_uri`, `response_type`, `scope`,
   `state`, `code_challenge`, and `code_challenge_method=S256`. Values are
   never inspected or printed.
3. The login form presents fields named exactly `credentialId`, `username`,
   and `password`; after a single authenticated POST (no consent screen — the
   client has `consentRequired=false`), the session lands **exactly** on the
   requested path `/cameras/` with HTTP 200 HTML — not the site root.
4. An authenticated `GET /oauth2/ping` answers HTTP 202 with body
   `Authenticated` (oauth2-proxy 7.15.x semantics).
5. `/multiview/` in the same session returns 200 HTML with no second login.
6. A known direct WebRTC stream URL under `/webrtc/.../` passes authentication
   without a sign-in bounce (any non-302-to-sign-in outcome, such as the 200
   signaling page, is the expected pass-through result).
7. The known `https://{{SERVER_FQDN}}${SNAPSHOT_PATH}` in the same session
   returns 200 with `Content-Type: image/jpeg`, a body starting with the JPEG
   magic bytes (`FF D8 FF`), and `Cache-Control: no-store`; no second login.
8. In a **fresh** unauthenticated session, the direct snapshot URL redirects
   to `/oauth2/start?rd=<snapshot path>`; completing login in that session
   returns to the requested snapshot itself (not the site root) and serves a
   valid JPEG with `no-store`. A redirect to an HTML login page or merely a
   non-302 response is not success.

Out of scope for this phase by design: live video rendering (UDP ICE/DTLS/SRTP
cannot be asserted over HTTP checks) and confirming images display inside the
camera applications — both remain human confirmations, recorded separately.

Then run the MCP regression checks (record them as pending if REGISTER.md has
not yet been completed):

- Call `get_cameras` through authenticated MCP and verify every
  `web_snapshot_url` uses the expected HTTPS origin and exact profile paths.
- Call `get_snapshot` for the known camera/profile and require a valid image
  result **without supplying browser cookies** (server-to-server path).
- Verify the snapshot proxy target is loopback: on the MCP HTTP service,
  `SNAPSHOT_PROXY_URL` must be unset or explicitly `http://{{LOOPBACK_IP}}:{{SNAPSHOT_PORT}}`,
  never the public browser-protected URL. The code default when the variable
  is unset is loopback (`_SNAPSHOT_PROXY_DEFAULT = "http://127.0.0.1:8891"` in
  `packages/core/src/onvif_mcp_core/streaming.py`).

Finally verify Hermes MCP access remains independent:

Before starting a new login, back up the existing OAuth state privately and check
the actual authorization request includes `scope=mcp:tools` (and
`offline_access` if refresh access is wanted). Registration metadata containing a
scope does not prove that the authorization URL requests it. For this deployment:

```bash
hermes config set mcp_servers.camera-new.oauth.scope 'offline_access mcp:tools'
hermes config set mcp_servers.camera-new.ssl_verify /etc/ssl/certs/ca-certificates.crt
```

Resolve the entry name first; do not blindly modify `camera-new` on another host.
The CA bundle must contain the private root. Hermes' HTTP client may otherwise
use a bundled public CA store instead of the host store. Do not set
`ssl_verify=false`. Run only one login at a time: `hermes mcp login`/`reauth`
clears saved OAuth state, so it is not a read-only diagnostic. Inspect non-secret
claim summaries and require the MCP audience and scope before retrying a failed
connection. Do not make MCP scopes realm-wide defaults to mask a missing scope
parameter. See `STREAM_AUTH_RECOVERY.md` for the verified recovery and evidence.

```bash
hermes mcp test {{HERMES_SERVER_NAME}}
```

Verified execution (2026-09-08, all assertions passed): the login form
presented exactly `credentialId`/`username`/`password`; landing was exactly on
the requested path; authenticated ping returned 202 `Authenticated`; WebRTC
pass-through answered 200 with no bounce; both snapshot checks (in-session and
fresh-session) served real JPEGs with `no-store`. `get_cameras` returned all
seven cameras with HTTPS-origin `web_snapshot_url` values; `get_snapshot` for
`4B0013BPAABE264`/`MediaProfile000` returned a valid 181 KB JPEG without
browser cookies; `SNAPSHOT_PROXY_URL` is unset on the MCP service, so the
loopback default applies; `hermes mcp test camera-new` connected via saved
OAuth state.

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

The dump now exists ONLY at `/var/backups/keycloak-postgres/` (14-day local
retention). Copying it to `{{BACKUP_PATH}}` does not happen automatically —
no service or timer performs it — and this stage's checkpoint is worthless
until it lands on the share. Close this stage now, per BACKUP.md's Procedure,
into `{{BACKUP_PATH}}/stream-auth-{{DATETIME_STAMP}}` with:

- `final-var-backups-keycloak-postgres.tar` — the dump set INCLUDING the
  checkpoint dump just taken (this stage's dump is the restore source for
  later stages until superseded by add-user/add-client).
- `final-opt-keycloak.tar` — supersedes the keycloak folder's copy (compose
  now has the oauth2-proxy service; `.env` has the client/cookie secrets);
  same creation rules as KEYCLOAK.md §15b.
- `final-etc-nginx-conf.d.tar` — newest complete conf.d (adds `/oauth2/*` +
  `auth_request`); run the unpinned-listener check from CA_DISTRIBUTE.md
  "Stage-close backup" BEFORE archiving — this folder's conf.d is what a
  restore uses LAST, and the 2026-09-12 archive here carried the pinned
  `listen` forward into the newest set (D6; the restore must otherwise
  re-apply the amendment by hand).
- pre/post change state files (`.env` key names + counts only, values never;
  `.env.pre-oauth2-proxy.sha256` as the pre-change fingerprint — the pre-change
  `.env` content itself stays in the keycloak folder's tar, no duplicate
  secret copies on the share), `compose.yaml.pre-oauth2-proxy`,
  `final-docs-BACKUP.md`, `SHA256SUMS`.

Supersession: supersedes the keycloak folder's `final-opt-keycloak.tar`,
dump set, and conf.d. Superseded later for opt-tar/dumps by add-user-*, then
add-client-on-server-*. Verify before closing as in KEYCLOAK.md §15b (checksum
round-trip, tar non-empty guards, dump catalog listing).

## Troubleshooting

### `/outputs/` returns 404 without a login redirect

Nginx `return 404` executes in the rewrite phase, before `auth_request`. In a
protected fallback location intended to serve no files, replace it with
`try_files "" =404;` so the authentication access phase runs first. Preserve the
separately protected exact `/outputs/camera_registry.json` location. Validate,
reload, and check new requests after workers have adopted the configuration:
unauthenticated fallback requests must redirect; authenticated ones remain 404.

### `curl --cacert {{PRIVATE_CA_FILE}}` reports "file does not exist"

The CA file exists and is world-readable, but direct curl use of it failed
intermittently during the 2026-09-08 preflight ("badly used here") while a
byte-identical copy (md5-verified) in a temporary path worked. If this
recurs, copy the CA to a temporary file for verification commands and remove
the copy afterward. Do not treat the failure as certificate invalidity.

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
- All authenticated browser users currently receive access to all five route
  families. Add Keycloak roles/groups and corresponding authorization policy
  if per-user or per-route access is required.
- Keep the snapshot proxy bound to loopback; public snapshot access goes
  through the protected HTTPS location. HTTP must redirect to HTTPS.
- Preserve `Cache-Control: no-store` on JPEG responses.
- Same-host backups do not protect against host or disk loss.

## Final checklist

- Confidential browser client exists with exact redirect and origin.
- Login user has a nonempty verified email.
- oauth2-proxy secrets are stored once and never printed.
- oauth2-proxy is bound only to loopback and returns ping `200`.
- Direct unauthenticated auth check returns `401`.
- Nginx oauth2 support routes are active.
- All five browser route families redirect unauthenticated users to login.
- Keycloak login returns users to the requested route.
- Static apps load after authentication.
- Direct WebRTC playback works after authentication.
- Snapshot proxy is active and bound only to loopback.
- Known direct snapshot URL redirects to login without a browser session.
- Authenticated snapshots return valid JPEGs with `Cache-Control: no-store`.
- Direct snapshot login returns to the requested image.
- HTTP snapshot access redirects to HTTPS; generated browser links use HTTPS.
- After Hermes registration, MCP `get_snapshot` returns an image independently
  of browser cookies.
- MCP continues to return `401` without a bearer token.
- Hermes reconnects independently with saved OAuth state.
- Post-configuration backup exists and has a valid archive catalog.
