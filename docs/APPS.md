# Camera Applications — Installation Guide

This document describes how to install the two local camera-viewing
applications in `apps/` so they are served by nginx on this host
(`gmktec.home.arpa`) and pull live streams from the MediaMTX server
(see `docs/MEDIAMTX.md`). It reflects a working deployment, not just the
original design.

## Applications

| App | URL | Purpose |
|-----|-----|---------|
| Camera Switchboard | `http://gmktec.home.arpa/cameras/` | One large live stream with fast camera switching (uses each camera's **main** stream) |
| Four-Camera View | `http://gmktec.home.arpa/multiview/` | Four simultaneous streams in a responsive 2x2 layout (uses each camera's **substream**) |

Both apps are static HTML/CSS/JS. They need no build step and run as the
system nginx user, not under a per-user `python -m http.server` process.

## Prerequisites

1. **MediaMTX must already be installed and running** with every camera
   path online (see `docs/MEDIAMTX.md`). Verify with:
   ```bash
   sudo systemctl status mediamtx --no-pager
   sudo journalctl -u mediamtx | grep "stream is available"
   ```
   Each healthy line looks like
   `INF [path <SERIAL>/<PROFILE>] stream is available and online, N track(s)`.

2. **nginx installed**:
   ```bash
   sudo apt-get install nginx
   ```

3. The apps live at `/home/stephen/Projects/onvif-mcp/apps/` with this layout:
   ```
   apps/
     cameras/index.html  app.js  styles.css     # Camera Switchboard
     multiview/index.html  app.js  styles.css   # Four-Camera View
     outputs/camera_registry.json               # shared registry (authoritative)
   ```

## Step 1: Fix the camera registry URLs

`apps/outputs/camera_registry.json` is the single source of truth for
stream URLs. Every `media_player_url` / `substream_player_url` must point at
the **MediaMTX WebRTC player URL** — not directly at a camera RTSP URI and
not at HTTPS (this host has no TLS):

```
http://gmktec.home.arpa/webrtc/<SERIAL_NUMBER>/<PROFILE_TOKEN>/
```

- `<SERIAL_NUMBER>` = the camera `serial_number` from `get_cameras`
  (camera MCP server).
- `<PROFILE_TOKEN>` = the profile token for that stream. Main stream token
  → `media_player_url`, lower-bandwidth substream token →
  `substream_player_url`.
- **The trailing slash is required.** MediaMTX returns a redirect without it
  and browsers (notably Firefox) may not follow it inside an iframe.
- Use plain `http://` — nginx serves port 80 with no TLS certificate.

Example entry:

```json
{
  "hostname": "Hikvision",
  "ip_address": "10.1.1.70",
  "manufacturer": "HIKVISION",
  "model": "DS-2CD2142FWD-IS",
  "media_player_url": "http://gmktec.home.arpa/webrtc/DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1/",
  "substream_player_url": "http://gmktec.home.arpa/webrtc/DS-2CD2142FWD-IS20171118BBWR129028868/Profile_2/"
}
```

Every path referenced by the registry must exist in `paths:` of
`/etc/mediamtx/mediamtx.yml` (same serial/token naming). Add missing paths
there and restart mediamtx before proceeding.

## Step 2: Let nginx read the project folder

nginx workers run as a system user that cannot traverse `/home/stephen`
(mode `750`). Create a dedicated web user in the owner's group:

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin webcam
sudo usermod -aG stephen webcam     # 'stephen' = the project owner's group
sudo sed -i 's/^user www-data;/user webcam;/' /etc/nginx/nginx.conf
```

The group membership is what grants `x` (traverse) + `r` on
`/home/stephen/Projects/...`. No setuid bits or extra file permissions are
needed.

## Step 3: Configure the nginx vhost

All of this lives in **one** server block alongside the MediaMTX proxy, at
`/etc/nginx/sites-available/mediamtx` (already present from the
MEDIAMTX.md install — extend it; do not create a second vhost):

```nginx
server {
    listen 80;
    server_name gmktec.home.arpa;

    # --- MediaMTX WebRTC proxy (from docs/MEDIAMTX.md, unchanged) ---
    location /webrtc/ {
        proxy_pass http://127.0.0.1:8889/;   # trailing slash REQUIRED
        proxy_redirect / /webrtc/;            # preserve /webrtc/ in redirects

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # --- Camera applications (static, straight from the project folder) ---
    location = /cameras { return 301 /cameras/; }
    location = /multiview { return 301 /multiview/; }

    location /cameras/ {
        alias /home/stephen/Projects/onvif-mcp/apps/cameras/;
    }

    location /multiview/ {
        alias /home/stephen/Projects/onvif-mcp/apps/multiview/;
    }

    # Shared camera registry — both apps fetch it at this root-relative path
    location /outputs/ {
        alias /home/stephen/Projects/onvif-mcp/apps/outputs/;
    }

    location = / {
        return 200 "MediaMTX server at gmktec.home.arpa | apps: /cameras/ (switchboard), /multiview/ (four-camera view)\n";
        add_header Content-Type text/plain;
    }
}
```

Installation:

```bash
sudo cp <your-vhost> /etc/nginx/sites-available/mediamtx
sudo ln -sf /etc/nginx/sites-available/mediamtx /etc/nginx/sites-enabled/mediamtx
sudo rm -f /etc/nginx/sites-enabled/default   # if a default site is enabled
sudo nginx -t
sudo systemctl reload nginx
```

### Configuration notes (lessons learned)

- **`alias`, not `root`.** The app URLs are `/cameras/...` but the files
  live under `apps/cameras/`, so each location needs an `alias` pointing at
  the real directory.
- **No copies of the app files.** Serving by alias means edits to the apps
  take effect immediately — no rebuild, no deploy step. Do not copy them
  into `/usr/share/nginx/html`.
- **Trailing-slash redirects are required in practice.** Browsers request
  `/cameras` (no slash) and Firefox does not append it. Without the two
  `location = /cameras { return 301 ...; }` lines the request falls through
  to nginx's default static root and returns **404** even though
  `/cameras/` works fine.
- **Root-relative asset paths.** The apps reference `/cameras/styles.css`,
  `/multiview/app.js`, and fetch `/outputs/camera_registry.json` with a
  leading slash, so the `location`s above (not relative paths) are what make
  them work. If you move the app roots, update both the vhost and any
  hardcoded references in the HTML/JS.
- **Single-line `return` strings.** A multi-line `"a\n" "b"` form in a
  `return` directive fails `nginx -t` with "invalid number of arguments".

## Step 4: Verify

```bash
# All endpoints should be 200:
for u in /cameras/ /multiview/ /outputs/camera_registry.json \
         /cameras/styles.css /cameras/app.js /multiview/app.js; do
  printf "%-35s %s\n" "$u" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1$u)"
done

# Slash-less URLs must redirect, not 404:
curl -sI http://127.0.0.1/cameras | head -3        # expect 301 -> /cameras/

# A player page through the proxy (trailing slash!):
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1/webrtc/4B0013BPAABE264/MediaProfile000/
```

Then open `http://gmktec.home.arpa/cameras/` in a browser. If a tile stays
black, check `sudo journalctl -u mediamtx` for that path — common causes are
a missing path in `mediamtx.yml`, camera auth failure (`bad status code: 401`),
or a registry URL with the wrong serial/token or a missing trailing slash.

## Browser behavior

- Each app remembers its state in browser localStorage:
  - Switchboard key: `camera-switchboard:last-camera`
  - Multi-view key: `camera-multiview:selected-cameras` (per-tile selections)
- Changing the registry only takes effect after a page refresh.
- The switchboard plays main streams; multi-view deliberately prefers
  substreams to keep four simultaneous connections light on bandwidth.

## Operations

- **Add a camera:** add its entry to `outputs/camera_registry.json` (with
  both stream URLs), make sure the matching paths exist in
  `/etc/mediamtx/mediamtx.yml`, restart mediamtx, refresh the browser. No
  nginx change needed — new cameras are picked up from the registry alone.
- **Restart / reload:**
  ```bash
  sudo systemctl reload nginx     # after vhost changes (nginx -t first)
  sudo systemctl restart mediamtx # after mediamtx.yml changes
  ```
- **Logs:** `sudo tail -n 50 /var/log/nginx/access.log` and
  `sudo journalctl -u mediamtx -f`.

## Security notes

- The apps carry no credentials themselves; camera authentication happens
  inside MediaMTX (`/etc/mediamtx/mediamtx.yml`, mode 640). Access to the
  web UIs is open to anyone who can reach port 80 on this host — same
  posture as documented in `docs/MEDIAMTX.md`. Add an nginx auth layer (e.g.
  `auth_basic`) on the app locations and/or `/webrtc/` if that is not
  acceptable.
