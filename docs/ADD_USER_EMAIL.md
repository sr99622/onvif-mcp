# Add a human user by email invitation

Use this in place of README Step 8's ADD_USER.md after completing
KEYCLOAK_EMAIL.md. Do not execute the old password creation, handoff, or
password-file verification steps for this account.

The administrator creates an enabled account without a password. Keycloak
emails a link for email verification and password creation. The recipient
sets their own normal password; the administrator does not know or retain it.
The invitation expires after 24 hours. This expiry applies to the link, not
the password; existing realm password policy still applies.

## Inputs

| Value | Meaning |
|---|---|
| `{{NEW_LOGIN_USER}}` | Administrator-supplied new username |
| `{{FIRST_NAME}}`, `{{LAST_NAME}}` | Recipient's first and last names |
| `{{USER_EMAIL}}` | Real inbox controlled by the recipient |
| `{{SERVER_FQDN}}` | Camera server hostname |
| `{{BACKUP_PATH}}` | Existing backup folder |

No PASSWORD input is accepted. Do not invent an email address, create a
temporary password, mark email verified manually, or run headless login
drivers that would require knowing the recipient's password.

Defaults: realm `mcp`, Compose directory `/opt/keycloak`, existing CLI config
`/tmp/kcadm.config`. Validate against the installation. Use JSON serialization
for names and email, with properly shell-quoted variable assignments.

## 1. Establish the CLI session and verify prerequisites

Use the preflight and authentication instructions in KEYCLOAK_EMAIL.md §2.
Run the commands below in the same Bash session:

```bash
set -euo pipefail
set +x
export MCP_REALM='mcp'
export NEW_LOGIN_USER='{{NEW_LOGIN_USER}}'
export FIRST_NAME='{{FIRST_NAME}}'
export LAST_NAME='{{LAST_NAME}}'
export USER_EMAIL='{{USER_EMAIL}}'

kc() {
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config
}

kc get realms --fields realm,enabled
kc get authentication/required-actions -r "$MCP_REALM" \
  --fields alias,enabled,defaultAction
kc get "realms/$MCP_REALM" --fields registrationAllowed,passwordPolicy
```

Require VERIFY_EMAIL and UPDATE_PASSWORD to be enabled. If disabled, stop
and resolve that configuration before creating the account. Do not turn on
self-registration. Preserve the existing password policy and required actions.
Run KEYCLOAK_EMAIL.md §3's safe SMTP readback if needed.

Check for an exact username and email collision:

```bash
kc get users -r "$MCP_REALM" -q exact=true -q "username=$NEW_LOGIN_USER" \
  --fields id,username,email
kc get users -r "$MCP_REALM" -q exact=true -q "email=$USER_EMAIL" \
  --fields id,username,email
```

Both must return `[]`. Otherwise stop account creation; do not overwrite an
existing person. To resume a failed invitation for the same account, use §5.
Record a baseline of existing user IDs and enabled states, using pagination
if needed, so the final comparison can show that they remain intact.

## 2. Create the account without credentials

```bash
python3 - <<'PY' |
import json
import os
import sys
fields = {'username': 'NEW_LOGIN_USER', 'firstName': 'FIRST_NAME',
          'lastName': 'LAST_NAME', 'email': 'USER_EMAIL'}
user = {key: os.environ[value] for key, value in fields.items()}
if any(not value.strip() for value in user.values()):
    raise SystemExit('Every identity field must be nonempty.')
user.update(enabled=True, emailVerified=False,
            requiredActions=['VERIFY_EMAIL', 'UPDATE_PASSWORD'])
json.dump(user, sys.stdout)
PY
  kc create users -r "$MCP_REALM" -f -
```

Resolve the new ID live and require exactly one username match:

```bash
NEW_USER_UUID="$(kc get users -r "$MCP_REALM" \
  -q exact=true -q "username=$NEW_LOGIN_USER" --fields id,username |
  python3 -c 'import json,os,sys
users=json.load(sys.stdin)
assert len(users)==1 and users[0]["username"]==os.environ["NEW_LOGIN_USER"], "Expected one exact user"
print(users[0]["id"])')"
export NEW_USER_UUID

kc get "users/$NEW_USER_UUID" -r "$MCP_REALM" \
  --fields id,username,email,firstName,lastName,enabled,emailVerified,requiredActions
kc get "users/$NEW_USER_UUID/credentials" -r "$MCP_REALM" --fields type
```

