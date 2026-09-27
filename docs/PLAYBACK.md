# Recorded Stream Playback

## Purpose

This document gives agent instructions for displaying MediaMTX recordings from the camera system in Chrome through the Hermes browser/CDP controller.

The server exposes MediaMTX playback through Nginx at:

```text
https://gmktec.home.arpa/playback/
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
https://gmktec.home.arpa/playback/list?path={url_encoded_media_path}[&start={url_encoded_rfc3339}][&end={url_encoded_rfc3339}]
https://gmktec.home.arpa/playback/get?path={url_encoded_media_path}&start={url_encoded_rfc3339}&duration={seconds}[&format=fmp4|mp4]
```

Loopback-only upstream endpoints:

```text
http://127.0.0.1:9996/list?path={url_encoded_media_path}[&start={url_encoded_rfc3339}][&end={url_encoded_rfc3339}]
http://127.0.0.1:9996/get?path={url_encoded_media_path}&start={url_encoded_rfc3339}&duration={seconds}[&format=fmp4|mp4]
```

Media paths are the MediaMTX path names, for example:

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

## Browser/CDP display procedure

Use the Hermes browser controller (`browser_exec`) to drive Chrome. Do not use curl cookies from the shell for browser playback, and do not print session cookies.

1. Open the authenticated origin or a target playback URL in Chrome:

```python
new_tab('https://gmktec.home.arpa/playback/list?path=4B0013BPAABE264%2FMediaProfile000')
wait_for_load()
print(page_info())
```

2. If Chrome lands on the Keycloak/oauth2 login flow, complete login using the browser-vault workflow. Never type or ask for passwords, one-time codes, or cookies in chat.

3. Once Chrome has an authenticated session, query the list endpoint from the browser context so the request carries the browser session cookie:

```python
from urllib.parse import quote
path = '4B0013BPAABE264/MediaProfile000'
url = 'https://gmktec.home.arpa/playback/list?path=' + quote(path, safe='')
new_tab(url)
wait_for_load()
print(js('(() => document.body.innerText)()'))
```

The response is JSON. Each item has:

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
    'https://gmktec.home.arpa/playback/get?path=' + quote(path, safe='') +
    '&start=' + quote(start, safe='') +
    '&duration=' + str(duration) +
    '&format=mp4'
)
print(video_url)
```

5. Display the recording in Chrome by creating a simple HTML video player in a data URL:

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
new_tab('data:text/html;charset=utf-8,' + quote(html))
wait_for_load()
print(page_info())
```

6. If playback does not render, check the browser DOM and network-facing state from the page:

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

curl -L --fail --silent --show-error \
  'http://127.0.0.1:9996/get?path=AMC014641NE6L35AT8%2FMediaProfile000&start=2026-09-27T09%3A00%3A00-04%3A00&duration=600&format=mp4' \
  -o "$src"

ffmpeg -y -hide_banner -loglevel error \
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
https://gmktec.home.arpa/playback-cache/amcrest_2026-09-27_0900_10min.mp4
```

This URL remains protected by oauth2-proxy, like `/playback/`, `/webrtc/`, and `/snapshot/`.

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
https://gmktec.home.arpa/playback/      -> 302 /oauth2/start?rd=/playback/
https://gmktec.home.arpa/playback/list  -> 302 /oauth2/start?rd=/playback/list...
https://gmktec.home.arpa/playback/get   -> 302 /oauth2/start?rd=/playback/get...
```

Expected listener state:

```text
MediaMTX playback: 127.0.0.1:9996 only
Nginx public HTTPS: :443
```

Do not add unauthenticated aliases for `/list` or `/get`. Keep playback behind `/playback/` so the route family is clear and protected.
