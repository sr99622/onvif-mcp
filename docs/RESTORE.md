# Camera System Restore Guide

System-wide reconstruction instructions for the ONVIF camera server, distilled
from `BACKUP.md`'s reconstruction sections and the full end-to-end restore
executed on 2026-09-13 (the only restore of this backup set performed to date;
items marked **[verified]** were executed successfully in that restore).

This document is the ordering authority. The per-stage mechanics currently
still live in `BACKUP.md` ("Reconstructing…" sections) and in each runbook;
this document tells you **what order to do them in, which artifacts supersede
which, and what the docs currently get wrong.** Before starting any restore,
read "Known doc defects" below — several restore steps as written fail or
silently regress the system.

## Site constants

Authoritative values (from `BACKUP.md` Required Values table):

| Placeholder | Value |
|---|---|
| `{{BACKUP_PATH}}` | `/mnt/taurus/Camera-System-Backup` |
| `{{SERVER_FQDN}}` | `gmktec.home.arpa` |
| `{{SERVER_IP}}` | `10.1.1.5` (LAN, `enp170s0`) |
| `{{REPO_PATH}}` | `/home/stephen` |
| `{{SERVER_USER}}` | `stephen` |
| `{{PRVT_CAMERA_NET_EN_NAME}}` | `enp171s0` |
| `{{CA_ROOT_PATH}}` | `/home/stephen/Private-CA` |
| Camera creds | `admin` / from `~/.hermes/config.yaml` (never copy into docs) |

Out-of-band trust anchor — verify before trusting any CA material:
Root CA SHA-256 fingerprint `09:9F:3C:3B:90:C8:AF:8F:42:D2:B1:DA:53:E0:10:08:2F:BE:6C:5E:EA:11:51:8D:22:62:DF:F1:8E:89:A9:4F`

## Phase 0 — Preflight (do not skip)

1. Mount the SMB backup and confirm it is writable: **[verified]**
   ```bash
   ls /mnt/taurus/Camera-System-Backup/ && touch /mnt/taurus/Camera-System-Backup/.wtest && rm $_
   ```
2. Verify every stage folder's `SHA256SUMS`: **[verified]**
   ```bash
   cd /mnt/taurus/Camera-System-Backup
   for d in */; do (cd "$d" && [ -f SHA256SUMS ] && echo "$d: $(sha256sum -c SHA256SUMS 2>/dev/null | grep -c OK) OK"); done
   ```
   Any mismatch: stop, investigate, do not restore from that folder.
3. Inventory the expected folder set (13 stage folders + `Camera-CA-Backups/`).
   Missing folders = missing capabilities; check the supersession registry
   below to see what is lost.
4. Confirm host preconditions match the constants (hostname `gmktec`, LAN IP,
   `/etc/hosts` entry, repo checkout, camera creds present in Hermes config).
5. Expect slow restores over SMB for large tars (venv ≈ 79 MB / 3754 files,
   2–3 minutes); run those in the background. **[verified]**

## Restore sequence (whole-system)

The nginx configs, `/etc/systemd/system`, `/etc/onvif-mcp`, and `/opt/keycloak`
overlap across stage folders. **Supersession is strict: a later row always wins
over an earlier one for the artifacts listed.** Never restore an earlier folder
after a later one.

| # | Stage | Backup folder | Restores | Supersedes (for) |
|---|---|---|---|---|
| 1 | DHCP/Kea | `dhcp-*` | Kea conf/leases, sysctl isolation, NM profile (*defect D1*) | — |
| 2 | MediaMTX | `mediamtx-*` | binary, unit, conf, state; nginx sites | — |
| 3 | Snapshot proxy | `snapshot-*` then `snapshot-user-correction-*` | routes, proxy source, unit; nginx sites | snapshot's unit+routes (typo fix) |
| 4 | Apps | `apps-*` | nginx.conf (`user webcam;`), sites, registry, app sources | stages 2–3 nginx sites |
| 5 | MCP HTTP | `mcp-http-*` | venv, unit, sites (adds `/mcp`) | stage 4 sites |
| 6 | CA recovery | `Camera-CA-Backups/` (user-driven, GPG→pass→age) | Private-CA tree | — (see CREATE_CA_CERT.md §13) |
| 7 | HTTPS cert | `site-cert-*` + live CA | reissued key+cert, conf.d (HTTPS), nginx.conf, onvif unit (https), tls dir | stage 5 unit/registry |
| 8 | CA distribute | `ca-distribute-*` | `/srv/camera-pki/public`, sites+conf.d (adds `/ca/`) | stage 7 sites AND conf.d |
| 9 | DNS | `dns-*` | dnsmasq conf, drop-in, defaults | — (independent) |
| 10 | Keycloak | `keycloak-*` | docker deploy, DB dump, units (ALL), nginx dirs | stage 8 sites; earlier `/etc/systemd/system` |
| 11 | Stream auth | `stream-auth-*` | `final-opt-keycloak.tar`, DB dumps, conf.d (oauth2) | stage 10 opt/conf.d/dumps |
| 12 | Add user | `add-user-*` | `final-opt-keycloak.tar`, DB dumps | stage 11 opt/dumps |
| 13 | Add client | `add-client-on-server-*` | `final-opt-keycloak.tar` (newest), DB dumps (**restore source**) | stage 12 opt/dumps |
| 14 | Amendments | *no folder* (defect D6) | unpinned 443 + nginx drop-in, sed | everything that touched conf.d |
| 15 | Final gates | — | step-9 driver RESULT=PASS, `hermes mcp test camera-new` 29 tools | — |

