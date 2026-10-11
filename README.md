## ONVIF MCP

This project builds a secure IP camera network with enterprise grade OAuth authentication and isolated private network ONVIF cameras. Cameras can be configured such that there is no direct access between the cameras and the local network or wider internet. All camera network traffic is proxied by a single secure server. The system includes web based switchboard apps that can select single camera views or multi-camera views of live streams. Streams are continuously recorded and available for immediate playback.

The system employs a Hermes Agent with elevated privileges to build and manage the system. The configurations described here have been tested using a locally hosted instance of Qwen3.8 27B inference model as the source of intelligence. If inference is locally hosted, the system is fully autonomous and does not require any external internet connection to function once it has been set up.

Clients can connect to the camera web apps without further configuration beyond importing the CA certificate and entering authorization credentials. Hermes can be configured on the client side to give the agent full control over camera operation including PTZ functions with additional security safeguards.

## System Requirements

* Server

    The system requires a server with dual network interface adapters. A LAN facing adapter connects to the local network and is accessible by other computers on the LAN. A second interface is configured as the DHCP controller providing a private isolated network hosting the cameras. The documentation has been developed and tested against an Ubuntu 26.04 Operating System installed on the server. A freshly installed, dedicated bare metal server is recommended. Computing requirements for the server are modest, a reasonably powered mini pc is ideal for the application. Reference SERVER_PREP.md in the docs folder for the recommended server setup.

* AI Provider

    A source of intelligence is required for the system. This configuration was developed and tested using Qwen3.8 27B model running on a NVIDIA 4500 with 32GB VRAM. This arrangement provides sufficient compute to efficiently build and run the system. A full build out will require about three hours for the agent to complete. Run time operation is sufficiently responsive that the system provides operational characteristics on par with legacy deterministic camera management systems. Lower powered compute arrangements can provide acceptable performance as well in accordance with their capability. Cloud based AI works as well, use a lower tier model to conserve token usage.

* Agent 

    This system is designed and tested around the Hermes Agent. This agent has many characteristics that make it ideal for this application. Hermes implements the full OAuth stack for MCP security and does not require any cloud access to operate. The MCP server is hosted locally and therefore not fully  compatible with ChatGPT and Claude Agents, both of which require connection to their cloud servers for MCP operation. OpenClaw was found to be less capable than Hermes in this scenario, and is not recommended. The Hermes Agent will require sudo privileges to build the server.

* Clients

    Configurations are documented for clients using Windows, Mac and Linux distros Ubuntu, Fedora and Cachy OS. Other distros can be easily adopted by following the instructions for the documented distro families. For example, Omarchy is easily configured using the instructions for Cachy OS. Android clients can be configured for access to the camera web apps. Hermes can be used on the client for AI enhanced operation including camera configuration and control. Hermes on the client can operate with full capabilities without using elevated privileges.

## Security Features

The documentation includes instructions for creating and maintaining a private Certificate Authority in order to provide certificates for HTTPS encrytption. Keycloak is used for the OAuth server and provides short-lived JWT token authentication for both the camera MCP server and the camera m apps. Cameras are isolated on a private network accessible only by proxy behind the protected server. Per-user credentials are securely stored and can be revoked at any time.

Clients using only the camera apps do not require any additional configuration. Clients that intend to use MCP services need to be registered with the server by IP address, which implies that they will need to have a static IP. If this requirement is overly strict, the authentication can be set to looser restriction by IP subnet, allowing a range of device IPs from the designated subnet.

## Agentic Server Administration

The Hermes agent is capable of managing most server functionality autonomously. This is a very powerful mechanism that enables control over a server without requiring that the user have deep expertise in the nuances of different server programs and protocols. For most well documented server functions, current agents have sufficient understanding to manage and maintain programs and processes without significant external guidance. 

This arrangement raises some questions regarding the permissions that should be given to the agent. While in theory it seems possible to force the agent to request sudo access each time it needs to execute a root function, in practice this strategy has been found to be unreliable and will most often produce unsatisfactory results. This leads to the recommendation that the agent be given passwordless sudo access. Enabling this access involves creating a root protected file that gives the user account with which the agent is associated particular assigned privileges. For the sake of simplicity, the file is formatted in this case to allow full sudo access to all features, but could be implemented in a stricter sense, confining the agent to a limited set of allowed commands. This functionality is implemented in the enable-nopasswd.sh script.

To revoke access, simply delete the file in the /etc/sudoers.d folder.

## Backup Strategies

A complex system in a production environment requires a robust backup strategy to avoid excessive downtime in the event of a server failure. The system is designed to support incremental backups as it is installed and maintained. Backup data can be held in a shared SMB folder, a mounted external drive, or a local filesystem folder. Whichever storage type is chosen, the backup location must enforce the same permission model the SMB mount enforced: mode 0700 owned by the runbook user, files 0600, no extra ACL entries.

* Shared SMB folder

    The agent is capable of configuring both the server and client sides of a shared SMB folder for backup purposes. In order for the agent to be able to work on the server side of the external host, it must be configured with SSH access and have been set up with passwordless sudo as describe above in Agentic Server Administration. In this configuration, the camera host, on which the agentic administrator resides, is the SMB client.

* Mounted external drive

    This is a simpler strategy that involves only a mounted external drive accessible to the agent. This will be a common arrangement in many systems and avoids the complexity of setting up a shared SMB folder.

* Local filesystem folder

    A folder on the local filesystem is also accepted as `{{BACKUP_PATH}}`, provided it enforces the permission model above. Note that a local folder does not provide off-host redundancy; it is intended for staging, testing, or single-machine arrangements.

## Building the Server

The server is built in stages as listed below. Server host preparation sets up the baseline operating system configuration, Plain HTTP sets up the services without encryption, HTTPS creates the certificate and maps the endpoints for protection, and Authentication implements the Keycloak server for login credential requirements. A firewall can be added at the conclusion of the configuration for additional protection.

 The Hermes agent is used to perform the configuration and can be prompted to follow this document and implement the steps as described in the runbooks referenced below. Values required for each step of the implementation are listed in the tables, Prompt Hermes with your own site specific variables and Hermes can implement the configuration autonomously.

Be mindful of model context size when running the configurations shown below. Starting a fresh context after it reaches 50 percent is advised. Runbooks can be executed individually on systems with modest context if necessary. The runbooks can be found in the `{{REPO_PATH}}/docs` directory. The runbooks are intended to be executed in the order listed.

1. ### Server Preparation

  Follow the [SERVER_PREP.md](docs/SERVER_PREP.md) document in the docs folder after installing Ubuntu 26.04 on the host.

2. ### Choose a Backup Path

  Read the [BACKUP.md](docs/BACKUP.md) and establish a backup path appropriate for your situation.

3. ### Supply Required Values and install

  Enter Required Values into the tables in [INSTALL.md](INSTALL.md), including users and allowed machine IP addresses.

  Start the hermes agent and prompt it

  ```
  Execute the runbook onvif-mcp/INSTALL.md
```

  The installation will require you to perform several actions in a separate terminal to initialize and manage the passwords used by the system.

## Configuring the Client

Clients are configured using the [CLIENT.md](docs/CLIENT.md) doc. Configurations have been mapped for major Linux distros, Windows and MacOS. Limited configuration for Android mobile devices gives access to the camera web apps.

Upon completion of user configuration and successful login, prompt the agent to backup the Keycloak authorization server.
