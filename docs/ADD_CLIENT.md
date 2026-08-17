# Add a Hermes Client to the Camera MCP Server

## Purpose

This runbook onboards a new machine to an existing camera MCP deployment that
uses Keycloak for OAuth 2.1/OpenID Connect authorization.

The current standard uses:

- OAuth Authorization Code flow with PKCE (`S256`)
- Dynamic Client Registration (DCR)
- A separate public OAuth client registration for each Hermes installation
- The `mcp:tools` scope
- A private CA for HTTPS
- Keycloak Trusted Hosts to restrict which machines may register clients

Do not manually create a fixed Keycloak client unless DCR is intentionally
disabled. Hermes should register its own public client and retain its own
registration and token files.

## Deployment values

Substitute these symbolic values for the target environment:

| Symbol | Meaning |
|---|---|
| `{{SERVER_FQDN}}` | Public DNS name of the MCP and Keycloak server |
| `{{SERVER_IP}}` | Address of the MCP server |
| `{{CLIENT_SOURCE_IP}}` | Source address Keycloak sees for the new client |
| `{{MCP_REALM}}` | Keycloak realm, normally `mcp` |
| `{{MCP_SCOPE}}` | Required MCP scope, normally `mcp:tools` |
| `{{MCP_LOGIN_USER}}` | Keycloak user used for interactive login |
| `{{HERMES_SERVER_NAME}}` | Local name for the Hermes MCP entry |
| `{{CA_CERT_PATH}}` | Client-local absolute path to the private root CA |
| `{{CALLBACK_PORT}}` | Optional fixed loopback callback port |

Derived URLs:

```text
MCP resource:  https://{{SERVER_FQDN}}/mcp
Issuer:        https://{{SERVER_FQDN}}/auth/realms/{{MCP_REALM}}
Discovery:     https://{{SERVER_FQDN}}/auth/realms/{{MCP_REALM}}/.well-known/openid-configuration
DCR endpoint:  https://{{SERVER_FQDN}}/auth/realms/{{MCP_REALM}}/clients-registrations/openid-connect
Metadata:      https://{{SERVER_FQDN}}/.well-known/oauth-protected-resource/mcp
```

## How authentication works

1. Hermes connects to the MCP resource without a token.
2. The MCP server returns `401 Unauthorized` and points Hermes to the
   protected-resource metadata document.
3. Hermes discovers the Keycloak issuer and DCR endpoint.
4. Hermes registers a native public client with a loopback redirect URI and
   requests `{{MCP_SCOPE}}`.
5. Keycloak accepts registration only if the request source and redirect host
   satisfy the anonymous DCR policies.
6. Hermes creates a PKCE verifier and `S256` challenge.
7. The user signs in through Keycloak and approves consent.
8. Keycloak returns an authorization code to Hermes' loopback callback.
9. Hermes exchanges the code and verifier for tokens.
10. Hermes saves its registration and token state locally and uses the access
    token for MCP requests.
11. The MCP server validates signature, issuer, audience, expiration, token
    type, and scope.

Hermes is a public native client. It must not be configured with a client
secret.

## 1. Verify public server metadata

Run on the new client machine:

```bash
curl -sS -o /dev/null -w 'Discovery: HTTP %{http_code}\n' \
  "https://{{SERVER_FQDN}}/auth/realms/{{MCP_REALM}}/.well-known/openid-configuration"

curl -sS \
  "https://{{SERVER_FQDN}}/.well-known/oauth-protected-resource/mcp" |
python3 -m json.tool
```

Expected results:

- Discovery returns `HTTP 200`.
- The issuer is exactly
  `https://{{SERVER_FQDN}}/auth/realms/{{MCP_REALM}}`.
- A registration endpoint is present.
- `S256` appears in `code_challenge_methods_supported`.
- `{{MCP_SCOPE}}` appears in `scopes_supported`.
- Protected-resource metadata names the exact MCP resource and issuer.

Do not use `curl -k`. If TLS validation fails, install or reference the private
CA correctly.

## 2. Install or reference the private CA

Hermes must validate the certificate for `{{SERVER_FQDN}}`. Copy only the
public root CA certificate to the client. Do not copy a server private key, CA
private key, or certificate-signing material.

Verify the certificate:

```bash
openssl x509 -in "{{CA_CERT_PATH}}" \
  -noout -subject -issuer -ext basicConstraints -fingerprint -sha256
```

Require `CA:TRUE`, then verify HTTPS using the exact path Hermes will use:

```bash
curl --cacert "{{CA_CERT_PATH}}" \
  -sS -o /dev/null -w 'Discovery: HTTP %{http_code}\n' \
  "https://{{SERVER_FQDN}}/auth/realms/{{MCP_REALM}}/.well-known/openid-configuration"
```

Expected result: `HTTP 200`.

## 3. Determine the client source address

The anonymous Keycloak Trusted Hosts policy validates the address from which
the DCR request arrives. This may differ from an address reported locally
because of routing, VPNs, multiple interfaces, or NAT.

First inspect addresses on the client. For example, on macOS:

```bash
ipconfig getifaddr en0
ipconfig getifaddr en1
```

The authoritative value is the address recorded by Nginx for the DCR request.
After an initial failed registration, or while testing, inspect the server log:

```bash
sudo grep 'clients-registrations/openid-connect' \
  /var/log/nginx/access.log |
tail -n 5
```

Use the source address at the beginning of the relevant entry as
`{{CLIENT_SOURCE_IP}}`.

## 4. Permit the client in the DCR Trusted Hosts policy

On the server, resolve the live realm component whose:

```text
type = org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy
providerId = trusted-hosts
subType = anonymous
```

Require exactly one match. Never copy its UUID from another installation or a
previous realm.

Retrieve the component directly and preserve all existing trusted hosts. Add
only `{{CLIENT_SOURCE_IP}}`. Retain both matching controls:

```json
{
  "trusted-hosts": [
    "{{SERVER_IP}}",
    "{{CLIENT_SOURCE_IP}}",
    "localhost",
    "127.0.0.1"
  ],
  "host-sending-registration-request-must-match": ["true"],
  "client-uris-must-match": ["true"]
}
```

Retrieve the component directly again and verify the exact stored
configuration. Collection views can display `config: {}` even when component
configuration exists.

### Individual addresses versus subnets

The strict default is to allow each observed client address individually.
This provides clear registration boundaries but requires stable addresses or
DHCP reservations.

A narrowly scoped trusted subnet may reduce administration on a controlled
LAN, but use it only after confirming that the installed Keycloak provider
accepts the intended CIDR syntax. Do not assume CIDR support, and do not
disable Trusted Hosts merely to simplify onboarding.

## 5. Add the Hermes MCP entry

Back up the existing Hermes configuration and preserve all unrelated entries.

```bash
hermes mcp add "{{HERMES_SERVER_NAME}}" \
  --url "https://{{SERVER_FQDN}}/mcp" \
  --auth oauth \
  --connect-timeout 30
```

The first connection may fail before the CA path is stored. If prompted, save
the entry for later correction.

Inspect `~/.hermes/config.yaml` structurally. Do not print unrelated settings
or credentials. Require:

```yaml
mcp_servers:
  {{HERMES_SERVER_NAME}}:
    url: https://{{SERVER_FQDN}}/mcp
    ssl_verify: {{CA_CERT_PATH}}
    connect_timeout: 30.0
    auth: oauth
    enabled: false
```

Set `auth: oauth` explicitly. Do not rely on Hermes inferring OAuth from the
HTTPS URL. Keep the entry disabled until browser login and saved-token testing
succeed; this prevents configuration reloads from initiating concurrent OAuth
flows.

### Optional fixed callback port

For headless or SSH-based login, add a fixed free callback port:

```yaml
mcp_servers:
  {{HERMES_SERVER_NAME}}:
    oauth:
      redirect_port: {{CALLBACK_PORT}}
```

The same port is used for the DCR redirect URI and callback listener. Confirm
it is free before login.

## 6. Complete OAuth login

### Login on the same desktop machine

When Hermes and the browser run on the same machine:

```bash
hermes mcp login "{{HERMES_SERVER_NAME}}"
```

Open the authorization URL, sign in as `{{MCP_LOGIN_USER}}`, approve
`{{MCP_SCOPE}}`, and allow the browser to return to the loopback callback.

Never paste the authorization URL, callback URL, authorization code, `state`,
PKCE values, passwords, or tokens into chat or logs.

### Login over SSH

