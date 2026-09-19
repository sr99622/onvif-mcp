# Camera System Backup Log

Backup destination: `{{BACKUP_PATH}}`

For this server, `{{BACKUP_PATH}}` currently resolves to `/mnt/taurus-camera-ca/Camera-CA-Backups`.

This document records backup actions taken before and during server configuration changes. Runbooks should refer to the backup location as `{{BACKUP_PATH}}` so future agents can substitute the correct SMB-mounted backup folder.

## Required Values

Authoritative substitutions for every `{{PLACEHOLDER}}` used in this document and its referenced runbooks. Resolve these **before** executing any runbook step; never substitute a placeholder literally, and never re-derive a value from a per-runbook mapping block below if it disagrees with this table.

| Placeholder | Required value | Notes |
|---|---|---|
| `{{BACKUP_PATH}}` | `/mnt/taurus-camera-ca/Camera-CA-Backups` | Backup root **includes** `Camera-CA-Backups/`; backup folders are `{{BACKUP_PATH}}/<runbook-name>-{{DATETIME_STAMP}}/`. Verify the mount is present and writable first. |
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
   (see "HTTPS listener unpinned" below). Check first — the 2026-09-15 backup
   set's `site-cert-*`/`stream-auth-*`/`keycloak-*` `final-etc-nginx-conf.d.tar`
   archives are ALREADY unpinned (the sed is a no-op), while the 2026-09-12 set's
   archives contain the pinned `listen 10.1.1.5:443;` line; restoring those
   regresses the boot-time bind race. `grep -n 'listen 10.1.1.5:443'
   /etc/nginx/conf.d/*.conf` decides whether the sed is needed.
3. **Large tar restores over SMB (e.g. the 79 MB venv archive) take 2–3 minutes** due to
   small-file SMB latency; run them in the background or with a generous timeout.

## Backup Entries

