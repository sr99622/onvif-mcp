# Camera System Backup Log

Backup destination: `{{BACKUP_PATH}}`

For this server, `{{BACKUP_PATH}}` currently resolves to `/mnt/taurus/Camera-System-Backup`.

This document records backup actions taken before and during server configuration changes. Runbooks should refer to the backup location as `{{BACKUP_PATH}}` so future agents can substitute the correct SMB-mounted backup folder.

## Required Values

Authoritative substitutions for every `{{PLACEHOLDER}}` used in this document and its referenced runbooks. Resolve these **before** executing any runbook step; never substitute a placeholder literally, and never re-derive a value from a per-runbook mapping block below if it disagrees with this table.

| Placeholder | Required value | Notes |
|---|---|---|
| `{{BACKUP_PATH}}` | `/mnt/taurus/Camera-System-Backup` | Backup root **includes** `Camera-System-Backup/`; backup folders are `{{BACKUP_PATH}}/<runbook-name>-{{DATETIME_STAMP}}/`. Verify the mount is present and writable first. |
| `{{SERVER_FQDN}}` | `gmktec.home.arpa` | Must match the site certificate SAN (SITE_CERT.md §4). |
| `{{SERVER_IP}}` | `10.1.1.5` | LAN interface address (`enp170s0`). Not used for nginx binding — 443 listens on all interfaces (SITE_CERT.md §9). |
| `{{REPO_PATH}}` | `/home/stephen` | Parent directory of the `onvif-mcp/` checkout. |
| `{{SERVER_USER}}` | `stephen` | Service user for snapshot-proxy and related units. |
| `{{PRVT_CAMERA_NET_EN_NAME}}` | `enp171s0` | Private camera network interface (Kea/DHCP `isolated` profile). |
| `{{CA_ROOT_PATH}}` | `/home/stephen/Private-CA` | Private CA working root (CREATE_CA_CERT.md). |
| `{{USERNAME}}` | `admin` | Camera login; source of truth `~/.hermes/config.yaml` camera env. |
| `{{PASSWORD}}` | *(not inlined — see source)* | Camera password; read from `~/.hermes/config.yaml` `mcp_servers.camera.env.CAMERA_PASSWORD` at run time. Do not copy the value into new doc sections. |
| `{{DATETIME_STAMP}}` | generate at run time: `date +%Y%m%d-%H%M%S` | One stamp per runbook execution, reused within a run. |
| `{{DATE}}` | generate at run time: `date +%F` | Legacy date-only stamp; prefer `{{DATETIME_STAMP}}` for new entries. |

Excluded from this table by design:
- Per-run identity inputs consumed by user/client onboarding runbooks (`ADD_USER.md`, `ADD_CLIENT_ON_SERVER.md`) — new Keycloak usernames, names, emails, and client source IPs. Those are site data persisted in the Keycloak database (and its `{{BACKUP_PATH}}` dumps); restoring the database restores them, so they are never configuration constants to track here.
- DNS deployment values (`{{RVRS_SRV_IP}}`, `{{UPSTREAM_DNS}}`) defined in DNS.md. They are materialized inside `/etc/dnsmasq.d/camera-system.conf`, which the `dns-*` backup archives restore; `{{RVRS_SRV_IP}}` is also mechanically derived from `{{SERVER_IP}}` (its octets reversed). Resolved values live in DNS.md's own table and the live config, not here.

## Backup Naming Convention

Each configuration backup is stored in a timestamped directory under `{{BACKUP_PATH}}`:

```text
{{BACKUP_PATH}}/<runbook-name>-{{DATETIME_STAMP}}/
```

Use `{{DATETIME_STAMP}}` for the timestamp component. Generate it at runtime with:

```bash
date +%Y%m%d-%H%M%S
```

Examples:

- `{{BACKUP_PATH}}/dhcp-{{DATETIME_STAMP}}/`
- `{{BACKUP_PATH}}/mediamtx-{{DATETIME_STAMP}}/`
- `{{BACKUP_PATH}}/snapshot-{{DATETIME_STAMP}}/`
- `{{BACKUP_PATH}}/snapshot-user-correction-{{DATETIME_STAMP}}/`

Within each backup directory:

- `pre-change-state.txt` or `pre-correction-state.txt` records state before changes.
- Files without a `final-` prefix are pre-change archives.
- Files with a `final-` prefix are the working configuration after changes.
- `post-change-state.txt` or `post-correction-state.txt` records state after changes.
- `SHA256SUMS` records checksums for every backed-up file except itself.

## Procedure

For each server configuration we touch:

1. Identify the files, directories, services, credentials, package state, and command output needed to reconstruct the configuration.
2. Create a timestamped folder under `{{BACKUP_PATH}}` before making changes.
3. Copy essential backup data to that folder before making changes.
4. Preserve file ownership, permissions, timestamps, ACLs, xattrs, and symlinks where applicable.
5. After the configuration is working, copy the final working configuration into the same backup folder with `final-` prefixes.
6. Generate `SHA256SUMS` in the backup folder.
7. Record the backup entry below with source paths, destination paths, commands used, and verification results.

## Restore-stage global rules (added 2026-09-13, first full restore test)

1. **Always remove the nginx default site after restoring any sites-enabled set.**
   The original build disabled `/etc/nginx/sites-enabled/default`, but tar restores cannot
   remove a file a fresh nginx install recreates. After every `final-etc-nginx-sites-enabled.tar`
   extraction run: `sudo rm -f /etc/nginx/sites-enabled/default` (the stock `_` vhost
   otherwise shadows `gmktec.home.arpa` routes — observed symptoms: `/mcp/` 404,
   `/cameras/` served unauthenticated, `/auth/` 404).
2. **Re-apply the unpinned-listener amendment LAST, after the final `conf.d` restore**
   (see "HTTPS listener unpinned" below). The `site-cert-*` and `stream-auth-*`
   `final-etc-nginx-conf.d.tar` archives both still contain the pinned
   `listen 10.1.1.5:443;` line; restoring them regresses the boot-time bind race.
3. **Large tar restores over SMB (e.g. the 79 MB venv archive) take 2–3 minutes** due to
   small-file SMB latency; run them in the background or with a generous timeout.

## Backup Entries

### DHCP/Kea isolated camera network

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/DHCP.md`

Runbook variables used:

- `{{PRVT_CAMERA_NET_EN_NAME}}`: `enp171s0`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folder:

- `{{BACKUP_PATH}}/dhcp-{{DATETIME_STAMP}}`

Backed up data:

- `pre-change-state.txt` — NetworkManager, IP address, route, sysctl forwarding, and package state before changes.
- `etc-NetworkManager-system-connections.tar` — pre-change NetworkManager system connection profiles.
- `post-change-state.txt` — NetworkManager, route, sysctl, package, service, and UDP 67 listener state after changes.
- `final-etc-kea.tar` — final Kea configuration under `/etc/kea/`.
- `final-etc-NetworkManager-system-connections.tar` — final NetworkManager connection profiles, including `isolated` for `{{PRVT_CAMERA_NET_EN_NAME}}`.
- `final-var-lib-kea.tar` — final Kea lease directory under `/var/lib/kea/`.
- `final-90-isolated.conf` — final persistent forwarding isolation file from `/etc/sysctl.d/90-isolated.conf`.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Installed `kea-dhcp4-server`.
- Created NetworkManager connection `isolated` on `{{PRVT_CAMERA_NET_EN_NAME}}`.
- Set `{{PRVT_CAMERA_NET_EN_NAME}}` to `10.2.2.1/24`.
- Configured Kea DHCPv4 to serve `10.2.2.100 - 10.2.2.200` on `{{PRVT_CAMERA_NET_EN_NAME}}`.
- Left DHCP clients without a router or DNS option.
- Persistently disabled IPv4 forwarding and IPv6 forwarding.
- Enabled and restarted `kea-dhcp4-server`.

Verification performed:

- `{{PRVT_CAMERA_NET_EN_NAME}}` is connected with `10.2.2.1/24`.
- Route on `{{PRVT_CAMERA_NET_EN_NAME}}` is only `10.2.2.0/24`.
- `net.ipv4.ip_forward = 0`.
- `net.ipv6.conf.all.forwarding = 0`.
- Kea config validates with `sudo -u _kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf`.
- `kea-dhcp4-server` is active.
- Kea is listening on UDP `10.2.2.1:67`.

### MediaMTX RTSP-to-WebRTC server

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/MEDIAMTX.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{USERNAME}}`: `admin`
- `{{PASSWORD}}`: `admin123`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folder:

- `{{BACKUP_PATH}}/mediamtx-{{DATETIME_STAMP}}`

Backed up data:

- `pre-change-state.txt` — pre-change MediaMTX, nginx, service, port, package, and HTTP state.
- `etc-nginx-sites-available.tar` — pre-change nginx available site configs.
- `etc-nginx-sites-enabled.tar` — pre-change nginx enabled site configs.
- `post-change-state.txt` — final MediaMTX/nginx/service/port/path-count/log verification state.
- `final-etc-mediamtx.tar` — final `/etc/mediamtx/` configuration. Sensitive: includes camera RTSP credentials.
- `final-usr-local-bin-mediamtx.tar` — final MediaMTX binary, version `v1.21.0`.
- `final-etc-systemd-system-mediamtx.service.tar` — final systemd service unit.
- `final-var-lib-mediamtx.tar` — final MediaMTX working directory.
- `final-var-log-mediamtx.tar` — final MediaMTX log directory.
- `final-etc-nginx-sites-available.tar` — final nginx site configs.
- `final-etc-nginx-sites-enabled.tar` — final nginx enabled site configs.
- `final-docs-MEDIAMTX.md` — final MediaMTX runbook with generic `{{BACKUP_PATH}}` backup instructions.
- `final-docs-BACKUP.md` — final backup log and reconstruction instructions.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Installed MediaMTX `v1.21.0` at `/usr/local/bin/mediamtx`.
- Created dedicated system user/group `mediamtx:mediamtx`.
- Created `/etc/mediamtx`, `/var/lib/mediamtx`, and `/var/log/mediamtx`.
- Wrote `/etc/mediamtx/mediamtx.yml` with 17 camera profile paths from the camera MCP server.
- Configured RTSP on `127.0.0.1:8554` with TCP transport only.
- Configured WebRTC signaling on `127.0.0.1:8889` and WebRTC UDP media on `:8189`.
- Disabled RTMP, HLS, SRT, MoQ, and the MediaMTX API.
- Installed `/etc/systemd/system/mediamtx.service` and enabled the service.
- Configured nginx site `/etc/nginx/sites-available/mediamtx` for `http://{{SERVER_FQDN}}/webrtc/`.
- Enabled the nginx site and removed the default enabled site.

Verification performed:

- `mediamtx` service is enabled and active.
- `/usr/local/bin/mediamtx --version` returns `v1.21.0`.
- nginx configuration test passes.
- `http://{{SERVER_FQDN}}/` returns the MediaMTX server text response.
- A WebRTC camera path returns HTTP `200` through nginx.
- MediaMTX listens on `127.0.0.1:8554`, `127.0.0.1:8889`, and UDP `:8189`.
- nginx listens on TCP `80`.
- `/etc/mediamtx/mediamtx.yml` contains 17 configured camera paths.
- Recent MediaMTX logs show all 17 paths became available and online.
- Backup checksums all passed.

### Camera snapshot proxy

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/SNAPSHOT.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{REPO_PATH}}`: `/home/stephen`
- `{{SERVER_USER}}`: `stephen`
- `{{USERNAME}}`: `admin`
- `{{PASSWORD}}`: `admin123`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folder:

- `{{BACKUP_PATH}}/snapshot-{{DATETIME_STAMP}}`

Backed up data:

- `pre-change-state.txt` — pre-change user, repo, snapshot service, nginx, and listener state.
- `etc-nginx-sites-available.tar` — pre-change nginx available site configs.
- `etc-nginx-sites-enabled.tar` — pre-change nginx enabled site configs.
- pre-change `{{REPO_PATH}}/onvif-mcp/services/snapshot_proxy.py` archive — pre-change snapshot proxy source.
- `post-change-state.txt` — final user, ACL, service, nginx, listener, route, and log state.
- `final-etc-onvif-mcp.tar` — final `/etc/onvif-mcp/`, including `snapshot_routes.json`.
- `final-etc-systemd-system-snapshot-proxy.service.tar` — final snapshot proxy systemd service. Sensitive: includes camera credentials in environment lines.
- `final-etc-nginx-sites-available.tar` — final nginx site configs with `/snapshot/` location.
- `final-etc-nginx-sites-enabled.tar` — final nginx enabled site configs.
- final `{{REPO_PATH}}/onvif-mcp/services/snapshot_proxy.py` archive — final snapshot proxy source.
- `final-docs-SNAPSHOT.md` — final snapshot runbook with generic `{{BACKUP_PATH}}` backup instructions.
- `final-docs-BACKUP.md` — final backup log and reconstruction instructions.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Corrected `{{SERVER_USER}}`; the earlier `stephem` value was a user input typo and has been removed from the active service configuration.
- Created `/etc/onvif-mcp/snapshot_routes.json` with 17 route entries matching the MediaMTX/camera MCP profile paths.
- Installed `/etc/systemd/system/snapshot-proxy.service` using `User={{SERVER_USER}}`.
- Started and enabled `snapshot-proxy` on loopback `127.0.0.1:8891`.
- Added nginx `/snapshot/` proxying to `http://127.0.0.1:8891/snapshot/` in the existing `{{SERVER_FQDN}}` site.
- Reloaded nginx.

Verification performed:

- Every upstream camera snapshot URI was tested live with `curl --digest`; all final route entries returned JPEG data.
- The AXIS routes that returned persistent `503 text/html` for profile-specific snapshot sizes were mapped to the reliable `1920x1080` JPEG endpoint while preserving the exact external route keys.
- `snapshot-proxy` is enabled and active.
- `snapshot-proxy` listens only on `127.0.0.1:8891`.
- nginx configuration test passes.
- All 17 loopback proxy routes returned `200 image/jpeg` with real JPEG data.
- All 17 nginx `/snapshot/<serial>/<profile>/` routes returned `200 image/jpeg` with real JPEG data and `Cache-Control: no-store`.
- Negative loopback checks returned `404` for an unknown route and `400` for garbage path.
- Backup checksums all passed.

### Camera applications (switchboard & multi-view)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/APPS.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{REPO_PATH}}`: `/home/stephen`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folder:

- `{{BACKUP_PATH}}/apps-{{DATETIME_STAMP}}`

Backed up data:

- `pre-change-state.txt` — repo app file state, runtime registry state, and full `nginx -T` dump before changes.
- `etc-nginx-nginx.conf.tar` — pre-change main nginx config (`user www-data;`).
- `etc-nginx-sites-available.tar` / `etc-nginx-sites-enabled.tar` — pre-change nginx site configs.
- `etc-onvif-mcp.tar` — pre-change site config directory (registry absent at this point).
- `home-stephen-onvif-mcp-apps.tar` — pre-change app sources.
- `post-change-state.txt` — final webcam user, nginx user directive, registry, endpoint, redirect, player, snapshot regression, and service state.
- `final-etc-nginx-nginx.conf.tar` — final main nginx config with `user webcam;`. Sensitive to placement: nginx will not read the repo without it.
- `final-etc-nginx-sites-available.tar` / `final-etc-nginx-sites-enabled.tar` — final vhost with `/cameras/`, `/multiview/`, `/snapshot/`, `/webrtc/`, `/outputs/` locations.
- `final-etc-onvif-mcp.tar` — final site config directory including `camera_registry.json` (7 cameras) and `snapshot_routes.json`. Sensitive: exposes camera hostnames, IPs, and endpoints.
- `final-home-stephen-onvif-mcp-apps.tar` — final app sources actually served by nginx.
- `final-docs-APPS.md` — final APPS runbook with generic `{{BACKUP_PATH}}` backup instructions.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Generated `/etc/onvif-mcp/camera_registry.json` (root:stephen, mode 640) with 7 camera entries from live `get_cameras` data; every `media_player_url`/`substream_player_url` points at the MediaMTX WebRTC player with a trailing slash over plain HTTP.
- Created system user `webcam` and added it to group `stephen` so nginx workers can traverse `/home/stephen`.
- Changed the nginx `user` directive from `www-data` to `webcam` in `/etc/nginx/nginx.conf` and restarted nginx.
- Extended the existing `gmktec.home.arpa` vhost with `/cameras/` and `/multiview/` alias locations, slash-less 301 redirects, `= /outputs/camera_registry.json` alias to the runtime registry, and a `/outputs/` 404 guard.

Verification performed:

- `/cameras/`, `/multiview/`, `/outputs/camera_registry.json`, `/cameras/styles.css`, `/cameras/app.js`, `/multiview/app.js` all return `200`.
- `/cameras` (no slash) returns `301` to `/cameras/`.
- All 14 player URLs referenced by the registry return `200` through the `/webrtc/` proxy.
- Snapshot regression check: `/snapshot/<serial>/<profile>/` still returns `200 image/jpeg`.
- `/outputs/` directory listing returns `404`.
- `nginx -t` passes; `nginx`, `mediamtx`, `snapshot-proxy` all active.
- Backup checksums all passed.

