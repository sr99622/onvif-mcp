# Camera Switchboard

## What we built

The Camera Switchboard is a small, local web application that displays a list
of cameras and loads the selected live stream into one reusable viewer.

Its local address is:

```text
http://127.0.0.1:8080/cameras/
```

The important behavior is that selecting another camera changes the `src` of
the existing `<iframe>`. It does not create a new browser tab or window. This
makes switching fast and keeps the browser workspace tidy.

## File layout

```text
ple/
├── SWITCHBOARD.md
├── cameras/
│   ├── index.html
│   ├── styles.css
│   └── app.js
└── outputs/
    └── camera_registry.json
```

- `cameras/index.html` defines the sidebar, camera list, Previous/Next buttons,
  and the single iframe used as the media viewer.
- `cameras/styles.css` provides the responsive dark interface.
- `cameras/app.js` loads the registry, creates the camera buttons, and performs
  camera switching.
- `outputs/camera_registry.json` is the data source. It keeps camera identity,
  network information, and the explicit media-player URL together.

## The registry

Each camera is represented by an object like this:

```json
{
  "hostname": "Back-Door",
  "ip_address": "10.1.1.71",
  "manufacturer": "Amcrest",
  "model": "IP2M-841EB",
  "media_player_url": "http://10.1.1.1:8889/AMC014641NE6L35AT8/MediaProfile000"
}
```

The `hostname` is the friendly name shown in the switchboard. The
`media_player_url` is the address placed directly into the viewer when the
camera is selected.

Keeping the complete player URL in the registry avoids rediscovering or
reconstructing it during every switch. To add another camera, add another
object to the `cameras` array and make sure it has a valid
`media_player_url`. The interface is generated from the registry
automatically.

## How switching works

When the page loads, `app.js` requests:

```text
/outputs/camera_registry.json
```

It filters out entries without a player URL and creates one button for every
remaining camera. Clicking a button calls `selectCamera(index)`, which:

1. Finds the camera at that index.
2. Assigns its `media_player_url` to `player.src`.
3. Updates the displayed name, IP address, manufacturer, and model.
4. Marks the corresponding button as active.
5. Saves the selected hostname in browser local storage.

The core switching statement is:

```js
player.src = camera.media_player_url;
```

Because `player` always refers to the same iframe, the selected stream replaces
the previous stream in the same tab.

The Previous and Next buttons use the same function. This expression wraps
around at both ends of the list:

```js
selectedIndex = (index + cameras.length) % cameras.length;
```

For example, selecting Next on the final camera returns to the first camera.

## Remembering the last camera

After every selection, the hostname is stored under:

```text
camera-switchboard:last-camera
```

On the next page load, the switchboard looks for that hostname in the current
registry and selects it. If the stored camera no longer exists, the first
camera is selected instead.

This is browser-local state. It does not modify the JSON registry.

## Why a local server is needed

The page should be served over HTTP instead of opened directly as a
`file:///...` document. Browsers commonly restrict `fetch()` from local files,
so opening `index.html` directly can prevent it from loading the JSON registry.

Serving the workspace root also makes both required URL paths available from
one origin:

```text
/cameras/
/outputs/camera_registry.json
```

The current server listens only on `127.0.0.1`, so it is available from this
computer but is not exposed to other devices on the network.

## Starting the server later

From the workspace root, a simple Python server is sufficient:

```powershell
cd C:\Users\sr996\Documents\Codex\2026-07-26\ple
python -m http.server 8080 --bind 127.0.0.1
```

If Windows uses the Python launcher instead:

```powershell
py -m http.server 8080 --bind 127.0.0.1
```

Keep that terminal open while using the switchboard, then visit:

```text
http://127.0.0.1:8080/cameras/
```

Stop the foreground server with `Ctrl+C`.

For this Codex session, the server was started through a persistent local
runtime after Windows blocked creation of a detached PowerShell process. The
HTTP page and registry endpoint were each verified with status `200`.

## Reusing this pattern

This architecture is useful for more than cameras. The same pattern works for
any collection of named destinations:

- dashboards or monitoring panels;
- internal tools;
- documentation pages;
- device administration pages;
- media players;
- remote lab views.

The reusable pieces are:

1. A JSON registry containing friendly names and destination URLs.
2. JavaScript that creates navigation controls from the registry.
3. One persistent iframe whose URL changes when an item is selected.
4. A small HTTP server that serves the application and its data.

To adapt it, change the registry fields and adjust the information displayed
beside the iframe. The switching mechanism can remain almost unchanged.

## Practical cautions

- Only place trusted URLs in the registry. Loading a URL in an iframe runs
  content supplied by that destination.
- Some websites refuse to appear inside an iframe by sending
  `X-Frame-Options` or Content Security Policy headers. The current relay
  player URLs allow this configuration.
- If the switchboard is served over HTTPS while a player uses HTTP, the browser
  may block the player as mixed content. The current switchboard and relay both
  use HTTP.
- Do not expose the local server to the wider network unless that is
  intentional and appropriate access controls are added.
- If port `8080` is already occupied, choose another port in the server command
  and use the same port in the browser address.
- The registry request uses `cache: "no-store"`, so refreshing the switchboard
  picks up registry edits without relying on a cached copy.

## Possible next improvements

- Add a search box for larger camera lists.
- Display stream health and reconnect status.
- Add keyboard shortcuts for Previous and Next.
- Group cameras by location or manufacturer.
- Add an automatic round-robin mode with a configurable interval.
- Move editable settings into a small administration page.
- Run the server as a managed background service if the switchboard becomes a
  permanent tool.
