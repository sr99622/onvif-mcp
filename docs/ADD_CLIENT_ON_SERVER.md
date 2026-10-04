# Permit a New DCR Client on the Server (Trusted Hosts)

## Purpose

Server-side configuration for Keycloak client access. It adds one new Hermes
client's source address to the anonymous Dynamic Client Registration (DCR)
Trusted Hosts policy in Keycloak, so that machine can register its own public
OAuth client.

This document is written for a single server where Nginx fronts both the MCP
server and Keycloak, and where Keycloak runs locally through the `/opt/keycloak`
Compose project. All Admin REST calls are made from the server host against the
loopback Keycloak listener; nothing here changes the network-facing stack.

## Required Values

| Symbol | Description |
|--------|-------------|
| `{{CLIENT_SOURCE_IP}}` | Client IP address as observed by the server. Clients running in a virtual machine or container may be observed by the server as coming from the client host computer. Attempt a login from the client prior to running these instructions to place the observed IP address in the server cache for verification. |
| `{{BACKUP_PATH}}` | Backup folder |

Runbook defaults used by the script:

| Symbol | Meaning | Typical value in this deployment |
|---|---|---|
| `{{MCP_REALM}}` | Keycloak realm hosting the MCP client-registration policy | `mcp` |
| `{{KEYCLOAK_ADMIN_USER}}` | Permanent administrator user in the `master` realm | `keycloak-admin` |
| `{{KEYCLOAK_PORT}}` | Loopback TCP port of the Keycloak listener | `8080` |
| `{{KEYCLOAK_PATH}}` | Keycloak relative path on loopback | `/auth` |

The admin password lives in `/opt/keycloak/admin.pass`, a root-owned mode `0600`
file. It must never appear on a command line, in an environment variable, or in
an untrusted location.

## Executable source of truth

Executable actions for this runbook are implemented by:

```bash
scripts/ADD_CLIENT_ON_SERVER/add_client_on_server_runbook.sh
```

That script is the single source of truth for commands that inspect Nginx DCR
logs, resolve the live Trusted Hosts component, update the host list, verify the
result, check cleanup, and create a Keycloak checkpoint. The prose below states
intent, boundaries, and expected verification output without duplicating shell
fragments that can drift from the script.

## Token lifetime and Step 3 gotcha

Keycloak access tokens used here are short-lived. The mutating operation must not
mint a token in one step and reuse it later. The script preserves this hard rule:
its update sequence runs inside one root-controlled Python process that mints the
token, resolves the component live, fetches the component by ID, edits the current
representation, sends the PUT, performs a second direct by-ID fetch, verifies the
stored result, and exits without leaving token/body/update files behind.

If that sequence fails, re-run the whole script. Do not retry individual Admin
REST calls with an old token or a component UUID remembered from another run.

## Security rules

- Never print the admin password, access token, or DCR registration artifacts to
  chat, logs, or shell history.
- Add exactly one address per client. Do not widen the policy to a subnet unless
  the installed Keycloak provider is confirmed to accept CIDR syntax; do not
  disable Trusted Hosts to simplify onboarding.
- Change only the anonymous `trusted-hosts` component of the MCP realm.
- Resolve the component live every time. Never copy a component UUID from another
  installation, another realm, or a previous deployment.
- Preserve pre-existing trusted hosts and keep both matching controls set to
  `["true"]`.

## 1. Add the client source IP (AGENT-run)

