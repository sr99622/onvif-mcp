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

This arrangement raises some questions regarding the permissions that should be given to the agent. While in theory it seems possible to force the agent to request sudo access each time it needs to execute a root function, in practice this strategy has been found to be unreliable and will most often produce unsatisfactory results. This leads to the recommendation that the agent be given passwordless sudo access. Enabling this access involves creating a root protected file that gives the user account with which the agent is associated particular assigned privileges. For the sake of simplicity, the file is formatted in this case to allow full sudo access to all features, but could be implemented in a stricter sense, confining the agent to a limited set of allowed commands. The command chain below will create the permissions file as described. Note that this functionality is also implemented in the enable-nopasswd.sh script.

```
sudo env USER="$USER" bash -c '
set -euo pipefail
u="${USER:?USER environment variable is not set}"
[[ "$u" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { echo "Invalid USER value: $u" >&2; exit 1; }
f="$(mktemp)"
trap "rm -f \"$f\"" EXIT
printf "%s ALL=(ALL) NOPASSWD: ALL\n" "$u" > "$f"
chmod 0440 "$f"
visudo -cf "$f"
install -o root -g root -m 0440 "$f" "/etc/sudoers.d/${u}-nopasswd"
echo "Created /etc/sudoers.d/${u}-nopasswd"
'

```
To revoke access, simply delete the file in the /etc/sudoers.d folder.

## Backup Strategies

A complex system in a production environment requires a robust backup strategy to avoid excessive downtime in the event of a server failure. The system is designed to support incremental backups as it is installed and maintained. There are two storage types available to hold backup data, shared SMB folder and mounted external drive.

  * Shared SMB folder

    The agent is capable of configuring both the server and client sides of a shared SMB folder for backup purposes. In order for the agent to be able to work on the server side of the external host, it must be configured with SSH access and have been set up with passwordless sudo as describe above in Agentic Server Administration. In this configuration, the camera host on which the agentic administrator resides, is the SMB client.

  * Mounted external drive

    This is a simpler strategy that involves only a mounted external drive accessible to the agent. This will be a common arrangement in many systems and avoids the complexity of setting up an SMB arrangement.

## Building the Server

The server is built in stages as listed below. Server host preparation sets up the baseline operating system configuration, Plain HTTP sets up the services without encryption, HTTPS creates the certificate and maps the endpoints for protection, and Authentication implements the Keycloak server for login credential requirements. A firewall can be added at the conclusion of the configuration for additional protection.

 The Hermes agent is used to perform the configuration and can be prompted to follow this document and implement the steps as described in the runbooks referenced below. Values required for each step of the implementation are listed in the tables, Prompt Hermes with your own site specific variables and Hermes can implement the configuration autonomously.

Be mindful of model context size when running the configurations shown below. Starting a fresh context after it reaches 50 percent is advised. Runbooks can be executed individually on systems with modest context if necessary. The runbooks can be found in the `{{REPO_PATH}}/onvif-mcp/docs` directory. The runbooks are intended to be executed in the order listed.

1. ### Server Preparation

    Follow the [SERVER_PREP.md](docs/SERVER_PREP.md) document in the docs folder after installing Ubuntu 26.04 on the host. The top section of the document installs several quality of life features that help manage the server, but are not strictly required for operation. The Essential Configurations section describes critical installations required for operation. The document assumes knowledge of the vi/nvim application for editing.

    To use an SMB server for backups, follow the instructions in Step 1. of [SMB_SERVE.md](docs/SMB_SERVE.md).

