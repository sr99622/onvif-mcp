# Add a New Login Account to the MCP Realm (Own Password)

## Purpose

`KEYCLOAK.md` Section 6 creates exactly one login user (`{{MCP_LOGIN_USER}}`).
This runbook adds one more enabled user in `{{MCP_REALM}}` with its own
password, for a second person or installation that needs separate credentials.

DCR is unaffected: each machine still registers its own public client per
`CLIENT.md`. This account only supplies the identity used at browser
sign-in. The new user needs no roles — `{{MCP_LOGIN_USER}}` was created
without any, and tokens get their claims from the `{{MCP_SCOPE}}` client
scope and audience mapper (`KEYCLOAK.md` Section 7), not from user roles.

If the new account will be used from a machine that is not yet allowed by the
anonymous DCR Trusted Hosts policy, run `ADD_CLIENT_ON_SERVER.md` first with
that machine's observed source address, then continue here.

## Values supplied by the Agent

| Name | Description |
|------|-------------|
| `{{NEW_LOGIN_USER}}` | New login username supplied by agent, e.g. `mcp-user2` | — |
| `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name | `camera.home.arpa` |
| `{{FIRST_NAME}}` | New login first name, supplied by agent; must be non-empty (the realm runs an active `update-profile` required action — see Section 3a). For a machine-only account, repeat `{{NEW_LOGIN_USER}}`. | `Joe` |
| `{{LAST_NAME}}` | New login last name, supplied by agent; must be non-empty (see Section 3a). For a machine-only account, repeat `{{NEW_LOGIN_USER}}`. | `Blow` |
| `{{USER_EMAIL}}` | New login email address, supplied by agent; must be non-empty. For a machine-only account use `{{NEW_LOGIN_USER}}@{{SERVER_FQDN}}` (same convention as `{{MCP_LOGIN_USER}}`). | `joe.blow@example.com` |


## Runbook values

| Symbol | Meaning | Typical value in this deployment |
|---|---|---|
| `{{MCP_REALM}}` | Keycloak realm hosting the MCP login users | `mcp` |
| `{{KEYCLOAK_ADMIN_USER}}` | Permanent administrator in the `master` realm | `keycloak-admin` |
| `{{KEYCLOAK_PORT}}` | Loopback TCP port of the Keycloak listener | `8080` |
| `{{KEYCLOAK_PATH}}` | Keycloak relative path on loopback (`KC_HTTP_RELATIVE_PATH`) | `/auth` |
| `{{SERVER_USER}}` | User account name on server | - |

All calls are made from the server host against the loopback Keycloak
listener via `kcadm.sh` inside the container, exactly as in `KEYCLOAK.md`.
The admin password lives in a root-owned, mode `0600` file
(`/opt/keycloak/admin.pass` in this deployment).

## Security rules

- Never print the new user's password to chat, logs, or shell history. The
  password exists only inside the root-owned secret file and in the piped
  command; display it only when explicitly handing it back to the user.
- Create exactly one new user. Do not modify `{{MCP_LOGIN_USER}}`, existing
  DCR clients, scopes, or components.
- Never copy a user ID from another installation or earlier run — every step
  below resolves IDs live against `{{MCP_REALM}}`.
- Keep the password secret file root-owned at mode `0600` (umask `077`).

## 1. Confirm Keycloak is up and the CLI is authenticated

Confirm health on loopback:

```bash
curl -sS -o /dev/null -w 'Health: HTTP %{http_code}\n' \
  http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/realms/master/.well-known/openid-configuration
```

Expected result: `HTTP 200`. If Keycloak is not up, start it before
continuing (`sudo docker compose --project-directory /opt/keycloak up -d keycloak`).

Confirm the CLI configuration is present and authenticated as the permanent
administrator (it lives at `/tmp/kcadm.config` inside the container and is
lost on container recreation — see `KEYCLOAK.md` Addendum 1):

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get realms \
  --config /tmp/kcadm.config \
  --fields realm,enabled
```

Expected: both `master` and `{{MCP_REALM}}` listed, enabled. If this fails
with an authentication error, re-establish the configuration from the
root-owned secret (the idiom from `KEYCLOAK.md` Section 5), then retry:

```bash
sudo cat /opt/keycloak/admin.pass |
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    sh -c 'IFS= read -r admin_password
      /opt/keycloak/bin/kcadm.sh config credentials \
        --config /tmp/kcadm.config \
        --server http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}} \
        --realm master \
        --user {{KEYCLOAK_ADMIN_USER}} \
        --password "$admin_password"'
```

## 2. Confirm the username is free in `{{MCP_REALM}}`

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get users \
  --config /tmp/kcadm.config \
  -r "{{MCP_REALM}}" -q exact=true -q username={{NEW_LOGIN_USER}} \
  --fields id,username
