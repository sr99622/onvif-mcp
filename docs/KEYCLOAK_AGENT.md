# Agent-Guided Keycloak Deployment for ONVIF MCP

## Status and intent

This document records the supervised agent deployment performed on
`gmktec.home.arpa` on 2026-08-17. It complements `KEYCLOAK_CLI.md` rather than
replacing it.

The immediate goal is repeatability: an operator should be able to give an
agent small, bounded tasks and verify each result before continuing. The
long-term goal is a fully unattended deployment agent. The current procedure
is **not ready for unsupervised execution**. Several steps still require human
judgment, browser interaction, careful reconciliation of conflicting reports,
and guarded cleanup of OAuth state.

The experiment ultimately succeeded:

- Keycloak 26.7.0 and PostgreSQL 17 run in Docker Compose.
- Nginx publishes Keycloak beneath `https://gmktec.home.arpa/auth/`.
- The MCP resource is `https://gmktec.home.arpa/mcp`.
- The issuer is `https://gmktec.home.arpa/auth/realms/mcp`.
- Anonymous DCR, Authorization Code with PKCE, and rotating refresh tokens
  are configured.
- Hermes Agent 0.20.1 reconnects with saved OAuth state and discovers 28
  protected MCP tools.
- Unauthenticated MCP requests return `401` with RFC 9728 protected-resource
  metadata.
- A root-only PostgreSQL backup was created, its catalog was verified, and an
  isolated restore test succeeded.

## Relationship to the canonical runbook

Use `KEYCLOAK_CLI.md` for the authoritative commands, target architecture,
and expected Keycloak objects. Use this document for agent behavior,
supervision boundaries, failure recovery, and lessons learned during the
experiment.

Never copy realm, user, client, scope, mapper, or component UUIDs from a prior
deployment. Resolve every installation-specific identifier from the target
Keycloak instance immediately before using it.

## Verified environment

The successful experiment used:

| Component | Version or value |
|---|---|
| Host | Ubuntu Server 26.04 LTS |
| Public host | `gmktec.home.arpa` (`10.1.1.5`) |
| Docker | 29.1.3 |
| Docker Compose | 2.40.3 |
| Keycloak | 26.7.0 |
| PostgreSQL | 17 (tools reported 17.11) |
| Nginx | 1.28.3 |
| Hermes Agent | 0.20.1 |
| MCP HTTP service | `127.0.0.1:8001` |
| Keycloak listener | `127.0.0.1:8080` |

The system hostname was `gmktec`, not `gmktec.home.arpa`. This was acceptable
because the public name resolved to a local address and matched the HTTPS
certificate.

## Agent operating contract

An agent running this procedure must follow these rules.

### Work in bounded phases

Perform one mutation phase at a time. Each phase should contain:

1. Read-only preflight.
2. Exact target resolution.
3. Guarded mutation.
4. Direct verification from the authoritative system.
5. A concise report followed by a stop.

Do not continue after a failed guard. Do not reinterpret “stop” as “continue
with the remaining commands.”

### Separate facts from inference

Reports must distinguish command output from interpretation. If state cannot
be explained, report that it is unexplained and perform a read-only audit.
Do not invent a causal explanation.

For example, removing `KC_BOOTSTRAP_ADMIN_*` environment variables cannot
delete an administrator already persisted in PostgreSQL. During this
experiment, an early agent incorrectly claimed that it could. The deployment
was paused until current users, container state, configuration references,
and Nginx routes were audited directly.

### Protect secrets

Never print or paste:

- `/opt/keycloak/.env`
- administrator or MCP-user passwords
- raw JWTs
- access or refresh tokens
- DCR registration access tokens
- Hermes token-file contents
- OAuth authorization codes, `state`, or PKCE values
- private keys

Secret-bearing files must be explicitly created with mode `0600`; do not rely
on a `umask` set in an earlier agent command because agent shell calls may run
in separate processes. One disposable DCR response was accidentally created
with mode `0644` despite an earlier `umask 077`. It was deleted immediately.

Safe reports may include public client IDs, internal Keycloak object IDs,
public URLs, certificate fingerprints, file modes, aggregate token-file
counts, and selected non-secret token claims.

### Guard destructive actions

Before deleting a user, client, database, or credential artifact:

1. Resolve the target from the live authoritative API.
2. Require exactly one match.
3. Validate its name and all relevant non-secret attributes.
4. Use the internal Keycloak UUID where the Admin API requires it.
5. Verify absence afterward.

Never delete a client merely because a public `client_id` resembles an
internal UUID. In this deployment they happened to be identical, but the
procedure must not assume that.

### Preserve existing configuration