### ONVIF MCP HTTP server

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/MCP_HTTP.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{REPO_PATH}}`: `/home/stephen`
- `{{SERVER_USER}}`: `stephen`
- `{{USERNAME}}`: `admin`
- `{{PASSWORD}}`: `admin123`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folder:

- `{{BACKUP_PATH}}/mcp-http-{{DATETIME_STAMP}}`

Backed up data:

- `pre-change-state.txt` — pre-change service state (not installed), executable path, listener state, full `nginx -T`, and existing endpoint checks.
- `etc-nginx-sites-available.tar` / `etc-nginx-sites-enabled.tar` — pre-change nginx site configs (no `/mcp` locations).
- `home-stephen-onvif-mcp-.venv.tar` — pre-sync virtualenv (unit file and executable absent pre-change; recorded in `pre-change-state.txt`).
- `post-change-state.txt` — final service, unit file, executable, listener, `server_name` conflict count, `/mcp/` redirect, live MCP handshake capture (initialize/tools/list/get_adapters/get_cameras), and regression checks.
- `final-etc-systemd-system-onvif-mcp-http.service.tar` — final systemd unit. Sensitive: includes camera credentials in `Environment=` lines.
- `final-etc-nginx-sites-available.tar` / `final-etc-nginx-sites-enabled.tar` — final vhost with merged `/mcp` locations.
- `home-stephen-onvif-mcp-.venv.tar` (`final-` archive also present) — final virtualenv with `onvif-mcp-http==0.1.7` installed.
- `final-docs-MCP_HTTP.md` — final runbook with generic `{{BACKUP_PATH}}` backup instructions and the 421 testing note.
- `final-docs-BACKUP.md` — final backup log and reconstruction instructions.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Installed the `onvif-mcp-http` package into the repo virtualenv with `uv sync --frozen` (executable at `.venv/bin/onvif-mcp-http`).
- Installed `/etc/systemd/system/onvif-mcp-http.service` running as `stephen` on loopback `127.0.0.1:8001` with `STREAM_SERVER_URL=http://gmktec.home.arpa`; enabled and started.
- Merged the `location = /mcp` proxy and `location = /mcp/` redirect into the existing `gmktec.home.arpa` vhost — no second server block (per the runbook's merge warning).

Verification performed:

- `onvif-mcp-http` is enabled and active; listening only on `127.0.0.1:8001`.
- `sudo nginx -T | grep -c 'server_name gmktec'` returns exactly 1 — no vhost conflict.
- Full MCP handshake over `http://gmktec.home.arpa/mcp`: initialize 200 with session ID, initialized notification, `tools/list` returns 29 tools, `get_adapters` returns `10.1.1.5` and `10.2.2.1`, `get_cameras` returns the fleet with `web_player_url` values under `http://gmktec.home.arpa/webrtc/`.
- `/mcp/` returns 301 to `http://gmktec.home.arpa/mcp`.
- Upstream host validation observed: bare-loopback POSTs return 421/406 by design; recorded as a testing note in the runbook.
- Regression: `/cameras/`, `/multiview/`, `/outputs/camera_registry.json` still 200; snapshot route still `200 image/jpeg`; WebRTC player page still 200.
- `nginx -t` passes.
- Backup checksums all passed.

### Site certificate and HTTPS deployment

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/SITE_CERT.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{SERVER_IP}}`: `10.1.1.5`
- `{{REPO_PATH}}`: `/home/stephen`
- `{{CA_ROOT_PATH}}`: `/home/stephen/Private-CA`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folders:

- `{{BACKUP_PATH}}/site-cert-{{DATETIME_STAMP}}` — host HTTPS configuration
- `{{BACKUP_PATH}}/Camera-CA-Backups/camera-system-ca-after-gmktec-cert-{{DATE}}.tar.gz.age` — post-issuance CA state (age-encrypted, per SITE_CERT.md §7; created during the runbook itself)

Backed up data (site-cert folder):

- `post-change-state.txt` — CA archive hash reference, issued certificate identity (serial `0x1000`, expires 2027-10-14), 443 listener pinning, `server_name` count, TLS chain verification, TLS dir listing, service states, `STREAM_SERVER_URL`, registry scheme count, nginx test result.
- `final-etc-nginx-conf.d.tar` — the HTTPS server block `/etc/nginx/conf.d/gmktec.home.arpa.conf` (created by this runbook; exists in no earlier backup).
- `final-etc-nginx-sites-available.tar` / `final-etc-nginx-sites-enabled.tar` — redirect-only `mediamtx` sites file plus the `.backup-2026-09-12` pre-HTTPS copies.
- `final-etc-nginx-nginx.conf.tar` — main nginx config (plus its `.backup-2026-09-12` copy in the sites-available tar).
- `final-etc-onvif-mcp.tar` — registry flipped to `https://` (14 URLs) plus the same-day registry backup. Sensitive: exposes camera hostnames/IPs/endpoints.
- `final-etc-systemd-system-onvif-mcp-http.service.tar` — unit with `STREAM_SERVER_URL=https://...`. Sensitive: camera credentials in `Environment=` lines.
- `final-etc-nginx-tls-public.tar` — leaf, chain, root CA, CSR only. The **server key is deliberately NOT archived**: recovery regenerates it via SITE_CERT.md §1–§6 + §8 (or §12 renewal); keeping server keys off the SMB share limits exposure. It remains only at `/etc/nginx/tls/gmktec.home.arpa.key.pem` (root, 600).
- `final-docs-SITE_CERT.md` — final runbook (with §9 registry-location fix, §10 sudo-curl note, §11 sudo note).
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- TLS server key (3072-bit RSA) + CSR with `DNS:gmktec.home.arpa` SAN; signed by the private CA as serial `0x1000`, 397 days, reviewed extensions.
- `/etc/nginx/tls/` populated (key 600 root; cert/CA/chain/CSR 644); chain = leaf + CA.
- HTTPS server block at `/etc/nginx/conf.d/gmktec.home.arpa.conf` pinned to `10.1.1.5:443` serving apps, registry, `/webrtc/`, `/mcp`, `/snapshot/`; the `mediamtx` sites file reduced to a port-80 → HTTPS hostname redirect (pre-change copies kept as `.backup-2026-09-12`). *(Superseded 2026-09-12: the pin caused a boot-time bind race; see "HTTPS listener unpinned" below.)*
- Registry player URLs flipped to `https://`; MCP service `STREAM_SERVER_URL=https://gmktec.home.arpa`.

Verification performed:

- `openssl verify` chain/purpose/hostname OK; cert↔key public-key hashes match (pre- and post-issuance).
- `Verify return code: 0 (ok)` from live `s_client` against our CA; 443 bound to `10.1.1.5` only, not `*`.
- All endpoints 200 over TLS (apps pages, assets, registry, WebRTC player, snapshot JPEG); `/mcp/` 301; port-80 redirect confirmed with correct Location headers.
- MCP handshake over HTTPS; `get_web_player_url` and `get_cameras` emit `https://` URLs.
- Post-issuance age archive decrypt-verified and hash-matched local/SMB copies.
- Backup checksums all passed.

### CA client distribution endpoint

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/CA_DISTRIBUTE.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{SERVER_IP}}`: `10.1.1.5`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folder:

- `{{BACKUP_PATH}}/ca-distribute-{{DATETIME_STAMP}}`

Backed up data:

- `post-change-state.txt` — out-of-band trust anchor (cert fingerprint `09:9F:3C:3B…89:A9:4F`, PEM file sha256 `6e9e7b24…ba8100`), distribution dir listing, checksum self-verify, all five endpoint checks, negative checks (camera-net 403, dir listing 403), non-CA redirect, nginx state.
- `final-srv-camera-pki.tar` — the public distribution directory (cert ×2, checksums ×2, README). Public material only; contains no secrets.
- `final-etc-nginx-sites-available.tar` / `final-etc-nginx-sites-enabled.tar` / `final-etc-nginx-conf.d.tar` — nginx config with the `/ca/` HTTP distribution location; these are the **newest complete nginx configs — restore from this folder last** among config-stage backups (supersedes the site-cert backup's sites configs). Includes the `mediamtx.backup-ca-2026-09-12` pre-edit copy.
- `final-docs-CA_DISTRIBUTE.md` — final runbook.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Created `/srv/camera-pki/public` (root 755) with the public CA cert under both `.crt.pem` and `.crt` names (identical bytes), both `sha256sum`-format checksum files, and a README with the real file hash and certificate fingerprint.
- Extended the port-80 `gmktec.home.arpa` block to serve `/ca/` over HTTP (alias, autoindex off, allow 10.1.1.0/24 + 192.168.68.0/22, deny all); all other paths still 301 to HTTPS.

Verification performed:

- All five distribution endpoints 200; cert endpoints serve `application/x-x509-ca-cert`; checksum files verify with `sha256sum --check`.
- Camera network (10.2.2.0/24) denied with 403; directory listing 403; `/cameras/` redirect intact.
- `nginx -T` shows exactly 2 `server_name gmktec` blocks; `nginx -t` passes.
- Fingerprint of the distributed cert matches the authoritative CA (single source: age-archived CA state).
- Backup checksums all passed.

The certificate SHA-256 fingerprint in `post-change-state.txt` is this site's recorded
out-of-band trust anchor — clients should compare it against the admin-supplied value
before installing the distributed certificate.

## Reconstructing the CA distribution endpoint from backup

Use these instructions with `{{BACKUP_PATH}}/ca-distribute-{{DATETIME_STAMP}}`. All contents are public material — no private key is involved in this restore.

```bash
BACKUP_DIR="{{BACKUP_PATH}}/ca-distribute-{{DATETIME_STAMP}}"
sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-srv-camera-pki.tar" -C /
sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-available.tar" -C /
sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-enabled.tar" -C /
sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-conf.d.tar" -C /
sudo nginx -t && sudo systemctl reload nginx
cd /srv/camera-pki/public && sha256sum --check *.sha256
curl -s --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} -o /dev/null -w '%{http_code}\n' \
  http://{{SERVER_FQDN}}/ca/README.txt                                   # expect 200
curl -s --resolve {{SERVER_FQDN}}:80:{{SERVER_IP}} --head \
  http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem | head -1      # expect 200
openssl x509 -in /srv/camera-pki/public/camera-system-root-ca.crt.pem \
  -noout -fingerprint -sha256   # must match the fingerprint in post-change-state.txt
```

Expected restored state: five endpoints serve 200 over HTTP from `10.1.1.0/24`/`192.168.68.0/22` only; camera network gets 403; other paths still redirect to HTTPS.

### Local DNS (dnsmasq)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/DNS.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{SERVER_IP}}`: `10.1.1.5`
- `{{RVRS_SRV_IP}}`: `5.1.1.10`
- `{{UPSTREAM_DNS}}`: `192.168.68.1`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folder:

- `{{BACKUP_PATH}}/dns-{{DATETIME_STAMP}}`

Backed up data:

- `post-change-state.txt` — variables, package versions (dnsmasq/dnsmasq-base 2.92-1ubuntu0.4), service state, combined unit (incl. drop-in), `ss` listener table, live dig verification (A, forwarding, NXDOMAIN, PTR).
- `final-etc-dnsmasq.d.tar` — camera-system.conf (listen-address 10.1.1.5, `local=/home.arpa/`, address mapping, `no-resolv` + explicit server, PTR record). Backup archives must never be placed inside `/etc/dnsmasq.d/` — the conf-dir glob would load them; keep them in this SMB folder.
- `final-etc-dnsmasq.conf.tar` — main config with line 684 `conf-dir=/etc/dnsmasq.d/,*.conf` uncommented.
- `final-etc-systemd-system-dnsmasq.service.d.tar` — drop-in blanking `ExecStartPost=`/`ExecStop=` (resolver-registration hooks).
- `final-etc-default-dnsmasq.tar` — `IGNORE_RESOLVCONF=yes`.
- `final-docs-DNS.md` — final runbook.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Installed `dnsmasq` 2.92 using the mask-during-install procedure (DNS.md §2); service enabled and active.
- Created `/etc/dnsmasq.d/camera-system.conf`; validated with `dnsmasq --test` before start.
- Systemd drop-in disables resolver-registration hooks; `IGNORE_RESOLVCONF=yes` set.
- dnsmasq bound to `10.1.1.5:53` only (UDP+TCP); systemd-resolved untouched on loopback stubs.

Verification performed:

- A record `gmktec.home.arpa → 10.1.1.5`; public forwarding works via 192.168.68.1; `*.home.arpa` unknown names NXDOMAIN (not forwarded); PTR `5.1.1.10.in-addr.arpa → gmktec.home.arpa`.
- Listeners: no dnsmasq on 10.2.2.1, 0.0.0.0, or loopback.
- `/etc/hosts` intentionally untouched (`127.0.1.1 gmktec` remains) — note there are two local resolution sources of truth; dnsmasq serves LAN clients, hosts serves the host itself.
- Backup checksums all passed.
- Client-side nslookup tests (DNS.md §10) and advertising 10.1.1.5 via the LAN DHCP server are off-box tasks.

## Reconstructing the local DNS server from backup

Use these instructions with `{{BACKUP_PATH}}/dns-{{DATETIME_STAMP}}`. No private keys are involved.

1. Install dnsmasq using the mask procedure (the default service must not start unrestricted):

   ```bash
   sudo systemctl mask dnsmasq.service
   sudo apt-get update && sudo apt-get install -y dnsmasq
   ```

2. Restore the configuration files, drop-in, and defaults (restores the conf-dir enable and camera config together):

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/dns-{{DATETIME_STAMP}}"
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-dnsmasq.conf.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-dnsmasq.d.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-systemd-system-dnsmasq.service.d.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-default-dnsmasq.tar" -C /
   ```

3. Unmask, validate, and start (full restart semantics — `reload` does not activate directives like `ptr-record`):

   ```bash
   sudo systemctl unmask dnsmasq.service
   sudo systemctl daemon-reload
   sudo dnsmasq --test
   sudo systemctl enable --now dnsmasq.service
   ```

4. Verify reconstruction:

   ```bash
   sudo ss -lntup 'sport = :53'                       # dnsmasq on 10.1.1.5 only; resolved on loopback
   dig @10.1.1.5 gmktec.home.arpa +noall +answer      # 10.1.1.5
   dig @10.1.1.5 ubuntu.com +noall +answer            # forwarded answers
   dig @10.1.1.5 x.home.arpa +noall +comments | grep -o NXDOMAIN
   dig @10.1.1.5 -x 10.1.1.5 +noall +answer           # PTR to gmktec.home.arpa
   ```

Expected restored state matches `post-change-state.txt`: enabled+active service, private A/PTR records, upstream forwarding via 192.168.68.1, `home.arpa` NXDOMAIN isolation, binding to `10.1.1.5:53` only.

## Reconstructing the DHCP/Kea server from backup

Use these instructions with a selected backup folder such as `{{BACKUP_PATH}}/dhcp-{{DATETIME_STAMP}}`.

1. Install required packages:

   ```bash
   sudo apt-get update
   sudo apt-get install -y kea-dhcp4-server
   ```

2. Restore NetworkManager connection profiles:

   **NOTE (2026-09-13 restore verification):** `final-etc-NetworkManager-system-connections.tar`
   is EMPTY (directory entry only — NetworkManager did not store the profiles at that path).
   Restoring it is a silent no-op. Recreate the profile with nmcli per DHCP.md §1 instead:

   ```bash
   sudo nmcli connection add type ethernet ifname {{PRVT_CAMERA_NET_EN_NAME}} \
     con-name isolated ipv4.method manual ipv4.addresses 10.2.2.1/24 \
     ipv4.never-default yes ipv4.ignore-auto-dns yes ipv6.method disabled \
     connection.autoconnect yes
   sudo nmcli connection modify isolated ipv4.gateway "" ipv4.dns "" ipv4.routes ""
   sudo nmcli connection up isolated
   ```

3. Restore Kea configuration and lease data:

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/dhcp-{{DATETIME_STAMP}}"
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-kea.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-var-lib-kea.tar" -C /
   sudo chown root:_kea /etc/kea/kea-dhcp4.conf
   sudo chmod 640 /etc/kea/kea-dhcp4.conf
   ```

4. Restore persistent forwarding isolation:

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/dhcp-{{DATETIME_STAMP}}"
   sudo cp -a "$BACKUP_DIR/final-90-isolated.conf" /etc/sysctl.d/90-isolated.conf
   sudo sysctl --system
   ```

5. Validate and start services:

   ```bash
   sudo -u _kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
   sudo systemctl enable --now kea-dhcp4-server
   sudo systemctl restart kea-dhcp4-server
   ```

6. Verify reconstruction:

   ```bash
   nmcli device show {{PRVT_CAMERA_NET_EN_NAME}}
   ip address show dev {{PRVT_CAMERA_NET_EN_NAME}}
   ip route show dev {{PRVT_CAMERA_NET_EN_NAME}}
   sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
   systemctl is-active kea-dhcp4-server
   ```

   NOTE (2026-09-14 correction): `ss -ulpn | grep ':67'` IS the authoritative
   listening check for Kea — it shows `10.2.2.1:67` plus the pid whenever Kea
   has a socket open (an earlier note here claiming raw AF_PACKET sockets are
   invisible to `ss` was a misdiagnosis: the empty result during the 2026-09-13
   restore meant Kea had no socket open at all). Empty output = failure;
   additionally confirm a fresh `DHCP4_LEASE_ALLOC` after a client connects.
   Do NOT rely on lease-file rows alone — step 3 restores
   `/var/lib/kea/kea-leases4.csv`, so stale rows are present by construction.

   ```bash
   sudo ss -ulpn | grep ':67'   # must be non-empty
   journalctl -u kea-dhcp4-server --since "-2 min" --no-pager | grep -E 'DHCPREQUEST|DHCPACK'
   sudo grep -v '^#' /var/lib/kea/kea-leases4.csv   # active leases appear as rows
   ```

Expected restored state:

- `{{PRVT_CAMERA_NET_EN_NAME}}` has `10.2.2.1/24`.
- No default route exists through `{{PRVT_CAMERA_NET_EN_NAME}}`.
- Forwarding values are both `0`.
- `kea-dhcp4-server` is active and listening on UDP port `67`.

## Reconstructing the MediaMTX server from backup

Use these instructions with a selected backup folder such as `{{BACKUP_PATH}}/mediamtx-{{DATETIME_STAMP}}`.

1. Install prerequisite package and restore the MediaMTX system user:

   ```bash
   sudo apt-get update
   sudo apt-get install -y nginx
   getent group mediamtx >/dev/null || sudo groupadd --system mediamtx
   id mediamtx >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g mediamtx mediamtx
   sudo install -d -m 0750 -o mediamtx -g mediamtx /etc/mediamtx /var/lib/mediamtx /var/log/mediamtx
   ```

2. Restore MediaMTX binary, configuration, service unit, and state:

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/mediamtx-{{DATETIME_STAMP}}"
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-usr-local-bin-mediamtx.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-mediamtx.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-systemd-system-mediamtx.service.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-var-lib-mediamtx.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-var-log-mediamtx.tar" -C /
   sudo chown -R mediamtx:mediamtx /etc/mediamtx /var/lib/mediamtx /var/log/mediamtx
   sudo chmod 640 /etc/mediamtx/mediamtx.yml
   sudo chmod 755 /usr/local/bin/mediamtx
   ```

3. Restore nginx site configuration:

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/mediamtx-{{DATETIME_STAMP}}"
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-available.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-enabled.tar" -C /
   sudo nginx -t
   ```

4. Reload services:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now mediamtx
   sudo systemctl restart mediamtx
   sudo systemctl reload nginx
   ```

5. Verify reconstruction:

   ```bash
   /usr/local/bin/mediamtx --version
   systemctl is-enabled mediamtx
   systemctl is-active mediamtx
   sudo nginx -t
   curl -fsS http://{{SERVER_FQDN}}/
   curl -sS -o /tmp/webrtc-check.out -w '%{http_code}\n' http://{{SERVER_FQDN}}/webrtc/DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1/
   sudo ss -tulpn | grep -E ':(80|8554|8889|8189)\b'
   sudo journalctl -u mediamtx -n 120 --no-pager
   ```

Expected restored state:

- `/usr/local/bin/mediamtx --version` returns `v1.21.0`.
- `mediamtx` is enabled and active.
- nginx configuration test passes.
- `http://{{SERVER_FQDN}}/` returns `MediaMTX server at {{SERVER_FQDN}}`.
- A configured `/webrtc/<serial>/<profile>/` path returns HTTP `200` through nginx.
- MediaMTX listens on RTSP `127.0.0.1:8554`, WebRTC TCP `127.0.0.1:8889`, and WebRTC UDP `:8189`.
- nginx listens on TCP `80`.
- MediaMTX logs show the configured camera paths becoming available and online.

## Reconstructing the snapshot proxy from backup

Use these instructions with a selected backup folder such as `{{BACKUP_PATH}}/snapshot-{{DATETIME_STAMP}}`.

1. Verify the service user and repository access exactly as deployed:

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/snapshot-{{DATETIME_STAMP}}"
   id {{SERVER_USER}}
   sudo -u {{SERVER_USER}} {{REPO_PATH}}/onvif-mcp/.venv/bin/python -c 'import sys; print(sys.version.split()[0])'
   ```

2. Restore route table, service unit, source snapshot, and nginx config:

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/snapshot-{{DATETIME_STAMP}}"
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-onvif-mcp.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-systemd-system-snapshot-proxy.service.tar" -C /
   SNAPSHOT_PROXY_ARCHIVE=$(find "$BACKUP_DIR" -maxdepth 1 -name 'final-*-onvif-mcp-services-snapshot_proxy.py.tar' -print -quit)
   sudo tar --xattrs --acls --selinux -xpf "$SNAPSHOT_PROXY_ARCHIVE" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-available.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-enabled.tar" -C /
   sudo chgrp {{SERVER_USER}} /etc/onvif-mcp
   sudo chmod 0750 /etc/onvif-mcp
   sudo chown root:{{SERVER_USER}} /etc/onvif-mcp/snapshot_routes.json
   sudo chmod 0640 /etc/onvif-mcp/snapshot_routes.json
   ```

3. Reload services:

   ```bash
   sudo nginx -t
   sudo systemctl daemon-reload
   sudo systemctl enable --now snapshot-proxy
   sudo systemctl restart snapshot-proxy
   sudo systemctl reload nginx
   ```

4. Verify reconstruction:

   ```bash
   systemctl is-enabled snapshot-proxy
   systemctl is-active snapshot-proxy
   sudo ss -lntpe | grep ':8891'        # expect 127.0.0.1:8891 only
   sudo nginx -t
   curl -s -o /tmp/snapshot-check.jpg -D /tmp/snapshot-check.headers \
     -w '%{http_code} %{content_type}\n' \
     http://{{SERVER_FQDN}}/snapshot/DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1/
   file /tmp/snapshot-check.jpg
   grep -i '^Cache-Control:.*no-store' /tmp/snapshot-check.headers
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8891/snapshot/NOSUCH/Profile_1/
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8891/garbage
   ```

Expected restored state:

- `snapshot-proxy` is enabled and active.
- It listens only on loopback `127.0.0.1:8891`.
- nginx configuration test passes.
- A configured `/snapshot/<serial>/<profile>/` URL through nginx returns `200 image/jpeg`, a real JPEG body, and `Cache-Control: no-store`.
- Unknown route returns `404`; garbage path returns `400`.

## Reconstructing the camera applications from backup

Use these instructions with a selected backup folder such as `{{BACKUP_PATH}}/apps-{{DATETIME_STAMP}}`. Requires MediaMTX and the snapshot proxy already reconstructed (their backups contain the overlapping nginx site configs; the apps backup's site configs are the newest complete set and supersede them).

1. Create the web user and grant repo traversal exactly as deployed:

   ```bash
   id webcam >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin webcam
   getent group {{SERVER_USER}} >/dev/null || echo "ERROR: group {{SERVER_USER}} missing"
   id -nG webcam | grep -qw {{SERVER_USER}} || sudo usermod -aG {{SERVER_USER}} webcam
   ```

2. Restore nginx main config, site configs, the site directory, and app sources:

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/apps-{{DATETIME_STAMP}}"
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-nginx.conf.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-available.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-enabled.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-onvif-mcp.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-home-{{SERVER_USER}}-onvif-mcp-apps.tar" -C /
   sudo chown root:{{SERVER_USER}} /etc/onvif-mcp/camera_registry.json
   sudo chmod 0640 /etc/onvif-mcp/camera_registry.json
   ```

3. Restart nginx (a restart, not a reload — the `user` directive in `nginx.conf` only takes effect on restart):

   ```bash
   sudo nginx -t
   sudo systemctl restart nginx
   ```

4. Verify reconstruction:

   ```bash
   grep '^user' /etc/nginx/nginx.conf                       # expect: user webcam;
   for u in /cameras/ /multiview/ /outputs/camera_registry.json \
            /cameras/styles.css /cameras/app.js /multiview/app.js; do
     printf "%-35s %s\n" "$u" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1$u)"
   done                                                     # expect all 200
   curl -sI http://127.0.0.1/cameras | head -1              # expect 301
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/outputs/   # expect 404
   curl -s -o /dev/null -w '%{http_code} %{content_type}\n' \
     http://{{SERVER_FQDN}}/snapshot/DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1/   # expect 200 image/jpeg
   ```

Expected restored state:

- nginx workers run as `webcam`, a member of the `{{SERVER_USER}}` group.
- `/cameras/` and `/multiview/` serve the app pages; `/outputs/camera_registry.json` serves the 7-camera runtime registry.
- All registry player URLs return `200` through `/webrtc/` (requires MediaMTX reconstructed).
- Snapshot routes still serve JPEGs (the apps vhost preserves the `/snapshot/` location).

## Reconstructing the ONVIF MCP HTTP server from backup

Use these instructions with a selected backup folder such as `{{BACKUP_PATH}}/mcp-http-{{DATETIME_STAMP}}`. This backup holds the newest complete nginx site configs (vhost includes `/webrtc/`, `/snapshot/`, apps locations, and `/mcp`) — restore it last among the HTTP-stage backups.

1. Restore the repository virtualenv (or rebuild it):

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/mcp-http-{{DATETIME_STAMP}}"
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-home-{{SERVER_USER}}-onvif-mcp-.venv.tar" -C /
   # alternative rebuild from source:
   # ( cd {{REPO_PATH}}/onvif-mcp && uv sync --frozen )
   # NOTE (2026-09-13 restore verification): this build of onvif-mcp-http IGNORES --help
   # and starts serving — `--help` hangs the shell. Probe non-blockingly instead:
   timeout 10 {{REPO_PATH}}/onvif-mcp/.venv/bin/python -c "import importlib.metadata as m; print(m.version('onvif-mcp-http'))"; echo "executable exit: $?"
   ```

2. Restore the systemd unit and nginx site configs:

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/mcp-http-{{DATETIME_STAMP}}"
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-systemd-system-onvif-mcp-http.service.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-available.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-enabled.tar" -C /
   sudo chmod 644 /etc/systemd/system/onvif-mcp-http.service   # credentials visible to root only via file mode policy of choice
   ```

3. Start services:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now onvif-mcp-http
   sudo nginx -t && sudo systemctl reload nginx
   ```

4. Verify reconstruction:

   ```bash
   systemctl is-enabled onvif-mcp-http
   systemctl is-active onvif-mcp-http
   sudo ss -tlnp | grep ':8001'                              # expect 127.0.0.1:8001 only
   sudo nginx -T | grep -c 'server_name {{SERVER_FQDN}}'     # expect exactly 1
   curl -s -o /dev/null -w '%{http_code}\n' http://{{SERVER_FQDN}}/mcp/   # expect 301
   ```

   Then run the full MCP handshake from the runbook's "MCP Protocol Usage" section against `http://{{SERVER_FQDN}}/mcp` (initialize → initialized → tools/list → get_cameras). Note: bare-loopback POSTs return 421/406 by upstream host-validation design — always use the FQDN or a `Host:` header.

Expected restored state:

- `onvif-mcp-http` is enabled and active, listening only on `127.0.0.1:8001`.
- Exactly one `server_name {{SERVER_FQDN}}` block exists; apps, snapshot, and webrtc endpoints still return 200.
- MCP handshake completes; `tools/list` returns 29 tools; `get_cameras` emits `web_player_url` values pointing at `http://{{SERVER_FQDN}}/webrtc/`.

## Reconstructing the HTTPS configuration from backup

Use these instructions with a selected backup folder such as `{{BACKUP_PATH}}/site-cert-{{DATETIME_STAMP}}`. This backup holds the complete nginx configuration **as of HTTPS deployment** — if a `ca-distribute-*` backup also exists (CA_DISTRIBUTE.md), restore the sites configs from THAT folder instead (it adds the `/ca/` distribution location and supersedes these); restore HTTPS configs last among the HTTP/MCP-stage backups either way.

The CA itself must be restored first per CREATE_CA_CERT.md §13 (GPG key → vault → age archive). The **server private key is not in any archive** — regenerate and reissue rather than restore:

1. Restore the server key and reissue a certificate (SITE_CERT.md §1–§6 + §8): generate a fresh 3072-bit key in `/etc/nginx/tls/`, create the CSR, stage it into the restored CA, sign with `openssl ca`, verify chain/purpose/hostname and key match, then install cert/CA/chain with modes 600/644. (If the old key is still intact at `/etc/nginx/tls/`, skip regeneration and reuse it — verify its hash against the archived public cert in `final-etc-nginx-tls-public.tar`.)

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/site-cert-{{DATETIME_STAMP}}"
   # public material (leaf/CA/chain/CSR) for comparison or reuse if the key survived:
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-tls-public.tar" -C /
   ```

2. Restore nginx configuration, site directory, and MCP unit:

   ```bash
   BACKUP_DIR="{{BACKUP_PATH}}/site-cert-{{DATETIME_STAMP}}"
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-nginx.conf.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-conf.d.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-available.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-enabled.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-onvif-mcp.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-systemd-system-onvif-mcp-http.service.tar" -C /
   ```

3. Reload everything:

   ```bash
   # RE-APPLY THE UNPINNED-LISTENER AMENDMENT (see "HTTPS listener unpinned" below):
   # this backup's conf.d archive still contains `listen 10.1.1.5:443 ssl;`.
   sudo sed -i 's/listen 10.1.1.5:443 ssl;/listen 443 ssl;/' /etc/nginx/conf.d/{{SERVER_FQDN}}.conf
   sudo mkdir -p /etc/systemd/system/nginx.service.d
   printf '[Unit]\nWants=network-online.target\nAfter=network-online.target\n' | \
     sudo tee /etc/systemd/system/nginx.service.d/wait-for-network.conf
   sudo nginx -t
   sudo systemctl daemon-reload
   sudo systemctl restart nginx onvif-mcp-http
   ```

4. Verify reconstruction (CA file is root-readable only — use sudo):

   ```bash
   sudo ss -lntp 'sport = :443'                                # expect 0.0.0.0:443 (post-amendment; see unpinned-listener note)
   sudo nginx -T | grep -c 'server_name {{SERVER_FQDN}}'       # expect 2 (redirect + 443 block)
   sudo curl --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
     --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
     --head -s -o /dev/null -w '%{http_code}\n' https://{{SERVER_FQDN}}/cameras/   # 200
   sudo curl -s --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
     --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
     -o /tmp/r.jpg -w '%{http_code} %{content_type}\n' \
     https://{{SERVER_FQDN}}/snapshot/DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1/   # 200 image/jpeg
   curl -sI http://{{SERVER_IP}}/cameras/ | grep -i '^location'  # redirects to https://{{SERVER_FQDN}}/cameras/
   systemctl show onvif-mcp-http --property=Environment | grep -o 'STREAM_SERVER_URL=[^ ]*'
   ```

Expected restored state:

- HTTPS served on all interfaces at `:443` (post-amendment; `server_name` scopes the
  vhost) — the original all-interfaces concern is noted under FIREWALL.md; port 80
  redirects to the FQDN.
- TLS chain verifies against the private CA (`Verify return code: 0`); cert/key hashes match.
- Apps, registry (all-`https` player URLs), `/webrtc/`, `/snapshot/` work over TLS; `/mcp` proxied; `STREAM_SERVER_URL=https://{{SERVER_FQDN}}`.

### Keycloak OAuth server

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/KEYCLOAK.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{SERVER_IP}}`: `10.1.1.5`
- `{{REPO_PATH}}`: `/home/stephen`
- `{{SERVER_USER}}`: `stephen`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Deployment constants (KEYCLOAK.md §1, non-secret):

- Realm `mcp`, scope `mcp:tools`, login user `mcp-user`, admin `keycloak-admin`
- Images pinned: `postgres:17-alpine`, `quay.io/keycloak/keycloak:26.7.0`
- Docker 29.1.3, Docker Compose 2.40.3 (Ubuntu `docker.io` + `docker-compose-v2`)

Backup folder:

- `{{BACKUP_PATH}}/keycloak-{{DATETIME_STAMP}}`

Backed up data:

- `pre-change-state.txt` — hostname/DNS/IP, docker absent, nginx, listener table, MCP service state, full `nginx -T`, `/opt/keycloak` absent.
- `etc-nginx-conf.d.tar` / `etc-nginx-sites-available.tar` / `etc-nginx-sites-enabled.tar` — pre-change nginx configs (no `/auth/` locations).
- `etc-systemd-system.tar` — pre-change systemd units (no keycloak backup unit, no MCP oauth drop-in).
- `post-change-state.txt` — variable mapping, file modes, container state, pinned image IDs, realm settings, realm users, client scope + mapper JSON, DCR policy component configs, DCR client list with active client_id, nginx `server_name` count, listener table, MCP OAuth env (non-secret), endpoint verification results, regression checks, dump listing, restore-test evidence, CA trust file, Hermes token file modes (contents never recorded).
- `final-opt-keycloak.tar` — final `/opt/keycloak/` including `compose.yaml`, `.env`, `admin.pass`, `mcp-user.pass`. Sensitive: contains the PostgreSQL password and both account passwords in root-only files; restore must re-apply mode 750 dir / 600 secrets.
- `final-var-backups-keycloak-postgres.tar` — the latest `keycloak-*.dump` (custom format, zstd). Sensitive: contains password hashes, the DCR registration access token, and the active Hermes client registration. This is the database restore source.
- `final-usr-local-sbin-backup-keycloak-postgres.tar` — backup script (mode 750).
- `final-etc-systemd-system.tar` — units including `keycloak-postgres-backup.service` and `onvif-mcp-http.service.d/oauth.conf`. Sensitive: oauth drop-in is non-secret; earlier entries' unit credentials apply.
- `final-etc-nginx-conf.d.tar` / `-sites-available.tar` / `-sites-enabled.tar` — final nginx configs with `/auth/` and `/.well-known/oauth-protected-resource/mcp`; newest complete nginx set — restore last among config-stage backups.
- `final-etc-nginx-backups.tar` — `/etc/nginx/backups/` including the runbook-mandated `gmktec.home.arpa.conf.pre-keycloak` copy.
- `final-docs-KEYCLOAK.md` — final runbook.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Installed `docker.io` 29.1.3 + `docker-compose-v2` 2.40.3.
- Deployed `/opt/keycloak/compose.yaml`: postgres:17-alpine (named volume `keycloak_keycloak_postgres_data`) + keycloak 26.7.0 bound `127.0.0.1:8080`, relative path `/auth`, hostname `https://gmktec.home.arpa/auth`, xforwarded proxies.
- Permanent admin `keycloak-admin` (master, role `admin`, password in `/opt/keycloak/admin.pass`); bootstrap `admin` user and both `KC_BOOTSTRAP_ADMIN_*` variables removed; container force-recreated.
- Realm `mcp`: ssoSessionIdle 8h, ssoSessionMax 7d, accessToken 300s, rotating single-use refresh tokens; login user `mcp-user` (password `/opt/keycloak/mcp-user.pass`).
- Client scope `mcp:tools` (uuid `5c6dae4d-3e85-4ffd-a68a-5f7865aef59d`) with `mcp-server-audience` mapper → `https://gmktec.home.arpa/mcp`; all three scope attributes true.
- Anonymous DCR policies: allowed scope `mcp:tools` + default scopes, trusted hosts `localhost, 127.0.0.1, 172.18.0.1 (compose gateway), 10.1.1.5 (server LAN IP)`, max clients 20.
- nginx HTTPS vhost extended with `/auth/` proxy and `/.well-known/oauth-protected-resource/mcp` proxy; `/mcp/` redirect already HTTPS.
- Private CA installed to `/usr/local/share/ca-certificates/camera-system-root-ca.crt`; discovery verified without `-k`.
- MCP OAuth drop-in `/etc/systemd/system/onvif-mcp-http.service.d/oauth.conf` (issuer, resource URL, loopback JWKS).
- DCR smoke test passed (201) and test client deleted.
- Hermes `camera-new` OAuth client registered via headless login; token files at `~/.hermes/mcp-tokens/camera-new.*` (mode 600, never archived); `hermes mcp test` lists 29 tools.
- PostgreSQL backup script + `keycloak-postgres-backup.service` (manual one-shot, 14-day retention); first dump taken after DCR client existed; isolated restore test passed (`realms=2 users=2 clients=14`) and test DB dropped.

Verification performed:

- Discovery 200 with exact issuer; `S256` and `mcp:tools` published.
- Unauthenticated `/mcp` → 401 with `resource_metadata` pointing at `/.well-known/oauth-protected-resource/mcp`; metadata JSON exact.
- DCR policies re-read per component ID (collection view collapses config to `{}`).
- `/cameras/`, `/multiview/`, registry, snapshot JPEG regression all 200 over TLS.
- Postgres containers healthy; `pg_restore --list` catalog readable; restore test nonzero row counts.
- `post-change-state.txt` scanned for secret leakage — filenames and non-secret values only.
- Backup checksums all passed.

## Reconstructing the Keycloak OAuth server from backup

Use these instructions with `{{BACKUP_PATH}}/keycloak-{{DATETIME_STAMP}}`. This backup holds the newest complete nginx configs (restore them last among config-stage backups) and the only copy of the Keycloak secrets and database.

1. Install Docker and Compose, then restore the deployment directory (secrets included):

   ```bash
   sudo apt-get update
   sudo apt-get install -y docker.io docker-compose-v2
   BACKUP_DIR="{{BACKUP_PATH}}/keycloak-{{DATETIME_STAMP}}"
   # NOTE (2026-09-13 restore verification): the archive root is `keycloak/`, NOT `opt/...`.
   # Extract into /opt directly (`-C / opt` fails with "Not found in archive"):
   sudo mkdir -p /opt
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-opt-keycloak.tar" -C /opt
   sudo chown -R root:root /opt/keycloak
   sudo chmod 750 /opt/keycloak
   sudo chmod 600 /opt/keycloak/.env /opt/keycloak/admin.pass /opt/keycloak/mcp-user.pass
   sudo chmod 640 /opt/keycloak/compose.yaml
   ```

