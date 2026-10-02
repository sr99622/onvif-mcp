# Recorded Stream Playback

## Purpose

This document gives agent instructions for displaying MediaMTX recordings from the camera system in an authenticated browser session — the Hermes embedded preview pane by default, or external Chrome via the Hermes browser/CDP controller when the user explicitly asks for their own browser.

The server exposes MediaMTX playback through Nginx at:

```text
https://{{SERVER_FQDN}}/playback/
```

Nginx strips the `/playback/` prefix and proxies to the loopback-only MediaMTX playback server:

```text
http://127.0.0.1:9996/
```

Browser access to `/playback/` is protected with the same oauth2-proxy `auth_request` gate used by `/webrtc/`, `/snapshot/`, `/cameras/`, `/multiview/`, and `/outputs/`.

Do not expose `127.0.0.1:9996` publicly. Public browser access must go through the authenticated HTTPS origin.

## Playback endpoints

Public authenticated endpoints:

```text
https://{{SERVER_FQDN}}/playback/list?path={url_encoded_media_path}[&start={url_encoded_rfc3339}][&end={url_encoded_rfc3339}]
https://{{SERVER_FQDN}}/playback/get?path={url_encoded_media_path}&start={url_encoded_rfc3339}&duration={seconds}[&format=fmp4|mp4]
```

Loopback-only upstream endpoints:

```text
http://127.0.0.1:9996/list?path={url_encoded_media_path}[&start={url_encoded_rfc3339}][&end={url_encoded_rfc3339}]
http://127.0.0.1:9996/get?path={url_encoded_media_path}&start={url_encoded_rfc3339}&duration={seconds}[&format=fmp4|mp4]
```

Media paths are the MediaMTX path names which are dervied from the camera serial number and main stream profile token (camera.serial_number/camera.profiles[0]/token), for example:

```text
4B0013BPAABE264/MediaProfile000
AMC014641NE6L35AT8/MediaProfile000
DS-2CD2142FWD-IS20171118BBWR129028868/Profile_1
5CF2075C9F49/profile1
```

URL-encode the whole path when using it as a query parameter:

```text
4B0013BPAABE264%2FMediaProfile000
```

## Browser display procedure

Use Hermes browser tools to drive an authenticated session. Do not use curl cookies from the shell for browser playback, and do not print session cookies. Trust tool return codes: a successful `open`/navigation call is assumed to have worked — verify with at most one read or page-state check, not repeated probing. Two display paths exist; pick based on how the user asked:

- **Path A — embedded preview pane** (default): the pane beside the chat, driven by `desktop_preview` (open/read/close) and `drive_preview` (elements/click/type/press/reload). Use it unless the user explicitly asks for their own browser.
- **Path B — external Chrome via CDP** (`browser_exec`): ONLY when the user explicitly requests their own browser — never auto-substitute it. Work in ONE tab: navigate the existing tab with `goto_url` (never pile up new tabs), and confirm state with `js(...)`.

### A. Embedded preview pane (default)

1. Open a target playback URL in the pane:

```text
desktop_preview action=open label='playback' url='https://{{SERVER_FQDN}}/playback/list?path=4B0013BPAABE264%2FMediaProfile000'
```

Wait ~5 s, then `action=read`. Read returns `{kind, url, title, text}`; for the list endpoint `text` is the JSON itself.

2. If the pane lands on the Keycloak login page (title/text shows "Sign in"), complete login with the browser-vault workflow: call `browser_vault_list` first. If an item exists for the origin, type the identifier into the username field using `drive_preview` elements + type and submit; the password is filled ONLY by `browser_vault_fill` (the user is prompted in their UI) — never typed or discussed in chat. If nothing is saved, call `browser_vault_save_login`. Then re-read; the pane should now be on the target URL.

3. Once authenticated, re-open the list URL in the same tab (`action=open` with the same URL) so the request carries the session cookie:

```text
desktop_preview action=open url='https://{{SERVER_FQDN}}/playback/list?path=4B0013BPAABE264%2FMediaProfile000'
```

The read returns JSON. Each item has:

```json
{
  "start": "2026-09-26T22:17:07.510524-04:00",
  "duration": 3600.0,
  "url": "http://127.0.0.1:9996/get?..."
}
```

Ignore the returned loopback `url` for browser display. Construct a public authenticated URL under `/playback/get` instead.

4. Build a public playback URL from the chosen JSON entry. Use `format=mp4` when the goal is browser display, because it asks MediaMTX to return a standard MP4 stream.

