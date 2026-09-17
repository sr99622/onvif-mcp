# STREAM_AUTH Step 9 recovery — gmktec.home.arpa

Date: 2026-09-16 (EDT)
Server: `gmktec.home.arpa`, `10.1.1.5`
Scope: README Step 6 / STREAM_AUTH.md Steps 9–10, plus defects found in verification.

## Outcome

Browser authentication and the authenticated HTTP MCP regression checks now pass.
The server's Keycloak policies did not need to be weakened or rebuilt. The fix
was to request the MCP scopes explicitly in the Hermes authorization flow,
restore a valid saved login, and use the correct CA trust bundle.

The `camera-new` entry remains disabled for automatic tool loading, as it was at
recovery start. Explicit `hermes mcp test camera-new` succeeds. The existing
local `camera` entry remains enabled. This recovery did not switch the running
agent's transport or alter other Hermes profiles.

## What actually stopped the previous agent

Evidence was recovered read-only from the default profile's session database,
session `20260916_092510_79e78a`, and compared with live service/API state.

1. The browser portion of Step 9 had already passed on gmktec. The agent was
   working on the subsequent MCP OAuth regression checks, not a broken browser
   login. Its session messages 653–655 explicitly record that distinction.
2. The agent ran reauthentication, which clears cached OAuth state. Its own
   account records that this discarded its prior token. Repeated replacement
   logins then produced access tokens with an empty `scope` and no `aud`.
3. Authorization URLs supplied to the headless driver in messages 673 and 699
   had `client_id`, redirect, response type, state and PKCE parameters, but NO
   `scope` parameter. A registration response mentioning scopes is not evidence
   that an authorization request actually asks for them.
4. On recovery, the saved client ID no longer existed in the live realm. Its
   cached token was expired and lacked the required claims. That also explains
   why refreshing this stale client was not a viable recovery path; the earlier
   session recorded `invalid_client`.
5. Repeated login/probe attempts produced callback listener collisions on port
   27890. The earlier session also records a broad `pkill -f` cleanup matching
   and terminating its own shell wrapper. The final assistant record says
   “Operation interrupted: waiting for model response.” There is no evidence
   here establishing an OOM or a camera-service crash; the demonstrated failure
   was a non-converging OAuth recovery, with interrupted agent execution.

The previous agent proposed making `mcp:tools` a default scope and asserted that
consent was disabled. Live inspection contradicted that explanation: the DCR
clients had consent enabled, and `mcp:tools` correctly existed as an optional
scope with the MCP audience mapper.

## Root-cause experiment

A bounded Authorization Code + S256 PKCE probe used an existing DCR client and
the same login user, with credentials and cookies kept in memory:

- Explicit `scope=offline_access mcp:tools`: token contained `mcp:tools`,
  `offline_access`, and audience `https://gmktec.home.arpa/mcp`.
- Same flow with the scope parameter omitted: token had empty scope and no
  audience; the assertion failed with `missing MCP scope`.

This isolates the missing authorization scope without changing realm policy.
The reason the installed client stack failed to infer the scope automatically
was not established; an explicit supported configuration removes that dependency.

## Changes made

### Hermes, default profile only

Configured through the supported CLI, then read back:

```bash
hermes config set mcp_servers.camera-new.oauth.scope 'offline_access mcp:tools'
hermes config set mcp_servers.camera-new.ssl_verify /etc/ssl/certs/ca-certificates.crt
```

Simply setting TLS verification to `true` failed in Hermes with
`CERTIFICATE_VERIFY_FAILED`, even though system Python and curl trusted the site.
The explicit host CA bundle works; TLS verification is not bypassed.

Completed one successful, bounded Hermes login after resolving that CA issue.
The authorization URL was captured in memory and checked for the scopes before
credentials were submitted. Verified the saved token's MCP scope and audience,
refresh-token presence, then tested a later independent connection successfully.
No password, code, state, bearer token or cookie was printed by the recovery
login harness. Temporary TLS-failing attempts were terminated by exact child
process handles, not pattern-based process killing.

### Browser verifier and runbook

- `scripts/stream_auth_step9_driver.py` now requires `--origin`; it no longer
  silently uses the unrelated `nuc.home.arpa` example host.
- Removed `CERT_NONE` and disabled-hostname-check overrides. The verifier now
  uses system CA trust and validates both certificate and hostname.
- Corrected the driver's documented path and the runbook invocation.
- Added offline regression tests proving TLS validation and mandatory origin.
  Both tests were observed failing before the corresponding fixes and passing
  afterward.
