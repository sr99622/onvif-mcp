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

Protected browser routes:

```text
/cameras/
/multiview/
/outputs/
/webrtc/
```

Routes that must remain independent and must not receive browser
`auth_request` protection:

```text
/auth/
/oauth2/
/mcp
/.well-known/oauth-protected-resource/mcp
```

## Status

This procedure reflects the current agent-guided deployment. It was verified
with Keycloak 26.7.0 and oauth2-proxy 7.15.3.

The procedure is suitable for supervised agent execution in bounded phases.
It is not yet intended as a fully unattended orchestration script.

## Symbolic deployment values

Replace every symbolic value with the target environment's actual value.

| Symbol | Meaning |
|---|---|
| `{{SERVER_FQDN}}` | Public DNS name shared by Nginx, Keycloak, and MCP |
| `{{SERVER_IP}}` | Address on which Nginx accepts public HTTPS |
| `{{LOOPBACK_IP}}` | Host loopback address used for private listeners |
| `{{MCP_REALM}}` | Keycloak realm, normally `mcp` |
| `{{MCP_LOGIN_USER}}` | Browser login user |
| `{{BROWSER_CLIENT_ID}}` | Confidential browser client, normally `camera-web` |
| `{{CONTAINER_BIND_IP}}` | In-container wildcard address used by oauth2-proxy |
| `{{KEYCLOAK_PORT}}` | Loopback Keycloak HTTP port, normally `8080` |
| `{{OAUTH2_PROXY_PORT}}` | Loopback oauth2-proxy port, normally `4180` |
| `{{MCP_HTTP_PORT}}` | Loopback MCP HTTP port, normally `8001` |
| `{{MEDIAMTX_WEBRTC_PORT}}` | Loopback MediaMTX signaling port, normally `8889` |
| `{{MEDIAMTX_ICE_PORT}}` | MediaMTX UDP ICE/media port, normally `8189` |
| `{{COMPOSE_DIR}}` | Keycloak Compose project directory |
| `{{ACTIVE_SITE_LINK}}` | Enabled Nginx site symlink name |
| `{{NGINX_SITE}}` | Active Nginx site file outside `sites-enabled` |
| `{{PRIVATE_CA_FILE}}` | Public private-CA root certificate on the server |
| `{{HERMES_SERVER_NAME}}` | Existing Hermes MCP entry used for regression testing |

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

## 2. Prepare the browser login user

Resolve `{{MCP_LOGIN_USER}}` by exact username in `{{MCP_REALM}}`. Require
exactly one enabled user with a nonempty email address.

oauth2-proxy requests the `email` scope. Require:

```text
emailVerified = true
requiredActions = []
```

If the address was verified outside Keycloak but the flag is false, update
only `emailVerified=true` and retrieve the user directly afterward. Do not
change the password, email, enabled state, or required actions.

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

Resolve the created client by exact client ID, require one match, capture its
live internal UUID, retrieve it directly, and verify every setting.

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

Back up `compose.yaml` outside the active Compose model. Add:

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

Add these blocks inside the HTTPS server before protected application routes:

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

Use a private/incognito browser session:

1. Open `https://{{SERVER_FQDN}}/cameras/`.
2. Authenticate as `{{MCP_LOGIN_USER}}`.
3. Confirm the requested page appears after callback.
4. Open `/multiview/` in the same browser session.
5. Open a known direct `/webrtc/.../` stream URL.
6. Confirm no second login is required and live video plays.

If the user password was generated by the deployment agent, retrieve it only
through a direct privileged terminal on the server. Do not copy it into chat
or documentation.

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
- successful `pg_restore --list` with output suppressed
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