Ordering rules that caused real failures when ignored:

- **After every `sites-enabled` tar: `sudo rm -f /etc/nginx/sites-enabled/default`**
  **[verified]** — the stock `_` default vhost shadows FQDN routes
  (observed: `/mcp/` 404, unauthenticated `/cameras/`, `/auth/` 404).
- **Apply amendment D6 (unpinned 443) AFTER the LAST conf.d restore (stage 11)**
  **[verified — needed twice]** — every archived conf.d still contains the pinned
  `listen 10.1.1.5:443;` line.
- **Keycloak-stage `/etc/systemd/system` restore brings every stage's units
  forward at once** — do not restore older stage folders after stage 10+.
- Stage 9 (DNS) and stage 1 (DHCP) are independent of the nginx chain and can
  run anytime after their package installs.

## Supersession registry — which artifact comes from where (final say)

| Artifact | Restore source |
|---|---|
| MediaMTX binary/config/unit/state | `mediamtx-*/final-etc-mediamtx.tar` etc. |
| `nginx.conf` (`user webcam;`) | `apps-*/final-etc-nginx-nginx.conf.tar` |
| nginx `sites-available` / `sites-enabled` | `keycloak-*/final-…` (newest complete set; identical in practice to ca-distribute + stage-10 edits) |
| nginx `conf.d` (HTTPS vhost) | `stream-auth-*/final-etc-nginx-conf.d.tar` **then apply D6 sed** |
| `/etc/onvif-mcp/` (registry + routes) | `site-cert-*/final-etc-onvif-mcp.tar` (registry https-flipped; routes from stage 3/4 chain) |
| venv | `mcp-http-*/final-home-*-onvif-mcp-.venv.tar` |
| `onvif-mcp-http.service` | `site-cert-*/…tar` (has `STREAM_SERVER_URL=https://…`) + `keycloak-*/etc-systemd` oauth drop-in |
| `/srv/camera-pki` | `ca-distribute-*/final-srv-camera-pki.tar` |
| dnsmasq set | `dns-*/` four tars |
| `/opt/keycloak/` (compose, .env, pass files) | `add-client-on-server-*/final-opt-keycloak.tar` |
| Keycloak DB | `add-client-on-server-*/final-var-backups-keycloak-postgres.tar` → newest dump (`keycloak-20260913T004014Z.dump` or later) |
| Backup script + backup unit | `keycloak-*/final-usr-local-sbin-…` / `final-etc-systemd-system.tar` |
| CA (GPG vault → age archive) | `Camera-CA-Backups/` — newest `camera-system-ca-after-*-tar.gz.age` |
| Server TLS key | **never backed up (by design)** — regenerate + reissue, SITE_CERT.md §1–§6 + §8 |

## Global restore rules

1. Verify checksums (Phase 0.2) before any tar extraction.
2. Restore `final-*` files only; pre-change tars are for provenance.
3. Remove the nginx default site after any sites-enabled restore.
4. Apply D6 after the last conf.d restore.
5. Use the corrected commands from "Known doc defects" — several verbatim
   BACKUP.md commands fail as written.
6. Never display secret material (token files, dumps, .env values) in shared
   output; restore blind, assert modes/counts.
7. A full restart (`restart`), not `reload`, is required for: nginx `user`
   directive changes, `listen` directive changes, and dnsmasq directive changes.

## Known doc defects (found by executing this restore 2026-09-13)

Already patched into BACKUP.md:

- **D1** `dhcp-*/final-etc-NetworkManager-system-connections.tar` is EMPTY.
  Recreate the profile with `nmcli connection add` per DHCP.md §1. **[verified]**
- **D2** Kea verification via `ss -ulpn` never matches (raw AF_PACKET socket).
  Use journalctl DHCPACK lines or lease-file rows. **[verified]**
- **D3** No restore section removes `sites-enabled/default` (global rule 3).
- **D4** Keycloak tars root at `keycloak/` and `keycloak-postgres-backups/`, not
  `/opt` and `/var/backups/keycloak-postgres` — fix `-C` targets, then move.
  **[verified]**
