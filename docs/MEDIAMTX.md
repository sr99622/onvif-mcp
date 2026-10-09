# MediaMTX Server Configuration

## Purpose

Configure MediaMTX to pull camera RTSP streams, serve browser WebRTC streams, and record main camera profiles.

Target state:

- Binary: `/usr/local/bin/mediamtx`
- Config: `/etc/mediamtx/mediamtx.yml`, mode `640 mediamtx:mediamtx`
- Recordings: `/var/lib/mediamtx/recordings`
- Service: `mediamtx.service`, enabled and active
- RTSP: `127.0.0.1:8554` TCP only
- WebRTC signaling: `127.0.0.1:8889`, proxied by nginx at `http://{{SERVER_FQDN}}/webrtc/`
- WebRTC media: UDP `:8189`
- Playback API: `127.0.0.1:9996`, proxied by nginx at `/playback/`
- One MediaMTX path for every camera profile returned by `get_cameras`
- Recording enabled only for the first/main profile of each camera

## Required Values

| Value | Description |
|---|---|
| `{{SERVER_FQDN}}` | Server fully qualified domain name |
| `{{CAMERA_USERNAME}}` | Camera username, normally `admin` |
| `pass show camera` | Camera password from the local password store |
| `{{REPO_PATH}}` | Full path to this repository |

Stop and ask the user if any required value is missing. Do not ask the user to paste the camera password into the runbook, shell history, or chat. The executable script reads the first line from `pass show camera` and URL-encodes it before writing MediaMTX RTSP source URLs.

## Agent Presentation Rules

This document is a script for the agent. The executable source of truth is:

```text
{{REPO_PATH}}/scripts/MEDIAMTX/mediamtx_runbook.sh
```

Before executing any AGENT-run command or presenting any USER-run command, replace every double-curly placeholder with the real site value. Do not ask the user to type placeholders literally.

For this runbook, the agent normally runs the commands directly. If a command must be shown to the user, include `cd {{REPO_PATH}}` as the first line of the copy-paste block after resolving `{{REPO_PATH}}`.

Do not replace the scripted workflow with ad hoc shell fragments. If behavior must change, update `scripts/MEDIAMTX/mediamtx_runbook.sh` and keep this runbook as orchestration guidance.

## 1. Apply MediaMTX Configuration (AGENT-run)

Run from the repository directory:

```bash
cd {{REPO_PATH}}
scripts/MEDIAMTX/mediamtx_runbook.sh apply \
  --server-fqdn {{SERVER_FQDN}} \
  --camera-username {{CAMERA_USERNAME}} \
  --repo-path {{REPO_PATH}}
```

The script performs the full MediaMTX runbook:

- Installs missing Debian/Ubuntu packages when `apt-get` is available.
- Downloads and installs the latest Linux amd64 MediaMTX release if `/usr/local/bin/mediamtx` is missing.
- Creates the dedicated `mediamtx:mediamtx` system user and protected directories.
- Calls the camera MCP HTTP server `get_cameras` tool through `http://{{SERVER_FQDN}}/mcp`.
- Reads the camera password from `pass show camera` and URL-encodes it.
- Generates `/etc/mediamtx/mediamtx.yml` with one path per camera profile.
- Adds `record: true` only to the first/main profile for each camera.
- Writes `/etc/systemd/system/mediamtx.service`.
- Adds nginx locations for `/webrtc/`, `/playback/`, and `/playback-cache/` to the existing camera site.
- Enables and restarts nginx and MediaMTX.
- Prints non-secret status output.

If `pass show camera` fails because GPG needs the passphrase, stop and ask the user to run this in their own terminal:

```bash
cd {{REPO_PATH}}
pass show camera >/dev/null
```

After the user confirms that command succeeded, rerun the `apply` command. Do not ask the user to paste the GPG passphrase or camera password into chat.

## 2. Verify MediaMTX (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/MEDIAMTX/mediamtx_runbook.sh status --server-fqdn {{SERVER_FQDN}}
```

Acceptance checks:

- `/usr/local/bin/mediamtx` exists and prints a version.
- `mediamtx.service` is enabled and active.
- `/etc/mediamtx` is `750 mediamtx:mediamtx`.
- `/etc/mediamtx/mediamtx.yml` is `640 mediamtx:mediamtx`.
- Listeners exist on `127.0.0.1:8554`, `127.0.0.1:8889`, `127.0.0.1:9996`, and UDP `:8189`.
- The generated path count equals the total number of profiles returned by `get_cameras`.
- Recent MediaMTX logs show camera paths becoming `stream is available and online`.

Warnings about skipped generic tracks or occasional RTP packet loss are not, by themselves, a failure if the stream is online.

## 3. Test WebRTC Proxy (AGENT-run)

Run:

```bash
cd {{REPO_PATH}}
scripts/MEDIAMTX/mediamtx_runbook.sh test --server-fqdn {{SERVER_FQDN}}
```

The script selects the first configured MediaMTX path and requests `http://{{SERVER_FQDN}}/webrtc/<serial>/<profile>/` through nginx. The test passes when the endpoint returns an HTTP success or redirect status.

## Operational Notes

MediaMTX camera credentials are embedded in `/etc/mediamtx/mediamtx.yml` as RTSP source URLs. Keep that file protected and never copy it into chat or source control.

Public browser access to `/webrtc/` is plain HTTP at this stage. TLS and Keycloak are added by later runbooks.
