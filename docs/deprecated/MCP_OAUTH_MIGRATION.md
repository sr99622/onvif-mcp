# Camera MCP Authentication Migration: Basic Auth to OAuth

**Date:** August 7, 2026  
**Host:** `camera.home.arpa` (`10.1.1.3`, trigkey)  
**Client:** OpenClaw on macOS  
**Identity provider:** Authelia 4.39.20  
**MCP endpoint:** `https://camera.home.arpa/mcp`

## Final architecture

```text
OpenClaw
   |
   | OAuth access token
   v
https://camera.home.arpa/mcp
   |
   | Nginx forwards Authorization: Bearer ...
   v
Camera MCP on 127.0.0.1:8001
   |
   | Validate JWT using Authelia JWKS
   v
Authelia on 127.0.0.1:9091
```

Authentication now uses:

- OAuth 2.0 authorization-code flow
- PKCE with `S256`
- A public client with no client secret
- RS256-signed JWT access tokens
- Refresh tokens
- RFC 9728 protected-resource metadata
- Authelia as the authorization server

Browser camera pages and WebRTC streams continue to use Authelia's browser-session authentication. The MCP endpoint uses OAuth bearer tokens.

## Previous Basic Authentication configuration

Nginx originally protected `/mcp` with HTTP Basic Authentication:

```nginx
location = /mcp {
    auth_basic "Camera System";
    auth_basic_user_file /etc/nginx/auth/camera-users.htpasswd;

    proxy_pass http://127.0.0.1:8001;
    proxy_set_header Authorization "";
}
```

OpenClaw supplied a Basic `Authorization` header from its configuration. This worked, but required storing a reusable password-equivalent credential on the client.

## Authelia OIDC provider

### Secrets

The following protected files were created:

```text
/etc/authelia/secrets/oidc-hmac
/etc/authelia/secrets/oidc-signing-key.pem
```

Both are owned by `authelia:authelia` and use mode `600`.

The HMAC secret was generated with:

```bash
sudo -u authelia authelia crypto rand \
  --length 64 \
  /etc/authelia/secrets/oidc-hmac
```

The signing key is a private RSA key owned by `authelia`.

### Systemd environment

File:

```text
/etc/systemd/system/authelia.service.d/oidc.conf
```

Contents:

```ini
[Service]
Environment="AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE=/etc/authelia/secrets/oidc-hmac"
Environment="X_AUTHELIA_CONFIG_FILTERS=template"
```

The template filter is required because the OIDC signing key is loaded through Authelia's `secret` template function.

### Registered OAuth client

The following client was added to `/etc/authelia/configuration.yml`:

```yaml
identity_providers:
  oidc:
    jwks:
      - algorithm: "RS256"
        use: "sig"
        key: {{ secret "/etc/authelia/secrets/oidc-signing-key.pem" | mindent 10 "|" | msquote }}

    clients:
      - client_id: "agent-camera-mcp"
        client_name: "Camera MCP Agent"
        client_secret: ""
        public: true
        authorization_policy: "one_factor"

        require_pkce: true
        pkce_challenge_method: "S256"

        redirect_uris:
          - "http://127.0.0.1:8989/oauth/callback"
          - "http://localhost:8989/oauth/callback"

        audience:
          - "https://camera.home.arpa/mcp"
        requested_audience_mode: "explicit"

        scopes:
          - "openid"
          - "profile"
          - "email"
          - "offline_access"

        grant_types:
          - "authorization_code"
          - "refresh_token"

        response_types:
          - "code"

        token_endpoint_auth_method: "none"
        access_token_signed_response_alg: "RS256"
```

Important details:

- `agent-camera-mcp` is a public client.
- It has no client secret.
- PKCE protects authorization-code redemption.
- Access tokens are restricted to the audience `https://camera.home.arpa/mcp`.

### Validate and restart Authelia