- **D5** `pg_restore … < /var/backups/…dump` fails (dumps are 0600 root; agent
  shell redirect is unprivileged). Use `sudo cat dump | docker exec -i …`.
  **[verified]**
- **D6** The unpinned-443 amendment (2026-09-12) has no backup folder and was
  never re-archived: every conf.d tar contains the pinned listen. Re-apply
  (sed + `nginx.service.d/wait-for-network.conf`) after the last conf.d restore.
  **[verified — the omission regressed the boot-race bug twice]**
- **D7** `onvif-mcp-http --help` hangs (this build serves instead of printing
  help); probe via `importlib.metadata` version or systemd status. **[verified]**
- **D8** Hermes `ssl_verify` file is `/etc/ssl/certs/camera-system-root-ca.pem`
  (update-ca-certificates renames `.crt` → `.pem`). **[verified]**
- **D9** `mcp-http` venv tar over SMB exceeds short timeouts; background it.

Still open (not yet patched):

- ~~BACKUP.md's one-line tar-pipe pg_restore idiom remains present but unverified~~
  — now marked unverified in-place; explicit sequence documented as preferred.
- `snapshot-user-correction`, `add-user`, `add-client` still have no dedicated
  BACKUP.md restore sections (their handling is encoded in the tables above);
  runbook-side stage-close sections now exist for SITE_CERT, CA_DISTRIBUTE,
  KEYCLOAK (§15b), and STREAM_AUTH (§10) as of 2026-09-13 — DNS, ADD_USER,
  ADD_CLIENT_ON_SERVER, FIREWALL, SERVER_PREP are still thin/absent.

## Per-stage procedures

Until BACKUP.md is restructured, execute the matching "Reconstructing…"
section in BACKUP.md for each stage, with the amendments above:

1. DHCP/Kea → BACKUP.md "Reconstructing the DHCP/Kea server from backup" (apply D1, D2)
2. MediaMTX → "Reconstructing the MediaMTX server from backup" (add: remove default site)
3. Snapshot → "Reconstructing the snapshot proxy from backup" (then overlay `snapshot-user-correction-*/final-etc-systemd-system-snapshot-proxy.service.tar` + `final-etc-onvif-mcp.tar`) **[verified]**
4. Apps → "Reconstructing the camera applications from backup" **[verified — all checks passed]**
5. MCP HTTP → "Reconstructing the ONVIF MCP HTTP server from backup" (apply D7, D9) **[verified incl. full MCP handshake, 29 tools]**
6. CA → CREATE_CA_CERT.md §13 (user runs GPG import + vault restore; then decrypt newest `after-*-cert` age archive) **[verified]**
7. HTTPS → "Reconstructing the HTTPS configuration from backup" + key reissue per SITE_CERT.md §1–§8 **[verified — reissued serial 0x1001; re-archive new CA state to Camera-CA-Backups]**
8. CA distribute → "Reconstructing the CA distribution endpoint from backup" **[verified incl. fingerprint match]**
9. DNS → "Reconstructing the local DNS server from backup" **[verified — all four dig checks]**
10–13. Keycloak chain → "Reconstructing the Keycloak OAuth server from backup" and "…browser authentication gate…" using **add-client's** `final-opt-keycloak.tar` + newest dump (apply D4, D5, global rules) **[verified — step-9 driver RESULT=PASS]**
13b. Hermes client re-login → KEYCLOAK.md §13 (apply D8) **[verified — 29 tools]**
14. Amendments → sed + drop-in (D6), then `systemctl restart nginx` **[verified]**

## Final gates (whole-system acceptance)

All four must pass before declaring the restore complete:

1. `cd {{REPO_PATH}}/onvif-mcp && sudo python3 scripts/stream_auth_step9_driver.py
   --origin https://{{SERVER_FQDN}} --snapshot-path /snapshot/<serial>/<profile>/
   --webrtc-url /webrtc/<serial>/<profile>/` → `RESULT=PASS` **[verified]**
2. `hermes mcp test camera-new` → connects, 29 tools **[verified]**
3. Services table: kea-dhcp4-server, mediamtx, snapshot-proxy, onvif-mcp-http,
   dnsmasq, nginx, docker all enabled+active; keycloak/postgres/oauth2-proxy
   containers up (postgres healthy) **[verified]**
4. Post-restore backups: fresh `keycloak-postgres-backup.service` run + new CA
   `after-*-cert` age archive copied to `{{BACKUP_PATH}}/Camera-CA-Backups/`
   (a restore that reissued the cert invalidated the previous CA archive's
   "latest" status) **[verified]**

## Known limits of this guide

- Live WebRTC video rendering (UDP ICE) is human-only verification.
- Camera-net 403 negative checks (ca-distribute allow/deny) need an off-box
  source inside `10.2.2.0/24`.
- The restore as a whole has been executed exactly once (2026-09-13); treat
  unmarked steps as inferred-from-build, not restore-verified.
