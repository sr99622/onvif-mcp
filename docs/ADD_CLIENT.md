# Hermes OAuth Client Configuration for Keycloak

## Objective

Configure Hermes on a MacBook to authenticate with the camera MCP server through the Keycloak `mcp` realm using OAuth Authorization Code flow with PKCE.

## Server details

| Setting | Value |
|---|---|
| Keycloak host | `https://gmktec.home.arpa` |
| Keycloak base path | `https://gmktec.home.arpa/auth/` |
| Realm | `mcp` |
| Issuer | `https://gmktec.home.arpa/auth/realms/mcp` |
| MCP resource | `https://gmktec.home.arpa/mcp` |
| Required scope | `mcp:tools` |
| Hermes server name | `camera_system` |

## Authentication theory

Hermes uses the OAuth 2.0 Authorization Code flow with PKCE.

The flow works as follows:

1. Hermes generates a random PKCE verifier and an `S256` code challenge.
2. Hermes starts a temporary HTTP callback listener on the MacBook.
3. Hermes opens the Keycloak authorization endpoint in a browser.
4. The user signs in to Keycloak and authorizes the requested `mcp:tools` scope.
5. Keycloak redirects the browser to Hermes’ loopback callback URL.
6. Hermes exchanges the authorization code and PKCE verifier for OAuth tokens.
7. Hermes uses the access token when calling the MCP server.
8. The MCP server validates the token’s issuer, audience, signature, expiration, and scope.

Because Hermes is a native client and cannot securely store a client secret, it is configured as a public Keycloak client:

```text
Client authentication: Off
```

PKCE protects the authorization-code exchange without requiring a client secret.

## Initial problem

Hermes opened an authorization request containing:

```text
client_id=agent-camera-mcp
```

Keycloak returned:

```text
Client not found
```

A manually created Keycloak client initially had this Client ID:

```text
macbook
```

OAuth Client IDs must match exactly. Keycloak therefore could not associate Hermes’ authorization request with the `macbook` client.

The original generic redirect URI was also replaced with the exact callback URL requested by Hermes.

## Final Keycloak client configuration

The client was created in the `mcp` realm with the following configuration.

### General settings

| Setting | Value |
|---|---|
| Client type | OpenID Connect |
| Client ID | `agent-camera-mcp` |
| Enabled | On |

The Keycloak display name may still identify the client as the MacBook; the OAuth request is matched using the Client ID.

### Access settings

| Setting | Value |
|---|---|
| Valid redirect URI | `http://127.0.0.1:8989/oauth/callback` |
| Root URL | Blank |
| Home URL | Blank |
| Web origins | Blank |
| Admin URL | Blank |

Using the exact callback URI restricts authorization responses to the local Hermes listener.

### Capability configuration

| Setting | Value |
|---|---|
| Client authentication | Off |
| Authorization | Off |
| Standard flow | On |
| Direct access grants | Off |
| Implicit flow | Off |
| Service account roles | Off |
| Require PKCE | On |
| PKCE method | `S256` |
| Require DPoP-bound tokens | Off |

In Keycloak 26.7, the PKCE controls appeared under **Settings → Capability config** as **Require PKCE**. Enabling it revealed the **PKCE Method** selection.

### Client scope

The existing client scope was assigned as:

| Client scope | Assigned type |
|---|---|
| `mcp:tools` | Optional |

Hermes explicitly requests this scope during authorization:

```text
scope=mcp:tools
```

The scope’s audience mapper causes the resulting access token to contain the MCP resource audience:

```text
https://gmktec.home.arpa/mcp
```

## Hermes login procedure

The configured Hermes server is named `camera_system`, not `camera`.

The successful login command was:

```bash
hermes mcp login camera_system
```

Hermes generated an authorization request with these important parameters:

```text
client_id=agent-camera-mcp
redirect_uri=http://127.0.0.1:8989/oauth/callback
code_challenge_method=S256
resource=https://gmktec.home.arpa/mcp
scope=mcp:tools
```

After the Keycloak Client ID and redirect URI were corrected, the browser reported:

```text
Authorization successful
```

## Verification

The authenticated connection was tested with:

```bash
hermes mcp test camera_system
```

Result:

```text
Camera MCP tool listing successfully returned.
```

This confirms that:

- Keycloak recognized the client.
- Browser authentication completed.
- The redirect reached Hermes’ callback listener.
- The PKCE authorization-code exchange succeeded.
- Hermes received usable OAuth tokens.
- The token contained the required `mcp:tools` authorization.
- The MCP server accepted the token.
- Hermes successfully discovered the camera MCP tools.

## Final result

Hermes on the MacBook is successfully authenticated with the camera MCP server through Keycloak.

The essential working configuration is:

```text
Hermes server: camera_system
Keycloak realm: mcp
Client ID: agent-camera-mcp
Redirect URI: http://127.0.0.1:8989/oauth/callback
Client authentication: Off
Standard flow: On
Require PKCE: On
PKCE method: S256
Client scope: mcp:tools (Optional)
```