# Camera System Restore Guide

System-wide reconstruction instructions for the ONVIF camera server, distilled
from `BACKUP.md`'s reconstruction sections and the full end-to-end restore
executed on 2026-09-13 (the only restore of this backup set performed to date;
items marked **[verified]** were executed successfully in that restore).

This document defines recovery ordering. Nginx configuration and nginx-specific
systemd overrides come from one completed checkpoint through
[NGINX_BACKUP.md](NGINX_BACKUP.md). Keycloak configuration and database come
from one completed checkpoint through KEYCLOAK_BACKUP.md. Historical stage names
and old verification records do not determine precedence for these targets.
DNS configuration and dnsmasq-specific overrides come from one completed
checkpoint through [DNS_BACKUP.md](DNS_BACKUP.md). Resolve the actual backup
destination and site values before recovery.

## Site constants

Historical example values are shown below. Resolve current site values from
the installation inputs before using commands; do not adopt these examples
or BACKUP.md history as authoritative configuration.

| Placeholder | Value |
|---|---|
| `{{BACKUP_PATH}}` | Current mounted backup root supplied for this installation |
| `{{SERVER_FQDN}}` | `gmktec.home.arpa` |
| `{{SERVER_IP}}` | `10.1.1.5` (LAN, `enp170s0`) |
| `{{REPO_PATH}}` | `/home/stephen` |
| `{{SERVER_USER}}` | `stephen` |
| `{{PRVT_CAMERA_NET_EN_NAME}}` | `enp171s0` |
| `{{CA_ROOT_PATH}}` | `/home/stephen/Private-CA` |
| Camera creds | `admin` / from `~/.hermes/config.yaml` (never copy into docs) |

## Phase 0 — Preflight (do not skip)

1. Mount the SMB backup and confirm it is writable: **[verified]**
   ```bash
   findmnt -T "{{BACKUP_PATH}}"
   test -d "{{BACKUP_PATH}}" && test -w "{{BACKUP_PATH}}"
   ```
2. Verify `SHA256SUMS` inside each selected target checkpoint and other backup
   folder before extraction. Do not treat the parent `nginx/` or `keycloak/`
   directory as a checkpoint; the same applies to `dns/`. A missing checksum or mismatch stops recovery.
3. Inventory the selected checkpoints, their external dependencies, and other
   required backup targets. If no complete nginx checkpoint exists, follow
   NGINX_BACKUP.md's explicit legacy-reconstruction path; do not silently use
   a partial procedure archive.


4. Confirm host preconditions match the constants (hostname `gmktec`, LAN IP,
   `/etc/hosts` entry, repo checkout, camera creds present in Hermes config).
5. Expect slow restores over SMB for large tars (venv ≈ 79 MB / 3754 files,
   2–3 minutes); run those in the background. **[verified]**

## Restore sequence (whole-system)

1. Prepare host packages, accounts, networking, DHCP, and the backup mount.
   Restore DNS through DNS_BACKUP.md before dependent client HTTPS checks.
2. Recover the CA and prepare a matching server certificate/key through
   CREATE_CA_CERT.md and SITE_CERT.md. Private TLS keys are never backed up.
3. Restore application binaries, web content, CA distribution content, and
   non-nginx service units from their respective backups. Regenerate camera-IP
   data as described below. Restore any whole-system unit archive before the
   nginx restore and exclude nginx-specific overrides from it.
4. Restore one Keycloak configuration/database pair through KEYCLOAK_BACKUP.md.
   Check its compatibility with the selected nginx checkpoint's metadata.
5. Restore one complete nginx checkpoint through NGINX_BACKUP.md, including
   the exact nginx override set and any recorded external configuration.
   Dependencies must be ready before nginx startup and endpoint validation.
6. Run the final gates. Do not overlay nginx files from any earlier stage.

## Restore-source registry

