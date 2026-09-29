# Keycloak CLI Deployment for the ONVIF MCP Server

## Values supplied by agent

| Name | Description |
|------|-------------|
| `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name e.g. camera.home.arpa |
| `{{BACKUP_PATH}}` | Backup folder |

Executable installation actions are implemented by:

```bash
scripts/KEYCLOAK/keycloak_runbook.sh
```

That script is the single source of truth for the commands that install and
configure Keycloak for this runbook. The prose below is the agent guide: it
states intent, required checks, boundaries, and follow-up checkpoints without
repeating executable shell fragments that can drift from the script.

## Purpose

This runbook creates a Keycloak OAuth 2.1/OpenID Connect deployment for an ONVIF
MCP server without using the Keycloak Admin Console. It assumes:

- Ubuntu Server with sudo access.
- Nginx already serving the MCP application over HTTPS.
- The MCP HTTP service listening on `127.0.0.1:8001`.
- A server certificate issued by the private camera CA.
- Docker and Keycloak not yet installed, or no production `/opt/keycloak`
  deployment unless explicitly inspected.
- A client such as Hermes Agent that supports DCR, Authorization Code flow,
  PKCE, and rotating refresh tokens.

The resulting access token must contain claims equivalent to:

```json
{
  "iss": "https://{{SERVER_FQDN}}/auth/realms/mcp",
  "aud": "https://{{SERVER_FQDN}}/mcp",
  "scope": "mcp:tools",
  "typ": "Bearer"
}
```

## Security rules

- Never paste passwords, `.env` contents, JWTs, refresh tokens, DCR registration
  access tokens, browser cookies, or Hermes token files into logs or chat.
- Never use `curl -k` for deployment verification. Install and trust the issuing
  CA instead.
- Keep Keycloak and PostgreSQL bound to loopback or their private Compose
  network. Do not publish PostgreSQL.
- Generate secrets with a restrictive umask and store them as root-owned files.
- Use a permanent Keycloak administrator and remove bootstrap credentials after
  verifying the permanent account.
- Treat DCR response files as secrets even when the client is disposable.
- Back up Nginx configuration outside included nginx directories.
- Resolve and verify exact object IDs before deleting anything.

## 1. Preflight

Confirm identity and baseline state before applying the script:

- `{{SERVER_FQDN}}` resolves to this server.
- Nginx owns ports 80 and 443.
- The MCP service owns `127.0.0.1:8001`.
- Port 8080 is available for loopback Keycloak.
- `/opt/keycloak` is absent or intentionally being resumed.
- `{{BACKUP_PATH}}` is a reachable mounted backup target for later checkpoints.

## 2. Install and configure Keycloak (AGENT-run)

Run with resolved values:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/KEYCLOAK/keycloak_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

For this deployment, the resolved command is:

```bash
cd /home/stephen/onvif-mcp
scripts/KEYCLOAK/keycloak_runbook.sh apply \
  --server-fqdn gmktec.home.arpa \
  --backup-path /mnt/camera-backup \
  --repo-path /home/stephen
```

The script performs these executable stages:

1. Installs Docker/Compose prerequisites and starts Docker.
2. Creates `/opt/keycloak`, root-owned generated secrets, and the Compose file
   for PostgreSQL 17 and Keycloak 26.7.0.
3. Starts Keycloak with a temporary bootstrap administrator.
4. Creates and verifies the permanent `keycloak-admin` user, grants the master
   realm `admin` role, deletes the bootstrap user, removes bootstrap environment
   variables, and recreates the container so bootstrap secrets leave the runtime
   environment.
5. Creates the `mcp` realm, session/token settings, the sample `mcp-user`, and a
   root-owned `mcp-user.pass` file.
6. Creates the `mcp:tools` client scope and audience mapper for
   `https://{{SERVER_FQDN}}/mcp`.
7. Configures anonymous Dynamic Client Registration policies for allowed scopes,
   trusted hosts, and a max client count.
8. Adds `/auth/` and protected-resource metadata proxy routes to the active HTTPS
   nginx vhost and reloads nginx after validation.
9. Installs the private camera CA into the system trust store and verifies public
   Keycloak discovery without `curl -k`.
10. Enables OAuth on `onvif-mcp-http.service` with a systemd drop-in and verifies
    unauthenticated MCP requests return `401` with protected-resource metadata.
11. Performs a safe DCR test that prints only non-secret fields, deletes the
    temporary client by verified internal ID, and removes the DCR response file.
12. Installs the Keycloak PostgreSQL one-shot backup service, runs it, verifies
    a readable dump catalog, and performs an isolated restore test into a throwaway
    database.
13. Writes the Hermes MCP server entry with `auth: oauth`, explicit private-CA
    `ssl_verify`, `auto_reload_on_config_change: false`, and `enabled: false`.

The script intentionally does not print generated secret values. It writes
passwords only to root-owned files under `/opt/keycloak`.

## 3. Configure and verify Hermes login

