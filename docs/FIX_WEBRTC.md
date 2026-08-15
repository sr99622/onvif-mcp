# Fix WebRTC Endpoints (2026-08-14)

## Problem

The `nuc.home.arpa` MediaMTX server was running but the `/webrtc/` endpoints returned 404 errors.

## Root Causes

### 1. Conflicting Nginx Server Blocks

Two enabled site configs both used `server_name nuc.home.arpa` on port 80:

- `/etc/nginx/sites-enabled/mediamtx` — had the `/webrtc/` proxy location
- `/etc/nginx/sites-enabled/camera-mcp` — had the `/mcp` proxy location

Nginx silently ignores duplicate server names for the same host+port, warning only:

```
conflicting server name "nuc.home.arpa" on 0.0.0.0:80, ignored
```

The `camera-mcp` block was selected; since it had no `/webrtc/` route, all WebRTC requests fell through to nginx's default 404.

### 2. Camera Serial Number Mismatch (Hikvision)

The Hikvision camera at `10.1.1.70` had been replaced — its serial number changed from
`DS-2CD2142022579764` to `DS-2CD2142FWD-IS20171118BBWR129028868`.
The MediaMTX config still referenced the old serial, so MediaMTX returned:

```json
{"status":"error","error":"path 'DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1' is not configured"}
```

## Fixes Applied

### Fix 1: Merge Nginx Configs into One Server Block

Combined the `/webrtc/`, `/mcp`, and `/` locations into a single server block in:
- **Config file:** `/etc/nginx/sites-available/camera-mcp`
- **Remove symlink:** `/etc/nginx/sites-enabled/mediamtx` (no longer needed)

The merged config includes all four location blocks:

| Location | Proxies To | Purpose |
|----------|-----------|---------|
| `/webrtc/` | `http://127.0.0.1:8889/` (with `proxy_redirect`) | MediaMTX WebRTC playback |
| `/mcp` (exact) | `http://127.0.0.1:8001/mcp` | ONVIF MCP JSON-RPC endpoint |
| `/mcp/` | 301 to `/mcp` | Redirect trailing slash |
| `/` (exact) | Inline `200` response | Health check placeholder |

Reload nginx:

```bash
sudo systemctl restart nginx
```

### Fix 2: Update MediaMTX Config for New Camera Serial

Updated path names in the MediaMTX config:
- **Repo config:** `/home/stephen/Projects/onvif-mcp/configs/mediamtx/mediamtx.yml`
- **Live config:** `/etc/mediamtx/mediamtx.yml`

Changed:
```yaml
# OLD (camera was replaced)
DS-2CD2142022579764/Profile_1:
  source: rtsp://admin:admin123@10.1.1.70:554/Streaming/Channels/101?...

# NEW
DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1:
  source: rtsp://admin:admin123@10.1.1.70:554/Streaming/Channels/101?...
```

Restart MediaMTX:

```bash
sudo systemctl restart mediamtx
```

## Verification

After fixes, all WebRTC endpoints return HTTP 200:

```bash
# All four cameras working (example):
curl -sI http://nuc.home.arpa/webrtc/AMC014641NE6L35AT8/MediaProfile000/
# -> HTTP/1.1 200 OK

curl -sI http://nuc.home.arpa/webrtc/DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1/
# -> HTTP/1.1 200 OK
```

## Known Issues

### Persistent RTSP Packet Loss / FU-A Errors

All cameras show frequent warnings in MediaMTX logs:

- `[RTSP source] N RTP packets lost` (recurring on every path)
- `processing error: invalid FU-A packet (non-starting)`
- `discarding frame since a RTP packet is missing`

This causes occasional video stuttering or artifacts. The issue appears to be network-level (switch/router, camera firmware, or MTU settings). MediaMTX is still able to reconstruct frames and serve them, so playback works but may be imperfect. If this becomes more severe per-camera investigation is needed (RTSP transport mode, MTU, QoS on the switch).

### No HTTPS Yet

Nginx only listens on port 80. The `camera_registry.json` references `https://gmktec.home.arpa/` URLs for other sites. If HTTPS is needed on nuc, SSL termination must be added to nginx (self-signed cert or Let's Encrypt via certbot).

## Files Changed

| File | Change |
|------|--------|
| `/home/stephen/Projects/onvif-mcp/configs/mediamtx/mediamtx.yml` | Updated Hikvision camera serial numbers for paths at `10.1.1.70` |
| `/etc/nginx/sites-available/camera-mcp` (live) | Merged mediamtx + camera-mcp server blocks into one config |
| Removed: `/etc/nginx/sites-enabled/mediamtx` | No longer needed after merge |