```

Expected result: an empty list (`[]`). If a user with that name already
exists, stop and choose a different `{{NEW_LOGIN_USER}}`; do not create or
overwrite it.

While here, confirm the pre-existing login user is intact (a second account
must never disturb the first):

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get users \
  --config /tmp/kcadm.config \
  -r "{{MCP_REALM}}" \
  --fields id,username,enabled
```

## 3. Create the user in `{{MCP_REALM}}`

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh create users \
  --config /tmp/kcadm.config \
  -r "{{MCP_REALM}}" \
  -s username="{{NEW_LOGIN_USER}}" \
  -s enabled=true
```

Do not capture the ID from this output. Resolve it live in `{{MCP_REALM}}`
and require exactly one match:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get users \
  --config /tmp/kcadm.config \
  -r "{{MCP_REALM}}" -q exact=true -q username={{NEW_LOGIN_USER}} \
  --fields id,username

export NEW_USER_UUID="UUID_RETURNED_BY_KEYCLOAK"
```

## 3a. Mark the email as verified (oauth2-proxy gate)

Keycloak leaves the email field **empty** when a user is created without an
explicit email — it assigns a placeholder address (`<username>@example.com`)
only lazily, at first login. The browser sign-in flow then fails at
`/oauth2/callback` with HTTP 500 — oauth2-proxy rejects the callback because
"email in id_token ... isn't verified". The pre-existing login user has a
verified email, which is why only new users hit this.

This realm runs an active `update-profile` (UPDATE_PROFILE) required action,
so a fresh user bounces to `/login-actions/required-action` at first login
until **all** of `email`, `firstName`, and `lastName` are nonempty *and*
`emailVerified=true`. Set all four fields from the agent-supplied values —
never an invented placeholder (for a machine-only account, repeat
`{{NEW_LOGIN_USER}}` for the names and use `{{NEW_LOGIN_USER}}@{{SERVER_FQDN}}`
for the email) — using the PUT-against-live representation idiom from
`STREAM_AUTH.md` Section 2 (PATCH is rejected with HTTP 405 on Keycloak 26;
PUT has replace semantics, so it must run against the freshly fetched body in
the same bounded command):

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh update "users/${NEW_USER_UUID}" \
  --config /tmp/kcadm.config -r "{{MCP_REALM}}" \
  -s email="{{USER_EMAIL}}" \
  -s firstName="{{FIRST_NAME}}" \
  -s lastName="{{LAST_NAME}}" \
  -s emailVerified=true
```

Prefer this in-container `kcadm.sh` call over the raw Admin-REST PUT: it is
one command, needs no token minting or bearer header, and cannot be tripped
by the mangled-shell-substitution failure described in Troubleshooting. The
raw REST route (fetch live representation → modify → `PUT`) remains valid —
see `STREAM_AUTH.md` Section 2 for why it must run as a single bounded
command (PATCH is rejected with HTTP 405 on Keycloak 26) — but the token must
never be assembled from shell substitution over a credential file.

Re-retrieve directly by UUID and confirm: exact username, `enabled=true`,
nonempty `email`/`firstName`/`lastName` exactly as supplied,
`emailVerified=true`. Never set the flag false. If first login later lands on
`/login-actions/required-action` ("Update Account Information"), some field
above is still empty — re-run this section from the top.

## 4. Generate the password and store it as a root-owned secret

Generate without displaying it:

```bash
sudo sh -c 'umask 077; printf "%s" "$(openssl rand -hex 32)" > /opt/keycloak/{{NEW_LOGIN_USER}}.pass'
sudo stat -c '%A %U %G %n' /opt/keycloak/{{NEW_LOGIN_USER}}.pass
```

Expected mode is `-rw-------` and owner `root`. The password is recoverable
via `sudo cat /opt/keycloak/{{NEW_LOGIN_USER}}.pass`, the same convention as
`admin.pass` and `{{MCP_LOGIN_USER}}`'s secret file in `KEYCLOAK.md`
Section 6.

## 5. Set the password from the root-owned secret file

The pipe idiom keeps the credential out of the host command line:

```bash
sudo cat /opt/keycloak/{{NEW_LOGIN_USER}}.pass |
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    sh -c 'IFS= read -r user_password
      /opt/keycloak/bin/kcadm.sh set-password \
        --config /tmp/kcadm.config \
        -r {{MCP_REALM}} \
        --username {{NEW_LOGIN_USER}} \
        --new-password "$user_password"'
```

Host-exported variables are not available inside the container, so the realm
and username are written literally in the inner command. If the Docker build
lacks `-T` (see `KEYCLOAK.md` Section 4), substitute `-i`.

## 6. Verify without displaying the password

Confirm the user exists enabled in `{{MCP_REALM}}`:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get "users/${NEW_USER_UUID}" \
  --config /tmp/kcadm.config -r "{{MCP_REALM}}" \
  --fields id,username,enabled
```

Expected: `username` is exactly `{{NEW_LOGIN_USER}}`, `enabled` is `true`.