2. ### Set up password store and backup folder

    The system will need several secret passwords for cameras, shared folders and server management. The [GPG_KEY.md](docs/GPG_KEY.md) runbook contains instructions for setting up a GPG protected password store for these secrets.

    The server will need a backup location for critical data. An SMB share is a good place to do this. Assuming you have another Ubuntu machine set up on your local network, Hermes can do this for you using the instructions in the runbook [SMB_SERVE.md](docs/SMB_SERVE.md). Other mounted storage locations work as well, but the procedures that follow will expect there to be a directory into which backup files can be written with proper file permissions.

    Assuming you have chosen the SMB strategy and have a server set up, prompt the agent to create the gpg key, password store, smb mount and backup the keys.

    During this step, the user will be prompted to create the GPG key on the local host. Advise the user that this key should be kept in a secure location. Once the key has been created, the password store will be created and the user will be prompted to enter the password for the cameras. This system assumes that the camera password is shared by the cameras on the network. The user will also be prompted to enter the SMB password associated with the SMB_USERNAME. The password store and GPG key will then be backed up on the SMB_MOUNT shared folder.

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{SMB_MOUNT}}` | Mounted SMB shared folder |
    | `{{SMB_USERNAME}}` | Samba username for the private camera CA backup share |
    | `{{SMB_SERVER_FQDN}}` | Samba server Fully Qualified Domain Name |

    **Runbook**

    [GPG_KEY.md](docs/GPG_KEY.md)

    ---

3. ### Set up Private Camera Subnet

    Attach the cameras to the second ethernet adapter. The value for `{{PRVT_NET_EN_NAME}}` can be found using the `nmcli dev show` command from a terminal.     The DHCP server is set up first and should be given ample opportunity to assign addresses to cameras before querying the camera MCP server tool get_cameras to discover cameras on the network. A couple of minutes should be long enough.

    The MCP_HTTP.md runbook sets up the camera MCP server to communicate with the cameras, and is used by later steps to gather camera information for system configuration. The user must reload the MCP using the command `/reload-mcp` or restart hermes to incorporate the camera MCP server into the current session.

    **Required Values**

    | Name | Description |
    |------|-------------|
    | `{{PRVT_NET_EN_NAME}}` | Ethernet adapter hosting the private camera network |
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the Server |
    | `{{CAMERA_USERNAME}}`    | Camera Username |
    | `{{REPO_PATH}}`   | Full Pathname of Repository Location |
    | `{{SERVER_USER}}` | System user the service runs as (project owner) |

    **Runbooks**

    [DHCP.md](docs/DHCP.md)

    [MCP_HTTP.md](docs/MCP_HTTP.md)
  
    ---

4. ### HTTP Services

    This is a baseline configuration required before layering encryption and authentication on the server. All essential services are initially configured here without encryption. This could theoretically be considered a fully functional unsecured system.

    **Required Values**

    | Name | Description |
    |------|-------------|
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server, e.g. camera.home.arpa |
    | `{{CAMERA_USERNAME}}` | Common username for cameras |
    | `{{REPO_PATH}}` | Parent directory of this repository |
    | `{{SERVER_USER}}` | Account name on the server under which Hermes is run |

    **Runbooks**

    [MEDIAMTX.md](docs/MEDIAMTX.md)

    [SNAPSHOT.md](docs/SNAPSHOT.md)

    [APPS.md](docs/APPS.md)

    ---

5. ### HTTPS Encryption

    Included are runbooks for generating and distributing a Certificate Authority (CA) and site certificate locally. The endpoints are re-mapped to provide encryption for the suite of services. The instructions include a backup to the SMB shared drive configured earlier.

    Following completion of this section, nginx will be serving the endpoints under SSL encryption and clients will need to authorize the keys from their certificate store. Instructions for client configuration are in the [CLIENT.md](docs/CLIENT.md) runbook. The site certificate can be accessed through an unencrypted endpoint on the server.

    **Required Values**

    | Name | Description |
    |------|-------------|
    | `{{CA_ROOT_PATH}}` | Private CA root directory (e.g. $HOME/Private-CA) |
    | `{{BACKUP_PATH}}` | SMB shared drive to be created on the local host (e.g. `/mnt/camera-backup`) |
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server, e.g. camera.home.arpa |
    | `{{SERVER_USER}}` | Account name on the server under which Hermes is run |
    | `{{REPO_PATH}}` | Parent directory of this repository |
    | `{{SERVER_IP}}` | IP address of the server e.g. 10.1.1.2 |
    | `{{RVRS_SRV_IP}}` | Reverse IP address of the server e.g. 2.1.1.10 |
    | `{{UPSTREAM_DNS}}` | Upstream DNS resolver |

    **Runbooks**

    [CREATE_CA_CERT.md](docs/CREATE_CA_CERT.md)

    [SITE_CERT.md](docs/SITE_CERT.md)

    [CA_DISTRIBUTE.md](docs/CA_DISTRIBUTE.md)

    [DNS.md](docs/DNS.md)

    ---

6. ### Keycloak installation

    The Keycloak server provides authentication services for the site. During installation a default user is created that can be used for testing the configuration. A fresh context may be needed at this point, if so, re-intialize the agent context in the prompt by having them review this document again. 

    **Required Values**

    | Name | Description |
    |------|-------------|
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server (e.g. camera.home.arpa) |
    | `{{BACKUP_PATH}}` | Backup folder (e.g. /mnt/camera-backup) |

    **Runbook**

    [KEYCLOAK.md](docs/KEYCLOAK.md)

    ---

7. ### Layer authentication on the rest of the site endpoints

    This step will require that the camera http MCP server is available to the agent. This can be accomplished using the `/reload-mcp` directive or by restarting hermes before starting the runbook.

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{SERVER_FQDN}}` | Public DNS name shared by Nginx, Keycloak, and MCP |
    | `{{SERVER_IP}}` | Address on which Nginx accepts public HTTPS |
    | `{{BACKUP_PATH}}` | Backup folder (e.g. /mnt/camera-backup) | - |

    **Runbook**

    [STREAM_AUTH.md](docs/STREAM_AUTH.md)

    ---

