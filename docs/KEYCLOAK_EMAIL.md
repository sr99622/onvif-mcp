# Configure Gmail delivery for Keycloak using Hermes

Run this once after README Step 7. Then use ADD_USER_EMAIL.md instead of the
existing ADD_USER.md for human accounts. Commands run on the camera server.
This runbook uses the existing Docker Compose installation and kcadm.sh; it
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
Substitute non-secret values with proper shell quoting, not raw interpolation
of user-provided strings into executable code.

## 1. Store the app password privately (User run)

The administrator runs the following block in their own interactive terminal
on the camera server (an SSH terminal is fine), outside Hermes. Enter the
Google app password named Camera Keycloak at the hidden prompt. It is not
the Gmail account's main password. Do not paste either password into Hermes.

```bash
sudo python3 - <<'PY'
import getpass
import os
import re
import warnings
warnings.simplefilter('error', getpass.GetPassWarning)
password = ''.join(getpass.getpass('Camera Keycloak app password (hidden): ').split())
if not re.fullmatch(r'[a-zA-Z]{16}', password):
    raise SystemExit('Expected the 16-letter Google app password; nothing saved.')
path = '/opt/keycloak/gmail-smtp.pass'
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, 'w') as out:
    out.write(password + '\n')
print('Saved app password in a root-owned file; value not displayed.')
PY
```

An existing file is not overwritten. If it already exists, determine whether
this setup was completed earlier; do not display its contents. To rotate a
credential later, deliberately replace that file using a hidden prompt, then
repeat the SMTP configuration and verification below.

Hermes may now verify the file without printing it:

```bash
sudo test -s /opt/keycloak/gmail-smtp.pass
sudo stat -c '%a %U:%G %n' /opt/keycloak/gmail-smtp.pass
```

Require `600 root:root`. Never run `cat` on this file to a terminal, turn on
shell tracing, print SMTP JSON, or include credentials in command arguments.

## 2. Preflight and authenticate the CLI (Agent run)

Run the remaining sections in Bash; stop on a failed command. Preserve the
variables/function across commands, or redefine them after a session reset.

```bash
set -euo pipefail
set +x
export MCP_REALM='mcp'
export GMAIL_ADDRESS='{{GMAIL_ADDRESS}}'

curl --fail --silent --show-error --output /dev/null \
  http://127.0.0.1:8080/auth/realms/master/.well-known/openid-configuration

kc() {
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config
}

kc get realms --fields realm,enabled
```

If the CLI session is missing or expired, use the existing administrator
secret to authenticate and then retry the last command:

```bash
sudo cat /opt/keycloak/admin.pass |
  sudo docker compose --project-directory /opt/keycloak exec -T keycloak \
    sh -c 'IFS= read -r admin_password || [ -n "$admin_password" ]
      /opt/keycloak/bin/kcadm.sh config credentials \
        --config /tmp/kcadm.config \
        --server http://127.0.0.1:8080/auth \
        --realm master --user keycloak-admin --password "$admin_password"'
```

The pipe handles the existing admin file having no trailing newline. Do not
display that file. The admin password is expanded inside the container, as
in the existing deployment runbook.

Verify public discovery with the trusted private CA. Require issuer
`https://{{SERVER_FQDN}}/auth/realms/mcp`; do not use `curl -k`.
The email recipient's device must resolve this hostname, reach it over LAN
or VPN, and trust its certificate. Gmail delivery does not require exposing
the camera server to the internet. The Keycloak container does need outbound
DNS and TCP 587 access to Gmail.

Complete a pre-change checkpoint using the repository's KEYCLOAK_BACKUP.md.
Do not display a full realm representation: it can include SMTP credentials.

## 3. Configure SMTP in the mcp realm

The password is read by root Python and piped directly into kcadm. Only the
smtpServer property is updated. This replaces any previous SMTP configuration
for this realm; preserve the pre-change backup for recovery.

```bash
sudo python3 - "$GMAIL_ADDRESS" <<'PY' |
import json
import pathlib
import sys
address = sys.argv[1]
if not address.endswith('@gmail.com') or any(c.isspace() for c in address):
    raise SystemExit('Supply the dedicated full @gmail.com address.')
password = pathlib.Path('/opt/keycloak/gmail-smtp.pass').read_text().strip()
if not password:
    raise SystemExit('SMTP password file is empty.')
json.dump({'smtpServer': {
    'host': 'smtp.gmail.com', 'port': '587',
    'from': address, 'fromDisplayName': 'Camera System',
    'auth': 'true', 'user': address, 'password': password,
    'starttls': 'true', 'ssl': 'false'
}}, sys.stdout)
PY
  kc update "realms/$MCP_REALM" -n -f -
```

Verify only the non-secret settings, keeping any full API response in the pipe:

```bash
kc get "realms/$MCP_REALM" --fields smtpServer |
  python3 -c 'import json,sys
s=json.load(sys.stdin)["smtpServer"]
expected={"host":"smtp.gmail.com","port":"587","auth":"true","starttls":"true","ssl":"false"}
assert all(s.get(k)==v for k,v in expected.items()), "SMTP settings mismatch"
for k in ("host","port","from","fromDisplayName","user","auth","starttls","ssl"):
    print(k + ": " + str(s.get(k,"")))'
```

Require From and user to match the dedicated Gmail address. Do not enable
public registration or change existing users, clients, or authentication flows.
No container restart is needed for this realm setting.

## 4. Verify actual delivery and take a checkpoint

Use ADD_USER_EMAIL.md to create the first intended user and send their
invitation. The administrator's instruction to invite that named recipient
authorizes that email. Do not invent a test recipient or send to other users.
If no first recipient has been supplied, finish the configuration checkpoint
and report that delivery has not yet been tested.

Successful API completion means the SMTP server accepted the message; it
does not establish inbox delivery. Ask the recipient to confirm receipt and
complete their own password setup. Do not request the invitation URL or
password, or open the action link on their behalf.

Publish a new checkpoint using KEYCLOAK_BACKUP.md. The database contains
the SMTP settings, including the credential, and keycloak.tar includes
gmail-smtp.pass with mode 0600. These backups contain recovery secrets.
Record configuration verification and actual delivery status separately.

Troubleshooting:

- Authentication failure: check full Gmail address and the app password,
  not the Google account password. Google may revoke app passwords after an
  account password change; generate a new one if necessary.
- Timeout: check outbound connectivity from the Keycloak container, DNS,
  and firewall rules for TCP 587. Do not disable certificate validation.
- SMTP accepted but no email: check spam and the recipient address before
  deliberately resending; do not loop-send invitations.
- Wrong invitation host: check KC_HOSTNAME and public discovery against
  KEYCLOAK.md. Do not substitute localhost in links sent to users.

## References

- Google app passwords: https://support.google.com/accounts/answer/185833
- Gmail SMTP settings: https://support.google.com/mail/answer/7104828
- Keycloak Admin CLI: https://www.keycloak.org/docs/latest/server_admin/#admin-cli
- Keycloak Admin REST API: https://www.keycloak.org/docs-api/latest/rest-api/index.html