When Hermes runs remotely but the browser is local, use one SSH command for
both the interactive terminal and port forwarding:

```bash
ssh -tt -L {{CALLBACK_PORT}}:127.0.0.1:{{CALLBACK_PORT}} \
  {{REMOTE_USER}}@{{SERVER_FQDN}} \
  '/absolute/path/to/hermes mcp login {{HERMES_SERVER_NAME}}'
```

Open the authorization URL locally and allow the redirect to complete through
the tunnel. Avoid manual callback pasting; it caused a callback-port retry race
during the verified deployment.

## 7. Verify saved OAuth state

Before enabling the entry:

```bash
hermes mcp test "{{HERMES_SERVER_NAME}}"
```

Success requires no additional browser login, a successful authenticated
connection, and discovery of the expected protected MCP tools.

Hermes normally stores files equivalent to:

```text
~/.hermes/mcp-tokens/{{HERMES_SERVER_NAME}}.client.json
~/.hermes/mcp-tokens/{{HERMES_SERVER_NAME}}.json
~/.hermes/mcp-tokens/{{HERMES_SERVER_NAME}}.meta.json
```

Treat every file in this directory as secret. Require mode `0600`, but never
display contents.

After the saved-state test passes, set `enabled: true`, then test again:

```bash
hermes mcp test "{{HERMES_SERVER_NAME}}"
```

The second test must also succeed without browser authorization.

## Troubleshooting

### `403 insufficient_scope` and `Host not trusted`

```json
{
  "error": "insufficient_scope",
  "error_description": "Policy 'Trusted Hosts' rejected request to client-registration service. Details: Host not trusted."
}
```

DCR reached Keycloak, but the received source address was not trusted.
Determine it from the Nginx DCR access-log entry, add only that address, verify
the component directly, and retry.

### `Client not found`

This usually indicates stale manual-client configuration or stale Hermes
registration state. The current standard uses DCR; do not create an arbitrary
fixed client ID to work around it.

### Callback port already in use

Do not start concurrent login attempts. Disable the Hermes entry, identify the
exact callback helper, and terminate it gracefully only after verifying its
owner and command.

If login did not produce a token file:

1. Parse `{{HERMES_SERVER_NAME}}.client.json` internally to obtain its client
   ID without displaying its registration token.
2. Match it to exactly one Keycloak client with the expected name, public
   client state, redirect URI, and `{{MCP_SCOPE}}` assignment.
3. Delete only that verified Keycloak client.
4. Remove only the matching local `.client.json` artifact.
5. Verify no callback listener remains before retrying.

If the main token file exists, test saved authentication before deleting
anything. The browser may report an error after token exchange succeeded.

### Browser succeeds but SSH reports connection failures

If Hermes already reported successful authentication, later SSH channel
connection failures can be harmless browser follow-up requests after the
one-time callback listener closed. Verify with `hermes mcp test` instead of
repeating login.

### Private CA validation failure

- Confirm `ssl_verify` is an absolute path readable by the Hermes user.
- Confirm the certificate has `CA:TRUE`.
- Compare its SHA-256 fingerprint with the authoritative public root CA.
- Test discovery with `curl --cacert`.
- Never disable verification or use `curl -k`.

## Final checklist

- `{{SERVER_FQDN}}` resolves to `{{SERVER_IP}}`.
- The private CA validates the server certificate.
- Public discovery returns `200` with the exact issuer.
- `S256` and `{{MCP_SCOPE}}` are published.
- Protected-resource metadata contains the exact resource and issuer.
- Nginx records `{{CLIENT_SOURCE_IP}}` for the client's DCR request.
- The anonymous Trusted Hosts policy includes `{{CLIENT_SOURCE_IP}}`.
- Hermes explicitly stores `auth: oauth` and the CA path.
- DCR creates a public client with the expected loopback redirect.
- Browser authorization succeeds.
- Hermes token artifacts are mode `0600`.
- `hermes mcp test` reconnects without another browser login.
- The entry is enabled only after saved-state verification.

## Result

Each onboarded machine receives its own Keycloak DCR client and Hermes token
state. No client secret is used or shared. Keycloak limits registration to
trusted source addresses and approved loopback redirect hosts, while the MCP
server enforces the exact issuer, audience, and `{{MCP_SCOPE}}` authorization.
