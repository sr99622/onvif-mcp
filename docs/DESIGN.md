# ONVIF MCP Shared-Core Design and Handoff

## Purpose of this document

This document records the reasoning and implementation history behind the
shared ONVIF MCP core package. It is intended to let a developer or a fresh
agent resume this work without access to the conversation in which the design
was developed.

For a description of how to use and extend the package, read `README.md`.
This document focuses on why the repository has its current shape, what has
already been completed, which decisions are intentional, and where work should
resume.

## Repository state at this handoff

The repository contains three `uv` workspace members:

```text
packages/core   onvif-mcp-core   0.2.1
packages/http   onvif-mcp-http   0.1.1
packages/stdio  onvif-mcp-stdio  0.1.1
```

Important commits from this work are:

```text
b3a2cd7  refactor: share camera tools across transports
a8dc7aa  chore: bump MCP server versions
```

At the time this handoff was written, `packages/core/README.md` and
`packages/core/DESIGN.md` were new, uncommitted documentation files. Run
`git status --short` rather than assuming that is still true.

## Original problem

The repository had two camera MCP servers:

- A mature stdio implementation in `packages/stdio/src/camera.py`.
- A partially implemented streamable-HTTP implementation in
  `packages/http/src/onvif_mcp_http/main.py`.

The servers use different MCP transports but perform many identical ONVIF
operations. `get_camera` and `get_cameras` were the first obvious examples:
their implementations had been copied into both servers. The intended HTTP
build-out would have required copying most of the large stdio module.

Continuing that approach would create predictable maintenance problems:

- Fixes would need to be made twice.
- Tool signatures and descriptions could drift.
- Camera-specific error handling could differ by transport.
- Testing would need to cover two copies of the same behavior.
- The already large stdio file would become the informal reference
  implementation rather than reusable application code.

The selected design was to make transport-independent camera behavior a
workspace library and leave each server responsible only for MCP transport and
transport-specific integration.

## Architectural decision

The central dependency direction is:

```text
                     onvif-mcp-core
                 shared camera behavior
                 and shared MCP guidance
                    /             \
                   /               \
          onvif-mcp-stdio     onvif-mcp-http
           stdio adapter       HTTP/ASGI adapter
```

`packages/core` must not import either transport package.

The core is not a server. It does not create the authoritative process-level
`FastMCP` instance, select a transport, configure CORS, open a listening port,
or own browser integration. It provides:

- Transport-independent ONVIF operations.
- Common return and error behavior.
- Canonical MCP-facing tool descriptions.
- Registration helpers for attaching groups of tools to a `FastMCP` instance.

The transport packages provide:

- Process startup.
- MCP transport configuration.
- Transport-specific middleware and routes.
- Process-local state such as subscribed event selections.
- Integrations that do not belong in a general camera library.

## Why a third package was chosen

An alternative was to keep one server as the implementation and import its
functions from the other. That was rejected because it would make one
transport depend on the other transport's startup code, global `FastMCP`
object, logging configuration, and unrelated integrations.

Another alternative was to create one distribution containing both server
entry points. Separate distributions were retained because the servers have
different dependencies, release versions, deployment methods, and future
event behavior.

The result is three distributions:

```text
onvif-mcp-core
onvif-mcp-http
onvif-mcp-stdio
```

Both server packages declare `onvif-mcp-core` as a `uv` workspace dependency.

## Completed extractions

### Camera queries

`camera_queries.py` owns:

- `get_camera`
- `get_cameras`
- Camera discovery callbacks
- Construction of lightweight camera summaries

`get_cameras` takes no arguments. An earlier design had it accept a
`subscribed_events_by_camera` mapping so summaries could include a
`subscribed_events` field, but that parameter was removed: subscription
selection is process-local state that differs by transport, and the core
query does not own it. Transports that need to report subscription state
merge it into a summary themselves after calling `get_cameras`.

This is an important boundary: discovery and summary construction are common;
event lifecycle and subscription state remain transport concerns.

### Video configuration

`video.py` owns:

- `set_camera_video_resolution`
- `set_camera_video_frame_rate`
- `set_camera_video_bitrate`
- `set_camera_video_gov_length`

The shared helper queries the camera, finds the selected profile, changes the
encoder object, pushes the complete video encoder configuration, checks
`camera.errors`, and returns an MCP-friendly status message.

### Audio configuration

`audio.py` owns:

- `set_camera_audio_encoding`
- `set_camera_audio_sample_rate`

Field testing confirmed an important hardware behavior already noted in the
tool guidance: some cameras couple audio sample rate and bitrate. Changing the
Driveway camera's substream from 16 kHz to 8 kHz also changed its bitrate from
64 kbps to 32 kbps. Configuration tools should therefore instruct agents to
re-query the camera after a successful write.

