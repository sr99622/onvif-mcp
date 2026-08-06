# MediaMTX WebRTC Access-Control Runbook

## Purpose

This runbook documents the tested procedure used to restrict camera-stream access to authorized users while preserving MediaMTX's outbound RTSP camera ingestion.

The final architecture is:

```text
Authorized browser
      |
      | HTTPS + Nginx Basic Authentication
      v
Nginx at 10.1.1.3:443
      |
      | loopback HTTP proxy
      v
MediaMTX at 127.0.0.1:8889
      |
      | encrypted WebRTC media through UDP 8189
      v
Authorized browser

MediaMTX
      |
      | outbound RTSP client connections
      v
Configured cameras on TCP/UDP port 554
```

## Final security state

- Direct network access to MediaMTX port `8889` is blocked by binding it to loopback.
- Nginx requires individual credentials for all HTTPS camera resources.
- Passwords are stored as bcrypt hashes.
- Browser credentials are not forwarded into MediaMTX.
- Obsolete unauthenticated Nginx port `8181` is closed.
- MediaMTX's inbound RTSP server is disabled.
- MediaMTX's RTMP, HLS, SRT, MoQ, playback, API, metrics, and profiling servers are disabled.
- MediaMTX continues pulling all configured cameras as an outbound RTSP client.
- WebRTC UDP port `8189` remains available because it carries encrypted WebRTC media negotiated through the authenticated signaling session.

## Site-specific values

| Purpose | Value |
|---|---|
| Server | `trigkey` |
| Server address | `10.1.1.3` |
| HTTPS hostname | `camera.home.arpa` |
| MediaMTX executable | `/home/stephen/.local/bin/mediamtx` |
| MediaMTX configuration | `/home/stephen/.local/bin/mediamtx.yml` |
| MediaMTX process ID during setup | `1744` |
| WebRTC signaling listener | `127.0.0.1:8889` |
| WebRTC ICE/media listener | UDP `8189` |
| Nginx site configuration | `/etc/nginx/sites-available/camera-apps` |
| Nginx password file | `/etc/nginx/auth/camera-users.htpasswd` |
| Initial user | `stephen` |

The process ID will change after a restart. Discover it with `pgrep -a mediamtx` instead of assuming `1744` in future work.

## 1. Understand the bypass risk

Initially, MediaMTX listened on every interface:

```text
*:8889
```

Although Nginx proxied MediaMTX under the authenticated HTTPS path `/webrtc/`, a client could bypass Nginx by opening:

```text
http://10.1.1.3:8889/STREAM/PATH/
```

Nginx authentication is effective only when MediaMTX's signaling listener cannot be reached directly.

## 2. Inspect MediaMTX authentication defaults

The initial authentication section used:

```yaml
authMethod: internal

authInternalUsers:
  - user: any
    pass:
    ips: []
    permissions:
      - action: publish
        path:
      - action: read
        path:
      - action: playback
        path:

  - user: any
    pass:
    ips: ["127.0.0.1", "::1"]
    permissions:
      - action: api
      - action: metrics
      - action: pprof
```

The first user allowed anonymous publishing, reading, and playback on every path from every IP.

Inspect the active section without displaying the rest of the configuration:

```bash
rg -n \
  '^auth|^[[:space:]]+- user:|^[[:space:]]+permissions:|^[[:space:]]+- action:' \
  /home/stephen/.local/bin/mediamtx.yml
```

## 3. Back up and protect the MediaMTX configuration

Create a backup before changing listeners:

```bash
cp --update=none \
  /home/stephen/.local/bin/mediamtx.yml \
  /home/stephen/.local/bin/mediamtx.yml.backup-2026-08-04
```

The active file and backup were initially mode `664`, which allowed group read/write access. MediaMTX configuration files may contain camera source credentials, so both were restricted to the owner:

```bash
chmod 600 \
  /home/stephen/.local/bin/mediamtx.yml \
  /home/stephen/.local/bin/mediamtx.yml.backup-2026-08-04
```

Verify:

```bash
ls -l \
  /home/stephen/.local/bin/mediamtx.yml \
  /home/stephen/.local/bin/mediamtx.yml.backup-2026-08-04
```

Expected owner and mode:

```text
-rw------- stephen stephen
```

## 4. Bind WebRTC signaling to loopback

Change:

```yaml
webrtcAddress: :8889
```

to:

```yaml
webrtcAddress: 127.0.0.1:8889
```

Tested command:

```bash
sed -i \
  's/^webrtcAddress: :8889$/webrtcAddress: 127.0.0.1:8889/' \
  /home/stephen/.local/bin/mediamtx.yml
```

MediaMTX hot-reloaded the configuration without a manual restart.

Verify the setting:

```bash
rg -n '^webrtcAddress:' /home/stephen/.local/bin/mediamtx.yml
```

Verify the active socket:

```bash
sudo ss -lntp 'sport = :8889'
```

Expected:

```text
127.0.0.1:8889
```

No wildcard or user-network listener should remain.

## 5. Verify Nginx can still reach MediaMTX

Nginx already proxied the `/webrtc/` path to loopback:

```nginx
location /webrtc/ {
    proxy_pass http://127.0.0.1:8889/;
    proxy_redirect / /webrtc/;
}
```

Test through trusted HTTPS:

```bash
sudo curl \
  --silent \
  --show-error \
  --output /dev/null \
  --write-out 'HTTP %{http_code}\nContent-Type: %{content_type}\n' \
  --resolve camera.home.arpa:443:10.1.1.3 \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  https://camera.home.arpa/webrtc/STREAM/PATH/
```

Expected before adding authentication:

```text
HTTP 200
Content-Type: text/html
```

From another network client, direct access must fail:

```bash
curl --connect-timeout 3 --head http://10.1.1.3:8889/
```

Tested result:

```text
curl: (7) Failed to connect to 10.1.1.3 port 8889
```

## 6. Install the password-management utility

Nginx's Basic Authentication uses an `htpasswd`-format password file. On Ubuntu, install the utility package:

```bash
sudo apt install apache2-utils
```

This package provides `htpasswd`; it does not install or enable the Apache web server.

Verify:

```bash
command -v htpasswd
dpkg-query -W -f='${Version}\n' apache2-utils
```

The tested package version was:

```text
2.4.66-2ubuntu2.4
```

## 7. Create the protected Nginx credential store

Create a root-owned directory that the Nginx `www-data` workers can traverse:

```bash
sudo install -d \
  -o root \
  -g www-data \
  -m 750 \
  /etc/nginx/auth
```

Create the initial user with bcrypt cost 12:

```bash
sudo htpasswd \
  -c \
  -B \
  -C 12 \
  /etc/nginx/auth/camera-users.htpasswd \
  stephen
```

Important:

- `-c` creates a new file and must be used only for the first user.
- Do not use `-c` when adding later users; it would replace the file.
- Do not include passwords on the command line.
- The command prompts twice without displaying the password.

Set ownership and mode:

```bash
sudo chown root:www-data /etc/nginx/auth/camera-users.htpasswd
sudo chmod 640 /etc/nginx/auth/camera-users.htpasswd
```

Expected:

```text
-rw-r----- root www-data
```

Verify a credential interactively:

```bash
sudo htpasswd \
  -v \
  /etc/nginx/auth/camera-users.htpasswd \
  stephen
```

Expected:

```text
Password for user stephen correct.
```

## 8. Back up Nginx before adding authentication

```bash
sudo cp --update=none \
  /etc/nginx/sites-available/camera-apps \
  /etc/nginx/sites-available/camera-apps.before-auth-2026-08-04
```

## 9. Protect the complete HTTPS camera application

Add authentication at the HTTPS `server` level so it applies to:

- `/cameras/`
- `/multiview/`
- `/outputs/`
- `/webrtc/`

Tested server-level directives:

```nginx
server {
    listen 10.1.1.3:443 ssl;
    server_name camera.home.arpa;

    auth_basic "Camera System";
    auth_basic_user_file /etc/nginx/auth/camera-users.htpasswd;

    # TLS and application configuration follows.
}
```

Authentication at server scope also protects camera registry data and prevents anonymous discovery of stream paths.

## 10. Strip browser credentials before proxying

Nginx validates the browser's Basic Authentication credentials. MediaMTX has a separate authentication layer with its own user database. Do not forward the Nginx password to MediaMTX.

The final proxy block is:

```nginx
location /webrtc/ {
    proxy_pass http://127.0.0.1:8889/;
    proxy_redirect / /webrtc/;
    proxy_set_header Authorization "";
}
```

