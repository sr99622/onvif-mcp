## ONVIF MCP

This project builds a secure IP camera network with enterprise grade OAuth authentication and isolated private network ONVIF cameras. Cameras can be configured such that there is no direct access between the cameras and the local network or wider internet. All camera network traffic is proxied by a single secure server. 

The system employs a Hermes Agent with elevated privileges to build and manage the system. The configurations described here have been tested using a locally hosted instance of Qwen3.8 27B inference model as the source of intelligence. The system is fully autonomous and does not require any external internet connection to function once it has been set up.

## System Requirements

* Server

    The system requires a server with dual network interface adapters. A LAN facing adapter connects to the local network and is accessible by other computers on the LAN. A second interface is configured as the DHCP controller providing a private isolated network hosting the cameras. The documentation has been developed and tested against an Ubuntu 26.04 Operating System installed on the server. A freshly installed, dedicated bare metal server is recommended. Computing requirements for the server are modest, a reasonably powered mini pc is ideal for the application. Reference SERVER_BUILD.md in the docs folder for the recommended server configuration.

* AI Provider

    A source of intelligence is required for the system. This configuration was developed and tested using Qwen3.8 27B model running on a NVIDIA 4500 with 32GB VRAM. This arrangement provides sufficient compute to efficiently build and run the system. A full build out will require about three hours for the agent to complete. Run time operation is sufficiently repsonsive that the system provides operational characteristics on par with legacy deterministic camera management systems. Lower powered compute arrangements can provide acceptable performance as well in accordance with their capability. Note that during build out, context on the order of 90k tokens is needed to avoid context compression events.

* Agent 

    This system is designed and tested around the Hermes Agent. This agent has many characteristics that make it ideal for this application. The MCP server is hosted locally and therefore incompatible with ChatGPT and Claude Agents. OpenClaw was found to be less capable than Hermes in this scenario, and is not recommended. The Hermes Agent will require sudo privileges in order to operate reasonably.

* Clients

    Configurations are documented for clients using Windows, Mac and Linux distros Ubuntu, Fedora and Cachy OS. Other distros can be easily adopted by following the instructions for the documented distro families. For example, Omarchy is easily configured using the instructions for Cachy OS. Clients can access camera feeds using the included web applications with minimal configuration. Hermes can be used on the client for AI enhanced operation including camera configuration and control. Hermes on the client can operate with full capabilities without elevated privilege.

## Security Features

The documentation includes instructions for creating and maintaining a private Certificate Authority in order to provide certificates for HTTPS encrytption. Keycloak is used for the OAuth server and provides short-lived JWT token authentication for both the camera MCP server and the camera stream apps. Cameras are isolated on a private network accessible only by proxy behind the protected server. Per-user credentials are securely stored and can be revoked at any time.

## Building the Server

The server is built in four stages, Server host configuratiom, Plain HTTP that sets up the services without encryption, HTTPS that creates the certificate and maps the endpoints for protection, and Authentication that implements the Keycloak server for login credential requirements.

1. Server Configuration

    Follow the SERVER_BUILD.md document in the docs folder after installing Ubuntu 26.04 on the host. The top section of the document installs several quality of life features that help manage the server, but are not strictly required for operation. The Essential Configurations section describes critical installations required for operation.

2. HTTP Services

    This is a baseline configuration required before layering encryption and authentication on the server. All essential services are intially configured here without encyption. This could theoretically be considered a fully functional unsecured system. The Hermes agent is used to perform the configuration and can be prompted to follow this document and implement the steps as described in the runbook referenced below. Values required for implementation are listed in the table, edit this document with your own site values and Hermes can implement the configuration autonomously.

    After following the instructions in SERVER_BUILD.md, attach the cameras to the second ethernet adapter.

    **Required Values**

    | Name | Description | Site Value |
    |------|-------------|------------|
    | `{{EN_NAME}}` | Ethernet adpater hosting the private camera network | - |
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server, e.g. camera.home.arpa | - |
    | `{{USERNAME}}` | Common username for cameras | - |
    | `{{PASSWORD}}` | Common password for cameras | - |
    | `{{REPO_PATH}}` | Parent directory of this repository | - |
    | `{{SERVER_USER}}` | Account name on the server under which Hermes is run | - |

    The runbooks to implement from the `{{REPO_PATH}}/onvif-mcp/docs` directory:

    ```
    DHCP.md
    MEDIAMTX.md
    SNAPSHOT.md
    APPS.md
    MCP_HTTP.md
    ```