2. Start the stack (the compose file pins image tags; `up -d` pulls them) and wait for readiness:

   ```bash
   sudo docker compose --project-directory /opt/keycloak up -d
   curl --fail --retry 24 --retry-all-errors --retry-delay 5 \
     -sS -o /dev/null -w 'HTTP %{http_code}\n' \
     http://127.0.0.1:8080/auth/realms/master/.well-known/openid-configuration
   ```

   Note: the postgres data volume starts empty on a fresh host. Before or after first
   start, restore the database from the archived dump into it:

   ```bash
   # stop keycloak first if it already started against an empty DB
   sudo docker compose --project-directory /opt/keycloak stop keycloak
   sudo docker compose --project-directory /opt/keycloak exec -i postgres \
     createdb --username=keycloak keycloak 2>/dev/null || true
   sudo sh -c 'tar -xOf "$0" var/backups/keycloak-postgres/$(tar -tf "$0" | grep -o "keycloak-[^/]*\.dump$" | head -1 | xargs basename) 2>/dev/null | docker compose --project-directory /opt/keycloak exec -i postgres pg_restore --username=keycloak --dbname=keycloak --exit-on-error' "$BACKUP_DIR/final-var-backups-keycloak-postgres.tar"
   sudo docker compose --project-directory /opt/keycloak up -d keycloak
   ```

   Simpler alternative on a fresh host (RECOMMENDED — verified 2026-09-13): the dump tar's
   root is `keycloak-postgres-backups/`, not `var/backups/keycloak-postgres/`, and dumps are
   mode 600 root, so a plain `< file` redirect from an agent shell fails with permission
   denied. Extract, move into the canonical path, then pipe via sudo:

   ```bash
   sudo tar -xf "$BACKUP_DIR/final-var-backups-keycloak-postgres.tar" -C /var/backups
   sudo mkdir -p /var/backups/keycloak-postgres
   sudo mv -n /var/backups/keycloak-postgres-backups/*.dump /var/backups/keycloak-postgres/
   sudo rmdir /var/backups/keycloak-postgres-backups
   sudo chmod 700 /var/backups/keycloak-postgres
   # fresh postgres init already creates and owns the keycloak DB; drop+recreate for a
   # clean restore:
   sudo docker compose --project-directory /opt/keycloak exec -T postgres \
     psql --username=keycloak --dbname=postgres -c "DROP DATABASE keycloak;"
   sudo docker compose --project-directory /opt/keycloak exec -T postgres \
     createdb --username=keycloak --owner=keycloak keycloak
   sudo cat /var/backups/keycloak-postgres/<newest>.dump | \
     sudo docker compose --project-directory /opt/keycloak exec -i postgres \
     pg_restore --username=keycloak --dbname=keycloak --exit-on-error
   sudo docker compose --project-directory /opt/keycloak up -d keycloak
   ```

   The one-line tar-pipe idiom above it has NOT been verified on restore; prefer the
   explicit sequence.

3. Restore the CA trust, backup script, systemd units, and nginx config:

   ```bash
   sudo install -m 644 /etc/nginx/tls/camera-system-root-ca.crt.pem \
     /usr/local/share/ca-certificates/camera-system-root-ca.crt 2>/dev/null || true
   sudo update-ca-certificates
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-usr-local-sbin-backup-keycloak-postgres.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-systemd-system.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-conf.d.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-available.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-nginx-sites-enabled.tar" -C /
   ```

   Note: restoring the whole `/etc/systemd/system` and nginx dirs brings every
   stage's units/config forward at once — this folder is the newest complete set;
   do not restore older stage folders after it.