8. ### Configure Keycloak email

    The user will create a dedicated Gmail account for the Keycloak administrator, then create a Google app password for Keycloak:

    1. Sign in to the new Gmail account and enable 2-Step Verification under [Google Account Security](https://myaccount.google.com/security).
    2. Open [App passwords](https://myaccount.google.com/apppasswords).
    3. Create one named Camera Keycloak. Save the generated password securely; don’t paste it here.

    Execute the runbook to establish the Keycloak adminstrator email account. Step 1 of the runbook is run by the user in a terminal on the camera server. After this, The app password is stored at /opt/keycloak/gmail-smtp.pass. Never display it or ask the user to paste it into chat. The balance of steps are run by the agent.

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{GMAIL_ADDRESS}}` | Dedicated Gmail address for keycloak admin |
    | `{{SERVER_FQDN}}` | Camera server hostname used by clients |
    | `{{BACKUP_PATH}}` | Existing backup folder |

    **Runbook**

    [KEYCLOAK_EMAIL.md](docs/KEYCLOAK_EMAIL.md)

    ---

9. ### Add user

    This step adds a user to the system that is authorized to access the apps endpoints of the nginx server. If connection to the MCP server is required, the additional step `Add client IP address to allowed hosts` must be executed, as the authentication server requires client machines to be registered by IP address before they are allowed access to MCP. 

    The runbook creates the user in the keycloak database and emails an invitation to this user. The recipient must create their own password. Complete the documented checks and backups, and report onboarding as pending until the recipient completes setup.

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{NEW_LOGIN_USER}}` | Administrator-supplied new username |
    | `{{FIRST_NAME}}` | Recipient's first name |
    | `{{LAST_NAME}}` | Recipient's last name |
    | `{{USER_EMAIL}}` | Real inbox controlled by the recipient |
    | `{{SERVER_FQDN}}` | Camera server hostname |
    | `{{BACKUP_PATH}}` | Existing backup folder |

    **Runbook**

    [ADD_USER_EMAIL.md](docs/ADD_USER_EMAIL.md)

    ---

10. ### Add client IP address to allowed hosts

    This step is needed for access to the camera MCP server.

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{CLIENT_SOURCE_IP}}` | IP Address to be allowed |
    | `{{BACKUP_PATH}}` | Backup folder |

    **Runbook**

    [ADD_CLIENT_ON_SERVER.md](docs/ADD_CLIENT_ON_SERVER.md)

    ---

11. ### Firewall Protection

    The document [FIREWALL.md](docs/FIREWALL.md) shows how to configure a firewall for this system using the built in ufw utility in Ubuntu.

    ---

## Configuring the Client

Clients are configured using the [CLIENT.md](docs/CLIENT.md) doc. Configurations have been mapped for major Linux distros, Windows and MacOS. Limited configuration for Android mobile devices gives access to the camera web apps.

---