- Back up Nginx outside `sites-enabled`.
- Back up Hermes configuration before every structural edit.
- Generate a candidate file and compare it semantically with the original.
- Require only the intended fields to differ.
- Validate Nginx or systemd before reload/restart.
- Preserve unrelated MCP servers and their configuration.

## Supervised phase sequence

The successful phase order was:

1. Establish host identity, DNS, ports, services, and absence of an existing
   `/opt/keycloak` deployment.
2. Install Docker and Compose.
3. Create `/opt/keycloak`, a root-only PostgreSQL password, and
   `compose.yaml`.
4. Create a temporary bootstrap administrator and start Keycloak.
5. Create, authorize, and independently verify a permanent administrator.
6. Remove the temporary administrator and all bootstrap environment
   references; recreate only the Keycloak container.
7. Create the `mcp` realm and configure session/token lifetimes.
8. Create `mcp-user` with a root-only password file.
9. Create the optional `mcp:tools` client scope and audience mapper.
10. Resolve and configure anonymous DCR policies as realm components.
11. Add Nginx `/auth/` and protected-resource metadata routes.
12. Enable OAuth in `onvif-mcp-http.service` through a systemd drop-in.
13. Test disposable DCR and delete the verified test client and response.
14. Configure Hermes with an explicit CA path, explicit `auth: oauth`, and a
    fixed callback port.
15. Complete Hermes login through a single SSH connection with port
    forwarding.
16. Verify saved OAuth reconnection before enabling the Hermes entry.
17. Create and test a manual PostgreSQL backup service.
18. Restore into a guarded test database, validate row counts, and drop only
    the verified test database.
19. Run the final verification checklist.

## Values used in the verified deployment

```text
PUBLIC_HOST=gmktec.home.arpa
MCP_REALM=mcp
MCP_SCOPE=mcp:tools
MCP_LOGIN_USER=mcp-user
KEYCLOAK_ADMIN_USER=keycloak-admin
MCP_RESOURCE_URL=https://gmktec.home.arpa/mcp
KEYCLOAK_PUBLIC_URL=https://gmktec.home.arpa/auth
MCP_ISSUER=https://gmktec.home.arpa/auth/realms/mcp
```

Passwords were generated as 32-byte hexadecimal values and stored in
root-only files:

```text
/opt/keycloak/.keycloak-admin-password
/opt/keycloak/.mcp-user-password
```

These files are an agent-centric adaptation of the human runbook. They allow
future maintenance without printing or placing passwords in command-line
arguments. A production hardening pass should consider a dedicated secret
manager or systemd credentials instead of long-lived plaintext root-only
files.

## Keycloak-specific agent lessons

### Bootstrap administrator lifecycle

Create a separate CLI configuration for the permanent administrator and prove
that it can list realms before touching the bootstrap account. Resolve the
bootstrap user by exact username immediately before deletion. Container
recreation clears `/tmp/kcadm*.config`, so reauthenticate afterward.

The bootstrap account disappeared unexpectedly during the experiment. The
agent initially gave an invalid explanation and continued past a stop guard.
The recovery was to audit current master-realm users, bootstrap references in
both deployment files, running container variable names, timestamps, and the
permanent administrator login. Future automation must treat an unexpected
zero-match as a hard failure requiring reconciliation.

### DCR policies are realm components

On Keycloak 26.7, do not use the obsolete
`client-registration-policy/anonymous` endpoint. Query realm components of
type:

```text
org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy
```

Select components whose `subType` is exactly `anonymous`. Resolve a fresh UUID
for each provider immediately before updating it. Collection output can
collapse configuration to `{}`, so verify every updated component with a
direct `components/UUID` request.

The verified anonymous configuration was:

- Allowed Client Scopes: `mcp:tools`
- Allow default scopes: `true`
- Trusted Hosts: `10.1.1.5`, `localhost`, `127.0.0.1`
- Source-host matching: `true`
- Client-URI matching: `true`
- Max clients: `20`
- Consent Required: present
- Full Scope Disabled: present

The experiment produced conflicting Trusted Hosts UUIDs in one agent report.
No reported UUID was trusted; all target UUIDs were re-resolved from the API
immediately before mutation.

### Client scope and audience

The `mcp:tools` client scope must include all three attributes:

```json
{
  "display.on.consent.screen": "true",
  "include.in.token.scope": "true",
  "include.in.openid.provider.metadata": "true"
}
```

The audience mapper must set the custom audience to
`https://gmktec.home.arpa/mcp`, include it in access and introspection tokens,
and exclude it from ID tokens. Omitting `include.in.token.scope=true` can
produce a correct audience with an empty scope claim, resulting in `403` from
the MCP server.

### DCR test artifact handling

A DCR response contains a registration access token. Pre-create its output
file with mode `0600`, or perform creation and request in one shell with an
explicit restrictive mode. Print only selected safe fields. Resolve the
resulting client through the Admin API, validate its name and attributes,
delete it by internal UUID, verify zero remaining matches, and remove the
response file.

