# Add a human user by email invitation

Use this after completing KEYCLOAK_EMAIL.md. Do not execute the older password
creation, handoff, or password-file verification steps for this account.

The administrator creates an enabled account without a password. Keycloak emails
a link for email verification and password creation. The recipient sets their own
normal password; the administrator does not know or retain it. The invitation
expires after 24 hours. This expiry applies to the link, not the password;
existing realm password policy still applies.

## Inputs

| Value | Meaning |
|---|---|
| `{{NEW_LOGIN_USER}}` | Administrator-supplied new username |
| `{{FIRST_NAME}}`, `{{LAST_NAME}}` | Recipient's first and last names |
| `{{USER_EMAIL}}` | Real inbox controlled by the recipient |
| `{{SERVER_FQDN}}` | Camera server hostname |
| `{{BACKUP_PATH}}` | Existing backup folder |
| `{{REPO_PATH}}` | Parent directory for this repository |

No PASSWORD input is accepted. Do not invent an email address, create a temporary
password, mark email verified manually, or run headless login drivers that would
require knowing the recipient's password.

Defaults: realm `mcp`, Compose directory `/opt/keycloak`, administrator
`keycloak-admin` in `master`.

## Executable source of truth

Executable actions for this runbook are implemented by:

```bash
scripts/ADD_USER_EMAIL/add_user_email_runbook.sh
```

That script is the single source of truth for commands that authenticate to
Keycloak, verify prerequisites, create the invited user, send or resend the email
action link, check onboarding status, write a non-secret local report, and create
Keycloak checkpoints. The prose below states intent, boundaries, and expected
verification output without duplicating shell fragments that can drift from the
script.

## 1. Create the account and send the invitation (AGENT-run)

Run with resolved values:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/ADD_USER_EMAIL/add_user_email_runbook.sh apply \
  --new-login-user {{NEW_LOGIN_USER}} \
  --first-name {{FIRST_NAME}} \
  --last-name {{LAST_NAME}} \
  --user-email {{USER_EMAIL}} \
  --server-fqdn {{SERVER_FQDN}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

The script performs these executable stages:

1. Verifies Keycloak local discovery, authenticates as the existing administrator
   without printing `/opt/keycloak/admin.pass`, and checks public discovery for
   `https://{{SERVER_FQDN}}/auth/realms/mcp` without `curl -k`.
2. Verifies realm `mcp` has self-registration disabled and required actions
   `VERIFY_EMAIL` and `UPDATE_PASSWORD` enabled.
3. Checks for exact username and email collisions. Account creation stops if
   either already exists; use `resend` only after confirming the existing account
   is the intended pending invite.
4. Records a baseline of existing user IDs and enabled states.
5. Creates the account with the supplied username, name, and email; enabled=true,
   emailVerified=false, and required actions `VERIFY_EMAIL` and `UPDATE_PASSWORD`.
6. Resolves the new user ID live and verifies the identity fields, enabled state,
   unverified email state, required actions, and an empty credentials list before
   sending email.
7. Sends a real 24-hour action email with no redirect URI or client ID.
8. Verifies existing users from the baseline were not changed.
9. Writes a non-secret local report at
   `scripts/ADD_USER_EMAIL/last-invitation-status.txt`.
10. Creates a Keycloak checkpoint through KEYCLOAK_BACKUP.md's script.
11. Reads the new user's status back and reports onboarding as pending until the
    recipient completes verification and password setup.

Successful API completion means Keycloak/Gmail accepted the message for sending;
it does not prove inbox delivery. Do not claim completed onboarding until the
recipient confirms receipt and completes setup.

## 2. Status checks (AGENT-run)

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/ADD_USER_EMAIL/add_user_email_runbook.sh status \
  --new-login-user {{NEW_LOGIN_USER}} \
  --user-email {{USER_EMAIL}} \
  --server-fqdn {{SERVER_FQDN}}
```

Pending onboarding state is expected immediately after invitation:

- enabled=true;
- emailVerified=false;
- requiredActions includes `VERIFY_EMAIL` and `UPDATE_PASSWORD`;
- credential-types is `(none)`;
- onboarding reports `pending`.

After the recipient completes setup, required completed state is:

- enabled=true;
- emailVerified=true;
- credential-types includes `password`;
- `VERIFY_EMAIL` and `UPDATE_PASSWORD` are absent from requiredActions;
- onboarding reports `complete`.

Any additional required actions must be completed, not silently removed.

## 3. Recipient completes setup

Tell the recipient to open the invitation on a device that can reach the camera
hostname and trusts the private CA. They complete email verification and choose a
password directly in Keycloak. A private browser window avoids conflicts with
another person's existing Keycloak session.

Do not ask for their password or action link, forward the link into logs, or
complete their actions as an administrator. Do not diagnose this account by
setting emailVerified=true: an unverified state is expected before onboarding.

After setup, the recipient can open:

```text
https://{{SERVER_FQDN}}/cameras/
```

If MCP access is required, follow ADD_CLIENT_ON_SERVER.md for a new client IP and
CLIENT.md for client setup. The recipient completes their browser OAuth login
themselves, then runs the normal Hermes MCP verification. IP enrollment is not
required for camera web access alone.

## 4. Resume or resend

Use resend only for the same intended pending user and email, such as an expired
or failed invitation:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/ADD_USER_EMAIL/add_user_email_runbook.sh resend \
  --new-login-user {{NEW_LOGIN_USER}} \
  --user-email {{USER_EMAIL}} \
  --server-fqdn {{SERVER_FQDN}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

The script requires exactly one matching username/email, no credentials,
emailVerified=false, and both pending required actions before resending. If a
credential exists and required actions have cleared, onboarding is complete; do
not resend a password action as a retry. A later password reset is a separate
authorized operation.

Do not assume sending another email revokes all prior links. If a link was sent
to the wrong person, disable the affected newly created account and resolve that
incident before issuing another invitation. Do not re-enable that account while a
misdelivered link may remain usable.

## 5. Backup checkpoints

The script creates a Keycloak checkpoint after creation/invitation. Run another
checkpoint after password setup is confirmed, using KEYCLOAK_BACKUP.md's script,
to capture completed onboarding state. Record delivery confirmation and
completed/pending onboarding status without recording passwords, invitation
tokens, or email bodies.

The new human account has no `/opt/keycloak/<username>.pass` file. That is
intentional. The PostgreSQL backup recovers its Keycloak password hash after
setup. Existing admin and older account secret files remain untouched, and the
Gmail app password remains a service secret.

An SMTP success alone is not completed onboarding. Keep the status clear when
handing the system back to the administrator.

## References

- Keycloak Admin REST API (execute-actions-email):
  https://www.keycloak.org/docs-api/latest/rest-api/index.html
