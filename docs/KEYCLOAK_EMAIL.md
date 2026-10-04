# Configure Gmail delivery for Keycloak using Hermes

Run this once after README Step 7. Then use ADD_USER_EMAIL.md instead of the
older ADD_USER.md for human accounts. Commands run on the camera server. This
runbook uses the existing Docker Compose installation and Keycloak Admin API; it
does not require the Keycloak web administrator console.

## Inputs

| Value | Meaning |
|---|---|
| `{{GMAIL_ADDRESS}}` | Dedicated Gmail sender address |
| `{{SERVER_FQDN}}` | Camera server hostname used by clients |
| `{{BACKUP_PATH}}` | Existing backup folder |

Deployment defaults from KEYCLOAK.md: realm `mcp`, administrator
`keycloak-admin` in `master`, loopback URL `http://127.0.0.1:8080/auth`,
Compose directory `/opt/keycloak`. Confirm these against this installation.

## Executable source of truth

Executable actions for this runbook are implemented by:

```bash
scripts/KEYCLOAK_EMAIL/keycloak_email_runbook.sh
```

That script is the single source of truth for commands that store the SMTP app
password, verify prerequisites, configure SMTP in Keycloak, create pre/post
Keycloak checkpoints, and perform redacted status checks. The prose below states
intent, boundaries, and expected verification output without duplicating shell
fragments that can drift from the script.

## 1. Store the app password privately (USER-run)

The administrator creates a Google app password named Camera Keycloak for the
dedicated Gmail account, then runs the script in their own interactive terminal
on the camera server. Enter the Google app password at the hidden prompt. It is
not the Gmail account's main password. Do not paste either password into Hermes.

Resolved command for this deployment:

```bash
cd /home/stephen/onvif-mcp
sudo /home/stephen/onvif-mcp/scripts/KEYCLOAK_EMAIL/keycloak_email_runbook.sh user-store-password
```

The script creates `/opt/keycloak/gmail-smtp.pass` as `0600 root:root` and never
prints the secret. An existing file is not overwritten. To rotate the credential
later, deliberately replace that file using a hidden prompt, then rerun the
`apply` command below.

## 2. Configure SMTP and create checkpoints (AGENT-run)

Run with resolved values:

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/KEYCLOAK_EMAIL/keycloak_email_runbook.sh apply \
  --gmail-address {{GMAIL_ADDRESS}} \
  --server-fqdn {{SERVER_FQDN}} \
  --backup-path {{BACKUP_PATH}} \
  --repo-path {{REPO_PATH}}
```

The script performs these executable stages:

1. Verifies `/opt/keycloak/gmail-smtp.pass` exists and is `0600 root:root`.
2. Verifies local Keycloak discovery, authenticates the admin CLI/API using the
   existing root-owned admin secret, and checks the public realm issuer is
   exactly `https://{{SERVER_FQDN}}/auth/realms/mcp` without `curl -k`.
3. Creates a pre-change Keycloak checkpoint through KEYCLOAK_BACKUP.md's script.
4. Configures realm `mcp` SMTP with Gmail host `smtp.gmail.com`, port `587`,
   STARTTLS, authentication enabled, From/user set to `{{GMAIL_ADDRESS}}`, and
   display name `Camera System`.
5. Reads back only non-secret SMTP fields plus a boolean password-present check.
6. Creates a post-change Keycloak checkpoint through KEYCLOAK_BACKUP.md's script.
7. Runs a final redacted status check.

Do not enable public registration or change existing users, clients, or
authentication flows. No container restart is needed for this realm setting.

## 3. Status checks (AGENT-run)

```bash
cd {{REPO_PATH}}/onvif-mcp
scripts/KEYCLOAK_EMAIL/keycloak_email_runbook.sh status \
  --gmail-address {{GMAIL_ADDRESS}} \
  --server-fqdn {{SERVER_FQDN}}
```

Required outcomes before declaring SMTP configuration complete:

- `/opt/keycloak/gmail-smtp.pass` reports `600 root:root`.
- Admin authentication succeeds without printing `/opt/keycloak/admin.pass`.
- Public discovery issuer is exactly `https://{{SERVER_FQDN}}/auth/realms/mcp`.
- SMTP redacted readback shows host `smtp.gmail.com`, port `587`, From/user equal
  to `{{GMAIL_ADDRESS}}`, `auth=true`, `starttls=true`, `ssl=false`, and
  `password-configured: True`.
- A pre-change and post-change checkpoint exist under `{{BACKUP_PATH}}/keycloak/`
  and their checksums were verified by the backup script.

## 4. Delivery verification

Use ADD_USER_EMAIL.md to create the first intended user and send their invitation.
The administrator's instruction to invite that named recipient authorizes that
email. Do not invent a test recipient or send to other users.

Successful API completion means Gmail accepted the message for sending; it does
not prove inbox delivery. Ask the recipient to confirm receipt and complete their
own password setup. Do not request the invitation URL or password, or open the
action link on their behalf.

If no first recipient has been supplied, report that SMTP configuration is
complete and delivery has not yet been tested.

## Troubleshooting

- Authentication failure: check the full Gmail address and the app password, not
  the Google account password. Google may revoke app passwords after an account
  password change; generate a new one if necessary.
- Timeout: check outbound connectivity from the Keycloak container, DNS, and
  firewall rules for TCP 587. Do not disable certificate validation.
- SMTP accepted but no email: check spam and the recipient address before
  deliberately resending; do not loop-send invitations.
- Wrong invitation host: check KC_HOSTNAME and public discovery against
  KEYCLOAK.md. Do not substitute localhost in links sent to users.

## References

- Google app passwords: https://support.google.com/accounts/answer/185833
- Gmail SMTP settings: https://support.google.com/mail/answer/7104828
- Keycloak Admin REST API: https://www.keycloak.org/docs-api/latest/rest-api/index.html