Before sending, require the identity fields to match the supplied recipient,
enabled=true, emailVerified=false, and both requested required actions to be
present. Credential list should be empty for this newly created local user.
No extra camera roles are needed in the documented deployment. Do not alter
existing clients, scopes, roles, trusted hosts, or users.

## 3. Send the invitation

The user must have explicitly identified the recipient to invite. This step
sends a real email to that account's recorded address.

```bash
printf '%s\n' '["VERIFY_EMAIL","UPDATE_PASSWORD"]' |
  kc update "users/$NEW_USER_UUID/execute-actions-email" \
    -r "$MCP_REALM" -q lifespan=86400 -n -f -
```

`-n` prevents a GET/merge against this action endpoint. Require exit status 0
(the underlying successful HTTP response is 204). Do not claim inbox delivery
until the recipient confirms it. If the send fails, the new account remains
created; do not rerun creation or set a fallback password. Repair delivery
and use §5 for a deliberate retry.

No redirect_uri or client_id is supplied. After finishing the action, the
recipient can open `https://{{SERVER_FQDN}}/cameras/` to sign in. Do not add
an arbitrary redirect URI or weaken existing client redirect restrictions.

## 4. Recipient completes setup; verify without their password

Tell the recipient to open the invitation on a device that can reach the
camera hostname and trusts the private CA. They complete email verification
and choose a password directly in Keycloak. A private browser window avoids
conflicts with another person's existing Keycloak session.

Do not ask for their password or action link, forward the link into logs, or
complete their actions as an administrator. Do not diagnose this account by
setting emailVerified=true: an unverified state is expected before onboarding.

After the recipient reports completion:

```bash
kc get "users/$NEW_USER_UUID" -r "$MCP_REALM" \
  --fields id,username,email,enabled,emailVerified,requiredActions
kc get "users/$NEW_USER_UUID/credentials" -r "$MCP_REALM" --fields type
```

Require enabled=true, emailVerified=true, a credential with type `password`
(lowercase), and VERIFY_EMAIL/UPDATE_PASSWORD absent from requiredActions.
Any additional required actions must be completed, not silently removed.
The recipient verifies camera login in their browser; the administrator
records the result without handling credentials. Check existing users
against the baseline.

If MCP access is required, follow ADD_CLIENT_ON_SERVER.md for a new client IP
and CLIENT.md for client setup. The recipient completes their browser OAuth
login themselves, then runs the normal Hermes MCP verification. IP enrollment
is not required for camera web access alone.

If the recipient has not finished, report `invitation sent; onboarding pending`
and checkpoint that state. Do not claim success or create a password for them.

## 5. Resume or resend

Resolve the username live as in §2, and read back username, email, enabled,
emailVerified, requiredActions, and credential types. Match these to the
original intended recipient. Do not change an existing account's address to
make it match a new request.

For an expired or failed invitation where onboarding is still pending,
repeat only §3. If a credential exists and the required actions have cleared,
onboarding is complete; do not resend a password action as a retry. A later
password reset is a separate administrator-authorized operation.

Do not assume sending another email revokes all prior links. If a link was
sent to the wrong person, disable the affected newly created account and
resolve that incident before issuing another invitation. Do not re-enable
that account while a misdelivered link may remain usable.

## 6. Backup checkpoint

Follow the repository's KEYCLOAK_BACKUP.md after creation/invitation and again
after password setup is confirmed, using new immutable checkpoints. Record
the new user ID, invitation acceptance by SMTP, delivery confirmation if
available, pending/completed onboarding, credential type, and existing-user
comparison. Never record passwords, invitation tokens, or email bodies.

The new human account has no `/opt/keycloak/<username>.pass` file. That is
intentional. The PostgreSQL backup recovers its Keycloak password hash after
setup. Existing admin and older account secret files remain untouched, and
the Gmail app password remains a service secret. Interpret the shared backup
runbook's references to user *.pass files as files that actually exist, not
as a requirement to create a plaintext copy for invited accounts.

An SMTP success alone is not completed onboarding. Keep the status clear
when handing the system back to the administrator.

## References

- Keycloak Admin REST API (execute-actions-email):
  https://www.keycloak.org/docs-api/latest/rest-api/index.html
- Keycloak Admin CLI:
  https://www.keycloak.org/docs/latest/server_admin/#admin-cli
