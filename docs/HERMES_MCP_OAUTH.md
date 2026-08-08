# Hermes Agent: Camera MCP OAuth Configuration

**Date:** August 7, 2026
**Host:** `camera.home.arpa` (`10.1.1.3`, trigkey)
**Client:** Hermes Agent on macOS
**Identity provider:** Authelia 4.39.20
**MCP endpoint:** `https://camera.home.arpa/mcp`

This documents connecting a second agent client — Hermes — to the Camera MCP server over OAuth, following the Basic-Auth-to-OAuth migration in [`MCP_OAUTH_MIGRATION.md`](MCP_OAUTH_MIGRATION.md). No changes were made on the camera server; this was a Hermes-side configuration exercise that reused the existing Authelia client.

## Summary

Hermes was pointed at the same public Authelia OIDC client OpenClaw already uses (`agent-camera-mcp`), using the same registered redirect URI. No new Authelia client was created (see [Future work](#future-work) for the case for splitting this out later). Result: `hermes mcp login camera_system` completes an interactive browser OAuth flow and Hermes reports **28 tools** available — the same count OpenClaw's probe reports.

## Hermes configuration

File: `~/.hermes/config.yaml`

```yaml
mcp_servers:
  camera_system:
    url: https://camera.home.arpa/mcp
    auth: oauth
    ssl_verify: /Users/stephen/.hermes/certs/camera-system-root-ca.crt.pem
    oauth:
      client_id: "agent-camera-mcp"
      client_name: "Camera MCP Agent"
      redirect_uri: "http://127.0.0.1:8989/oauth/callback"
      redirect_port: 8989
      scope: "openid profile email offline_access"
```

Notes:

- `ssl_verify` points at the same private CA cert (`camera-system-root-ca.crt.pem`) already used elsewhere for this host, copied into Hermes's own cert store rather than referencing another tool's copy.
- `redirect_uri` / `redirect_port` were pinned to `8989` — one of the two URIs already registered for `agent-camera-mcp` in Authelia (`http://127.0.0.1:8989/oauth/callback` / `http://localhost:8989/oauth/callback`). Authelia requires an exact redirect URI match, so Hermes's own default (a random ephemeral port) would never work here.
- No `client_secret` is set. `agent-camera-mcp` is a public client (`token_endpoint_auth_method: none`), so none is needed or accepted.
- `oauth.scope` is set here for documentation intent, but in practice **Hermes ignores it** for the actual authorization request — see [Known limitation](#known-limitation-no-refresh-token) below.

## Why a fresh Authelia client wasn't registered

Hermes's `hermes mcp add --url ... --auth oauth` attempts RFC 7591 Dynamic Client Registration by default. That failed against Authelia:

```
✗ Authentication failed: Invalid registration response: 1 validation error for OAuthClientInformationFull
  Invalid JSON: expected value at line 1 column 1 [type=json_invalid, input_value=b'<!doctype html>\n<html ...']
```

Authelia does not implement DCR (RFC 7591) — it's on Authelia's roadmap but not shipped as of 4.39.20. Confirmed two ways:

1. Authelia's own OIDC discovery document (`https://camera.home.arpa/authelia/.well-known/openid-configuration`) has no `registration_endpoint` field.
2. A direct probe of the authorization endpoint with a made-up `client_id` returns an explicit rejection, proving unregistered clients are never accepted (i.e. there's no fallback "implicit" registration path either):

   ```
   Location: https://camera.home.arpa/authelia/consent/completion?error=invalid_client
     &error_description=Client+authentication+failed...
     &error_hint=The+requested+OAuth+2.0+Client+does+not+exist.
   ```

Since `agent-camera-mcp` was already registered as a **public** client for OpenClaw, and public clients aren't tied to a single caller (PKCE protects each individual authorization-code exchange), reusing it for Hermes was the lower-effort, zero-server-change option instead of adding a second static client entry to `/etc/authelia/configuration.yml`. Each tool gets its own independently issued token; nothing is shared beyond the `client_id` itself.

## Verification

```
stephen@macbook onvif-mcp % hermes mcp login camera_system

  Starting OAuth flow for 'camera_system'...

  MCP OAuth: authorization required.
  Open this URL in your browser:

    https://camera.home.arpa/authelia/api/oidc/authorization?response_type=code&client_id=agent-camera-mcp&redirect_uri=...&resource=https%3A%2F%2Fcamera.home.arpa%2Fmcp&scope=openid

  (Browser opened automatically.)
  ✓ Authenticated — 28 tool(s) available
```

Confirmed working end-to-end: Hermes can call the camera tools through the MCP server using the OAuth access token.

## Known limitation: no refresh token

The issued token has no `refresh_token` and expires in 1 hour:

```json
{
  "keys": ["access_token", "expires_at", "expires_in", "scope", "token_type"],
  "scope": "openid",
  "expires_in": 3599
}
```
*(stored at `~/.hermes/mcp-tokens/camera_system.json`; values above are field names/shape, not actual token content)*

**Root cause:** the authorization request Hermes actually sent only requested `scope=openid`, not the `openid profile email offline_access` configured in `oauth.scope`. Hermes's MCP SDK (`mcp.client.auth.utils.get_client_metadata_scopes`) implements the MCP spec's mandatory scope-selection order and does **not** consult any client-side scope override:

1. `WWW-Authenticate` header scope, if present (not sent by this server)
2. Otherwise, the protected-resource-metadata's `scopes_supported`
3. Otherwise, omit the scope parameter

The Camera MCP server's protected-resource metadata (RFC 9728) currently advertises only:

```json
{
  "resource": "https://camera.home.arpa/mcp",
  "authorization_servers": ["https://camera.home.arpa/authelia"],
  "scopes_supported": ["openid"],
  "bearer_methods_supported": ["header"]
}
```

which traces to a single line in this repo:

```python
# packages/http/src/onvif_mcp_http/main.py:107
AuthSettings(
    issuer_url=AnyHttpUrl(MCP_OAUTH_ISSUER),
    resource_server_url=AnyHttpUrl(MCP_RESOURCE_URL),
    required_scopes=["openid"],
)
```

The MCP Python SDK (`mcp.server.auth`) builds the published `scopes_supported` directly from `required_scopes`. Because it's `["openid"]`, every spec-compliant MCP client (including Hermes, and presumably any future one) will only ever request `openid` here — never `offline_access` — and Authelia will not issue a refresh token without an explicit `offline_access` scope request. This isn't a Hermes bug; it's Hermes correctly following the spec against a resource server that only advertises a narrow scope set.

OpenClaw is unaffected because its OAuth client implementation apparently honors its own configured `scope` value (`"openid profile email offline_access"` in its OpenClaw config) rather than deriving the request scope from PRM `scopes_supported`. That's a spec deviation on OpenClaw's part, not a more-correct behavior — but it's why OpenClaw got a refresh token and Hermes didn't.

**Practical effect:** Hermes's camera_system access token expires roughly every hour. Once it does, tool calls will start failing until `hermes mcp login camera_system` is re-run interactively (it should reopen a browser; if Authelia's session cookie in the default browser is still valid, this may complete without requiring you to log in again, but it is still an interactive step today).

## Future work

1. **Widen `required_scopes` in `main.py`** (preferred fix): change

   ```python
   required_scopes=["openid"],
   ```

   to

   ```python
   required_scopes=["openid", "profile", "email", "offline_access"],
   ```

   in `packages/http/src/onvif_mcp_http/main.py`, restart `onvif-mcp.service`, and re-run `hermes mcp login camera_system`. This changes what *every* client sees in protected-resource metadata (not just Hermes), so it should be checked against the JWT verifier in `auth.py` — `AutheliaJWTVerifier` currently only requires `sub`/`iss`/`exp`/`iat` claims and doesn't hard-require specific scopes to be present, so widening `scopes_supported` should be safe, but re-verify `_extract_scopes` / any scope-gating logic before shipping. Also confirm the Authelia client's `scopes` list (already `[openid, profile, email, offline_access]`) doesn't need to change — it doesn't, it already permits all four.

2. **Split Hermes onto its own Authelia client**, e.g. `agent-camera-mcp-hermes` on a distinct port (`8765` suggested), mirroring `agent-camera-mcp`'s settings otherwise. Not required for functionality, but gives Hermes and OpenClaw independent audit trails/revocation in Authelia and removes the (small, currently theoretical) chance of both tools trying to bind port 8989 for a login callback at the same moment. Natural to pair with item 1, done in the same maintenance window.

3. **Automate re-auth** if item 1 isn't done or as a belt-and-suspenders measure: Hermes has `hermes mcp reauth camera_system` / `--all` and its own cron subsystem (`~/.hermes/cron`) — a scheduled reauth shortly before the 1-hour expiry could paper over the missing refresh token, though it still depends on an interactive browser step succeeding unattended (untested whether Authelia's session cookie makes this silent in practice).

## Security notes

Same posture as the original migration — carried forward here, not re-litigated:

- No access tokens, refresh tokens, authorization codes, or callback URLs are recorded in this document or in logs.
- `~/.hermes/mcp-tokens/camera_system.json` and its sibling `.client.json`/`.meta.json` files hold live credential material and must stay private to the `stephen` account.
- `agent-camera-mcp` remains a public client with no secret; PKCE (`S256`) is mandatory and is what actually protects the authorization-code exchange, not client confidentiality.