Request only `mcp:tools`. Explicitly requesting `openid mcp:tools` can fail
the Allowed Client Scopes policy even though realm-default scopes are allowed.

## Nginx and MCP service lessons

The active Nginx site was
`/etc/nginx/sites-available/camera-apps`, reached through the sole
`sites-enabled` symlink. The agent first performed a full read-only inspection
because an earlier report contained a `home.arapa` transcription error. The
live configuration correctly used `gmktec.home.arpa`.

The edit added only:

- `/auth` to `/auth/` redirect
- `/auth/` proxy to `127.0.0.1:8080/auth/`
- exact protected-resource metadata proxy to `127.0.0.1:8001`

The existing `/mcp`, WebRTC, TLS, and static routes were preserved. The backup
was stored at:

```text
/etc/nginx/backups/camera-apps.pre-keycloak
```

The private CA was already installed in the system trust store. Because
`/etc/nginx/tls` was not traversable by the Hermes user, only the public CA
certificate was copied to:

```text
/home/stephen/.hermes/certs/camera-system-root-ca.crt.pem
```

Source and destination SHA-256 fingerprints were required to match.

OAuth was enabled for the MCP service with:

```ini
[Service]
Environment=MCP_OAUTH_ENABLED=true
Environment=MCP_OAUTH_ISSUER=https://gmktec.home.arpa/auth/realms/mcp
Environment=MCP_RESOURCE_URL=https://gmktec.home.arpa/mcp
Environment=MCP_OAUTH_JWKS_URL=http://127.0.0.1:8080/auth/realms/mcp/protocol/openid-connect/certs
```

The loopback JWKS URL is intentional. Keycloak is on the same host and port
8080 is bound only to loopback.

Before OAuth was enabled, a plain `curl` to `/mcp` returned `406`. That was
MCP content negotiation, not proof of authentication enforcement. After
OAuth was enabled, the same unauthenticated request returned `401` with the
exact protected-resource metadata URL.

## Hermes OAuth: verified configuration

The final safe configuration fields were equivalent to:

```yaml
mcp_servers:
  camera-new:
    url: https://gmktec.home.arpa/mcp
    auth: oauth
    enabled: true
    ssl_verify: /home/stephen/.hermes/certs/camera-system-root-ca.crt.pem
    connect_timeout: 30.0
    oauth:
      redirect_port: 8765
```

Do not rely on Hermes inferring OAuth merely from an HTTPS URL. During the
experiment, `hermes mcp add --auth oauth` saved an entry without an explicit
`auth` key. Add and verify `auth: oauth` structurally.

Keep a new server disabled until login succeeds and saved-state testing passes.
Enabling it prematurely caused the running Hermes context to repeatedly start
OAuth flows during configuration reloads.

### Simplified supervised login

The successful login used one local terminal and one SSH command:

```bash
ssh -tt -L 8765:127.0.0.1:8765 stephen@gmktec.home.arpa \
  '/home/stephen/.local/bin/hermes mcp login camera-new'
```

The operator then opened the printed authorization URL, logged in as
`mcp-user`, approved consent, and allowed the browser to redirect normally to
`http://127.0.0.1:8765/callback` through the same SSH connection. No callback
URL was copied manually.

The browser displayed:

```text
Authorization Successful
You can close this tab and return to Hermes.
```

Hermes reported:

```text
Authenticated — 28 tool(s) available
```

SSH emitted several `channel ... connect failed: Connection refused` messages
after success. These were harmless browser follow-up requests after Hermes had
closed its one-time callback listener.

### Get password from client terminal

ssh -t stephen@gmktec.home.arpa 'sudo cat /opt/keycloak/.mcp-user-password'

### Failed approaches and recovery

Two earlier approaches failed:

1. An OAuth flow started automatically from a Hermes configuration reload.
   It left a callback helper, a DCR client, and only
   `camera-new.client.json`.
2. Manual callback-URL pasting caused a rapid retry that attempted to bind the
   same cached port twice.

Hermes source inspection identified a callback-port race involving a legacy
module-global port and cached redirect ports. Recovery required:

1. Disable `camera-new` to stop automatic reconnect/login attempts.
2. Resolve the process holding the callback port.
3. Send `SIGTERM` only if it was owned by `stephen` and its command was the
   expected `tools/mcp_oauth.py` helper.
4. Internally parse `camera-new.client.json` to obtain its client ID without
   displaying the registration token.
5. Match that ID to exactly one Keycloak client with the expected name,
   redirect URI, public-client state, and `mcp:tools` scope.
6. Delete the verified Keycloak client and local `.client.json` artifact.
7. Verify no `.json` token or `.meta.json` file existed before treating the
   attempt as incomplete.