```bash
sudo -u authelia env \
  X_AUTHELIA_CONFIG_FILTERS=template \
  AUTHELIA_SESSION_SECRET_FILE=/etc/authelia/secrets/session \
  AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/etc/authelia/secrets/storage-encryption-key \
  AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/etc/authelia/secrets/reset-password-jwt \
  AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE=/etc/authelia/secrets/oidc-hmac \
  authelia config validate \
    --config /etc/authelia/configuration.yml

sudo systemctl restart authelia.service
```

## OAuth discovery through Nginx

The authorization-server issuer is:

```text
https://camera.home.arpa/authelia
```

OpenClaw derives this RFC 8414 discovery URL:

```text
https://camera.home.arpa/.well-known/oauth-authorization-server/authelia
```

Authelia directly publishes OIDC discovery at:

```text
/authelia/.well-known/openid-configuration
```

Nginx maps the RFC 8414 URL to Authelia's OIDC discovery document:

```nginx
location = /.well-known/oauth-authorization-server/authelia {
    auth_request off;
    auth_basic off;

    proxy_pass http://127.0.0.1:9091/authelia/.well-known/openid-configuration;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection "";
}
```

This endpoint must be public. Protecting it with an Authelia browser redirect causes OAuth clients to receive HTML instead of JSON.

The discovery document identifies:

```text
Issuer:        https://camera.home.arpa/authelia
Authorization: https://camera.home.arpa/authelia/api/oidc/authorization
Token:         https://camera.home.arpa/authelia/api/oidc/token
JWKS:          https://camera.home.arpa/authelia/jwks.json
```

## Camera MCP OAuth support

The implementation was added in Git commit:

```text
ea7a3bc Add OAuth authentication to MCP HTTP server
```

Changed files:

```text
packages/http/pyproject.toml
packages/http/src/onvif_mcp_http/auth.py
packages/http/src/onvif_mcp_http/main.py
packages/http/tests/test_auth.py
uv.lock
```

### Dependency

The HTTP package now explicitly depends on:

```toml
"pyjwt[crypto]>=2.10.0"
```

### JWT verification

`AutheliaJWTVerifier` verifies:

- RS256 signature
- Signing key selected from Authelia's JWKS
- Exact issuer
- Exact audience
- Expiration
- Issued-at time
- Subject
- Client ID
- OAuth scopes

Authelia places scopes in the JWT `scp` array:

```json
{
  "scp": [
    "openid",
    "profile",
    "email",
    "offline_access"
  ]
}
```

The verifier accepts both a space-delimited `scope` string and a list-valued `scp` claim.

### Internal JWKS retrieval

The MCP server retrieves JWKS over loopback:

```text
http://127.0.0.1:9091/authelia/jwks.json
```

Authelia requires reverse-proxy context for this endpoint, so `PyJWKClient` supplies the appropriate non-secret forwarding headers.

Without these headers, the internal request returns a non-JSON error and every otherwise valid bearer token is rejected with HTTP 401.

### Production service environment

Service file:

```text
/home/stephen/.config/systemd/user/onvif-mcp.service
```

OAuth-related values:

```ini
Environment="MCP_OAUTH_ENABLED=true"
Environment="MCP_RESOURCE_URL=https://camera.home.arpa/mcp"
```

The MCP server remains bound to loopback:

```text
127.0.0.1:8001
```

Nginx is the only external entry point.

## Protected-resource metadata

The MCP SDK publishes RFC 9728 metadata internally. Nginx exposes it without browser authentication:

```nginx
location = /.well-known/oauth-protected-resource/mcp {
    auth_request off;
    auth_basic off;

    proxy_pass http://127.0.0.1:8001/.well-known/oauth-protected-resource/mcp;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
}
```

The public response is:

```json
{
  "resource": "https://camera.home.arpa/mcp",
  "authorization_servers": [
    "https://camera.home.arpa/authelia"
  ],
  "scopes_supported": [
    "openid"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

## Production Nginx MCP route

Basic Authentication was removed from `/mcp`. The final route is:

```nginx
location = /mcp {
    auth_request off;
    auth_basic off;

    proxy_pass http://127.0.0.1:8001;
    proxy_http_version 1.1;

    proxy_set_header Authorization $http_authorization;
    proxy_set_header Connection "";

    proxy_buffering off;
    proxy_request_buffering off;
    proxy_cache off;

    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
```

The critical change is:

```nginx
proxy_set_header Authorization $http_authorization;
```

Nginx must forward the bearer token to the MCP resource server.

Unauthenticated requests now return:

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer ... resource_metadata="https://camera.home.arpa/.well-known/oauth-protected-resource/mcp"
```

They no longer return a Basic challenge or an Authelia HTML login redirect.

## OpenClaw configuration

The production OpenClaw entry is:

```json
{
  "mcp": {
    "servers": {
      "camera": {
        "url": "https://camera.home.arpa/mcp",
        "transport": "streamable-http",
        "auth": "oauth",
        "oauth": {
          "scope": "openid profile email offline_access",
          "redirectUrl": "http://127.0.0.1:8989/oauth/callback"
        }
      }
    }
  }
}
```

The old Basic `Authorization` header was removed.

### Private CA support

OpenClaw continues to run through:

```text
~/.local/bin/openclaw-camera-ca
```

The wrapper sets:

```bash
NODE_EXTRA_CA_CERTS="$HOME/Private-CA/camera-system-ca/certs/camera-system-root-ca.crt.pem"
```

This allows Node and OpenClaw to trust the private certificate used by `camera.home.arpa`.

### Static client registration

Authelia does not provide the dynamic client-registration flow OpenClaw would otherwise attempt. The pre-registered client information was therefore seeded in OpenClaw's private OAuth store.

OpenClaw derives the store filename from:

```text
SHA-256(server name + NUL + server URL)
```

For production:

```text
Server name: camera
Server URL:  https://camera.home.arpa/mcp
Store:       ~/.openclaw/mcp-oauth/camera-95bfdc43a05911b1.json
```

Initial public client information:

```json
{
  "clientInformation": {
    "client_id": "agent-camera-mcp",
    "client_name": "Camera MCP Agent",
    "redirect_uris": [
      "http://127.0.0.1:8989/oauth/callback"
    ],
    "grant_types": [
      "authorization_code",
      "refresh_token"
    ],
    "response_types": [
      "code"
    ],
    "token_endpoint_auth_method": "none"
  }
}
```

The store file uses mode `600`. Once authorization is complete it contains sensitive OAuth tokens and must remain private.

## OpenClaw authorization

Authorization was initiated with:

```bash
"$HOME/.local/bin/openclaw-camera-ca" mcp login camera
```

OpenClaw displayed an Authelia authorization URL containing the client ID, PKCE challenge, requested scopes, audience, redirect URI, and state.

After approval, the entire callback URL was parsed locally to extract the authorization code. The callback URL and code were not copied into chat or documentation.

OpenClaw then reported:

```text
MCP OAuth credentials saved for "camera".
```

## Verification

### Protected-resource metadata

```bash
curl \
  --cacert camera-system-root-ca.crt.pem \
  https://camera.home.arpa/.well-known/oauth-protected-resource/mcp
```

Expected: HTTP 200 with JSON metadata.

### Unauthenticated MCP request

```bash
curl \
  --include \
  --header 'Accept: text/event-stream' \
  --cacert camera-system-root-ca.crt.pem \
  https://camera.home.arpa/mcp
```

Expected:

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer ...
```

### OpenClaw probe

```bash
"$HOME/.local/bin/openclaw-camera-ca" mcp probe camera
```

Verified result:

```text
camera: 28 tools, resources, prompts
```

### Agent-level test

A fresh OpenClaw session was asked:

> Use the camera MCP server to report its version.

Verified response:

```text
camera-mcp: 0.1.5
libonvif:   4.0.23
```

This confirmed that the gateway and agent runtime—not only the CLI probe—could use OAuth successfully.

## Temporary parallel deployment

The migration was tested without immediately disrupting production:

```text
Temporary endpoint: https://camera.home.arpa/mcp-oauth
Temporary upstream: 127.0.0.1:8002
Temporary service:  onvif-mcp-oauth-test.service
```

After production validation, all temporary components were removed:

- `camera-oauth-test` OpenClaw entry
- Temporary OpenClaw OAuth credentials
- Port-8002 transient service
- `/mcp-oauth` Nginx route
- Temporary protected-resource metadata route
- Temporary `/mcp-oauth` Authelia audience

Port 8002 is no longer listening.

## Rollback material

Configuration snapshots were retained:

```text
/home/stephen/.config/systemd/user/onvif-mcp.service.before-oauth-2026-08-07
/etc/nginx/sites-available/camera-apps.before-production-oauth-2026-08-07
~/.openclaw/openclaw.json.before-production-camera-oauth-2026-08-07
/home/stephen/backups/authelia/configuration.yml.before-oauth-2026-08-07
```

The old Nginx htpasswd file remains available for emergency rollback:

```text
/etc/nginx/auth/camera-users.htpasswd
```

It is not used by the live `/mcp` endpoint.

## Encrypted backup

Final backup:

```text
camera-auth-stack-after-mcp-oauth-2026-08-07.tar.gz.age
```

Verified SHA-256:

```text
e6e866c9efa96dc51aabf694ed328788572e835dbf4f7ecbac7cdd8abfc12703
```

Verified copies exist on:

- trigkey
- The Mac private-backup directory
- The external `Camera-CA-Backups` volume

The archive includes:

- Authelia configuration and users
- Authelia SQLite database
- Session, storage, reset-password, OIDC HMAC, and OIDC signing secrets
- Authelia systemd drop-ins
- Nginx configuration, authentication files, and TLS files
- Production MCP systemd service definition

## Operational commands

Check services:

```bash
systemctl is-active \
  nginx.service \
  authelia.service

systemctl --user is-active \
  onvif-mcp.service
```

Check listeners:

```bash
sudo ss -lntp \
  '( sport = :8001 or sport = :9091 )'
```

Expected listeners:

```text
127.0.0.1:8001  Camera MCP
127.0.0.1:9091  Authelia
```

Validate Nginx:

```bash
sudo nginx -t
```

Validate Authelia:

```bash
sudo -u authelia env \
  X_AUTHELIA_CONFIG_FILTERS=template \
  AUTHELIA_SESSION_SECRET_FILE=/etc/authelia/secrets/session \
  AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/etc/authelia/secrets/storage-encryption-key \
  AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/etc/authelia/secrets/reset-password-jwt \
  AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE=/etc/authelia/secrets/oidc-hmac \
  authelia config validate \
    --config /etc/authelia/configuration.yml
```

Reload OpenClaw's MCP runtimes:

```bash
"$HOME/.local/bin/openclaw-camera-ca" mcp reload
```

Probe production:

```bash
"$HOME/.local/bin/openclaw-camera-ca" mcp probe camera
```

## Security notes

- Never copy access tokens, refresh tokens, authorization codes, callback URLs, private keys, or the full OpenClaw OAuth store into logs or documentation.
- OpenClaw OAuth-store files must remain mode `600`.
- Authelia secrets and signing keys must remain owned by `authelia` and mode `600`.
- OAuth discovery and protected-resource metadata must be public JSON endpoints.
- `/mcp` itself must require a valid bearer token.
- Nginx must forward `Authorization` to MCP.
- The MCP verifier must continue enforcing signature, issuer, audience, expiry, client identity, and required scopes.
- The public OAuth client intentionally has no client secret; PKCE is mandatory.
