<h2>ONVIF MCP Server</h2>

This MCP server is designed specifically to work with desktop AI agents. The server communicates with the agent over the STDIO interface, so no web server is needed. Explicit instructions are included here for working with

* Claude Desktop
* OpenClaw
* ChatGPT Desktop

Each of these platforms has different pros and cons. Claude Desktop has an integrated installer, so it is very easy to set up and get started, but is not as feature rich as the others. OpenClaw works best from the command line and supports ONVIF events, so built in camera detectors (people, cars, pets, etc.) can asynchronously notify OpenClaw and start a model analysis automatically. ChatGPT has a very evolved user interface and can display snapshot and live camera streams directly in the user interface.

This server uses the [uv](https://docs.astral.sh/uv/getting-started/installation/) runtime, so you will need that installed on your machine. If you are not familiar, uv is an advanced Python implementation that seamlessly handles package and project management for Python programs, and is widely used for AI projects.

If you want to include live streaming abilities, you will need a stream server. This project is designed to work with [Cayenue](https://github.com/sr99622/Cayenue) for that service. This can be run on the localhost, which is convenient, or a seperate server, which is a more robust configuration and is recommended. The STREAM_SERVER_IP found in the configuration parameters is the the IP address of the Cayenue server. The ONVIF MCP server will work just fine without this, but will be restricted to snapshots, unable to live stream.

<h3>Claude Desktop Installation</h3>

To install the server in Claude Destop, you can download the [installer](https://github.com/sr99622/onvif-mcp) to your local hard drive. Open Claude Desktop and use the hamburger icon in the upper left corner to open the File -> Settings menu and select Extensions from the left side panel. Click the Advanced Settings then click the Install Extension button to open a file selection dialog. Navigate to the repository and select the simple-mcp-server.mcpb file and the MCP server installer will present a dialog to be filled out with site parameters.

To create the installer, you need the CLI tool from Anthropic

```
npm install -g @anthropic-ai/mcpb
```

Then run the command

```
mcpb pack
```

<h3>OpenClaw Installation</h3>

The server is installed to OpenClaw by downloading the source files for this project then editing the .openclaw/openclaw.json configuration file. You will need git installed on your machine to get the source code.

```
git clone https://github.com/sr99622/onvif-mcp
```

The default location for the .openclaw folder is in the users home directory. For best results, use the full path name to identify the uv installation location in the "command" parameter, you can find it using `which uv` on Mac OS and Linux. Adjust the path seen below the `--directory` arg for the location that you git cloned above. To enable event handling, include the "hooks" section as shown below. The ONVIF MCP server will work fine without hooks if you don't want that feature.

```
  "mcp": {
    "sessionIdleTtlMs": 0,
    "servers": {
      "camera": {
        "command": "/Users/stephen/.local/bin/uv",
        "args": [
          "--directory",
          "/Users/stephen/Projects/local.mcpb.stephen-rhodes.camera/src",
          "run",
          "camera.py"
        ],
        "env": {
          "CAMERA_USERNAME": "admin",
          "CAMERA_PASSWORD": "admin123",
          "STREAM_SERVER_IP": "10.1.1.13",
          "OPENCLAW_HOOK_TOKEN": "shared-secret",
        }
      }
    }
  },
  "hooks": {
    "enabled": true,
    "token": "shared-secret",
    "path": "/hooks",
    "mappings": [
      {
        "id": "camera-motion",
        "match": { "path": "camera-motion" },
        "action": "agent",
        "wakeMode": "now",
        "name": "Camera Motion",
        "messageTemplate": "{{payload.message}}",
        "allowUnsafeExternalContent": true
      }
    ]
  },
```

<h3>ChatGPT Desktop App Installation</h3>

The configuration is made by editing the file .codex/config.toml, add the following

```
mcp_servers.camera]
command = "uv"
args = ["run", "camera.py"]
cwd = '/path/to/onvif-mcp/src'

[mcp_servers.camera.env]
CAMERA_USERNAME = "admin"
CAMERA_PASSWORD = "admin123"
STREAM_SERVER_IP = "10.1.1.13"
```