| Artifact | Restore source |
|---|---|
| Nginx configuration and nginx-specific unit overrides | Newest completed `nginx/YYYYMMDDHHMMSSZ/` checkpoint, verified and restored per NGINX_BACKUP.md |
| `/etc/onvif-mcp/camera_registry.json` + `snapshot_routes.json` | **never restore from backup** — generate from a live `get_cameras` after the HTTPS stage (see "Camera-IP files: generate, don't restore"). `site-cert-*/final-etc-onvif-mcp.tar` is kept for provenance only. |
| `/etc/mediamtx/mediamtx.yml` | **never restored (by design)** — not in any backup; generated from the same live `get_cameras` capture |
| venv | `mcp-http-*/final-home-*-onvif-mcp-.venv.tar` |
| `onvif-mcp-http.service` | `site-cert-*/…tar` (has `STREAM_SERVER_URL=https://…`) + `keycloak-*/etc-systemd` oauth drop-in |
| `/srv/camera-pki` | `ca-distribute-*/final-srv-camera-pki.tar` |
| dnsmasq configuration and service overrides | Newest completed `dns/YYYYMMDDHHMMSSZ/` checkpoint per DNS_BACKUP.md |
| `/opt/keycloak/` (compose, .env, pass files) | Selected completed `keycloak/YYYYMMDDHHMMSSZ/keycloak.tar` |
| Keycloak DB | `keycloak-postgres.tar` from the same selected Keycloak checkpoint |
| Backup script + backup unit | Install/recreate from repository and KEYCLOAK.md §14 |
| CA (GPG vault → age archive) | `Camera-CA-Backups/` — newest `camera-system-ca-after-*-tar.gz.age` |
| Server TLS key | **never backed up (by design)** — regenerate + reissue, SITE_CERT.md §1–§6 + §8 |

## Global restore rules

1. Verify checksums before extraction; inspect archive roots and symlinks.
2. Nginx, DNS and Keycloak use their timestamped target histories. Other targets
   retain their documented archive names. Pre-change files are rollback
   evidence, not the default recovery source.
3. Follow NGINX_BACKUP.md for clean-tree restoration, default-site removal,
   unpinned-listener checks, TLS material, and service restart. No nginx
   supersession chain or historical post-restore amendment is required.
4. Never display secrets in shared output; verify modes and results without
   printing passwords, private keys, tokens or database contents.
5. Use a full nginx restart after configuration restoration; a reload does
   not reliably apply service-user or listener changes.

## Camera-IP files: generate, don't restore (operator policy, 2026-09-15)

The three files that embed per-camera IP addresses —
`/etc/mediamtx/mediamtx.yml` (RTSP sources, creds inline),
`/etc/onvif-mcp/snapshot_routes.json` (upstream snapshot URIs), and
`/etc/onvif-mcp/camera_registry.json` (ip_address field; the player URLs are
serial-keyed and IP-free) — are **regenerated from a live `get_cameras`
capture on every restore. They are never extracted from backup**, even though
`final-etc-onvif-mcp.tar` (registry + routes) exists in the
site-cert/ca-distribute/dns folders. Cameras are DHCP clients; a restore
performed when the fleet holds different addresses than at backup time would
silently misroute snapshots to whichever camera now owns the archived
address — a wrong-camera failure, worse than a broken one. (mediamtx.yml was
never in any backup at all — it was already live-generated only.)

Procedure: generate the camera data once discovery is available, using the
intended HTTPS origin. Verify serving behavior after the complete nginx
checkpoint and its upstream services are restored:

```bash
# 1. capture live discovery (one camera per JSON line; see MCP_HTTP.md for the handshake)
#    <discovery-file> holds the raw get_cameras tool text
python3 {{REPO_PATH}}/onvif-mcp/scripts/generate_site_camera_config.py \
  --discovery-file /tmp/discovery.json \
  --server-fqdn {{SERVER_FQDN}} \
  --username {{CAMERA_USER}} --password '{{CAMERA_PASS}}'
#    writes all three files with live IPs; the password is read by the
#    script, never echoed. Optional per-route fixes: /etc/onvif-mcp/camera_site_overrides.json
# 2. verify consistency (registry<->mediamtx<->routes, url scheme, trailing slashes)
python3 {{REPO_PATH}}/onvif-mcp/scripts/verify_site_camera_config.py --server-fqdn {{SERVER_FQDN}}
# 3. fix modes (generator runs unprivileged):
sudo chown mediamtx:mediamtx /etc/mediamtx/mediamtx.yml && sudo chmod 640 /etc/mediamtx/mediamtx.yml
# 4. apply
sudo systemctl restart mediamtx snapshot-proxy
# 5. assert: every mediamtx path online; every snapshot route returns a JPEG (SNAPSHOT.md §5)
#    VENDOR QUIRKS: the generator maps each profile to its native ONVIF
#    snapshot_uri. Some cameras (AXIS in particular) 503/502 on certain
#    resolutions — re-test every route live (SNAPSHOT.md §2) and pin the
#    working endpoint per route via /etc/onvif-mcp/camera_site_overrides.json
#    ({"snapshot_routes": {"<serial>/<token>": "<working-url>"}}), then re-run
#    the generator + step 4. Do a fresh override pass on every restore — a
#    pin from a previous build carries the old IP and may 502.
```

During the plain-HTTP stage (before the cert exists) the same generator is
used with `http://` URLs for the registry (edit the scheme in
`generate()` or post-process); the HTTPS-stage regeneration above is the
final form. The `final-etc-onvif-mcp.tar` archives remain in backups for
provenance and for cross-checking (diff the live-generated files against
them to confirm no camera was lost between builds) — never as a restore
source.

## Per-stage procedures

Until BACKUP.md is restructured, execute the matching "Reconstructing…"
section in BACKUP.md for each stage, with the amendments above:

1. CA → CREATE_CA_CERT.md §13, executing the GPG passphrase steps per "Headless CA recovery over SSH" below (the §13 interactive prompts do not work over SSH); then decrypt newest `after-*-cert` age archive **[verified — headless over SSH, 2026-09-15]**
2. HTTPS → "Reconstructing the HTTPS configuration from backup" + key reissue per SITE_CERT.md §1–§8, **skipping the `final-etc-onvif-mcp.tar` extraction** (see "Camera-IP files: generate, don't restore" — regenerate registry+routes from live `get_cameras` after this stage) **[verified — reissued serial 0x1001; re-archive new CA state to Camera-CA-Backups]**
3. CA distribute → "Reconstructing the CA distribution endpoint from backup" **[verified incl. fingerprint match]**
4. DNS → DNS_BACKUP.md using the selected complete checkpoint; perform its listener, record, forwarding and client checks.
10–13. Keycloak → KEYCLOAK_BACKUP.md using the selected shared checkpoint pair; nginx → NGINX_BACKUP.md using the compatible complete checkpoint.
13b. Hermes client re-login → KEYCLOAK.md §13 (apply D8) **[verified — 29 tools]**
14. Nginx validation → NGINX_BACKUP.md; verify the listener and access controls for the selected checkpoint without applying historical configuration overlays.

## Final gates (whole-system acceptance)

All four must pass before declaring the restore complete:

1. `cd {{REPO_PATH}}/onvif-mcp && sudo python3 scripts/stream_auth_step9_driver.py
   --origin https://{{SERVER_FQDN}} --snapshot-path /snapshot/<serial>/<profile>/
   --webrtc-url /webrtc/<serial>/<profile>/` → `RESULT=PASS` **[verified]**
2. `hermes mcp test camera-new` → connects, 29 tools **[verified]**
3. Services table: kea-dhcp4-server, mediamtx, snapshot-proxy, onvif-mcp-http,
   dnsmasq, nginx, docker all enabled+active; keycloak/postgres/oauth2-proxy
   containers up (postgres healthy) **[verified]** — but systemctl-active is
   NOT sufficient evidence for daemons that can run with a broken config
   (observed: kea-dhcp4-server "active" with zero sockets for 24h). Kea must
   additionally pass the functional check:
   `sudo ss -ulpn | grep ':67'` non-empty, ideally followed by a fresh
   `DHCP4_LEASE_ALLOC` in journalctl after a client connects.