Run with resolved values:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/ADD_CLIENT_ON_SERVER/add_client_on_server_runbook.sh apply \
  --client-source-ip {{CLIENT_SOURCE_IP}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

The script performs these executable stages:

1. Validates `{{CLIENT_SOURCE_IP}}` as an IP address.
2. Prints server addresses, verifies Keycloak loopback discovery returns HTTP
   200, and shows recent Nginx DCR access-log entries.
3. Resolves exactly one anonymous `trusted-hosts` component and prints its
   current trusted hosts and matching controls.
4. Runs the required single bounded root-controlled update command:
   mint token, resolve component live, fetch by ID, append the client IP if
   absent, PUT the full current representation, fetch by ID again, and verify.
5. Verifies the stored list contains `{{CLIENT_SOURCE_IP}}`, preserves
   `localhost` and `127.0.0.1`, and keeps both matching controls at `["true"]`.
6. Writes non-secret update evidence to
   `scripts/ADD_CLIENT_ON_SERVER/last-trusted-hosts-update.json`.
7. Confirms no known Keycloak token/body/update temporary files remain.
8. Reads the Trusted Hosts component back again as a final status check.
9. Creates a Keycloak checkpoint through KEYCLOAK_BACKUP.md's script.
10. Shows recent DCR log entries again and reports client DCR/login verification
    as pending until the client retries.

## 2. Status checks (AGENT-run)

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/ADD_CLIENT_ON_SERVER/add_client_on_server_runbook.sh status \
  --client-source-ip {{CLIENT_SOURCE_IP}}
```

Required outcomes before handing back to the client:

- Keycloak loopback discovery returns HTTP 200.
- Exactly one anonymous `trusted-hosts` component exists in realm `mcp`.
- Trusted hosts include `10.1.1.4` plus the pre-existing hosts.
- `host-sending-registration-request-must-match` is `["true"]`.
- `client-uris-must-match` is `["true"]`.
- No `.kctmp.*`, `.kctok.*`, `kc-components.json`, `kc-cid.txt`, or `kc-th-*`
  temp artifacts remain in `/tmp`.

## 3. Hand back to the client

Tell the client to retry the OAuth login so it can run DCR from the newly trusted
source address. Confirm success by watching Nginx record a `201` for the
`clients-registrations/openid-connect` POST from `{{CLIENT_SOURCE_IP}}`.

If the client receives `Host not trusted` again, its observed source address
differs from the one added (NAT/routing change). Re-run the script only with the
new observed address; do not broaden to a subnet by default.

## 4. Individual addresses versus subnets

The strict default is to allow each observed client address individually. This
gives clear registration boundaries but requires stable addresses or DHCP
reservations. A narrowly scoped trusted subnet may reduce administration on a
controlled LAN, but use it only after confirming that the installed Keycloak
provider accepts the intended CIDR syntax. Do not assume CIDR support, and do not
disable Trusted Hosts merely to simplify onboarding.

## 5. Keycloak backup checkpoint

The script creates a stage-close checkpoint under:

```text
{{BACKUP_PATH}}/keycloak/YYYYMMDDHHMMSSZ/
```

That checkpoint is created through KEYCLOAK_BACKUP.md's shared script and
contains a fresh PostgreSQL dump with the trusted-host policy write, a fresh
`keycloak.tar`, metadata, and verified `SHA256SUMS`.

If later client registration changes the database, take another checkpoint after
that registration is verified; do not modify a completed checkpoint.

## Troubleshooting

- `401` on the token endpoint: wrong admin username or password file; check
  `keycloak-admin` and `/opt/keycloak/admin.pass`. Never retry with a different
  realm than `master`.
- Zero components matching: wrong realm, or the anonymous DCR policy was
  deleted/renamed by hand. Inspect before touching anything; restoring a provider
  from memory is not supported.
- PUT returns a conflict or the component changes concurrently: rerun the whole
  script so it re-fetches current state and re-applies the one-address addition.
- Client still gets `insufficient_scope` or `Host not trusted`: verify Nginx is
  forwarding the real client address and that the access-log source column is the
  address you added.

## Final checklist

- Keycloak health on loopback returned 200.
- `{{CLIENT_SOURCE_IP}}` came from the Nginx DCR access log or another explicit
  observation, not a guess.
- Exactly one anonymous `trusted-hosts` component existed in `mcp`.
- All pre-existing trusted hosts were preserved; exactly one address was added or
  confirmed already present.
- Both matching controls remain `["true"]`.
- Verification used a direct by-ID GET after the PUT in the same process.
- Token/body/update temp files are deleted; no secret is printed anywhere.
- The client's next DCR attempt from the same address succeeds with HTTP 201.
- Stage-close backup is complete and checksums verify.
