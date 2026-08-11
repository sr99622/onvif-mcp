# Keycloak Authentication for Camera Apps and WebRTC Streams

## Purpose

This runbook documents the browser authentication added on August 11, 2026 for the camera applications and live WebRTC streams hosted at `gmktec.home.arpa`.

The implementation uses Keycloak for OpenID Connect authentication, oauth2-proxy for browser sessions, and Nginx `auth_request` checks. It protects:

- `/cameras/`
- `/multiview/`
- `/outputs/`
- `/webrtc/`

The existing MCP OAuth bearer-token flow remains separate and unchanged. Hermes continues to access `/mcp` with an OAuth 2.1 access token, while Chrome uses an encrypted oauth2-proxy session cookie.

## Final architecture

```text
Chrome
  |
  | HTTPS request plus browser session cookie
  v
Nginx on gmktec.home.arpa:443
  |
  |-- /oauth2/* ----------------------> oauth2-proxy on 127.0.0.1:4180
  |                                         |
  |                                         | OpenID Connect + PKCE
  |                                         v
  |                                     Keycloak realm mcp
  |
  |-- /cameras/, /multiview/, /outputs/
  |       `-- auth_request /oauth2/auth, then serve static content
  |
  `-- /webrtc/
          `-- auth_request /oauth2/auth, then proxy MediaMTX on 127.0.0.1:8889

Hermes
  `-- /mcp ----------------------------> MCP JWT validation (unchanged)
```

## Important identifiers

| Item | Value |
|---|---|
| Public origin | `https://gmktec.home.arpa` |
| Keycloak realm | `mcp` |
| OIDC issuer | `https://gmktec.home.arpa/auth/realms/mcp` |
| Browser OIDC client ID | `camera-web` |
| OAuth callback | `https://gmktec.home.arpa/oauth2/callback` |
| Browser login user | `mcp-user` |
| oauth2-proxy image | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.3` |
| oauth2-proxy listener | `127.0.0.1:4180` |
| MediaMTX WebRTC listener | `127.0.0.1:8889` |
| Compose project directory | `/opt/keycloak` |
| Nginx site | `/etc/nginx/sites-enabled/camera-apps-https` |

## 1. Create the Keycloak browser client

In the `mcp` realm, create an OpenID Connect client with:

| Setting | Value |
|---|---|
| Client ID | `camera-web` |
| Client authentication | On |
| Authorization | Off |
| Standard flow | On |
| Direct access grants | Off |
| Implicit flow | Off |
| Service accounts | Off |
| Require PKCE | On |
| PKCE method | `S256` |
| Require DPoP-bound tokens | Off |
| Root URL | `https://gmktec.home.arpa/` |
| Home URL | `https://gmktec.home.arpa/cameras/` |
| Valid redirect URI | `https://gmktec.home.arpa/oauth2/callback` |
| Valid post-logout redirect URI | `https://gmktec.home.arpa/cameras/` |
| Web origin | `https://gmktec.home.arpa` |

Copy the generated client secret directly into the protected server environment file. Never place the value in this document, Compose YAML, shell history, or diagnostic output.

The `mcp-user` account must have an email address and **Email verified** enabled because oauth2-proxy requests the `email` scope and authorizes authenticated email identities.

## 2. Store oauth2-proxy secrets

The root-owned file `/opt/keycloak/.env` contains these variable names:

```text
POSTGRES_PASSWORD
OAUTH2_PROXY_CLIENT_SECRET
OAUTH2_PROXY_COOKIE_SECRET
```

It must remain mode `0600` and owned by `root:root`.

Add the copied Keycloak client secret using `nvim`:

```bash
sudo nvim /opt/keycloak/.env
```

The entry has this form:

```dotenv
OAUTH2_PROXY_CLIENT_SECRET=REDACTED
```

Generate the cookie-encryption secret without printing it:

```bash
sudo sh -c 'umask 077; printf "OAUTH2_PROXY_COOKIE_SECRET=%s\n" "$(openssl rand -base64 32 | tr -- "+/" "-_")" >> /opt/keycloak/.env'
```

Verify names without revealing values:

```bash
sudo sed -n 's/=.*//p' /opt/keycloak/.env
```

## 3. Add oauth2-proxy to Compose

Back up the original Compose file:

```bash
sudo cp --update=none \
  /opt/keycloak/compose.yaml \
  /opt/keycloak/compose.yaml.pre-oauth2-proxy
```

Add this service beneath the existing `keycloak` service and before the top-level `volumes:` section:

```yaml
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.15.3
    command:
      - --provider-ca-file=/etc/oauth2-proxy/camera-system-root-ca.crt.pem
      - --use-system-trust-store=true
    restart: unless-stopped
    depends_on:
      - keycloak
    environment:
      OAUTH2_PROXY_PROVIDER: keycloak-oidc
      OAUTH2_PROXY_CLIENT_ID: camera-web
      OAUTH2_PROXY_CLIENT_SECRET: ${OAUTH2_PROXY_CLIENT_SECRET}
      OAUTH2_PROXY_COOKIE_SECRET: ${OAUTH2_PROXY_COOKIE_SECRET}
      OAUTH2_PROXY_OIDC_ISSUER_URL: https://gmktec.home.arpa/auth/realms/mcp
      OAUTH2_PROXY_REDIRECT_URL: https://gmktec.home.arpa/oauth2/callback
      OAUTH2_PROXY_HTTP_ADDRESS: 0.0.0.0:4180
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
      - /etc/nginx/tls/camera-system-root-ca.crt.pem:/etc/oauth2-proxy/camera-system-root-ca.crt.pem:ro
    ports:
      - "127.0.0.1:4180:4180"
```

The private CA must be passed with the explicit `--provider-ca-file` command argument. The singular environment variable attempted initially was not applied because this option accepts a list.

The published port is bound to loopback only. Do not expose port 4180 on the LAN.

Validate, pull, and start:

```bash
sudo docker compose --project-directory /opt/keycloak config --quiet
sudo docker compose --project-directory /opt/keycloak pull oauth2-proxy
sudo docker compose --project-directory /opt/keycloak up -d oauth2-proxy
sudo docker compose --project-directory /opt/keycloak ps oauth2-proxy
```

Health check:

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  http://127.0.0.1:4180/ping
```

Expected result:

```text
HTTP 200
```

An unauthenticated authorization check must return `401`:

```bash
curl -sS -D - -o /dev/null \
  -H 'Host: gmktec.home.arpa' \
  -H 'X-Forwarded-Proto: https' \
  http://127.0.0.1:4180/oauth2/auth