4. Reload services:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart onvif-mcp-http
   sudo nginx -t && sudo systemctl restart nginx
   ```

5. Verify reconstruction:

   ```bash
   sudo docker compose --project-directory /opt/keycloak ps       # both up, postgres healthy
   curl -sS -o /dev/null -w '%{http_code}\n' \
     https://{{SERVER_FQDN}}/auth/realms/mcp/.well-known/openid-configuration   # 200
   curl -sS -D - -o /dev/null https://{{SERVER_FQDN}}/mcp 2>&1 | grep -E '^HTTP|www-authenticate'  # 401 + resource_metadata
   curl -sS https://{{SERVER_FQDN}}/.well-known/oauth-protected-resource/mcp    # exact metadata JSON
   sudo ss -ltnp | grep ':8080'                                   # 127.0.0.1:8080 only
   ```

   Then re-authenticate `kcadm.sh` per KEYCLOAK.md §4 (password from
   `/opt/keycloak/admin.pass`) and confirm the realm, scope, and DCR policy
   components match `post-change-state.txt`. The archived database already
   contains the active Hermes DCR client; existing Hermes token files on clients
   remain valid only while the Keycloak signing keys are unchanged — a fresh
   database restored from this dump includes the original keys. If the OAuth
   client's tokens fail, re-run the KEYCLOAK.md §13 login.

   NOTE (2026-09-13 restore verification): for the Hermes-side login (KEYCLOAK.md §13),
   the `ssl_verify` path must be `/etc/ssl/certs/camera-system-root-ca.pem` —
   `update-ca-certificates` installs the `.crt` source under a `.pem` link in
   `/etc/ssl/certs`; the literal `<ca-name>.pem` placeholder in §13.1 resolves there.
   Verified working flow: write the config entry (`enabled: false`), run the login under
   `HERMES_HOME=<isolated-dir>` with `env -u DISPLAY -u WAYLAND_DISPLAY`, complete the
   browser step with `scripts/kc-headless-login-driver.py <auth-url>`, copy the three
   token files to `~/.hermes/mcp-tokens/` (mode 600), shred the isolated copies,
   `hermes mcp test <name>` (expect 29 tools), then set `enabled: true`.

Expected restored state matches `post-change-state.txt`: discovery 200, 401 with
correct metadata, 29 tools for `camera-new`, regression endpoints 200 over TLS,
Keycloak bound to loopback only.

### Browser authentication gate (STREAM_AUTH / oauth2-proxy)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/STREAM_AUTH.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa` (user-supplied value `gmktc.home.arpa` was a typo — it does not resolve and is outside the certificate SAN; corrected with user awareness, standard placeholder-verification procedure)
- `{{SERVER_IP}}`: `10.1.1.5`
- `{{REPO_PATH}}`: `/home/stephen`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`
- Defaults as documented: realm `mcp`, browser client `camera-web`, login user `mcp-user`, oauth2-proxy `v7.15.3` on `127.0.0.1:4180`

Backup folder:

- `{{BACKUP_PATH}}/stream-auth-{{DATETIME_STAMP}}`

Backed up data:

- `pre-change-state.txt` — services, container state, `.env` key names, listener table, full `nginx -T`, unauthenticated baseline.
- `etc-nginx-conf.d.tar` — pre-change HTTPS site (no oauth2 locations); `compose.yaml.pre-oauth2-proxy` — compose before the oauth2-proxy service was added.
- `.env.pre-oauth2-proxy.sha256` — hash of the pre-change `.env` only (content stays in the keycloak folder's `final-opt-keycloak.tar` — no duplicate secret copies on the share).
- `post-change-state.txt` — container state, oauth2-proxy image pin, listeners, file modes, `.env` key names + counts (values never), `camera-web` client representation with secret redacted, loopback ping/auth results, unauthenticated 302 behavior for all protected routes, HTTP→HTTPS snapshot redirect, MCP env non-secrets, Phase-9 driver PASS evidence, MCP regression (cookie-independent `get_snapshot`), dump verification, deviations list.
- `final-opt-keycloak.tar` — final `/opt/keycloak/` incl. updated `compose.yaml` (oauth2-proxy service), `.env` (+client/cookie secrets), `.env.pre-oauth2-proxy`, `gmktec.home.arpa.conf.pre-stream-auth` vhost copy, and the new `mcp-user.pass`-bearing set. Sensitive.
- `final-var-backups-keycloak-postgres.tar` — dumps incl. `keycloak-20260912T234716Z.dump` taken after `camera-web` existed (STREAM_AUTH §10 checkpoint; `pg_restore_exit=0`). Restore source. Sensitive.
- `final-etc-nginx-conf.d.tar` — HTTPS site with `/oauth2/*` support blocks and `auth_request` on all five protected route families; newest complete nginx config — restore last among config-stage backups.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Confidential client `camera-web` created via Admin REST (kcadm create path is unreliable per runbook); standard flow only, PKCE S256, exact redirect `https://{{SERVER_FQDN}}/oauth2/callback`, post-logout `/cameras/`, web origin exact, consent off; all 15 settings verified on the stored representation.
- `OAUTH2_PROXY_CLIENT_SECRET` + 32-byte URL-safe `OAUTH2_PROXY_COOKIE_SECRET` appended to `/opt/keycloak/.env` (mode 600 preserved, keys occur exactly once, stored secret equals live Keycloak secret, cookie secret decodes to 32 bytes); `.env.pre-oauth2-proxy` created 600.
- oauth2-proxy `v7.15.3` added to `/opt/keycloak/compose.yaml` (postgres/keycloak/volumes verified object-identical before write); bound `127.0.0.1:4180`; provider CA mounted read-only via `--provider-ca-file`.
- nginx HTTPS site: `/oauth2/auth` (body-less auth subrequest), `/oauth2/` (32k/64k buffers), `@oauth2_signin` relative-`rd` redirect; `auth_request` + cookie-forwarding quartet added exactly once to `/cameras/`, `/multiview/`, `= /outputs/camera_registry.json`, `/outputs/`, `/webrtc/`, `/snapshot/`; snapshot proxy headers/timeouts/no-cache preserved. Single reload.

Verification performed:

- oauth2-proxy loopback ping 200, unauthenticated auth check 401, listener `127.0.0.1:4180` only.
- All protected routes 302 → `/oauth2/start?rd=<path>`; direct snapshot returns no JPEG unauthenticated; HTTP snapshot entry 301→HTTPS then 302→login; 4180 not publicly exposed.
- `/oauth2/start` reaches Keycloak authorize with all PKCE/param names present (values never printed).
- Discovery still 200; `/mcp` still 401 with protected-resource metadata.
- Phase-9 driver RESULT=PASS: login lands exactly on requested route, ping 202 `Authenticated`, multiview no second login, WebRTC pass-through, in-session and fresh-session snapshots real JPEGs with `no-store`.
- MCP regression cookie-independent: `get_cameras` serves HTTPS-origin `web_snapshot_url` for all cameras; `get_snapshot` returns valid 1920×1080 JPEG via loopback; `SNAPSHOT_PROXY_URL` unset (loopback default); `hermes mcp test camera-new` connects with saved OAuth state, 29 tools.
- Public TLS chain verified against the private CA; no `-k` used anywhere.
- Backup checksums all passed.

Known deviations (recorded in `post-change-state.txt`): bare `/outputs/` answers 404 before auth (the `return 404` guard runs pre-authorization but serves no content; the only real file redirects to login correctly); slash-less `= /cameras`/`= /multiview` 301s left unauthenticated (redirect-only, no content exposed).

Human-confirmation items (out of driver scope by design): live video rendering in a browser after login (UDP ICE path) and images visibly displaying inside `/cameras/` and `/multiview/`.

## Reconstructing the browser authentication gate from backup

Use `{{BACKUP_PATH}}/stream-auth-{{DATETIME_STAMP}}`. This supersedes the keycloak folder's `compose.yaml`/`.env`/nginx configs and its dumps — restore this folder's artifacts after (not before) the Keycloak procedure, or simply use this folder's copies of `final-opt-keycloak.tar` and `final-etc-nginx-conf.d.tar` in place of the keycloak folder's.

1. Everything in "Reconstructing the Keycloak OAuth server from backup" steps 1–4, but substituting this folder's `final-opt-keycloak.tar`, `final-var-backups-keycloak-postgres.tar`, and `final-etc-nginx-conf.d.tar`. The compose file here includes the oauth2-proxy service; `up -d` starts all three containers.
2. Verify:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4180/ping                      # 200
   sudo ss -ltnp | grep ':4180'                                                              # loopback only
   curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://{{SERVER_FQDN}}/cameras/ # 302 /oauth2/start?rd=/cameras/
   ```

3. Then run the runbook's own §9 driver end-to-end — it is the authoritative functional restore test:

   ```bash
   cd {{REPO_PATH}}/onvif-mcp && sudo python3 scripts/stream_auth_step9_driver.py \
     --origin https://{{SERVER_FQDN}} \
     --snapshot-path /snapshot/DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1/ \
     --webrtc-url /webrtc/DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1/
   ```

Expected restored state matches `post-change-state.txt`: all five route families gated, 29-tool MCP flow independent of browser auth.

### Additional login account (ADD_USER)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/ADD_USER.md`

Runbook variables used:

- `{{NEW_LOGIN_USER}}`: `stephen`
- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{FIRST_NAME}}` / `{{LAST_NAME}}` / `{{USER_EMAIL}}`: Stephen Rhodes / sr99622@gmail.com
- `{{PASSWORD}}`: supplied by agent (see security note)
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folder:

- `{{BACKUP_PATH}}/add-user-{{DATETIME_STAMP}}`

Backed up data:

- `post-change-state.txt` — new user representation (username, names, email, `emailVerified=true`, `requiredActions=[]`, uuid `8ae46fcd-2fae-4343-9834-e69ed788e103`), credential type list, realm user list (existing `mcp-user` intact), secret file mode, driver PASS evidence for the new account, dump listing + catalog verification. Password value NOT recorded anywhere in the folder.
- `final-opt-keycloak.tar` — final `/opt/keycloak/` now including `stephen.pass` (root 600). Sensitive.
- `final-var-backups-keycloak-postgres.tar` — dumps including the post-user dump (`pg_restore_exit=0`). Newest restore source. Sensitive.
- `SHA256SUMS` — verified.

Configuration completed:

- One user `stephen` created in realm `mcp` with all identity fields atomic (`emailVerified=true`, no required actions), password from root-owned `/opt/keycloak/stephen.pass` via stdin pipe. No other object touched; no host-file changes outside `/opt/keycloak/stephen.pass`.

Verification performed:

- Username absent before, exactly one match after, enabled; `PASSWORD` credential present; `mcp-user` unchanged.
- Full browser login flow executed as `stephen` with the §9 driver: RESULT=PASS (lands on requested route, real JPEG with `no-store`).

Security note: the password was supplied through the agent chat channel; rotation is recommended once client onboarding completes (set new password via ADD_USER.md §5 idiom, overwrite `stephen.pass`).

This stage changes no nginx/systemd/compose state — the folder supersedes the stream-auth folder only for `final-opt-keycloak.tar` and the postgres dumps.

### DCR trusted-host addition (ADD_CLIENT_ON_SERVER)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/ADD_CLIENT_ON_SERVER.md`

Runbook variables used:

- `{{CLIENT_SOURCE_IP}}`: `192.168.68.57`
- `{{BACKUP_PATH}}`: `/mnt/taurus/Camera-System-Backup`

Backup folder:

- `{{BACKUP_PATH}}/add-client-on-server-{{DATETIME_STAMP}}`

Backed up data:

- `post-change-state.txt` — before/after trusted-host lists, live-resolved component UUID, token-lifetime-compliant single-command execution evidence, temp-artifact cleanup confirmation, pending client 201 confirmation.
- `final-opt-keycloak.tar` — unchanged from add-user (policy lives in the DB, not the directory); kept for folder self-sufficiency. Sensitive.
- `final-var-backups-keycloak-postgres.tar` — fresh dump taken after the policy write (`pg_restore_exit=0`); newest restore source. Sensitive.
- `SHA256SUMS` — verified.

Configuration completed:

- Exactly one address `192.168.68.57` appended to the anonymous `trusted-hosts` component of realm `mcp` (mint→resolve→fetch→PUT→verify in one bounded command per the 60-second token rule); all four pre-existing hosts preserved; both matching controls asserted `["true"]`. No host files outside `/var/backups/keycloak-postgres/` changed.

Verification performed:

- Preflight: health 200, exactly one anonymous trusted-hosts component; second direct by-ID GET after PUT passed every assert; all `/tmp` secret artifacts confirmed removed.
- Pending: nginx `201` for the client's DCR POST from `192.168.68.57` — confirm when the client runs login (final checklist item).

### HTTPS listener unpinned (SITE_CERT §9 amendment)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/SITE_CERT.md` (§7/§9 updated in place)

Trigger: on boot at 22:04, nginx failed with `bind() to 10.1.1.5:443 failed (99: Cannot assign requested address)` — the pinned `listen` raced NetworkManager's assignment of `{{SERVER_IP}}` to the LAN interface (stock unit orders only after `network.target`), leaving nginx failed and all HTTPS/MCP/OAuth endpoints refusing connections until a manual restart.

Backup:

- `/etc/nginx/conf.d/gmktec.home.arpa.conf.backup-2026-09-12` — exact pre-change file (same-disk copy; no SMB folder for this one-line amendment).

**Restore implication (verified 2026-09-13):** this amendment has NO backup folder, and
every `final-etc-nginx-conf.d.tar` (site-cert, keycloak, stream-auth) still contains the
pinned listen line. Whoever restores the LAST conf.d archive MUST re-apply this change
immediately afterwards (sed + systemd drop-in, as in "Reconstructing the HTTPS
configuration" step 3) — otherwise the system regresses to the boot-time bind race and
oauth2-proxy crash-loops against a hostname-404ing vhost. A rebuild should also re-archive
the amended conf.d into a fresh backup folder.

Configuration completed:

- `listen 10.1.1.5:443 ssl;` → `listen 443 ssl;` in `/etc/nginx/conf.d/gmktec.home.arpa.conf` (host binding dropped; `server_name` still scopes the vhost).
- systemd drop-in `/etc/systemd/system/nginx.service.d/wait-for-network.conf` ordering nginx after `network-online.target` (belt-and-braces; retained even with the unpinned listen).

Verification performed:

- `nginx -t` successful; clean restart (a reload alone kept the master's old bound socket — restart required for listen changes).
- `ss -lntp 'sport = :443'` now `0.0.0.0:443`.
- `https://gmktec.home.arpa/mcp` → `401` (expected pre-auth) via FQDN and loopback; reboot at 22:19 with the drop-in showed correct service ordering.
- Firewall note: unpinned listen exposes 443 on all interfaces (`10.2.2.1`, `192.168.68.5`); ufw is currently inactive, so interface restriction now depends on FIREWALL.md rules if ever desired.
