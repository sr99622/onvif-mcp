# ONVIF MCP Core

`onvif-mcp-core` contains the camera operations shared by the stdio and
streamable-HTTP ONVIF MCP servers in this repository.

It is a library, not a standalone MCP server. It does not choose a transport,
listen on a port, or start a `FastMCP` process. The transport packages import
the core functions and expose them as MCP tools.

## Why this package exists

The repository contains two MCP server implementations:

- `packages/stdio` communicates with an MCP client over standard input and
  output.
- `packages/http` exposes a streamable-HTTP MCP endpoint through an ASGI
  application.

Most camera operations have identical ONVIF behavior regardless of transport.
Keeping that behavior in both servers would create two implementations that
could acquire different bug fixes, validation, return messages, and tool
schemas. The core package provides one implementation for those common
operations.

The relationship is:

```text
                 packages/core
            shared ONVIF operations
             and MCP tool guidance
                  /       \
                 /         \
       packages/stdio     packages/http
        stdio transport    HTTP transport
```

Transport-specific behavior remains in the relevant server package. Event
delivery is expected to differ between the transports and is intentionally not
part of the shared core at this stage.

## Package contents

The Python package is under `src/onvif_mcp_core`.

| Module | Responsibility |
| --- | --- |
| `camera_queries.py` | Query one camera, discover cameras, and create the lightweight summaries returned by `get_cameras`. |
| `video.py` | Change video resolution, frame rate, bitrate, and GOV/GOP length. |
| `audio.py` | Change audio encoding and sample rate. |
| `ptz.py` | PTZ movement, stopping, presets, and preset tours. |
| `device.py` | Change a hostname, synchronize a camera clock, and request a reboot. |
| `streaming.py` | Build the web-player URL for a camera live stream. |
| `guidance.py` | Canonical, human-editable MCP descriptions for every shared tool. |
| `tools.py` | Register groups of shared functions on a `FastMCP` server. |
| `__init__.py` | Export the primary public core functions and registration helpers. |

## Tool guidance

`guidance.py` is the source of truth for the instructions an MCP client
receives when it lists the shared tools. Both transports explicitly register
their tools with the descriptions in `TOOL_GUIDANCE`.

Edit that file when experience with real cameras reveals better warnings,
examples, argument explanations, or operating procedures. The stdio and HTTP
servers should not maintain separate copies of shared tool guidance.

The test and verification workflow compares the registered descriptions and
input schemas from both servers to prevent accidental drift.

## Using the core from a transport

`tools.py` provides registration functions for groups of related tools:

```python
from mcp.server.fastmcp import FastMCP
from onvif_mcp_core.tools import (
    register_audio_configuration_tools,
    register_device_management_tools,
    register_ptz_tools,
    register_streaming_tools,
    register_video_configuration_tools,
)

mcp = FastMCP("onvif-mcp")

register_video_configuration_tools(mcp)
register_audio_configuration_tools(mcp)
register_ptz_tools(mcp)
register_device_management_tools(mcp)
register_streaming_tools(mcp)
```

Calling a registration function attaches the core Python functions to that
specific `FastMCP` instance. Importing a registration function alone does not
register or run anything.

```python
from onvif_mcp_core.camera_queries import get_cameras

result = await get_cameras()
```

`get_cameras` does not own event-subscription state; that remains
process-local to each transport. This keeps camera discovery and summary
construction shared while allowing stdio and HTTP to develop different event
implementations.

## Credentials and camera access

Core operations use `libonvif` and read camera credentials from:

- `CAMERA_USERNAME`
- `CAMERA_PASSWORD`

The functions return MCP-friendly status strings rather than raising routine
camera communication or configuration errors to the transport. Functions that
modify a camera generally:

1. Query the current camera state.
2. Locate the requested media profile, preset, or tour.
3. Change the relevant `libonvif` object.
4. Push the complete ONVIF configuration.
5. Inspect `camera.errors`.
6. Return a success or failure message.

Callers should re-query a camera after a configuration change. Some cameras
accept a request but normalize, couple, or reject settings in
hardware-specific ways. For example, some devices couple audio sample rate and
bitrate.

## Development

The core package is a member of the repository's `uv` workspace and is an
editable workspace dependency of both transport packages.

From the repository root:

```powershell
uv sync
```

Run the non-destructive unit tests with:

```powershell
uv run python -m unittest discover -s packages/core/tests -v
```

The unit tests mock `libonvif` calls. They validate object updates, ONVIF call
arguments, error handling, and guard conditions without changing or moving real
cameras.

When adding a shared tool:

1. Add its transport-independent implementation to the appropriate core
   module.
2. Add its human-readable MCP description to `guidance.py`.
3. Export or register it through `tools.py`.
4. Expose it from both transports.
5. Add mocked core tests.
6. Verify that stdio and HTTP expose matching names, input schemas, and
   descriptions.

## Current boundaries

The core currently owns shared camera queries, media configuration, PTZ, and
basic device management. It does not currently own:

- MCP server startup or shutdown
- stdio or HTTP transport configuration
- ASGI middleware, CORS, or HTTP routes
- browser and local-file integration
- OpenClaw integration
- camera-event delivery and transport-specific event lifecycle

Those concerns remain in `packages/stdio` or `packages/http` until there is a
clear transport-independent abstraction for them.