Confirm a password credential was actually created. The API representation
returns the credential type but not the secret value:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get "users/${NEW_USER_UUID}/credentials" \
  --config /tmp/kcadm.config -r "{{MCP_REALM}}" |
python3 -c 'import sys,json; print([c.get("type") for c in json.load(sys.stdin)])'
```

Expected: a list containing `PASSWORD`. If the list is empty, stop and re-run
Section 5 — do not continue to client onboarding without a credential.

Re-check that the pre-existing login user from Step 2 still lists enabled;
this procedure must have touched nothing else.

## 7. Hand back to the client machine

Hand the password back exactly once, from the server, using the same pattern
as the existing deployment. The client is configured by following the instructions
in `CLIENT.md`. The password may be accessed remotely from the client by using
one of the methods below.

```bash
sudo cat /opt/keycloak/{{NEW_LOGIN_USER}}.pass
```

or from a local terminal over SSH (the remote command runs on the camera
server, where `/opt/keycloak/` lives; same pattern as `CLIENT.md`,
Troubleshooting — substitute `{{NEW_LOGIN_USER}}.pass` for the example):

```bash
ssh -t {{SERVER_USER}}@{{SERVER_FQDN}} 'sudo cat /opt/keycloak/mcp-user.pass'
```

The secret file remains on the server as a recovery copy. To rotate, set a
new password per Section 5 and overwrite the file; the old value is then gone
from both.

## Troubleshooting

- **`kcadm.sh config credentials` returns `401`** — wrong admin username or
  password file; check `{{KEYCLOAK_ADMIN_USER}}` against the permanent
  administrator created in `KEYCLOAK.md` Section 5 and that
  `/opt/keycloak/admin.pass` is the current one. Never retry with a realm
  other than `master`.
- **`kcadm.sh` in-container succeeds but host-side Admin REST calls (e.g. the
  Section 3a `curl` steps) return `401`** — do not chase Keycloak; the
  asymmetry means the request itself is malformed, not the token or server.
  Check what actually reached the wire: capture loopback port
  `{{KEYCLOAK_PORT}}` with `tcpdump` during one mint plus a single admin GET
  and read the Authorization line of the captured request. If it contains
  literal asterisks followed by an unexpanded command stub (the header being
  built as `Bearer $(cat tokenfile)` with the substitution mangled in transit
  by the terminal's secret-protection layer), Keycloak rejects it — this looks
  like a mysterious, intermittent `401` but is a corrupted header. Never build
  a bearer header from shell substitution over a credential file: do the mint
  and all Admin REST calls inside one `python3` process (read
  `/opt/keycloak/admin.pass` directly with `open()`, set the header in
  memory, no temp token file), or fall back to `kcadm.sh` inside the
  container — Section 3a is fully expressible as a single `update users/... -s email=... -s emailVerified=true` call.
- **Browser login says "User or client not found"** — typo'd username at
  sign-in, or the user was created disabled. Re-run Step 6 checks; fix with a
  single `-s enabled=true` update if (and only if) that is what the check
  shows.
- **Credential list missing `PASSWORD`** — re-run Section 5 from the top; it
  is idempotent (sets the password again) and never displays the value.
- **Browser login bounces to `/login-actions/required-action`
  ("Update Account Information")** — the realm's `update-profile` required
  action is unsatisfied: one of `email`, `firstName`, `lastName` is still
  empty or `emailVerified` is false. The password was accepted (a wrong
  credential re-lands on `/login-actions/authenticate` instead). Re-run
  Section 3a; confirm all four fields with the user GET before retrying.
- **Browser login returns HTTP 500 from `/oauth2/callback`** — the new user's
  email is unverified; oauth2-proxy rejects the redeemed token ("email in
  id_token ... isn't verified"). Check `emailVerified` on the user and run
  Section 3a. The Keycloak login itself succeeds; the failure is downstream.
- **Existing user disturbed** — stop and report it; restoring from the last
  verified backup (`keycloak-postgres-backup.service`) is the supported path,
  not manual edits.

## Final checklist

- Keycloak health on loopback returned `200`; CLI authenticated as
  `{{KEYCLOAK_ADMIN_USER}}`.
- `{{NEW_LOGIN_USER}}` was absent before creation; exactly one match exists
  after, in `{{MCP_REALM}}`, enabled.
- `email`, `firstName`, `lastName` are nonempty and `emailVerified=true`
  (Section 3a); the `update-profile` required action is satisfied.
- Secret file exists at `/opt/keycloak/{{NEW_LOGIN_USER}}.pass`, root-owned,
  mode `0600`; the password was never printed except during hand-back.
- Credential check lists a `PASSWORD` entry.
- Pre-existing login user still lists enabled; no other object was touched.
- Client machine (if new) is permitted in Trusted Hosts per
  `ADD_CLIENT_ON_SERVER.md`, and its DCR attempt returns `201`.
- Browser login as `{{NEW_LOGIN_USER}}` succeeds, and `hermes mcp test`
  passes twice before the entry is enabled.