### PTZ

`ptz.py` owns all 12 shared PTZ operations:

- Go to a preset.
- Create or overwrite a preset.
- Remove a preset.
- Create, update, remove, start, and stop a preset tour.
- Start pan/tilt or zoom movement.
- Stop pan/tilt or zoom movement.

Two existing command styles were intentionally preserved:

1. IP-based operations query a full camera before changing presets or tours.
2. Direct movement operations construct a minimal `Camera` using the PTZ
   service address, profile token, credentials, and time offset supplied from
   a recent camera summary.

Do not merge those styles casually; they reflect how the existing
`libonvif` operations are called.

### Device management

`device.py` owns:

- `change_camera_hostname`
- `sync_camera_time`
- `reboot_camera`

These were grouped as basic device-management operations even though they do
not form a large feature family.

### Streaming

`streaming.py` owns:

- `get_web_player_url`

This is pure string construction from the `STREAM_SERVER_URL` environment
variable plus the caller-supplied serial number and profile token. It does
not query the camera via `libonvif` and has no camera-specific error
handling, unlike the rest of core. It was migrated from stdio's `camera.py`
as an example of continuing the original stdio-to-core migration: `stdio` was
the first transport implemented, and existing stdio behavior is moved into
`packages/core` incrementally, tool by tool, as this work resumes.

`stream_camera` (opens the URL in a local web browser via `webbrowser.open`)
was deliberately left stdio-only rather than migrated alongside
`get_web_player_url`: opening a browser is local-process, deployment-specific
behavior, not a general camera operation.

## Tool registration design

`tools.py` contains registration functions:

```python
register_camera_query_tools(...)
register_video_configuration_tools(...)
register_audio_configuration_tools(...)
register_ptz_tools(...)
register_device_management_tools(...)
register_streaming_tools(...)
```

Calling one of these functions attaches core functions to a particular
`FastMCP` instance. Importing the registration function does nothing on its
own.

The HTTP server registers most common functions directly through these
helpers. The stdio server currently retains thin wrapper functions. Those
wrappers preserve the mature stdio surface and delegate immediately to the
core:

```python
@mcp.tool(description=TOOL_GUIDANCE["reboot_camera"])
async def reboot_camera(ip_address: str) -> str:
    return await reboot_camera_core(ip_address)
```

The wrapper contains no camera behavior. This is acceptable as a transport
adapter, especially when transport-owned state must be passed into the core.

## Canonical MCP guidance

An important design correction occurred during this work.

Initially, the stdio wrappers retained their extensive docstrings while the
HTTP server registered core functions with short docstrings. Function names
and JSON schemas matched, so the HTTP tools worked, but HTTP clients received
less operational guidance.

FastMCP exposes a registered function's description during MCP tool listing.
That description can materially affect an agent's ability to choose and safely
operate a tool. This is independent of stdio versus HTTP; it depends on which
description is registered.

The final design makes `guidance.py` the single, human-editable source of truth:

```python
TOOL_GUIDANCE["set_camera_preset"]
```

Both transports explicitly register every shared tool with the corresponding
canonical description. The descriptions are formatted as readable,
triple-quoted prose so field experience can be incorporated directly.

Do not reintroduce duplicated MCP guidance in transport wrappers. When a
shared tool's operating advice changes, edit `guidance.py`.

The duplicate docstrings were removed from the 23 shared stdio wrappers after
description parity was verified. Stdio-only tools retain their own docstrings
because those docstrings still provide their MCP descriptions.

## Invariants to preserve

Future work should preserve these properties:

1. Shared camera behavior has one implementation in `packages/core`.
2. Core code never imports a transport package.
3. Stdio and HTTP expose the same name and input schema for a shared tool.
4. Stdio and HTTP use the exact same `TOOL_GUIDANCE` description.
5. Transport-owned state is passed into core functions rather than stored in
   new core globals.
6. Routine camera and ONVIF failures become clear tool-result strings.
7. A successful configuration response should not be treated as proof that
   hardware retained the exact requested value; re-query where appropriate.
8. Tests must not move, reboot, rename, or reconfigure real cameras.
9. Shared unit tests mock `libonvif` at the core-module boundary.
10. Event delivery remains outside the core until a genuinely common event
    abstraction is designed.

## Testing strategy

Tests live under `packages/core/tests` and use `unittest` with mocks.

Current coverage includes:

- Video encoder mutation and push behavior.
- Audio encoder mutation, camera errors, and profile lookup.
- PTZ guard conditions, minimal command construction, velocities, and tour
  spot replacement.