### Site certificate and HTTPS deployment

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/SITE_CERT.md`

Runbook variables used:

- `{{SERVER_FQDN}}`: `gmktec.home.arpa`
- `{{SERVER_IP}}`: `10.1.1.5`
- `{{REPO_PATH}}`: `/home/stephen`
- `{{CA_ROOT_PATH}}`: `/home/stephen/Private-CA`
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups`

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
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups`

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
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups`

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
   # SKIP final-etc-onvif-mcp.tar (policy: camera-IP files are never restored
   # from backup — they embed per-camera DHCP IPs. Regenerate
   # camera_registry.json + snapshot_routes.json from a live get_cameras via
   # scripts/generate_site_camera_config.py; see RESTORE.md "Camera-IP files:
   # generate, don't restore". Keep this tar only for provenance/cross-check.)
   # sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-onvif-mcp.tar" -C /
   sudo tar --xattrs --acls --selinux -xpf "$BACKUP_DIR/final-etc-systemd-system-onvif-mcp-http.service.tar" -C /
   ```

3. Reload everything:

   ```bash
   # RE-APPLY THE UNPINNED-LISTENER AMENDMENT (see "HTTPS listener unpinned" below):
   # 2026-09-12-set archives contain `listen 10.1.1.5:443 ssl;`; the 2026-09-15
   # set is already unpinned, so the sed below is a harmless no-op there.
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
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups`

Deployment constants (KEYCLOAK.md §1, non-secret):

- Realm `mcp`, scope `mcp:tools`, login user `mcp-user`, admin `keycloak-admin`
- Images pinned: `postgres:17-alpine`, `quay.io/keycloak/keycloak:26.7.0`
- Docker 29.1.3, Docker Compose 2.40.3 (Ubuntu `docker.io` + `docker-compose-v2`)

Backup folder (actual, 2026-09-16):

- `{{BACKUP_PATH}}/keycloak-20260916-175524`

NOTE: the pre-change archives in this folder were staged at stage close (the
folder is created after the work per §15b): pre-change conf.d is the
runbook-mandated `.pre-keycloak` copy; pre-change sites/systemd are live trees
with this stage's additions removed. The previous build's keycloak entry in
this log (old UUIDs `51738624-…`/`c7bc563d-…`) was a laboratory artifact of an
earlier build — all IDs below are from THIS deployment.

Backed up data:

- `pre-change-state.txt` — hostname/DNS/IP, docker absent, nginx, listener table (80/443 nginx, 8001 MCP loopback, 8080 free), `/opt/keycloak` absent.
- `etc-nginx-conf.d.tar` / `etc-nginx-sites-available.tar` / `etc-nginx-sites-enabled.tar` — pre-change nginx configs (no `/auth/` locations).
- `etc-systemd-system.tar` — pre-change systemd tree (no keycloak backup unit, no MCP oauth drop-in).
- `post-change-state.txt` — variable mapping, file modes, container state, pinned image IDs, realm settings, realm users, client scope + mapper JSON, DCR policy component configs, active Hermes DCR client_id, nginx `server_name` count, listener table, MCP OAuth env (drop-in lines only, non-secret), endpoint verification results, regression checks, dump listing, restore-test evidence, CA trust file, Hermes token file modes (contents never recorded).
- `final-opt-keycloak.tar` — final `/opt/keycloak/` (root `keycloak/`, restore with `-C /opt`) including `compose.yaml`, `.env`, `admin.pass`, `mcp-user.pass`. Sensitive: contains the PostgreSQL password and both account passwords in root-only files; restore must re-apply mode 750 dir / 600 secrets. Contains NO token files.
- `final-var-backups-keycloak-postgres.tar` — the dump set (root `keycloak-postgres-backups/`): `keycloak-20260916T215030Z.dump` (custom format, zstd, 520 catalog entries). Sensitive: contains password hashes, the DCR registration access token, and the active Hermes client registration. This is the database restore source.
- `final-usr-local-sbin-backup-keycloak-postgres.tar` — backup script (mode 750).
- `final-etc-systemd-system.tar` — complete `/etc/systemd/system` tree including `keycloak-postgres-backup.service` and `onvif-mcp-http.service.d/oauth.conf`. Newest complete systemd set — restore last.
- `final-etc-nginx-conf.d.tar` / `-sites-available.tar` / `-sites-enabled.tar` — final nginx configs with `/auth/` and `/.well-known/oauth-protected-resource/mcp`; newest complete nginx set — restore last among config-stage backups. conf.d is UNPINNED (`listen 443 ssl;` — the 2026-09-12-set pinned-listener problem does not recur from this archive).
- `final-etc-nginx-backups.tar` — `/etc/nginx/backups/` including the runbook-mandated `gmktec.home.arpa.conf.pre-keycloak` copy.
- `final-docs-KEYCLOAK.md`, `final-docs-BACKUP.md` — runbook + this log.
- `SHA256SUMS` — checksums for files in the backup folder.

Configuration completed:

- Installed `docker.io` 29.1.3 + `docker-compose-v2` 2.40.3+ds1.
- Deployed `/opt/keycloak/compose.yaml`: postgres:17-alpine (named volume `keycloak_keycloak_postgres_data`, not published) + keycloak 26.7.0 bound `127.0.0.1:8080`, relative path `/auth`, hostname `https://gmktec.home.arpa/auth`, xforwarded proxies, health endpoint.
- Permanent admin `keycloak-admin` (master, realm-level `admin` role, password in `/opt/keycloak/admin.pass` 600 root); bootstrap `admin` user deleted (id resolved before delete) and both `KC_BOOTSTRAP_ADMIN_*` variables removed from `.env` and `compose.yaml`; keycloak container force-recreated; CLI config re-established afterward.
- Realm `mcp`: ssoSessionIdle 28800, ssoSessionMax 604800, client sessions inherited (0), accessToken 300, `revokeRefreshToken=true`, `refreshTokenMaxReuse=0`; login user `mcp-user` (password in `/opt/keycloak/mcp-user.pass` 600 root).
- Client scope `mcp:tools` (uuid `172bba24-bd7c-44d0-b3b4-45b268d33f4e`) with all three attributes true; audience mapper `mcp-server-audience` (uuid `b375c484-f298-47d9-99da-ef3b7b76404f`) → `https://gmktec.home.arpa/mcp` (access+introspection claims, no id token).
- Anonymous DCR components (realm `mcp`): allowed-client-templates `d2f995ed-6db5-40ac-bdb4-c8aedc3a2df0` (`mcp:tools` + default scopes), trusted-hosts `eaea6b9f-9d50-4e02-a8e9-6c9e2e568161` (`localhost, 127.0.0.1, 172.18.0.1 (compose gateway), 10.1.1.5 (server LAN IP)`, both matching controls true), max-clients `dd100a3e-49ae-425e-bbc8-5209bd26e6a1` (20); consent-required `81b3ce31-44ff-4ee5-a1ea-881b030c288f` and scope (Full Scope Disabled) `c21cc43e-4612-4956-b776-26df797e09d0` present.
- nginx HTTPS vhost `/etc/nginx/conf.d/gmktec.home.arpa.conf` extended with `= /auth` 301, `/auth/` proxy to `127.0.0.1:8080/auth/`, and `= /.well-known/oauth-protected-resource/mcp` proxy to `127.0.0.1:8001`; existing `/mcp` proxy and HTTPS `/mcp/` redirect retained.
- Private CA installed to `/usr/local/share/ca-certificates/camera-system-root-ca.crt` (CA:TRUE verified); all endpoint checks without `-k`.
- MCP OAuth drop-in `/etc/systemd/system/onvif-mcp-http.service.d/oauth.conf` (issuer, resource URL, loopback HTTP JWKS).
- DCR smoke test passed (HTTP 201, scope `mcp:tools`); test client `temporary-dcr-verification` (`2ad904ca-30a3-46cd-b551-db871d5bc113`) verified by name then deleted; credential-bearing response file removed.
- Hermes `camera-new` OAuth client registered via isolated-home headless login (`HERMES_HOME=/tmp/hermes-login-home`, display vars unset, single flow, listener 127.0.0.1:27890; `scripts/kc-headless-login-driver.py` delivered the `?code=&state=` callback). Entry was first written under the name `camera-https` and renamed to `camera-new` (with its three token files) to match the downstream runbooks' `{{HERMES_SERVER_NAME}}`; `mcp.auto_reload_on_config_change=false` set; entry `enabled: true` after test. Token files at `~/.hermes/mcp-tokens/camera-new.*` (mode 600, never archived).
- PostgreSQL backup script + `keycloak-postgres-backup.service` (manual one-shot, 14-day retention); first dump `keycloak-20260916T215030Z.dump` (250148 bytes) taken after the real Hermes DCR client existed; isolated restore test into `keycloak_restore_test_20260916` passed (`realms=2 users=2 clients=14`) and test DB dropped.