4. Post-restore backups: fresh `keycloak-postgres-backup.service` run + new CA
   `after-*-cert` age archive copied to `{{BACKUP_PATH}}/Camera-CA-Backups/`
   (a restore that reissued the cert invalidated the previous CA archive's
   "latest" status) **[verified]**

## Headless CA recovery over SSH (GPG passphrase, verified 2026-09-15)

Stage 6 (CA recovery) is the only stage whose steps normally require the
operator to sit at the host's physical terminal to answer a GUI passphrase
prompt. This section records how it was instead completed entirely over SSH,
with the operator joining from a remote session — the flow to reuse on every
future restore. CREATE_CA_CERT.md §13 was written for local TTY use and
**cannot be followed verbatim over SSH**; do not try to.

### Why the naive approach fails over SSH

The agent (this system's AI operator) must never hold the GPG passphrase —
it is the long-lived root of trust for the whole CA/vault chain. The user
must supply it. Three things conspire against the obvious remote flow:

1. **Importing a protected key does not prompt.** `gpg --import` on a
   passphrase-protected export stores the encrypted material silently and
   reports success. The passphrase is only ever demanded when the key is
   *used* (sign/decrypt/unprotect). So "import succeeded" is not the moment
   the cache gets primed — a later sign is.
2. **`pinentry` is a GUI program on desktop Ubuntu** (the `pinentry`
   alternative points at `pinentry-gnome3`). A gpg-agent spawned from a
   systemd user service or from an SSH session has no display, so when it
   needs a passphrase it launches pinentry, which cannot render, and the
   command dies with `error sending to agent: Timeout`. GnuPG then reports
   `signing failed: No secret key` even though the secret material is on
   disk — that misleading error was the single most confusing symptom of
   the 2026-09-15 restore.
3. **The gpg-agent's PIN cache is per-agent-instance.** A passphrase
   entered by one gpg invocation is usable by later invocations only while
   the *same* gpg-agent process lives and the TTL has not expired (default
   ~60 s). The agent and the user must therefore agree on one agent, and
   the user's prompt must happen while that agent is the one serving the
   agent's later headless `pass show` calls.

### The working procedure (exact order)

The agent prepares everything that does not need the passphrase; the user
supplies it once in their own terminal; the agent then runs everything that
needed it, headlessly, inside the warm-cache window.

**A. Agent-side preparation (no passphrase involved):**

1. Stage the exported key and verify it is a real protected secret
   (no value is printed — packet structure only):
   ```bash
   install -m 600 "$BACKUP/Camera-CA-Backups/ca-vault-gpg.key.gpg" ~/ca-vault-gpg.key.gpg
   gpg --list-packets ~/ca-vault-gpg.key.gpg | grep -E 'secret key|user ID'
   ```
2. Extend the agent's PIN cache so one user prompt covers the whole
   headless phase (2 h):
   ```bash
   printf 'default-cache-ttl 7200\nmax-cache-ttl 7200\nallow-loopback-pinentry\n' \
     > ~/.gnupg/gpg-agent.conf
   ```
   `allow-loopback-pinentry` is what makes the user's prompt render inside
   *their* SSH session (see B.2). Reload the agent afterwards:
   `gpgconf --kill gpg-agent` (it respawns on demand).
3. Restore the `pass` vault — the `.gpg` entry files are encrypted, so this
   step itself needs no passphrase:
   ```bash
   mkdir -p ~/.password-store
   tar -xzf "$BACKUP/Camera-CA-Backups/password-store-backup-{{DATE}}.tar.gz" -C ~/.password-store
   pass ls   # expect: camera-ca/age-archive-{{DATE}}, camera-ca/root-key-passphrase
   ```
4. Hand the user the single command from B.2 and wait.

**B. User-side passphrase supply (run in the user's own terminal, over SSH):**

1. Import the key. No prompt will appear — that is correct:
   ```bash
   gpg --import ~/ca-vault-gpg.key.gpg
   ```
2. Prime the PIN cache with one real use, in loopback pinentry mode:
   ```bash
   gpg --pinentry-mode loopback --clearsign -u <vault-key-fpr> <<< prime
   ```
   `--pinentry-mode loopback` tells gpg to render the passphrase prompt
   through the *gpg process itself*, in the user's SSH TTY, instead of
   asking the agent to spawn a pinentry GUI. The user sees the prompt,
   types the passphrase, and gets the signed "prime" block. **This is the
   one interactive moment of the whole remote restore.**

   If it fails with `No secret key`, the import stored only the public
   part (usually because the import ran while a stuck, dead, or
   systemd-socket-activated gpg-agent was serving the socket): kill all
   agent processes (`pkill -9 gpg-agent`; also clear
   `/run/user/$(id -u)/gnupg/S.gpg-agent*`), then re-run the import and
   the loopback clearsign.

**C. Agent-side headless continuation (no more prompts — run within the 2 h):**

Everything from CREATE_CA_CERT.md §13 step 4 onward, plus the reissue, runs
unattended because the PIN cache is warm:

1. Sanity-check the vault headlessly (byte counts only, never values):
   ```bash
   pass show camera-ca/root-key-passphrase | wc -c   # 29
   pass show camera-ca/age-archive-{{DATE}} | wc -c  # 29
   ```
   If this errors, the user's prompt never landed in this agent's cache —
   have them repeat B.2, do not attempt the decrypt.
2. Decrypt the newest post-issuance CA state archive with the stdin-fed
   `script` PTY pattern (CREATE_CA_CERT.md §13 step 4 verbatim) and
   restore it to `{{CA_ROOT_PATH}}`; shred the decrypted intermediate.
3. Proceed to stage 7: the same warm cache feeds every subsequent
   `pass show` — the `openssl ca` sign (SITE_CERT.md §5, passphrase +
   "y" + "y" piped through the two-line `script -qec` PTY pattern), the
   post-issuance age re-encryption (§7, two passphrase prompts fed the
   same way), and the decrypt-verify of the fresh archive.

**Verification that the cache is genuinely warm (agent-side, before any
destructive step):**

```bash
echo test | gpg --pinentry-mode loopback --clearsign -u <vault-key-fpr> \
  2>/dev/null | gpg --verify   # "Good signature" with no prompt = warm
```

### Pitfalls learned (2026-09-15)

- **`No secret key` on sign does not mean the key is missing.** It means
  the agent could not prompt for the passphrase (pinentry/GUI or stale
  agent). Check `gpg --list-secret-keys` for a `sec#` flag and
  `~/.gnupg/private-keys-v1.d/` for the keygrip-named key files before
  re-importing anything.
- **A secret-key import can silently store only the subkey.** The 2026-09-15
  import wrote only the cv25519 subkey's key file because the primary
  key's unprotect step timed out at pinentry. Verify with
  `gpg --with-keygrip --list-secret-keys` that the primary signing key has
  a matching file in `private-keys-v1.d/`, and re-import (user terminal,
  loopback mode) until both are present.
- **Do not kill the gpg-agent between the user's prompt and the agent's
  `pass show` phase** — that discards the warm cache and costs another
  user round-trip.
- **The `script -qec "…"` PTY pattern is still required for `age`** (its
  passphrase reads are `/dev/tty`-only) — loopback pinentry covers GPG
  only, not age. The two-line `bash -lc 'pass show …; pass show …' |
  script -qec "… age -p …"` wrapper from CREATE_CA_CERT.md §10/§13 remains
  the correct form.
- **Never print the passphrase or the vault values.** This section's
  commands are written so that only packet structures, byte counts, and
  fingerprints are ever visible in shared output.

## Known limits of this guide

- Live WebRTC video rendering (UDP ICE) is human-only verification.
- Camera-net 403 negative checks (ca-distribute allow/deny) need an off-box
  source inside `10.2.2.0/24`.