8. Configure a fixed free port and retry with the single-command SSH tunnel.

If `camera-new.json` exists after an apparent failure, do not delete anything
until `hermes mcp test camera-new` is attempted. Tokens may already have been
acquired even if the browser displayed an error.

## Backup and restore verification

The experiment installed:

```text
/usr/local/sbin/backup-keycloak-postgres
/etc/systemd/system/keycloak-postgres-backup.service
/var/backups/keycloak-postgres/
```

The service is deliberately manual; no timer was installed. The backup script
creates a custom-format, zstd-compressed archive through `pg_dump`, writes via
a temporary file, applies mode `0600`, moves atomically, and retains 14 days.

The verified backup was created after the real Hermes DCR/login, so it includes
the active client registration. Validation required:

- one-shot service exit `0/SUCCESS`
- nonempty root-owned archive with mode `0600`
- successful `pg_restore --list`
- restore into a uniquely named `keycloak_restore_test_*` database
- nonzero counts for `realm`, `user_entity`, and `client`
- guarded deletion of only the verified test database
- production `keycloak` database still present and containers healthy

Same-host backups do not protect against host or disk loss. Unattended
production operation will need a separately protected backup destination and
a retention/restore policy.

## Final verification criteria

A deployment is complete only when all of these pass:

- PostgreSQL is healthy and Keycloak is running.
- Nginx and `onvif-mcp-http.service` are active.
- Public discovery returns `200`.
- Issuer is exactly `https://gmktec.home.arpa/auth/realms/mcp`.
- Registration endpoint is exactly
  `https://gmktec.home.arpa/auth/realms/mcp/clients-registrations/openid-connect`.
- `S256` is supported.
- `mcp:tools` is published.
- Unauthenticated `/mcp` returns `401`.
- `WWW-Authenticate` contains the exact protected-resource metadata URL.
- Protected-resource metadata contains the exact resource, issuer, scope, and
  `header` bearer method.
- Anonymous disposable DCR returns `201` and can be precisely cleaned up.
- `hermes mcp test camera-new` reconnects without browser login.
- Hermes discovers 28 tools in the verified deployment.
- The post-login backup exists, is mode `0600`, and has a readable catalog.
- The isolated restore test succeeds and its test database is removed.

## Work required before unsupervised operation

The following items should be implemented before granting an agent unattended
control:

1. **Idempotent orchestration.** Convert phases into scripts with explicit
   state models and machine-readable results rather than prose-driven shell
   execution.
2. **Transaction journals.** Record each resolved target, mutation, and
   verification so interrupted runs can resume or roll back safely.
3. **Typed secret handling.** Replace plaintext password files where practical
   and ensure every secret output path is created with explicit mode `0600`.
4. **Hard stop enforcement.** A failed assertion must terminate the complete
   phase, not merely one subprocess.
5. **Structured Keycloak reconciliation.** Compare desired and actual realms,
   users, scopes, mappers, and components without trusting reported UUIDs.
6. **Hermes OAuth lifecycle management.** Detect and clean incomplete DCR
   clients, token artifacts, and callback helpers without racing the active
   Hermes process.
7. **Browser automation or device-style flow.** Remove the remaining human
   browser step while retaining phishing-resistant authorization and consent.
8. **Concurrency locks.** Permit only one OAuth flow and one deployment phase
   for a named server at a time.
9. **Automatic rollback tests.** Exercise failed Nginx, systemd, DCR, OAuth,
   backup, and restore paths in a disposable environment.
10. **Off-host backups.** Add encrypted transfer, retention, integrity checks,
    and periodic automated restore tests.
11. **Report provenance.** Attach exact command exit status and authoritative
    source to every reported fact; reject unsupported narrative claims.
12. **Version gates.** Refuse untested Keycloak, Hermes, Docker, or PostgreSQL
    versions until compatibility tests pass.

Until these controls exist, retain a human approval checkpoint before:

- deleting any Keycloak user or client
- changing DCR policy
- reloading Nginx or restarting the MCP service
- initiating or cleaning an OAuth flow
- deleting token artifacts
- dropping a restore-test database
- changing backup retention or scheduling

## Conclusion

The experiment proves that an agent can perform nearly the entire deployment
through CLI-driven, evidence-backed phases. It also demonstrates why full
autonomy is premature: the most serious problems came from continuing past
failed guards, reporting inference as fact, leaking OAuth state into chat,
and allowing concurrent Hermes OAuth attempts.

The next iteration should turn this supervised narrative into idempotent,
machine-verifiable phase scripts. The agent should orchestrate those scripts,
interpret structured results, and request human intervention only at explicit
policy boundaries or genuinely unrecoverable ambiguity.
