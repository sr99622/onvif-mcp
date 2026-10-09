# Automated SSH Login Runbook

## Purpose

Manage key-based automated (passwordless) SSH login from the camera server to
one machine on the local network. The runbook owns exactly three artifacts per
server:

1. an `ed25519` key pair in `~/.ssh` (created once, shared across servers);
2. one `Host` block in `~/.ssh/config` with `BatchMode yes` so scripts fail
   fast instead of hanging on a password prompt;
3. this runbook's public key as one line in the server user's
   `~/.ssh/authorized_keys`.

The executable workflow lives in:

```bash
scripts/SSH_LOGIN/ssh_login_runbook.sh
```

That script is the single source of truth for executable actions. Do not
replace it with ad hoc shell fragments from this document.

## Required Values

| Symbol | Required value |
|---|---|
| `{{SSH_SERVER_FQDN}}` | FQDN of the machine being logged in to |
| `{{SSH_USERNAME}}` | User on that machine |
| `{{REPO_PATH}}` | Full path to this repository |

Runbook defaults used by the script:

| Symbol | Meaning | Typical value in this deployment |
|---|---|---|
| `{{SSH_ALIAS}}` | `Host` alias written to `~/.ssh/config` | first label of `{{SSH_SERVER_FQDN}}` (e.g. `taurus`) |

## Guards (hard rules)

1. `apply` refuses to run over an existing configuration: if a `Host` block
   already matches the alias or FQDN, or if the public key is already present
   in the server's `authorized_keys`, the script exits without changing
   anything. Inspect with `status`, or revoke first.
2. `revoke` removes only the entry belonging to this runbook. Other `Host`
   blocks in `~/.ssh/config` and other lines in the server's
   `authorized_keys` are preserved verbatim.
3. `revoke` is always able to clean up its own config entry. If this runbook's
   key is absent from the server's `authorized_keys`, revoke skips the server
   rewrite (nothing to remove) but still removes the config entry and host key.
   It refuses to rewrite `authorized_keys` only when the key is duplicated,
   because a blind rewrite could damage entries the runbook does not own.
4. `apply` installs the key on the server before writing the config entry, so a
   failed apply (wrong password, refused connection) cannot leave a config entry
   without a matching server-side key — the state that previously deadlocked
   apply against revoke.
5. `~/.ssh/config` must be mode `600`; ssh refuses group-readable config
   files, so the script enforces the mode on every write.
6. The one-time password prompt for `ssh-copy-id` is USER-run in the user's
   own terminal. The agent must never ask for or capture the password.

## 1. Create the automated login (USER-run)

Run with resolved values from the user's own terminal, because the first run
prompts for the server password exactly once:

```bash
cd {{REPO_PATH}}
scripts/SSH_LOGIN/ssh_login_runbook.sh apply \
  --server-fqdn {{SSH_SERVER_FQDN}} \
  --username {{SSH_USERNAME}}
```

The `apply` command:

- creates `~/.ssh/id_ed25519` only if no key exists;
- refuses if a config entry or server-side key already exists (guard 1);
- appends the `Host` block for this server only;
- installs the public key on the server via `ssh-copy-id` (single password
  prompt, last time);
- verifies a `BatchMode` login succeeds.

Expected final output:

```text
apply-ok alias=<alias> server=<fqdn> user=<user>
```

## 2. Revoke the automated login (USER-run)

```bash
cd {{REPO_PATH}}
scripts/SSH_LOGIN/ssh_login_runbook.sh revoke \
  --server-fqdn {{SSH_SERVER_FQDN}} \
  --username {{SSH_USERNAME}}
```

The `revoke` command removes only:

- this server's `Host` block from `~/.ssh/config`;
- this runbook's key line from the server's `authorized_keys` (all other lines
  preserved);
- the server's host key from `known_hosts`.

The private key pair is kept, since other servers may share it. Expected
output:

```text
revoke-ok alias=<alias> server=<fqdn> user=<user> (other config and authorized_keys entries left intact)
```

## 3. Verify and inspect (AGENT-run)

```bash
cd {{REPO_PATH}}
scripts/SSH_LOGIN/ssh_login_runbook.sh verify \
  --server-fqdn {{SSH_SERVER_FQDN}} \
  --username {{SSH_USERNAME}}
```

`verify` checks the config entry, key pair, config permissions, exactly one
authorized_keys match on the server, and a live `BatchMode` login. Expected:
`verify-ok`.

Non-mutating inspection:

```bash
cd {{REPO_PATH}}
scripts/SSH_LOGIN/ssh_login_runbook.sh status \
  --server-fqdn {{SSH_SERVER_FQDN}} \
  --username {{SSH_USERNAME}}
```

## Acceptance criteria

After `apply`: `ssh <alias> 'echo login-ok'` prints `login-ok` with no
password prompt, and `status` shows the entry, the key, and exactly one
server-side match. After `revoke`: the alias no longer resolves, the server
rejects key login for this key, and every other entry in `~/.ssh/config` and
`authorized_keys` is byte-identical to before.

## Pitfalls and notes

- Plain `grep` cannot see `known_hosts` entries: ssh hashes hostnames
  (`|1|...` lines). Use `ssh-keygen -F` — the script does.
- `grep -v` exits 1 when the result is empty. When this runbook's key is the
  only line in the server's `authorized_keys`, the revoke filter legitimately
  produces no output; the script tolerates that exit status explicitly so
  `set -euo pipefail` does not abort revoke before the removal is written.
- A `kex_exchange_identification: read: Connection reset by peer` on a host
  that previously reached the password prompt indicates a temporary
  connection ban (fail2ban or similar) triggered by failed auth attempts —
  not a script fault. Wait for the ban window to expire and retry once;
  check the server's auth log if a correct first password entry is still
  rejected.
- Files created in `~/.ssh` must be mode `600` (directory `700`); a
  group-readable `config` causes `Bad owner or permissions`. The script sets
  the mode on every write.
- The key pair is shared across servers; revoking one server never deletes
  the key.
- If the target machine's `authorized_keys` was populated outside this
  runbook, `apply`'s guard fires on the already-present key. That is intended:
  the runbook only manages configurations it created.
