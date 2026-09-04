# Add a New Login Account to the MCP Realm (Own Password)

## Purpose

`KEYCLOAK.md` Section 6 creates exactly one login user (`{{MCP_LOGIN_USER}}`).
This runbook adds one more enabled user in `{{MCP_REALM}}` with its own
password, for a second person or installation that needs separate credentials.

DCR is unaffected: each machine still registers its own public client per
`ADD_CLIENT.md`. This account only supplies the identity used at browser
sign-in. The new user needs no roles — `{{MCP_LOGIN_USER}}` was created
without any, and tokens get their claims from the `{{MCP_SCOPE}}` client
scope and audience mapper (`KEYCLOAK.md` Section 7), not from user roles.

If the new account will be used from a machine that is not yet allowed by the
anonymous DCR Trusted Hosts policy, run `ADD_CLIENT_ON_SERVER.md` first with
that machine's observed source address, then continue here.

Runbook values:

| Symbol | Meaning | Typical value in this deployment |
|---|---|---|
| `{{MCP_REALM}}` | Keycloak realm hosting the MCP login users | `mcp` |
| `{{KEYCLOAK_ADMIN_USER}}` | Permanent administrator in the `master` realm | `keycloak-admin` |
| `{{KEYCLOAK_PORT}}` | Loopback TCP port of the Keycloak listener | `8080` |
| `{{KEYCLOAK_PATH}}` | Keycloak relative path on loopback (`KC_HTTP_RELATIVE_PATH`) | `/auth` |
| `{{NEW_LOGIN_USER}}` | New login username supplied by agent, e.g. `mcp-user2` | — |
| `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name | `camera.home.arpa` |
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

Set `emailVerified=true`, and if `email` is still empty also set it to a
nonempty placeholder (`<username>@example.com`), using the PUT-against-live
representation idiom from `STREAM_AUTH.md` Section 2 (PATCH is rejected with
HTTP 405 on Keycloak 26; PUT has replace semantics, so it must run against
the freshly fetched body in the same bounded command):

```bash
# Mint a token first (same pattern as ADD_CLIENT_ON_SERVER.md).
curl -sS -H "Authorization: Bearer $(cat $tfile)" \
  "http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/users/${NEW_USER_UUID}" > /tmp/.kcuser.$$
python3 -c "import json; u = json.load(open('/tmp/.kcuser.$$')); assert u['username'] == '{{NEW_LOGIN_USER}}'; u.setdefault('email', '{{NEW_LOGIN_USER}}@example.com'); u['emailVerified'] = True; json.dump(u, open('/tmp/.kcpayload.tmp', 'w'))"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -X PUT \
  -H "Authorization: Bearer $(cat $tfile)" -H "Content-Type: application/json" \
  --data @/tmp/.kcpayload.tmp \
  "http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/users/${NEW_USER_UUID}"
```

Require HTTP 204, then re-retrieve directly by UUID and confirm: exact
username, `enabled=true`, nonempty email, `emailVerified=true`. Delete
`/tmp/.kcuser.$$` and `/tmp/.kcpayload.tmp` afterward. Never set the flag
false.

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

The account works in the browser sign-in step of `ADD_CLIENT.md`. If this is
a new machine:

1. Run `ADD_CLIENT_ON_SERVER.md` end to end with that machine's observed
   DCR source address (from the Nginx access log, not a guess).
2. On the client machine run Steps 1–2 and Step 5 of `ADD_CLIENT.md`.
3. Complete browser login as `{{NEW_LOGIN_USER}}` instead of
   `{{MCP_LOGIN_USER}}`, approving `{{MCP_SCOPE}}`.
4. Only enable the entry after `hermes mcp test` passes on saved state, per
   `ADD_CLIENT.md` Step 7.

Hand the password back exactly once, from the server, using the same pattern
as the existing deployment (see `ADD_CLIENT.md`, Troubleshooting):

```bash
sudo cat /opt/keycloak/{{NEW_LOGIN_USER}}.pass
```

or from a local terminal over SSH (the remote command runs on the camera
server, where `/opt/keycloak/` lives; same pattern as `ADD_CLIENT.md`,
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
- **Browser login says "User or client not found"** — typo'd username at
  sign-in, or the user was created disabled. Re-run Step 6 checks; fix with a
  single `-s enabled=true` update if (and only if) that is what the check
  shows.
- **Credential list missing `PASSWORD`** — re-run Section 5 from the top; it
  is idempotent (sets the password again) and never displays the value.
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
- Secret file exists at `/opt/keycloak/{{NEW_LOGIN_USER}}.pass`, root-owned,
  mode `0600`; the password was never printed except during hand-back.
- Credential check lists a `PASSWORD` entry.
- Pre-existing login user still lists enabled; no other object was touched.
- Client machine (if new) is permitted in Trusted Hosts per
  `ADD_CLIENT_ON_SERVER.md`, and its DCR attempt returns `201`.
- Browser login as `{{NEW_LOGIN_USER}}` succeeds, and `hermes mcp test`
  passes twice before the entry is enabled.