## 11. Validate and activate Nginx authentication

Validate before reloading:

```bash
sudo nginx -t
```

Reload:

```bash
sudo systemctl reload nginx.service
```

Test without credentials:

```bash
sudo curl \
  --resolve camera.home.arpa:443:10.1.1.3 \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  --head \
  https://camera.home.arpa/cameras/
```

Expected:

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Basic realm="Camera System"
```

Test interactively with credentials without placing the password in shell history:

```bash
sudo curl \
  --user stephen \
  --resolve camera.home.arpa:443:10.1.1.3 \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  --head \
  https://camera.home.arpa/cameras/
```

Curl prompts for the password. Expected:

```text
HTTP/1.1 200 OK
```

Test the authenticated MediaMTX proxy:

```bash
sudo curl \
  --user stephen \
  --silent \
  --show-error \
  --output /dev/null \
  --write-out 'HTTP %{http_code}\nContent-Type: %{content_type}\n' \
  --resolve camera.home.arpa:443:10.1.1.3 \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  https://camera.home.arpa/webrtc/STREAM/PATH/
```

Expected:

```text
HTTP 200
Content-Type: text/html
```

## 12. Test browser authentication

Open a new Firefox Private Window and visit:

```text
https://camera.home.arpa/cameras/
```

Verify:

1. Firefox prompts for a username and password.
2. Cancelling or entering invalid credentials does not reveal the page.
3. Valid credentials load the page and streams.

Firefox caches Basic Authentication credentials for the browser session. To retest the login prompt:

- Close every Private Window and open a new one, or
- Fully quit Firefox and reopen it, or
- Use a different browser or client.

An independent no-cache test is:

```bash
/usr/bin/curl --head https://camera.home.arpa/cameras/
```

Without credentials, this must return `401 Unauthorized`.

Basic Authentication limitations:

- Browser-native prompt rather than a custom login page
- No standard logout button
- Credentials remain cached for the session
- No MFA or advanced session policy

It is appropriate for the initial private-LAN deployment but can later be replaced with an identity service such as Authelia through Nginx `auth_request`.

## 13. Remove the obsolete port-8181 HTTP site

The original Nginx configuration exposed unauthenticated static pages on port `8181`. Once confirmed unused, its entire `server` block was removed.

Validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx.service
```

Verify closure:

```bash
sudo ss -lntp 'sport = :8181'
```

No listener is expected.

## 14. Audit MediaMTX sockets

Discover the process:

```bash
pgrep -a mediamtx
```

Inspect its network sockets, replacing the PID as needed:

```bash
sudo lsof -Pan -p 1744 -i
```

The initial audit showed:

- `TCP *:8554` — inbound RTSP server
- `UDP *:8000` — inbound RTSP RTP
- `UDP *:8001` — inbound RTSP RTCP
- `TCP 127.0.0.1:8889` — loopback WebRTC signaling
- `UDP *:8189` — WebRTC ICE/media
- Multiple outbound connections to camera port `554`
- High-numbered UDP pairs used to receive camera RTSP media

The FUSE warnings emitted by `lsof` concerned unrelated user-mounted filesystems and did not invalidate inspection of ordinary MediaMTX sockets.

## 15. Confirm that configured paths do not require inbound publishing

The global default was:

```yaml
pathDefaults:
  source: publisher
```

Every explicit camera path overrode it with an RTSP source URL. The following command classified paths without revealing credentials:

```bash
awk '
  /^paths:/ { in_paths=1; next }

  in_paths && /^  [^ #][^:]*:$/ {
    path=$0
    sub(/^  /, "", path)
    sub(/:$/, "", path)
  }

  in_paths && /^    source:/ {
    value=$0
    sub(/^    source:[[:space:]]*/, "", value)

    if (value == "" || value == "publisher")
      type="inbound publisher"
    else if (value ~ /^rtsps?:\/\//)
      type="pulled RTSP source"
    else
      type="other source"

    print path ": " type
  }
' /home/stephen/.local/bin/mediamtx.yml
```

All 18 configured paths were classified as `pulled RTSP source`.

## 16. Disable the inbound RTSP server

Create a fresh backup of the already secured configuration:

```bash
cp --update=none \
  /home/stephen/.local/bin/mediamtx.yml \
  /home/stephen/.local/bin/mediamtx.yml.before-disable-rtsp-2026-08-04

chmod 600 \
  /home/stephen/.local/bin/mediamtx.yml.before-disable-rtsp-2026-08-04
```

Change:

```yaml
rtsp: true
```

to:

```yaml
rtsp: false
```

Tested command:

```bash
sed -i \
  's/^rtsp: true$/rtsp: false/' \
  /home/stephen/.local/bin/mediamtx.yml
```

MediaMTX hot-reloaded the change.

Verify the RTSP server ports:

```bash
sudo ss -lntup \
  '( sport = :8554 or sport = :8000 or sport = :8001 )'
```

Expected MediaMTX result:

- No listener on `8554`
- No MediaMTX listener on UDP `8000`
- No listener on `8001`

The tested server still had `kea-ctrl-agent` listening on `127.0.0.1:8000`. This is unrelated to MediaMTX, belongs to DHCP management, and is confined to loopback.

## 17. Verify outbound RTSP ingestion remains active

Count established MediaMTX connections to camera RTSP port `554` without displaying URLs or credentials:

```bash
sudo lsof -Pan -p 1744 -iTCP 2>/dev/null |
awk '
  /->.*:554 \(ESTABLISHED\)$/ { count++ }
  END { print "Established RTSP camera connections:", count+0 }
'
```

Tested result:

```text
Established RTSP camera connections: 18
```

Disabling MediaMTX's RTSP server does not disable MediaMTX acting as an RTSP client for configured camera sources.

## 18. Confirm WebRTC-only protocol configuration

Inspect all MediaMTX server toggles:

```bash
rg -n \
  '^(api|metrics|pprof|playback|rtsp|rtmp|hls|webrtc|srt|moq):' \
  /home/stephen/.local/bin/mediamtx.yml
```

Final tested state:

```yaml
api: false
metrics: false
pprof: false
playback: false
rtsp: false
rtmp: false
hls: false
webrtc: true
srt: false
moq: false
```

## 19. Final verification checklist

- Direct client access to `10.1.1.3:8889` fails.
- Port `8889` listens only on `127.0.0.1`.
- Port `8181` has no listener.
- Ports `8554`, MediaMTX UDP `8000`, and `8001` are closed.
- Unauthenticated HTTPS returns `401 Unauthorized`.
- A fresh browser session prompts for credentials.
- Invalid credentials do not reveal pages or streams.
- Valid credentials display all expected streams.
- All configured camera RTSP connections remain established.
- MediaMTX has only WebRTC enabled as an inbound viewing protocol.

## Adding and removing users

Add another user without `-c`:

```bash
sudo htpasswd \
  -B \
  -C 12 \
  /etc/nginx/auth/camera-users.htpasswd \
  NEW_USERNAME
```

Remove a user:

```bash
sudo htpasswd \
  -D \
  /etc/nginx/auth/camera-users.htpasswd \
  USERNAME
```

After modifying users, verify file ownership and permissions remain:

```text
root:www-data 640
```

Nginx reads the password file per request; a service reload is normally unnecessary after changing users.

## Rollback

### Restore MediaMTX before RTSP shutdown

```bash
cp \
  /home/stephen/.local/bin/mediamtx.yml.before-disable-rtsp-2026-08-04 \
  /home/stephen/.local/bin/mediamtx.yml
chmod 600 /home/stephen/.local/bin/mediamtx.yml
```

MediaMTX should hot-reload. Verify listeners and streams afterward.

### Restore Nginx before authentication

```bash
sudo cp \
  /etc/nginx/sites-available/camera-apps.before-auth-2026-08-04 \
  /etc/nginx/sites-available/camera-apps
sudo nginx -t
sudo systemctl reload nginx.service
```

Be aware that this rollback also restores unauthenticated access and may restore the port-8181 block, depending on the backup's exact state.

## Future improvements

- Replace Basic Authentication with a session-based identity gateway such as Authelia.
- Add MFA for remote or VPN-based access.
- Add firewall rules as defense in depth, even though unused MediaMTX listeners are disabled.
- Restrict WebRTC ICE UDP `8189` to intended client networks where practical.
- Restrict outbound camera connections by interface and destination.
- Encrypt or externalize sensitive camera credentials stored in `mediamtx.yml`.
- Add monitoring for repeated authentication failures.