- Hostname, time synchronization, time-offset refresh, reboot, and query
  failures.

Run:

```powershell
uv sync
uv run python -m unittest discover -s packages/core/tests -v
uv run python -m compileall -q packages/core/src packages/http/src packages/stdio/src
git diff --check
```

During the refactor, validation also imported both servers and compared each
shared `FastMCP` tool's:

- Presence
- Input schema
- Description

At the handoff point there were:

```text
23 shared tools
0 missing tools
0 schema differences
0 description differences
0 canonical-description differences
14 passing core tests
```

When adding tools, repeat those parity checks rather than checking only that
the modules import.

## Live validation performed

In addition to mocked tests, the following end-to-end checks were performed
through the connected camera MCP:

- `get_cameras` returned all seven cameras through the extracted query path.
- A direct `get_camera` query returned a full camera representation.
- Back-Door main profile `MediaProfile000` was changed from `1920 x 1080` to
  `1280 x 720`, then re-queried successfully.
- Driveway substream `MediaProfile001` was changed from 16 kHz to 8 kHz, then
  re-queried successfully. Its bitrate changed from 64 kbps to 32 kbps as a
  coupled hardware behavior.

These were deliberate user-requested writes. Unit tests remain non-mutating.

## Work intentionally deferred

### `update_camera_data`

This stdio tool was deliberately skipped. It has known issues unrelated to the
shared-core effort. Do not migrate it blindly or use it as a pattern for new
core code. Diagnose and specify its desired behavior before refactoring it.

### Events

The stdio server contains event listener, subscription, snapshot, and
OpenClaw-related behavior. HTTP event handling is expected to differ.

The likely future split is:

- Shared ONVIF subscription mechanics and normalized camera-event models,
  where genuinely common.
- Transport-specific event sinks and lifecycle management.

Do not copy the stdio event subsystem wholesale into HTTP. Design the event
boundary first.

### Remaining stdio-only integrations

Examples still present in `camera.py` include:

- Environment inspection
- `stream_camera` (opens a live stream in a local browser via
  `webbrowser.open`) — `get_web_player_url`, the other half of the original
  "stream and web-player helpers" pair, has since moved to
  `packages/core/src/onvif_mcp_core/streaming.py`.
- Snapshot encoding, downloading, and browser display
- OpenClaw messaging and motion notification
- File/grep helper tools

Some may eventually move to core, but only if they are appropriate for both
transports. Browser, filesystem, and local-process behavior may be inherently
deployment-specific.

### Version reporting

Both servers currently contain their own version-reporting tool. Separate
server versions are intentional, so version reporting may remain a transport
or distribution responsibility even if a small shared helper is later useful.

## Security and operational observations

- Camera credentials come from `CAMERA_USERNAME` and `CAMERA_PASSWORD`.
- Full camera serialization currently includes credential fields. Avoid
  logging, committing, or unnecessarily displaying complete `get_camera`
  payloads. Consider redaction as a separate security improvement.
- Direct PTZ commands rely on a recent PTZ service address, profile token, and
  time offset from `get_cameras`.
- `set_camera_preset` overwrite mode saves the camera's current position.
  Guidance must continue to warn agents about this.
- Tour spot updates replace the entire spot list rather than appending.
- Continuous movement requires an explicit stop call or continues until the
  camera reaches a physical limit.
- Camera firmware behavior varies. Treat device-reported option lists and a
  fresh post-write query as authoritative.

## How to resume

A fresh developer or agent should:

1. Read `packages/core/README.md`.
2. Read this file completely.
3. Run `git status --short` and preserve unrelated user changes.
4. Review the latest commits listed near the top of this document.
5. Run `uv sync`.
6. Run the 14 core tests and compilation command above.
7. Inspect `guidance.py` before changing any shared tool description.
8. Compare stdio and HTTP tool schemas and descriptions after any shared-tool
   change.
9. Ask whether the next goal is:
   - More shared non-event tools
   - Cleanup of transport wrappers
   - Diagnosis of `update_camera_data`
   - Design of the event abstraction
   - HTTP-specific feature completion
10. Keep event work separate from generic camera-operation extraction until
    its cross-transport contract is explicit.

## Definition of done for a new shared tool

A shared tool is complete when:

- Its ONVIF behavior is implemented once in core.
- Its name and signature are appropriate for both transports.
- Its detailed operational description is in `guidance.py`.
- Both transports expose it.
- Both transports report equal JSON schemas and descriptions.
- Mocked core tests cover success, lookup/validation failure, and
  camera-reported errors where applicable.
- `uv sync`, unit tests, compilation, and `git diff --check` pass.
- Any live-camera test is explicitly authorized and followed by a fresh
  read-back verification.