- Added runbook guidance on explicit MCP scopes, CA trust, destructive reauth,
  and avoiding overlapping OAuth flows.

Important security observation: the initial unmodified-driver reproduction in
this recovery used its documented default and submitted the local test-user
password to `nuc.home.arpa`, where login failed repeatedly. It did NOT test
gmktec. This is why a mandatory origin is a safety fix, not just convenience.
If nuc is not an equally trusted server, rotate the mcp-user password and
invalidate its sessions. No password value is included in this report.

### Nginx

In `/etc/nginx/conf.d/gmktec.home.arpa.conf`, changed only the `/outputs/`
fallback's `return 404;` to `try_files "" =404;` and added an explanatory comment.
The old return executed before `auth_request`. The new fallback authenticates
first, then returns 404. The separately protected camera registry remains intact.

`nginx -t` passed before reload. After the new workers adopted the configuration,
unauthenticated fallback access returned 302 and authenticated access returned
404. An immediate request during reload still saw the old worker's 404; the
subsequent assertion-based checks passed.

## Verification results

- Nginx, MediaMTX, HTTP MCP and snapshot-proxy active; Keycloak and oauth2-proxy
  running; PostgreSQL healthy.
- Keycloak discovery: HTTPS 200 with certificate validation.
- Internal HTTP listeners 4180, 8080, 8001, 8889 and 8891 on loopback only.
- oauth2-proxy internal `/ping`: 200.
- All five browser route families, the exact registry path, and the known
  snapshot path: unauthenticated 302 to login, preserving the requested path.
- HTTP snapshot: 301 to the same HTTPS path; HTTPS then requires login.
- Step 9 driver with explicit gmktec origin: `RESULT=PASS`, including exact
  post-login landing, authenticated ping, second app, WebRTC signaling page,
  authenticated JPEG/no-store, and fresh-session direct-image login.
- Authenticated camera registry: 200, 8 cameras; authenticated `/outputs/`: 404.
- Unauthenticated MCP: 401 Bearer challenge with protected-resource metadata,
  not a browser-login redirect.
- `hermes mcp test camera-new`: connected, 29 tools, including a later connection
  after the initial access-token lifetime had elapsed.
- Authenticated HTTP MCP `get_cameras`: 8 cameras, 19 `web_snapshot_url` values;
  all match the expected HTTPS origin and each live serial/profile-token pair.
- Authenticated HTTP MCP `get_snapshot`, `4B0013BPAABE264` / `MediaProfile000`:
  decoded 1920×1080 JPEG, no browser cookies supplied.
- MCP `STREAM_SERVER_URL` is the HTTPS origin; `SNAPSHOT_PROXY_URL` is unset,
  retaining the loopback default.
- `python3 -m unittest discover -s tests -v`: both tests pass.
- `git diff --check`: passes.

## Backup and rollback

Local pre-recovery rollback archive:
`/var/backups/stream-auth-recovery-20260916-110947/pre-recovery-config.tar`
(root-only directory/archive). It contains the pre-recovery Nginx tree and
Hermes configuration. Temporary copies of obsolete OAuth state were removed
from this archive; do not restore stale tokens.

Stage-close share directory:
`/mnt/taurus/Camera-System-Backup/stream-auth-20260916-110947/`

The checkpoint includes the complete `/opt/keycloak` tree (archive root
`keycloak/`), PostgreSQL dump set (root `keycloak-postgres-backups/`), complete
Nginx conf.d (root `etc/nginx/conf.d/`), pre-change Compose copy, non-secret
pre/post state and Hermes settings, runbook/report/tests, and SHA256SUMS.
It supersedes earlier Keycloak/stream-auth opt-tree, dump-set and conf.d archives,
not the other earlier stage artifacts. OAuth token files are excluded.

Secrets remain inside the required Keycloak/dump archives: this is a sensitive
backup. The mounted SMB share projects local file modes as 0664, so local chmod
is not evidence of server-side access control. Restrict access on Taurus; do not
publish or distribute these archives. Live secrets remain root-owned 0600 and
Compose 0640. Archive catalog and checksum validation are recorded with the
checkpoint; this recovery does not claim a full disaster-restore test.

## Remaining boundaries

Live video rendering/ICE/DTLS/SRTP and visual image display inside the camera apps
remain human confirmation items, as the runbook specifies. No firewall,
new-user onboarding, camera isolation changes or cleanup of unrelated old DCR
clients was performed. Automatic HTTP MCP loading remains disabled by choice
of the pre-existing configuration; enable it separately if that is desired.