```

## 4. Configure Nginx OAuth endpoints

Store configuration backups outside `sites-enabled`; every regular file there may be loaded as an active site. The backup from this change is:

```text
/etc/nginx/sites-available/camera-apps-https.pre-oauth2-proxy
```

Add these locations inside the HTTPS `server` block before the protected application locations:

```nginx
location = /oauth2/auth {
    proxy_pass http://127.0.0.1:4180;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location /oauth2/ {
    proxy_pass http://127.0.0.1:4180;
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

The relative `rd=$request_uri` is intentional. An absolute redirect destination was replaced by oauth2-proxy with `/`; the relative form safely preserves paths such as `/cameras/`.

The larger proxy buffers are also intentional. Keycloak and oauth2-proxy produce session-cookie response headers larger than Nginx's defaults. Without them, a successful callback fails with `502 Bad Gateway` and Nginx logs `upstream sent too big header`.

## 5. Protect the application and stream routes

Add the following directives at the beginning of each protected location:

```nginx
auth_request /oauth2/auth;
error_page 401 = @oauth2_signin;
auth_request_set $auth_cookie $upstream_http_set_cookie;
add_header Set-Cookie $auth_cookie always;
```

The final static application locations have this form:

```nginx
location /cameras/ {
    auth_request /oauth2/auth;
    error_page 401 = @oauth2_signin;
    auth_request_set $auth_cookie $upstream_http_set_cookie;
    add_header Set-Cookie $auth_cookie always;

    try_files $uri $uri/ =404;
}

location /multiview/ {
    auth_request /oauth2/auth;
    error_page 401 = @oauth2_signin;
    auth_request_set $auth_cookie $upstream_http_set_cookie;
    add_header Set-Cookie $auth_cookie always;

    try_files $uri $uri/ =404;
}

location /outputs/ {
    auth_request /oauth2/auth;
    error_page 401 = @oauth2_signin;
    auth_request_set $auth_cookie $upstream_http_set_cookie;
    add_header Set-Cookie $auth_cookie always;

    try_files $uri $uri/ =404;
}
```

The WebRTC location retains its MediaMTX proxy and WebSocket settings:

```nginx
location /webrtc/ {
    auth_request /oauth2/auth;
    error_page 401 = @oauth2_signin;
    auth_request_set $auth_cookie $upstream_http_set_cookie;
    add_header Set-Cookie $auth_cookie always;

    proxy_pass http://127.0.0.1:8889/;
    proxy_redirect / /webrtc/;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
}
```

Do not add browser `auth_request` protection to `/auth/`, `/mcp`, or `/.well-known/oauth-protected-resource/mcp`.

Validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 6. Verify browser protection

Check every route without a session:

```bash
for path in /cameras/ /multiview/ /outputs/ /webrtc/; do
  curl -sS -o /dev/null \
    -w "${path} HTTP %{http_code} redirect=%{redirect_url}\n" \
    "https://gmktec.home.arpa${path}"
done
```

Expected behavior is an HTTP `302` to `/oauth2/start`, preserving the requested path in `rd=`.

Verify that the full redirect chain reaches Keycloak and retains `/cameras/` in the encoded OAuth state:

```bash
curl -sS -L -o /dev/null \
  -w 'HTTP %{http_code} final=%{url_effective}\n' \
  https://gmktec.home.arpa/cameras/
```

Browser verification completed successfully in a fresh Chrome Incognito window:

1. Open `https://gmktec.home.arpa/cameras/`.
2. Authenticate as `mcp-user`.
3. Confirm the cameras page appears.
4. Open `https://gmktec.home.arpa/multiview/` and confirm its streams appear.
5. Open a direct `/webrtc/<camera>/<profile>/` URL and confirm live video appears.

## 7. Verify MCP access remains independent

On the Mac:

```bash
hermes mcp test camera
```

Verified result:

```text
Connected
Tools discovered: 28
```

This confirms the Nginx browser-auth changes did not interfere with MCP OAuth discovery or JWT bearer-token validation.

## 8. Troubleshooting

### oauth2-proxy continuously restarts

Inspect logs:

```bash
sudo docker compose --project-directory /opt/keycloak logs \
  --tail=80 oauth2-proxy
```

Observed initial error:

```text
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

Resolution: mount the Camera System Root CA and supply it with the explicit `--provider-ca-file` argument shown in the Compose configuration.

### Nginx returns 502 after successful Keycloak login

Inspect:

```bash
sudo tail -n 40 /var/log/nginx/error.log
```

Observed error:

```text
upstream sent too big header while reading response header from upstream
```

Resolution: add the 32 KiB/64 KiB proxy buffer settings to `location /oauth2/`, validate Nginx, reload it, and restart the login from a fresh Incognito window.

### Login returns to the site root

Inspect the Keycloak authorization URL. If the OAuth `state` ends in an encoded `/` rather than the requested application path, ensure the sign-in redirect is:

```nginx
return 302 /oauth2/start?rd=$request_uri;
```

Do not set `X-Auth-Request-Redirect` in the `/oauth2/` proxy location in this configuration.

### Nginx reports a conflicting server name

Do not leave backup files in `/etc/nginx/sites-enabled`. Move them to `/etc/nginx/sites-available` or a dedicated backup directory.

## 9. Operations

Check services:

```bash
sudo docker compose --project-directory /opt/keycloak ps
sudo systemctl status nginx --no-pager
```

View oauth2-proxy logs:

```bash
sudo docker compose --project-directory /opt/keycloak logs \
  --tail=200 oauth2-proxy
```

Restart only oauth2-proxy:

```bash
sudo docker compose --project-directory /opt/keycloak up -d oauth2-proxy
```

After changing Compose:

```bash
sudo docker compose --project-directory /opt/keycloak config --quiet
sudo docker compose --project-directory /opt/keycloak up -d \
  --force-recreate oauth2-proxy
```

After changing Nginx:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 10. Backup checkpoint

After completing this configuration, a new Keycloak PostgreSQL backup was created:

```text
/var/backups/keycloak-postgres/keycloak-20260811T180552Z.dump
```

Verified properties:

```text
-rw------- root root 251178 bytes
```

The archive catalog passed `pg_restore --list` validation.

Create another manual backup after future Keycloak client, realm, or user changes:

```bash
sudo systemctl start keycloak-postgres-backup.service
sudo systemctl status keycloak-postgres-backup.service --no-pager
```

Validate the newest archive non-destructively:

```bash
sudo sh -c 'docker compose --project-directory /opt/keycloak exec -T postgres pg_restore --list < /var/backups/keycloak-postgres/keycloak-YYYYMMDDTHHMMSSZ.dump >/dev/null' \
  && echo "BACKUP_ARCHIVE_VALID"
```

## Security notes

- Never document or display the client secret, cookie secret, user password, access tokens, refresh tokens, or session cookies.
- Keep `/opt/keycloak/.env` root-owned and mode `0600`.
- Keep oauth2-proxy bound to `127.0.0.1`; Nginx is its only public entry point.
- Keep `Secure` and `SameSite=Lax` enabled on the browser session cookie.
- Use exact Keycloak redirect URIs and web origins; do not replace them with broad wildcards.
- Continue using the private CA normally; do not bypass certificate validation with `curl -k` or insecure OIDC options.
- A user who can authenticate as `mcp-user` can currently reach all four protected route families. Add Keycloak groups or roles and oauth2-proxy authorization rules if per-user or per-route access control becomes necessary.
- The browser session and Hermes MCP credentials are intentionally independent. Logging out or expiring one does not imply immediate invalidation of the other.
