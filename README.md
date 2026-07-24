<h2>ONVIF MCP Server</h2>

This MCP server is designed specifically to work with desktop AI agents. The server communicates with the agent over the STDIO interface, so no web server is needed. Explicit instructions are included here for working with

* Claude Desktop
* OpenClaw
* ChatGPT Desktop

Each of these platforms has different pros and cons. Claude Desktop has an integrated installer, so it is very easy to set up and get started, but is not as feature rich as the others. OpenClaw works best from the command line and supports ONVIF events, so built in camera detectors (people, cars, pets, etc.) can asynchronously notify OpenClaw and start a model analysis automatically. ChatGPT has a very evolved user interface and can display snapshot and live camera streams directly in the user interface.

This server uses the [uv](https://docs.astral.sh/uv/getting-started/installation/) runtime, so you will need that installed on your machine. If you are not familiar, uv is an advanced Python implementation that seamlessly handles package and project management for Python programs, and is widely used for AI projects.

If you want to include live streaming abilities, you will need a stream server. This project is designed to work with [Cayenue](https://github.com/sr99622/Cayenue) for that service. This can be run on the localhost, which is convenient, or a seperate server, which is a more robust configuration and is recommended. The STREAM_SERVER_IP found in the configuration parameters is the the IP address of the Cayenue server. The ONVIF MCP server will work just fine without this, but will be restricted to snapshots, unable to live stream.

<h3>Claude Desktop Installation</h3>

To install the server in Claude Destop, you can download the [installer](https://github.com/sr99622/onvif-mcp/releases/download/v0.0.70/onvif-mcp.mcpb) to your local hard drive. Open Claude Desktop and use the hamburger icon in the upper left corner to open the File -> Settings menu and select Extensions from the left side panel. Click the Advanced Settings then click the Install Extension button to open a file selection dialog. Navigate to the repository and select the simple-mcp-server.mcpb file and the MCP server installer will present a dialog to be filled out with site parameters.

The installer will ask you for camera credentials and the STREAM_SERVER_IP. If you're not using the Cayenue server, you can leave that last one blank, but you will need camera credentials to log into the cameras. Enabled the MCP server and click Configure to view the settings and permissions for the server, the settings will be behind the current screen, so you might need to close that.

To create the installer, you need the CLI tool from Anthropic

```
npm install -g @anthropic-ai/mcpb
```

Then run the command

```
mcpb pack
```

If you want to uninstall, you might need to click the uninstall button twice to get it to stick.

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

<h2>Using the ONVIF MCP Server</h2>

Once installed, the tool will be available for the agent. A good starting point is to query the agent to tell you the server version. 

```
Please tell me the current version of the camera mcp server.
```

On the first run, the model may not recognize the server right away. There may be some delay while the agent is asking permission to run the server. You might need to confirm the permission first before the agent is able to use the tool. If it struggles during the first run, ask again after you have granted permission.

To see cameras on your local network

```
get cameras
```

This should produce a list of cameras that are connected to your local network. If your cameras are remote, you can ask to see a camera using its IP address

```
get camera at 10.1.1.77
```

To see the camera snapshot in your browser

```
please show the camera snapshot from 10.1.1.77 in the browser
```

There is a default name assigned to the camera when it is discovered. This is not necessarily the best name to work with, so you can set your own name using the change hostname function.

```
Please change the hostname on camera 10.1.1.77 to Driveway
```

You will then be able to address the camera by that name.

You can introduce the camera snapshot into the model context by downloading to file

```
Please download the Driveway snapshot to file.
```

Depending on agent abilities, the snapshot can be displayed in the model chat, and the model can be asked to describe the image. 

There are many other functions available to control and observe the camera, you can ask the agent about it's abilities or to explain a function, and it will be able to come up with an answer for you.