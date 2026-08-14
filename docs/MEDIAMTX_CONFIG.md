# MediaMTX Server Configuration

This document describes the MediaMTX RTSP-to-WebRTC/HLS streaming server deployed on `nuc.home.arpa`. It pulls live video from IP cameras and makes them available via WebRTC for browser playback.

## Binary Executable

location: https://github.com/bluenviron/mediamtx/releases

look for the latest amd64 binary, it will look something like

mediamtx_v1.20.0_linux_amd64.tar.gz

In this example, the most recent version is 1.20.0, which can change. The generic representation of this name would be

mediamtx_v{version}_linux_amd64.tar.gz

Example Deployment steps:
```bash
# Download latest version
curl -sL "https://github.com/bluenviron/mediamtx/releases/download/v1.20.0/mediamtx_v1.20.0_linux_amd64.tar.gz" | tar xz

# Install binary
sudo cp mediamtx /usr/local/bin/mediamtx && sudo chmod 755 /usr/local/bin/mediamtx
```

## Deployment Details

| Item | Value |
|------|-------|
| Server URL | http://{server_hostname}.home.arpa/webrtc/ |
| Binary | `/usr/local/bin/mediamtx` |
| Config | `/etc/mediamtx/mediamtx.yml` |
| Service | `sudo systemctl status mediamtx` (system service, multi-user.target) |
| User | `mediamtx:mediamtx` (dedicated system user) |

### Prerequisites: Create System User

```bash
sudo groupadd --system mediamtx
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g mediamtx mediamtx
sudo mkdir -p /etc/mediamtx /var/log/mediamtx
```

## Protocols & Ports

| Protocol | Port(s) | Status | Use |
|----------|---------|--------|-----|
| RTSP | **127.0.0.1:8554** (TCP only) | **Enabled** | Camera pulls (loopback only — not accessible from LAN) |
| WebRTC | :8889 (TCP HTTP), :8189 (UDP ICE) | **Enabled** | Browser live streams |
| HLS | :8888 | Disabled | Low-latency HLS segments |
| RTMP | :1935 | Disabled | RTMP ingest |
| SRT | :8890 | Disabled | Secure Reliable Transport |

Note: UDP RTP (ports 8000, 8001) and multicast ports (8002, 8003) are **disabled**. Camera streams are pulled over TCP interleaved within the RTSP connection. This reduces exposed attack surface while WebRTC clients continue working normally through port 8889.

UDP port 8189 carries the actual WebRTC audio/video media between MediaMTX and the browser.

The connection works in two stages:

1. nginx proxies HTTP signaling to MediaMTX on TCP 8889. This loads the player and negotiates the WebRTC session.

2. The browser then connects directly to MediaMTX on UDP 8189 using ICE/DTLS/SRTP. The encrypted camera stream travels over this connection.

So nginx does not normally proxy UDP 8189. If it is bound to 127.0.0.1, remote browsers can load the player but cannot receive video.

The appropriate arrangement is:
```
webrtcAddress: 127.0.0.1:8889      # signaling through nginx
webrtcLocalUDPAddress: :8189        # media reachable by browsers
```
UDP 8189 carries encrypted WebRTC media, not the original unencrypted RTSP feed. A firewall can restrict it to trusted LAN/VPN client networks.

## Camera Streams

Each camera exposes two or more named paths in the YAML config. The streams are declared in the `paths:` section of the `mediamtx.yml`. The path consists of a name and a `source:` field. The name is a combination of the camera serial number and profile token delimited by a slash character. The source is the camera RTSP endpoint, known as the stream_uri, modified to include the username and password credentials for authorization. Agents can collect the necessary camera data from the camera MCP server tool get_cameras. The username and password can be found from the environment variables CAMERA_USERNAME and CAMERA_PASSWORD.

### Exmaple Camera Stream Path Construction

The camera path is constructed using the formula

```py
  {serial_number}/{profile.token}
    source: {stream_uri[:7]}{username}:{password}@{stream_uri[7:]}
```

Using concrete example values

* Serial Number: DS-2CD2142022579764
* Profile Token: Profile_1
* Stream URI: rtsp://10.1.1.70:554/Streaming/Channels/101?transportmode=unicast&profile=Profile_1
* Username: admin
* Password: admin123

```yaml
paths:
  DS-2CD2142022579764/Profile_1:
    source: rtsp://admin:admin123@10.1.1.70:554/Streaming/Channels/101?transportmode=unicast&profile=Profile_1
```

## Authentication

MediaMTX uses **internal database mode** with permissive access rules — no password is required for any user (`pass:` is empty). The config grants full permissions (publish, read, playback) to all cameras. Access control is managed by the nginx proxy front end.

## MediaMTX Configuration File (`/etc/mediamtx/mediamtx.yml`)

```yaml
logLevel: info
logDestinations: [stdout]

# RTSP server (loopback only)
rtsp: true
rtspTransports: [tcp]
rtspAddress: 127.0.0.1:8554

# WebRTC server
webrtc: true
webrtcAddress: 127.0.0.1:8889
webrtcLocalUDPAddress: :8189

# Disable unused protocols to reduce attack surface
rtmp: false
hls: false
srt: false
moq: false
api: false  # Not needed for basic operation

# Authentication - internal mode, no password required
authMethod: internal
authInternalUsers:
  - user: any
    pass: ""
    ips: []
    permissions:
      - action: publish
        path: ""
      - action: read
        path: ""
      - action: playback
        path: ""

# Camera paths (pull from RTSP sources)
paths:
  DS-2CD2142022579764/Profile_1:
    source: rtsp://admin:admin123@10.1.1.70:554/Streaming/Channels/101?transportmode=unicast&profile=Profile_1
  # ... additional paths follow same pattern
```