```python
from urllib.parse import quote
path = '4B0013BPAABE264/MediaProfile000'
start = '2026-09-26T22:17:07.510524-04:00'
duration = 120
video_url = (
    'https://{{SERVER_FQDN}}/playback/get?path=' + quote(path, safe='') +
    '&start=' + quote(start, safe='') +
    '&duration=' + str(duration) +
    '&format=mp4'
)
```

5. Display by opening the URL **directly** in the pane: top-level navigation carries the session cookie and the browser renders the MP4 with native controls — no wrapper page needed.

```text
desktop_preview action=open label='{path} — {start} — {duration}s' url={video_url}
```

Note `read` returns empty `text` for a video page; that is normal, not an error. If you want a labeled header instead, write a player HTML file to the scratch directory and open its path via `desktop_preview` (`action=open url=file:///…`) — but some browsers do not send cookies from file:/data: pages to cross-origin `<video>` sources, so verify playback before relying on that variant.

6. Diagnostics: if nothing renders, check `read`'s title/text for "500" or "Sign in". A 500 (auth-token timeout) can appear even though the open call reported success — a single `drive_preview action=reload` usually clears it. If auth is lost entirely, re-open the list URL and repeat step 2. If reads fail outright ("no page is loaded / bridge timed out") on a current app build, fall back to path B or `get_snapshot`; do not loop identical reads.

### B. External Chrome via CDP (`browser_exec`)

1. Open the authenticated origin or a target playback URL in Chrome:

```python
new_tab('https://{{SERVER_FQDN}}/playback/list?path=4B0013BPAABE264%2FMediaProfile000')
wait_for_load()
print(page_info())
```

From here on, work in that ONE tab: navigate it with `goto_url` — never pile up new tabs.

2. If Chrome lands on the Keycloak/oauth2 login flow, complete login using the browser-vault workflow (identifier via `fill_input`; password only via `browser_vault_fill`; `browser_vault_save_login` if nothing is saved). Never type or ask for passwords, one-time codes, or cookies in chat.

3. Once Chrome has an authenticated session, navigate the same tab to the list URL so the request carries the browser session cookie:

```python
from urllib.parse import quote
path = '4B0013BPAABE264/MediaProfile000'
url = 'https://{{SERVER_FQDN}}/playback/list?path=' + quote(path, safe='')
goto_url(url)
wait_for_load()
print(js('(() => document.body.innerText)()'))
```

The response is JSON with the same shape as path A. Ignore the returned loopback `url`; construct a public authenticated URL under `/playback/get` with `format=mp4`.

4. Display the recording in Chrome by navigating the same tab to a simple HTML video player in a data URL:

```python
from urllib.parse import quote
html = f'''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Camera recording playback</title>
  <style>
    body {{ margin: 0; background: #111; color: #eee; font-family: sans-serif; }}
    header {{ padding: 12px 16px; background: #222; }}
    video {{ width: 100vw; height: calc(100vh - 48px); background: black; }}
  </style>
</head>
<body>
  <header>{path} — {start} — {duration}s</header>
  <video controls autoplay src="{video_url}" type="video/mp4"></video>
</body>
</html>'''
goto_url('data:text/html;charset=utf-8,' + quote(html))
wait_for_load()
print(page_info())
```

5. If playback does not render, check the browser DOM and network-facing state from the page:

```python
print(js('(() => ({title: document.title, text: document.body.innerText, videos: [...document.querySelectorAll("video")].map(v => ({readyState: v.readyState, networkState: v.networkState, error: v.error && v.error.message, currentTime: v.currentTime, duration: v.duration}))}))()'))
```

Then test a shorter duration and `format=fmp4` if needed:

```text
&duration=30&format=fmp4
```

## Selecting recordings

Prefer the main stream paths because this deployment records only main streams. Substreams are live-only unless explicitly configured otherwise.

To list all current recording directories from the server shell without exposing browser credentials:

```bash
sudo find /var/lib/mediamtx/recordings -mindepth 2 -maxdepth 2 -type d -printf '%P\n'
```

To list timespans for a path from the server shell, use the loopback endpoint:

```bash
curl -sS 'http://127.0.0.1:9996/list?path=4B0013BPAABE264%2FMediaProfile000'
```

This shell loopback check bypasses browser authentication and is only for server-side diagnostics. Browser display must use the public `/playback/` URL.

## ffmpeg availability

ffmpeg may not be on the server's PATH even though a working build ships with the Hermes installation:

```bash
ls ~/.hermes/tools/ | grep '^ffmpeg'   # e.g. ffmpeg-9.0.1-linux-x64
FF=$(ls -d ~/.hermes/tools/ffmpeg-*/bin/ffmpeg)   # unquoted glob expansion — do NOT quote the pattern
"$FF" -version   # verify before use
```

