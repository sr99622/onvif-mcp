# Camera Applications

This folder contains local camera-viewing applications that share one verified
camera registry.

## Applications

### Camera Switchboard

- URL: `http://127.0.0.1:8080/cameras/`
- Purpose: one large live stream with fast camera switching
- Files: `cameras/`
- Browser settings key: `camera-switchboard:last-camera`

### Four-Camera View

- URL: `http://127.0.0.1:8080/multiview/`
- Purpose: four simultaneous live streams in a responsive 2x2 layout
- Files: `multiview/`
- Browser settings key: `camera-multiview:selected-cameras`

Each tile has its own camera selector. Assignments are remembered in browser
local storage and restored the next time the application opens. The four-camera
view uses each camera's lower-bandwidth substream when configured, while the
single-camera switchboard continues to use the main stream.

## Shared data

Both applications load:

`outputs/camera_registry.json`

This is the authoritative source for camera names, addresses, manufacturers,
models, and media-player URLs. Update the registry once and both applications
will use the change after a page refresh.

Camera entries may provide both `media_player_url` (main stream) and
`substream_player_url` (lower-bandwidth stream). The multiview uses substream URL
and the camera switchboard uses the mainstream URL.

## Start the local server

Serve this folder as the HTTP root:

```powershell
cd C:\Users\sr996\Documents\Codex\2026-07-26\ple
python -m http.server 8080 --bind 127.0.0.1
```

The server listens only on this computer. Keep the server running while using
either application.

## Organization guidelines

- Keep each application in its own folder and give it a stable URL.
- Keep camera identity and stream information in the shared registry.
- Use a unique browser-storage key for each application.
- Do not move or rename a working application without updating its URL and
  documentation.
- Add broadly reusable assets to a future `shared/` folder only when at least
  two applications genuinely need them.