## Systemd Service Setup

Service file at `/etc/systemd/system/mediamtx.service`:

```ini
[Unit]
Description=MediaMTX RTSP-to-WebRTC streaming server
Documentation=https://github.com/bluenviron/mediamtx
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mediamtx
Group=mediamtx
WorkingDirectory=/var/lib/mediamtx
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mediamtx

ReadWritePaths=/var/log/mediamtx /var/lib/mediamtx

[Install]
WantedBy=multi-user.target
```

Installation steps:
```bash
sudo cp mediamtx.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable mediamtx
sudo systemctl start mediamtx
sudo systemctl status mediamtx  # verify active (running)
```

## Nginx Reverse Proxy Configuration

**Critical:** The nginx reverse proxy requires TWO specific directives that are often missing:

1. **Trailing slash in `proxy_pass`**: `http://127.0.0.1:8889/` (note the trailing slash)
2. **`proxy_redirect / /webrtc/;`** — this ensures MediaMTX's redirects preserve the `/webrtc/` prefix

Without these, MediaMTX returns a redirect like `302 Location: /camera/path/`, which nginx then tries to serve as a static file (causing 405 errors or broken behavior).

Full nginx config at `/etc/nginx/sites-available/mediamtx`:

```nginx
server {
    listen 80;
    server_name nuc.home.arpa;

    location /webrtc/ {
        proxy_pass http://127.0.0.1:8889/;   # trailing slash REQUIRED
        proxy_redirect / /webrtc/;            # preserve /webrtc/ in redirects

        # WebSocket support for WebRTC signaling
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Long timeouts for WebRTC sessions
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location = / {
        return 200 "MediaMTX server at nuc.home.arpa\n";
        add_header Content-Type text/plain;
    }
}
```

Installation:
```bash
sudo cp mediamtx /etc/nginx/sites-available/mediamtx
sudo ln -sf /etc/nginx/sites-available/mediamtx /etc/nginx/sites-enabled/mediamtx
sudo rm -f /etc/nginx/sites-enabled/default  # if needed
sudo nginx -t                              # test configuration
sudo systemctl reload nginx                # apply changes
```

### URL Format (Trailing Slash Required)

MediaMTX requires a **trailing slash** at the end of camera paths. Both work:

- ✅ `http://nuc.home.arpa/webrtc/DS-2CD2142022579764/Profile_1/`
- ❌ `http://nuc.home.arpa/webrtc/DS-2CD2142022579764/Profile_1` (redirects but browser may not follow)

The `proxy_redirect / /webrtc/;` directive ensures that MediaMTX's internal redirects preserve the `/webrtc/` prefix.

## Operations

### Check status and logs
```bash
sudo systemctl status mediamtx --no-pager
sudo journalctl -u mediamtx -f                    # live logs
sudo tail -n 50 /var/log/mediamtx/mediamtx.log     # file log (if configured)
```

### Restart
```bash
sudo systemctl restart mediamtx
```

### View running cameras (from status output)
MediaMTX prints a startup line showing which paths have online streams. Look for:
- `INF [path <name>] stream is available and online, N track(s)` = healthy
- `ERR [path <name>] bad status code: 401` = camera auth failure (occurs on HIKVISION Profile_2)

### Adding a new camera
1. Add a new path entry in `/etc/mediamtx/mediamtx.yml`:
```yaml
paths:
  NewCameraName/Profile_1:
    source: rtsp://admin:<password>@<camera_ip>:554/path_to_stream
```
2. Restart the service:
```bash
sudo systemctl restart mediamtx
```

### Removing a camera
Delete the path entry from `/etc/mediamtx/mediamtx.yml` and restart.

## Security Notes

- Camera credentials are embedded in RTSP URLs in the config file (`/etc/mediamtx/mediamtx.yml`). Keep this file protected (mode 640, owned by mediamtx:mediamtx).
- MediaMTX listens on `0.0.0.0` for WebRTC ports, but access flows through Nginx at `/webrtc/`.
- Without authentication layers, anyone on the network who can reach port 8889 (or port 80 via nginx) gets a live stream.
- All cameras use default credentials (`admin` / `admin123`). Changing them should be scheduled for a maintenance window if possible.

## Known Issues

### RTP Packet Loss
Some camera streams show warnings in logs:
```
WAR [path DS-2CD2142022579764/Profile_1] [RTSP source] 14 RTP packets lost
WAR [path DS-2CD2142022579764/Profile_1] 23 processing errors, last was: invalid FU-A packet (non-starting)
```

These are common with Hikvision cameras and do not prevent streaming. The streams remain available despite the warnings. Amcrest cameras on certain substreams may show similar behavior.

## Related Documents

- **SYSTEMD_SETUP.md** — service startup and management
- **STREAM_AUTH.md** — browser authentication (Keycloak/oauth2-proxy)
- **HTTPS.md** — TLS certificate setup for nuc.home.arpa
- **DESIGN.md** — overall ONVIF MCP architecture
- **KEYCLOAK.md** — Keycloak realm and client configuration