After the script finishes, the Hermes MCP entry is present but disabled so no
background process starts a competing OAuth flow. Complete the real OAuth login
with the procedure in this section, then enable the entry only after testing.

No other Hermes process may have this server loaded while `hermes mcp login`
runs. With the entry present in an active session, background discovery can
launch a second concurrent OAuth flow and cause `OAuth callback port 27890 is
already in use`.

Use an isolated Hermes home for login, copy the resulting token files back, and
never display their contents. The browser step can be completed headlessly using
`scripts/kc-headless-login-driver.py`; it reads `/opt/keycloak/mcp-user.pass` via
`sudo cat` and never prints credentials or token values.

Expected post-login checks:

- token files exist at `~/.hermes/mcp-tokens/camera.{json,client.json,meta.json}`
  with mode `0600`;
- `hermes mcp test camera` succeeds and lists the expected tools;
- the config entry is enabled only after the test passes;
- any failed/orphan DCR clients are removed only after matching client IDs and
  verifying the internal Keycloak UUID/name.

After the real OAuth client completes DCR and login, create another database
backup/checkpoint so the active client registration is included.

## 4. Status checks (AGENT-run)

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/KEYCLOAK/keycloak_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --repo-path {{REPO_PATH}}
```

For this deployment:

```bash
cd /home/stephen/onvif-mcp
scripts/KEYCLOAK/keycloak_runbook.sh status \
  --server-fqdn gmktec.home.arpa \
  --repo-path /home/stephen
```

Required outcomes before declaring the installation ready:

- PostgreSQL is healthy and Keycloak is running.
- Nginx and the MCP service are active.
- Public Keycloak discovery returns 200 with the exact issuer.
- `S256` appears in `code_challenge_methods_supported`.
- `mcp:tools` appears in `scopes_supported`.
- An unauthenticated MCP request returns 401 with protected-resource metadata.
- Anonymous DCR succeeds for `mcp:tools` from an allowed host.
- Hermes completes browser authorization and reconnects using saved state.
- The MCP client discovers the expected tools.
- A post-login database backup exists, its catalog is readable, and an isolated
  restore test has succeeded.

## 5. Shared checkpoints

After nginx validation, create a complete nginx checkpoint per
[NGINX_BACKUP.md](NGINX_BACKUP.md):

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/NGINX_BACKUP/nginx_backup_runbook.sh create-checkpoint \
  --server-fqdn {{SERVER_FQDN}} \
  --backup-path {{BACKUP_PATH}} \
  --trigger KEYCLOAK.md
```

After the isolated restore test and successful real-client DCR/login, create a
Keycloak checkpoint per [KEYCLOAK_BACKUP.md](KEYCLOAK_BACKUP.md):

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/KEYCLOAK_BACKUP/keycloak_backup_runbook.sh create-checkpoint \
  --backup-path {{BACKUP_PATH}} \
  --trigger KEYCLOAK.md
```

If creating coordinated nginx and Keycloak checkpoints, prepare both target paths
and pass the compatible checkpoint path to the other script before publication.
Publish only after each checkpoint's own checks pass. Do not mutate a completed
checkpoint to add links.

Host-unit configuration outside nginx is separate. Reinstall the backup script
and unit from this runbook's script rather than storing them in nginx or
Keycloak checkpoints.

## Routine operations

Status:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/KEYCLOAK/keycloak_runbook.sh status \
  --server-fqdn {{SERVER_FQDN}} \
  --repo-path {{REPO_PATH}}
```

Manual local database backup:

```bash
sudo systemctl start keycloak-postgres-backup.service
sudo systemctl show keycloak-postgres-backup.service -p Result -p ExecMainStatus
```

Hermes verification:

```bash
hermes mcp test camera
```

Review DCR clients periodically and remove obsolete registrations only after
matching their client IDs to the active ID stored by the OAuth client. Never
display associated token files.

## Known pitfalls

- `client-registration-policy/anonymous` returns 404 on Keycloak 26.7. Use realm
  components and select policies with `subType: anonymous`.
- Component UUIDs change on every realm installation. Never reuse example UUIDs.
- Collection component output can show `config: {}` even when configuration is
  stored. Retrieve each component by ID when diagnosing.
- An explicit DCR request for `openid mcp:tools` can fail with
  `insufficient_scope`. Request `mcp:tools`; allow realm-default scopes through
  `allow-default-scopes`.
- Omitting `include.in.token.scope=true` produces tokens whose audience may be
  correct but whose `scope` claim is empty.
- A redirect from `/mcp/` to `http://...` downgrades HTTPS and must be fixed.
- Saving a Hermes entry before setting `ssl_verify` can leave it disabled. Add
  the CA path and explicitly enable it only after login/test succeeds.
- Never diagnose private-CA failures with `curl -k`; install the CA correctly.
- A Compose container recreation clears `/tmp/kcadm.config`; it does not erase
  PostgreSQL data stored in the named volume.
- Same-host backups do not protect against disk or host loss. Publish recovery
  checkpoints to a separately protected backup target.