Prefer this hermes-bundled binary in the remux steps below over installing a system package or downloading a static build — it is present on every machine running Hermes and needs no dependencies.

## Seekable static MP4 workflow

MediaMTX `/playback/get` dynamically generates the response. Chrome can play that response, but it is not a normal seekable file because MediaMTX sends it without byte-range support:

```text
Accept-Ranges: none
Transfer-Encoding: chunked
```

The native Chrome scrub bar may not be able to jump forward inside that dynamic response. To make a recording seekable with normal browser controls, download the requested time slice from MediaMTX, remux it into a static MP4, and serve that file through Nginx with byte-range support.

### 1. Create a static playback cache directory

Use a directory outside the source tree. The Nginx worker user in this deployment is `webcam`, so the directory and file modes must allow that user to traverse and read the files.

```bash
sudo install -d -o www-data -g www-data -m 0755 /srv/camera-playback-cache
```

### 2. Download and remux a clip

Example: Amcrest main stream from 9:00 AM for 10 minutes.

```bash
work="$HOME/.hermes/cache/scratch/amcrest_0900_remux"
mkdir -p "$work"

src="$work/amcrest_2026-09-27_0900_10min_source.mp4"
out="$work/amcrest_2026-09-27_0900_10min_static.mp4"

FF=$(ls -d $HOME/.hermes/tools/ffmpeg-*/bin/ffmpeg)   # hermes-bundled build; see "ffmpeg availability"

curl -L --fail --silent --show-error \
  'http://127.0.0.1:9996/get?path=AMC014641NE6L35AT8%2FMediaProfile000&start=2026-09-27T09%3A00%3A00-04%3A00&duration=600&format=mp4' \
  -o "$src"

"$FF" -y -hide_banner -loglevel error \
  -i "$src" \
  -map 0 \
  -c copy \
  -movflags +faststart \
  "$out"

sudo install -o www-data -g www-data -m 0644 \
  "$out" \
  /srv/camera-playback-cache/amcrest_2026-09-27_0900_10min.mp4
```

`-c copy` avoids transcoding. `-movflags +faststart` moves the MP4 metadata to the front of the file so browsers can start playback and seek efficiently.

### 3. Serve the static cache through authenticated Nginx

Add this location inside the existing HTTPS server block, before the `/playback/` proxy location:

```nginx
location /playback-cache/ {
    auth_request /oauth2/auth;
    error_page 401 = @oauth2_signin;
    auth_request_set $auth_cookie $upstream_http_set_cookie;
    add_header Set-Cookie $auth_cookie always;

    alias /srv/camera-playback-cache/;
    add_header Accept-Ranges bytes always;
}
```

Then validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

The public URL for the example clip is:

```text
https://{{SERVER_FQDN}}/playback-cache/amcrest_2026-09-27_0900_10min.mp4
```

This URL remains protected by oauth2-proxy, like `/playback/`, `/webrtc/`, and `/snapshot/`. It is a normal authenticated URL, so it can be shown in the embedded preview pane directly (path A, step 5) as well as in external Chrome.

### 4. Verify byte-range support

From an authenticated browser session, or with a local diagnostic that can access the route, verify that Nginx returns partial content for range requests:

```text
HTTP 206 Partial Content
Accept-Ranges: bytes
Content-Range: bytes 0-1023/{file_size}
Content-Length: 1024
Content-Type: video/mp4
```

A verified example returned:

```text
HTTP status: 206
Accept-Ranges: bytes
Content-Range: bytes 0-1023/309881382
Content-Length: 1024
Content-Type: video/mp4
```

When loaded in Chrome, the static file should report a normal finite duration, no video error, and support native seek/scrub controls.

### 5. Cleanup

The static cache is not automatically pruned by MediaMTX `recordDeleteAfter`. Delete static files when no longer needed, or add a separate retention policy for `/srv/camera-playback-cache` if this workflow becomes routine.

```bash
sudo rm -f /srv/camera-playback-cache/amcrest_2026-09-27_0900_10min.mp4
```

Do not store camera credentials or browser session cookies in cached files, filenames, shell history, or documentation.

## Security and routing checks

Expected unauthenticated public behavior:

```text
https://{{SERVER_FQDN}}/playback/      -> 302 /oauth2/start?rd=/playback/
https://{{SERVER_FQDN}}/playback/list  -> 302 /oauth2/start?rd=/playback/list...
https://{{SERVER_FQDN}}/playback/get   -> 302 /oauth2/start?rd=/playback/get...
```

Expected listener state:

```text
MediaMTX playback: 127.0.0.1:9996 only
Nginx public HTTPS: :443
```

Do not add unauthenticated aliases for `/list` or `/get`. Keep playback behind `/playback/` so the route family is clear and protected.