Verification performed:

- Discovery 200 with exact issuer `https://gmktec.home.arpa/auth/realms/mcp`; `S256` in `code_challenge_methods_supported`; `mcp:tools` published; registration endpoint present.
- Unauthenticated `/mcp` → 401 with `resource_metadata=https://gmktec.home.arpa/.well-known/oauth-protected-resource/mcp`; protected-resource metadata JSON exact.
- DCR policies re-read per component ID (collection view collapses config to `{}`).
- `/cameras/`, `/multiview/`, registry, snapshot JPEG (1920×1080), WebRTC player regression all 200 over TLS; `server_name` count 2; unpinned-listener check 1 unpinned / 0 pinned.
- Postgres healthy; `pg_restore --list` catalog readable (520 entries); restore test row counts nonzero; dump archived to this folder.
- `hermes mcp test camera-new`: connects with saved state, 29 tools; no orphan DCR clients in realm `mcp` (active client `f3f20dfa-24ad-4929-9134-6caff61dc340` "Hermes Agent").
- `post-change-state.txt` scanned for secret leakage — one initial leak (base-unit camera credentials in the MCP env line) caught and removed before close; final file holds key names and non-secret values only.
- Backup checksums all passed (`sha256sum -c` clean; regenerated once after the state-file fix).

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
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups`
- Defaults as documented: realm `mcp`, browser client `camera-web`, login user `mcp-user`, oauth2-proxy `v7.15.3` on `127.0.0.1:4180`

Backup folder (actual, 2026-09-16):

- `{{BACKUP_PATH}}/stream-auth-20260916-180935`

NOTE: the previous build's stream-auth entry in this log (folder
`stream-auth-20260916-110947`, its "Re-close (2026-09-16)" paragraph, and its
dump `keycloak-20260916T184123Z.dump`) was a laboratory artifact of an earlier
build — that folder never existed on this host's share. This 2026-09-16
`stream-auth-20260916-180935` folder is the authoritative record of THIS
deployment's browser-auth stage.

Backed up data:

- `pre-change-state.txt` — services/listeners, `.env` key names (values never), compose services, nginx layout, snapshot preflight, unauthenticated baseline (roots + known snapshot path + HTTP entry), MCP `STREAM_SERVER_URL` and registry scheme counts.
- `etc-nginx-conf.d.tar` — pre-change conf.d (sourced from `gmktec.home.arpa.conf.pre-stream-auth`, verified byte-identical to the live site at run start via `cmp`).
- `etc-nginx-sites-available.tar` / `etc-nginx-sites-enabled.tar` — pre-change sites trees (untouched by this runbook).
- `.env.pre-oauth2-proxy.sha256` — hash of the pre-change `.env` only; the pre-change `.env` content itself stays in the keycloak folder's `final-opt-keycloak.tar` — no duplicate secret copies on the share.
- `compose.yaml.pre-oauth2-proxy` — pre-change compose (non-secret; the oauth2-proxy service not yet present).
- `post-change-state.txt` — `.env` key names + counts (values never), oauth2-proxy image pin + listener, `camera-web` client representation (secret never printed), nginx location changes, unauthenticated 302 behavior for all five route families + HTTP→HTTPS snapshot redirect, Phase-9 driver PASS evidence, MCP regression (cookie-independent `get_snapshot`), checkpoint dump verification, deviations list.
- `final-opt-keycloak.tar` — final `/opt/keycloak/` (root `keycloak/`, restore with `-C /opt`) incl. updated `compose.yaml` (oauth2-proxy service), `.env` (+ client/cookie secrets), `.env.pre-oauth2-proxy`, `compose.yaml.pre-oauth2-proxy`, `gmktec.home.arpa.conf.pre-stream-auth`, and both `.pass` files. Contains NO token files. Sensitive.
- `final-var-backups-keycloak-postgres.tar` — complete dump set (root `keycloak-postgres-backups/`) incl. the §10 checkpoint `keycloak-20260916T220859Z.dump` (251321 bytes, `pg_restore --list` exit 0, 520 catalog entries). Restore source for this stage until superseded. Sensitive.
- `final-etc-nginx-conf.d.tar` — newest complete conf.d set: `/oauth2/*` support blocks + `auth_request` on all five route families, `try_files "" =404;` amendment on `/outputs/`, UNPINNED `listen 443 ssl;` (unpinned-listener check: 1 unpinned / 0 pinned-IP). Restore last among config-stage backups.
- `final-docs-STREAM_AUTH.md`, `final-docs-BACKUP.md` — runbook and this log.
- `SHA256SUMS` — round-trip verified.

Configuration completed:

- Login user `mcp-user` resolved in realm `mcp`: enabled, nonempty verified email, `requiredActions=[]`.
- Confidential client `camera-web` (internal UUID `9863e51e-960f-4321-ac39-eb4a951dff8e`) created via host-side Admin REST (kcadm create path unreliable per runbook); standard flow only, PKCE S256, exact redirect `https://gmktec.home.arpa/oauth2/callback`, post-logout `/cameras/`, web origin exact, consent off; all 15 settings verified on the stored representation (secret carried in top-level `secret`, never printed).
- `OAUTH2_PROXY_CLIENT_SECRET` (byte-compared equal to the live Keycloak client secret) + 32-byte URL-safe `OAUTH2_PROXY_COOKIE_SECRET` appended to `/opt/keycloak/.env` (mode 600 preserved, each key occurs exactly once, all values nonempty); `.env.pre-oauth2-proxy` created 600.
- oauth2-proxy `v7.15.3` added to `/opt/keycloak/compose.yaml` (postgres/keycloak/volumes verified object-identical before write); bound `127.0.0.1:4180`; provider CA mounted read-only via `--provider-ca-file`.
- nginx HTTPS site: `/oauth2/auth` (body-less auth subrequest), `/oauth2/` (32k/64k buffers), `@oauth2_signin` relative-`rd` redirect; `auth_request` + cookie-forwarding quartet added to `/cameras/`, `/multiview/`, `= /outputs/camera_registry.json`, `/outputs/`, `/webrtc/`, `/snapshot/`; snapshot proxy headers/timeouts/no-cache preserved; single reload.
- `/outputs/` fallback: `return 404` → `try_files "" =404;` so the auth access phase runs first (authenticated fallback remains 404).

Verification performed:

- oauth2-proxy loopback ping 200, unauthenticated auth check 401, listener `127.0.0.1:4180` only.
- All protected routes 302 → `/oauth2/start?rd=<path>`; direct snapshot returns no JPEG unauthenticated; HTTP snapshot entry 301→HTTPS then 302→login; 4180 not publicly exposed.
- `/oauth2/start` reaches Keycloak authorize with all PKCE/param names present (values never printed).
- Discovery still 200; `/mcp` still 401 with protected-resource metadata.
- Phase-9 driver RESULT=PASS: login lands exactly on requested route, ping 202 `Authenticated`, multiview no second login, WebRTC pass-through, in-session and fresh-session snapshots real JPEGs with `no-store`.
- MCP regression cookie-independent: `get_cameras` (8 cameras) serves HTTPS-origin `web_snapshot_url` for all cameras; `get_snapshot` returns a valid JPEG via loopback; `SNAPSHOT_PROXY_URL` unset (loopback default); `hermes mcp test camera-new` connects with saved OAuth state, 29 tools.
- Public TLS chain verified against the private CA (`s_client` + `openssl verify` OK); no `-k` used anywhere.
- §10 checkpoint dump taken after the browser client and login existed; `pg_restore --list` exit 0; no timer created; all services healthy afterward.
- Backup checksums all passed (`sha256sum -c` clean).

Known deviations (recorded in `post-change-state.txt`): none — the bare `/outputs/`
answers 404 after auth (by design; the real file is protected separately) and the
slash-less `= /cameras`/`= /multiview` 301s are redirect-only (no content exposed).

Human-confirmation items (out of driver scope by design): live video rendering in a browser after login (UDP ICE path) and images visibly displaying inside `/cameras/` and `/multiview/`.

### Browser authentication gate — re-execution on this host (STREAM_AUTH, 2026-09-19)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/STREAM_AUTH.md`

Runbook variables used (all verified against system reality):

- `{{SERVER_FQDN}}`: `gmktec.home.arpa` (`hostname -f` → `gmktec`; `getent hosts` → `10.1.1.5`; matches the site certificate SAN)
- `{{SERVER_IP}}`: `10.1.1.5` (`enp170s0`)
- `{{REPO_PATH}}`: `/home/stephen`
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups` (cifs mount rw; write probe passed)
- Defaults: realm `mcp`, login user `mcp-user`, browser client `camera-web`, oauth2-proxy `v7.15.3` on `127.0.0.1:4180`

Backup folder (actual):

- `{{BACKUP_PATH}}/stream-auth-20260919-091744`

NOTE (2026-09-19): the earlier stream-auth entry in this log (folder
`stream-auth-20260916-180935`) was a laboratory artifact — that folder never
existed on this host's share. This `stream-auth-20260919-091744` folder is the
authoritative record of THIS deployment's browser-auth stage (fresh deployment;
prior folders untouched). Tar roots match this host's existing convention:
`conf.d/`, `sites-available/`, `sites-enabled/`, `keycloak/` (restore with `-C /opt`),
`keycloak-postgres-backups/`.

Backed up data:

- `pre-change-state.txt` — services/listeners, `.env` key names only (`POSTGRES_PASSWORD` single line; no `OAUTH2_PROXY_*` keys yet — guard satisfied), compose services (no oauth2-proxy yet), nginx layout (unpinned 443 site with all target locations, no oauth2/auth_request yet), snapshot preflight (known path `4B0013BPAABE264/MediaProfile000` → 200 valid JPEG), unauthenticated baseline (roots + known snapshot path + `/mcp` 401), `STREAM_SERVER_URL` and registry scheme counts.
- `etc-nginx-conf.d.tar` — pre-change conf.d (sourced from `gmktec.home.arpa.conf.pre-stream-auth`, byte-identical to live site at run start via `cmp`). Root `conf.d/`.
- `etc-nginx-sites-available.tar` / `etc-nginx-sites-enabled.tar` — pre-change sites trees (untouched by this runbook).
- `.env.pre-oauth2-proxy.sha256` — hash of the pre-change `.env` only; its content stays in the keycloak folder's `final-opt-keycloak.tar` (no duplicate secret copies on the share).
- `compose.yaml.pre-oauth2-proxy` — pre-change compose (non-secret; no oauth2-proxy service yet).
- `post-change-state.txt` — `.env` key names + counts (values never), oauth2-proxy image pin + loopback-only listener, `camera-web` representation settings (secret never printed), nginx location changes, unauthenticated 302 behavior for all five route families + HTTP→HTTPS snapshot redirect, phase-9 driver PASS evidence, MCP regression (cookie-independent `get_snapshot`), checkpoint dump verification, deviations list.
- `final-opt-keycloak.tar` — final `/opt/keycloak/` (root `keycloak/`, restore with `-C /opt`) incl. updated `compose.yaml` (oauth2-proxy service), `.env` (+ client/cookie secrets), `.env.pre-oauth2-proxy`, `compose.yaml.pre-oauth2-proxy`, `gmktec.home.arpa.conf.pre-stream-auth`, and both `.pass` files. Contains NO token files. Sensitive.
- `final-var-backups-keycloak-postgres.tar` — complete dump set (root `keycloak-postgres-backups/`) incl. the §10 checkpoint `keycloak-20260919T133018Z.dump` (251323 bytes, mode 0600 root:root, `pg_restore --list` exit 0, catalog readable). Restore source for this stage until superseded. Sensitive.
- `final-etc-nginx-conf.d.tar` — newest complete conf.d set: `/oauth2/*` support blocks + `auth_request` on all five route families, `try_files "" =404;` amendment on `/outputs/`, UNPINNED `listen 443 ssl;` (unpinned-listener check run BEFORE archiving: 1 unpinned / 0 pinned-IP). Restore last among config-stage backups.
- `final-docs-STREAM_AUTH.md`, `final-docs-BACKUP.md` — runbook and this log.
- `SHA256SUMS` — checksums for every backed-up file except itself; round-trip verified.

Configuration completed:

- Login user `mcp-user` resolved in realm `mcp` by exact username: exactly one match, enabled, nonempty verified email, `requiredActions=[]`.
- Confidential client `camera-web` created via host-side Admin REST (zero existing matches first — re-run guard held; kcadm create path unreliable per runbook); standard flow only, PKCE S256, exact redirect `https://gmktec.home.arpa/oauth2/callback`, post-logout `/cameras/`, web origin exact, consent off; all settings verified on the re-fetched representation (secret carried in top-level `secret` / dedicated client-secret endpoint, never printed).
- `OAUTH2_PROXY_CLIENT_SECRET` (byte-compared equal to the live Keycloak client secret) + 32-byte URL-safe `OAUTH2_PROXY_COOKIE_SECRET` appended to `/opt/keycloak/.env` (mode 600 preserved; each key occurs exactly once; all values nonempty); `.env.pre-oauth2-proxy` created 0600 root-owned.
- oauth2-proxy `v7.15.3` added to `/opt/keycloak/compose.yaml` (postgres/keycloak/volumes verified parsed-object-identical vs the pre-change copy before write); bound `127.0.0.1:4180`; provider CA mounted read-only via `--provider-ca-file`.
- nginx HTTPS site: `/oauth2/auth` (body-less auth subrequest), `/oauth2/` (32k×8 / 64k buffers), `@oauth2_signin` relative-`rd` redirect; `auth_request` + cookie-forwarding quartet added to `/cameras/`, `/multiview/`, `= /outputs/camera_registry.json`, `/webrtc/`, `/snapshot/`; snapshot proxy headers/timeouts/no-cache preserved; single reload (done once, after auth_request landed).
- `/outputs/` fallback: `return 404` → `try_files "" =404;` so the auth access phase runs first (authenticated fallback remains 404 by design).

Verification performed:

- oauth2-proxy loopback ping 200; unauthenticated auth check 401; listener `127.0.0.1:4180` only (public IP connection refused).
- All protected routes (including the registry file and the known snapshot path) 302 → `/oauth2/start?rd=<path>` with original path preserved; no image content unauthenticated; HTTP snapshot entry 301→HTTPS then 302→login (port-80 vhost already redirects every path — verified, no edit needed); 4180 not publicly exposed.
- `/oauth2/start` reaches Keycloak authorize with all PKCE parameter names present (values never printed).
- Discovery 200; `/mcp` still 401 with protected-resource metadata; all containers healthy.
- Phase-9 driver (`scripts/stream_auth_step9_driver.py --origin https://gmktec.home.arpa`, known snapshot + WebRTC paths) RESULT=PASS: login lands exactly on the requested route, ping 202 `Authenticated`, multiview no second login, WebRTC pass-through, in-session and fresh-session snapshots real JPEGs with `no-store` (fresh-session returns to the requested image, not the site root).
- MCP regression cookie-independent: `get_cameras` (4 cameras / 9 profiles) all HTTPS-origin; `get_snapshot` for `4B0013BPAABE264/MediaProfile000` returned a valid JPEG with no browser cookies; `SNAPSHOT_PROXY_URL` unset on the MCP service (loopback default applies); registry 8/8 URLs `https://`; `hermes mcp test camera-new` connected via saved OAuth state, 29 tools.
- Public TLS chain verified against the private CA (`s_client` + `openssl verify -CAfile` OK; no `-k` anywhere).
- §10 checkpoint dump taken after the browser client and login existed; mode 0600 root:root; `pg_restore --list` exit 0 (temp file removed from container); no timer created; all services healthy afterward.
- Backup checksums all passed (`sha256sum -c` clean).

Known deviations (recorded in `post-change-state.txt`): none functional — the bare `/outputs/` answers 404 after auth (by design; the real file is protected separately) and the slash-less `= /cameras`/`= /multiview` 301s are redirect-only. One bookkeeping note: `compose.yaml` mode was briefly set to 640 by a staging install, then restored to the original 644 (final state verified).

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
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups`

Backup folder (actual, 2026-09-16):

- `{{BACKUP_PATH}}/add-user-20260916-181555`

NOTE: the prior build's add-user entry (folder `add-user-20260916-145556`, uuid
`e1360b93-…`, dump `keycloak-20260916T185630Z.dump`) was a laboratory artifact of an
earlier build. This `add-user-20260916-181555` folder is the authoritative record of
THIS deployment.

Backed up data:

- `post-change-state.txt` — new user representation (username, names, email, `emailVerified=true`, `requiredActions=[]`, uuid `1bfb9d84-4506-40e9-a928-1eb874df3440`), credential type list, realm user list (existing `mcp-user` intact), secret file mode, §9 driver PASS evidence for the new account, dump listing + catalog verification, isolated restore test proof that the new user is IN the dump. Password value NOT recorded anywhere in the folder.
- `final-opt-keycloak.tar` — final `/opt/keycloak/` (root `keycloak/`, restore with `-C /opt`) now including `stephen.pass` (root 600). Contains NO token files. Sensitive.
- `final-var-backups-keycloak-postgres.tar` — complete dump set (root `keycloak-postgres-backups/`) including the post-user dump `keycloak-20260916T221600Z.dump` (251849 bytes, 520 catalog entries, `pg_restore --list` exit 0; isolated restore into scratch DB exit 0, both users present). Newest restore source. Sensitive.
- `SHA256SUMS` — round-trip verified.

Configuration completed:

- One user `stephen` created in realm `mcp` with all identity fields atomic (`emailVerified=true`, `requiredActions=[]`), password from root-owned `/opt/keycloak/stephen.pass` (umask 077) via the `exec -i` stdin pipe (`-T` is unavailable on this docker build). No other object touched; no host-file changes outside `/opt/keycloak/stephen.pass`.

Verification performed:

- Username absent before, exactly one match after, enabled; `password` credential present; `mcp-user` unchanged.
- Full browser login flow executed as `stephen` with the §9 driver: RESULT=PASS (lands exactly on requested route, ping 202, real JPEG with `no-store`, fresh-session snapshot login returns to the requested image).
- Isolated restore into `keycloak_restore_test_20260916_au` (exit 0) listed both `mcp-user` and `stephen` in the restored realm; test DB dropped with the explicit guard.
- `hermes mcp test camera-new` still connects via saved OAuth state (MCP independent of the new account).

Security note: the password was supplied through the agent chat channel; rotation is
recommended once client onboarding completes (set a new password per ADD_USER.md §5 and
overwrite `stephen.pass`).

This stage changes no nginx/systemd/compose state — the folder supersedes the stream-auth folder only for `final-opt-keycloak.tar` and the postgres dumps.

### Additional login account — re-execution on this host (ADD_USER, 2026-09-19)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/ADD_USER.md`

Runbook variables used:

- `{{NEW_LOGIN_USER}}`: `stephen`
- `{{FIRST_NAME}}` / `{{LAST_NAME}}`: Stephen / Rhodes
- `{{USER_EMAIL}}`: sr99622@gmail.com (user-supplied)
- `{{PASSWORD}}`: supplied by the user via chat; archived only as the root-0600 `stephen.pass` file inside the tar — never in state files, logs, or chat after hand-back.
- `{{SERVER_FQDN}}`: `gmktec.home.arpa` (verified)
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups`

Backup folder (actual):

- `{{BACKUP_PATH}}/add-user-20260919-095228`

NOTE (2026-09-19): the prior add-user entry in this log (folder
`add-user-20260916-181555`) was a laboratory artifact — that folder never existed on this
host's share. This `add-user-20260919-095228` folder is the authoritative record of THIS
deployment (uuid `5867f360-…`).

Backed up data:

- `post-change-state.txt` — new user representation (username, names, email, `emailVerified=true`, `requiredActions=[]`, uuid `5867f360-043d-4004-809f-451b67ddf56c`), credential type list `["password"]`, realm user list (existing `mcp-user` intact, uuid `47324b5f-…`), client/scope sets unchanged, secret file mode (0600 root:root, 8 bytes), kcadm session-expiry recovery note, §9 driver PASS evidence for the new account, dump listing + catalog verification, isolated restore test proof that the new user is IN the dump. Password value NOT recorded anywhere in the folder.
- `final-opt-keycloak.tar` — final `/opt/keycloak/` (root `keycloak/`, restore with `-C /opt`) now including `stephen.pass` (root 600). Contains NO token files. Sensitive.
- `final-var-backups-keycloak-postgres.tar` — complete dump set (root `keycloak-postgres-backups/`) including the post-user dump `keycloak-20260919T135552Z.dump` (251845 bytes, 0600 root:root; catalog `pg_restore --list` exit 0; isolated restore into `keycloak_restore_test_20260919_au` exit 0 with all three users present; scratch DB dropped). Newest restore source. Sensitive.
- `SHA256SUMS` — round-trip verified.

Configuration completed:

- One user `stephen` created in realm `mcp` with all identity fields atomic (`emailVerified=true`, `requiredActions=[]`), password from root-owned `/opt/keycloak/stephen.pass` (written via staged install + shred of the staging copy; umask 077 equivalent) set via the `exec -i` stdin pipe (`-T` unavailable on this docker build). No other object touched; no host-file changes outside `/opt/keycloak/stephen.pass`.

Verification performed:

- Username absent before, exactly one match after, enabled; `password` credential present; `mcp-user` unchanged; client/scope lists identical to the pre-existing set.
- Full browser login flow executed as `stephen` with the §9 driver: RESULT=PASS (lands exactly on requested route, ping 202, real JPEG with `no-store`, fresh-session snapshot login returns to the requested image).
- Isolated restore into `keycloak_restore_test_20260919_au` (exit 0) listed `mcp-user` and `stephen` in the restored realm; test DB dropped with the explicit guard.
- `hermes mcp test camera-new` still connects via saved OAuth state (MCP independent of the new account, 29 tools).

Security note: the password was supplied through the agent chat channel; rotation is
recommended once client onboarding completes (set a new password per ADD_USER.md §5 and
overwrite `stephen.pass`). Pending: client-side configuration per CLIENT.md and, if that
machine is new, ADD_CLIENT_ON_SERVER.md trusted-hosts addition.

This stage changes no nginx/systemd/compose state — the folder supersedes the stream-auth folder only for `final-opt-keycloak.tar` and the postgres dumps.

### DCR trusted-host addition (ADD_CLIENT_ON_SERVER)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/ADD_CLIENT_ON_SERVER.md`

Runbook variables used:

- `{{CLIENT_SOURCE_IP}}`: `10.1.1.4`
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups`

Backup folder (actual, 2026-09-16):

- `{{BACKUP_PATH}}/add-client-on-server-20260916-182219`

NOTE: the prior build's entry for this stage (folder `add-client-on-server-20260916-150515`,
component UUID `29e93f3d-…`) was a laboratory artifact of an earlier build. This
`add-client-on-server-20260916-182219` folder is the authoritative record of THIS
deployment (component UUID `eaea6b9f-…`).

Backed up data:

- `post-change-state.txt` — before/after trusted-host lists (before: `127.0.0.1, 172.18.0.1, localhost, 10.1.1.5`; after: those four plus `10.1.1.4`), live-resolved component UUID `eaea6b9f-9d50-4e02-a8e9-6c9e2e568161`, both matching controls `["true"]`, single-process execution note, temp-artifact cleanup confirmation, pending `201` DCR confirmation. Tokens/passwords: never.
- `final-opt-keycloak.tar` — unchanged since add-user-20260916-181555 (the policy lives in the DB, not the directory); re-archived for folder self-sufficiency. Sensitive.
- `final-var-backups-keycloak-postgres.tar` — complete dump set (root `keycloak-postgres-backups/`) incl. post-write dump `keycloak-20260916T222227Z.dump` (252207 bytes, 520 catalog entries, `pg_restore --list` exit 0; isolated restore exit 0 with the `10.1.1.4` policy row present). Newest restore source. Sensitive.
- `SHA256SUMS` — round-trip verified.

Configuration completed:

- Exactly one address `10.1.1.4` appended to the anonymous `trusted-hosts` component of realm `mcp` (mint→resolve→fetch→PUT(204)→second-GET verify, single bounded in-memory process — no temp token file, no shell substitution over the credential file); all four pre-existing hosts preserved; both matching controls `["true"]`. No host files changed at all (the policy lives only in the DB).

Verification performed:

- Preflight: health 200; exactly one anonymous trusted-hosts component in realm `mcp` (the master realm's own component is a separate, untouched object); the client's pre-change 403 from `10.1.1.4` (18:18:53) corroborated the supplied address.
- Second direct by-ID GET after the PUT passed every assert; `/tmp` confirmed free of all step artifacts (none were created).
- Pending: nginx `201` for the client's DCR POST from `10.1.1.4` — confirm when the client retries login (final checklist item; its pre-change attempt logged `403` at 18:18:53).

NOTE (2026-09-19): this prior-build entry's folder (`add-client-on-server-20260916-182219`,
component UUID `29e93f3d-…`) never existed on this host's share — laboratory artifact.
The authoritative record of THIS deployment's trusted-host addition is below.

### DCR trusted-host addition — re-execution on this host (ADD_CLIENT_ON_SERVER, 2026-09-19)

Runbook: `{{REPO_PATH}}/onvif-mcp/docs/ADD_CLIENT_ON_SERVER.md`

Runbook variables used:

- `{{CLIENT_SOURCE_IP}}`: `10.1.1.4` (user-supplied; corroborated by the nginx DCR access log — a `403` from `10.1.1.4` at 2026-09-19 10:04:45, while two earlier `201` registrations came from `10.1.1.5`)
- `{{BACKUP_PATH}}`: `/mnt/taurus-camera-ca/Camera-CA-Backups`

Backup folder (actual):

- `{{BACKUP_PATH}}/add-client-on-server-20260919-100610`

Backed up data:

- `post-change-state.txt` — before/after trusted-host lists (before: `10.1.1.5, 127.0.0.1, 172.18.0.1, localhost`; after: those four plus `10.1.1.4`), live-resolved component UUID `4e3388de-4ff6-4a41-9564-eab3fbd91646`, both matching controls `["true"]`, single-process execution note (no temp token files; header built in memory), temp-artifact cleanup confirmation, pending `201` DCR confirmation. Tokens/passwords: never.
- `final-opt-keycloak.tar` — unchanged since add-user-20260919-095228 (the policy lives in the DB, not the directory); re-archived for folder self-sufficiency. Sensitive.
- `final-var-backups-keycloak-postgres.tar` — complete dump set (root `keycloak-postgres-backups/`) incl. post-write dump `keycloak-20260919T141015Z.dump` (252035 bytes, 0600 root:root; catalog exit 0; isolated restore into `keycloak_restore_test_20260919_ac3` reached the realm-`mcp` component by ID and listed all five trusted-host values including `10.1.1.4` with both matching controls present; scratch DB dropped). Newest restore source. Sensitive.
- `SHA256SUMS` — round-trip verified.

Configuration completed:

- Exactly one address `10.1.1.4` appended to the anonymous `trusted-hosts` component of realm `mcp` (single bounded root process: mint → resolve → fetch-by-ID → append → PUT 204 → second by-ID GET verify); all four pre-existing hosts preserved; both matching controls `["true"]`. No host files changed at all (the policy lives only in the DB).

Verification performed:

- Preflight: health 200; exactly one anonymous trusted-hosts component in realm `mcp` (a second, separate one exists in the master realm — untouched by design); the client's pre-change 403 from `10.1.1.4` corroborated the supplied address.
- Second direct by-ID GET after the PUT passed every assert (new host present, all prior hosts preserved, both controls true).
- /tmp confirmed free of all step artifacts (none were created; the single step script was removed after success).
- Isolated restore proof that the `10.1.1.4` policy row is IN the new dump (scratch DB dropped with guard).
- Pending: nginx `201` for the client's DCR POST from `10.1.1.4` — confirm when the client retries login (its pre-change attempt logged `403` at 10:04:45).

This stage changes no host files — the folder supersedes the add-user folder only for the postgres dumps (the opt tar is byte-identical to it, re-archived for self-sufficiency).

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
