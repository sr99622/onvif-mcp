## ONVIF MCP

This project builds a secure IP camera network with enterprise grade OAuth authentication and isolated private network ONVIF cameras. Cameras can be configured such that there is no direct access between the cameras and the local network or wider internet. All camera network traffic is proxied by a single secure server. The system includes web based switchboard apps that can select single camera views or multi-camera views of live streams.

The system employs a Hermes Agent with elevated privileges to build and manage the system. The configurations described here have been tested using a locally hosted instance of Qwen3.8 27B inference model as the source of intelligence. If inference is locally hosted, the system is fully autonomous and does not require any external internet connection to function once it has been set up.

Clients can connect to the camera web apps without further configuration beyond entering authorization credentials. Hermes can be configured on the client side to give the agent full control over camera operation including PTZ functions with additional security safeguards.

## System Requirements

* Server

    The system requires a server with dual network interface adapters. A LAN facing adapter connects to the local network and is accessible by other computers on the LAN. A second interface is configured as the DHCP controller providing a private isolated network hosting the cameras. The documentation has been developed and tested against an Ubuntu 26.04 Operating System installed on the server. A freshly installed, dedicated bare metal server is recommended. Computing requirements for the server are modest, a reasonably powered mini pc is ideal for the application. Reference SERVER_PREP.md in the docs folder for the recommended server setup.

* AI Provider

    A source of intelligence is required for the system. This configuration was developed and tested using Qwen3.8 27B model running on a NVIDIA 4500 with 32GB VRAM. This arrangement provides sufficient compute to efficiently build and run the system. A full build out will require about three hours for the agent to complete. Run time operation is sufficiently responsive that the system provides operational characteristics on par with legacy deterministic camera management systems. Lower powered compute arrangements can provide acceptable performance as well in accordance with their capability. Note that during build out, context on the order of 90k tokens is needed to avoid context compression events. Cloud based AI works as well, use a lower tier model to conserve token usage.

* Agent 

    This system is designed and tested around the Hermes Agent. This agent has many characteristics that make it ideal for this application. Hermes implements the full OAuth stack for MCP security and does not require any cloud access to operate. The MCP server is hosted locally and therefore not fully  compatible with ChatGPT and Claude Agents, both of which require connection to their cloud servers for MCP operation. OpenClaw was found to be less capable than Hermes in this scenario, and is not recommended. The Hermes Agent will require sudo privileges to build the server.

* Clients

    Configurations are documented for clients using Windows, Mac and Linux distros Ubuntu, Fedora and Cachy OS. Other distros can be easily adopted by following the instructions for the documented distro families. For example, Omarchy is easily configured using the instructions for Cachy OS. Android clients can be configured for access to the camera web apps. Hermes can be used on the client for AI enhanced operation including camera configuration and control. Hermes on the client can operate with full capabilities without using elevated privileges.

## Security Features

The documentation includes instructions for creating and maintaining a private Certificate Authority in order to provide certificates for HTTPS encrytption. Keycloak is used for the OAuth server and provides short-lived JWT token authentication for both the camera MCP server and the camera stream apps. Cameras are isolated on a private network accessible only by proxy behind the protected server. Per-user credentials are securely stored and can be revoked at any time.

Clients using only the camera apps do not require any additional configuration. Clients that intend to use MCP services need to be registered with the server by IP address, which implies that they will need to have a static IP. If this requirement is overly strict, the authentication can be set to looser restriction by IP subnet, allowing a range of device IPs from the designated subnet.

## Building the Server

The server is built in stages as listed below. Server host preparation sets up the baseline operating system configuration, Plain HTTP sets up the services without encryption, HTTPS creates the certificate and maps the endpoints for protection, and Authentication implements the Keycloak server for login credential requirements. A firewall can be added at the conclusion of the configuration for additional protection.

Be mindful of model context size when running the configurations shown below. As they are grouped, they will require around 90k token context window for each group of Runbooks. Starting a fresh context after each group is advised for models with standard context length. Runbooks can be execute individually on systems with modest context abilities.

1. ### Server Preparation

    Follow the SERVER_PREP.md document in the docs folder after installing Ubuntu 26.04 on the host. The top section of the document installs several quality of life features that help manage the server, but are not strictly required for operation. The Essential Configurations section describes critical installations required for operation.

    #### Set up password store and backup folder

    The system will need several secret passwords for cameras, shared folders and server management. The `GPG_KEY.md` runbook contains instructions for setting up a GPG protected password store for these secrets.

    The server will need a backup location for critical data. An SMB share is a good place to do this. Assuming you have another Ubuntu machine set up on your local network, Hermes can do this for you using the instructions in the runbook SMB_SERVE.md. Other mounted storage locations work as well, but the procedures that follow will expect there to be a directory into which backup files can be written with proper file permissions.

    Assuming you have chosen the SMB strategy and have a server set up, prompt the agent to create the gpg key, password store, smb mount and backup the keys.

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{SMB_MOUNT}}` | Mounted SMB shared folder |
    | `{{SMB_USERNAME}}` | Samba username for the private camera CA backup share |

    **Runbook**

    ```
    GPG_KEY.md
    ```
    ---

2. ### HTTP Services

    This is a baseline configuration required before layering encryption and authentication on the server. All essential services are initially configured here without encryption. This could theoretically be considered a fully functional unsecured system. The Hermes agent is used to perform the configuration and can be prompted to follow this document and implement the steps as described in the runbook referenced below. Values required for implementation are listed in the table, edit this document with your own site values and Hermes can implement the configuration autonomously.

    After following the instructions in SERVER_PREP.md, attach the cameras to the second ethernet adapter. Prompt the agent with the required values and the list of runbooks to make the build. The value for `{{PRVT_CAMERA_NET_EN_NAME}}` can be found using the `nmcli dev show` command from a terminal. The runbooks to implement the configuration are found in the `{{REPO_PATH}}/onvif-mcp/docs` directory. The runbooks are intended to be executed in the order listed.


    **Required Values**

    | Name | Description | Site Value |
    |------|-------------|------------|
    | `{{PRVT_CAMERA_NET_EN_NAME}}` | Ethernet adapter hosting the private camera network | - |
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server, e.g. camera.home.arpa | - |
    | `{{USERNAME}}` | Common username for cameras | - |
    | `{{REPO_PATH}}` | Parent directory of this repository | - |
    | `{{SERVER_USER}}` | Account name on the server under which Hermes is run | - |

    **Runbooks**

    ```
    DHCP.md
    MEDIAMTX.md
    SNAPSHOT.md
    APPS.md
    MCP_HTTP.md
    ```
    
    **Agent Instructions**

    The runbooks are intended to be executed in order. 
    
    The DHCP server is set up first and should be given ample opportunity to assign addresses to cameras before querying the camera MCP server tool get_cameras to discover cameras on the network. A couple of minutes should be long enough. 
    
    Use the stdio camera MCP server tool `get_cameras` to get camera data. This server is already configured for your use. It returns all the data needed in a delimited json format. Do not attempt to develop methods to query the cameras directly using ONVIF or other methods. The camera MCP server is the most reliable method of finding the data.

    There is another camera MCP server that is configured by the runbook MCP_HTTP.md. It is not intended to be used by you to gather camera data. That server is available for remote agents to access the camera system. You will be configuring and testing the HTTP MCP server, but you should use the stdio MCP server that you have already to query cameras for data.

    The SNAPSHOT.md runbook builds a server that is used to get camera snapshots. This server will query the cameras directly as a proxy to get jpg snapshots. You should not try to emulate the snapshot server. You should follow the runbook directions for testing closely. This server is intended for use by remote agents, similar to HTTP MCP.

    ---

3. ### HTTPS Encryption

    Included are runbooks for generating and distributing a Certificate Authority (CA) and site certificate locally. The endpoints are re-mapped to provide encryption for the suite of services. The instructions include a backup to an SMB shared drive, so there should be one available on the local network to hold the certificates in the case of server failure. The backup can be skipped if necessary, but that is obviously not recommended.

    During execution of the `GPG_KEY.md` runbook, the user will be prompted for passwords twice. The use will open their own terminal for these actions. First a a prompt for the gpg key generation. A second prompt occurs during the backup and testing. During execution of CREATE_CA_CERT.md, the user may be prompted for a key to warm up the key cache.

    Following completion of this section, nginx will be serving the endpoints under SSL encryption and clients will need to authorize the keys from their certificate store. Instructions for client configuration are in the `CLIENT.md` runbook. The site certificate can be accessed through an unencrypted endpoint on the server.

    **Required Values**

    | Name | Description | Site Value |
    |------|-------------|------------|
    | `{{CA_ROOT_PATH}}` | Private CA root directory (e.g. $HOME/Private-CA) | - |
    | `{{BACKUP_PATH}}` | SMB shared drive to be created on the local host (e.g. `/mnt/backup/Camera-System-Backup`) | - |
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server, e.g. camera.home.arpa | - |
    | `{{SERVER_USER}}` | Account name on the server under which Hermes is run | - |
    | `{{REPO_PATH}}` | Parent directory of this repository | - |
    | `{{SERVER_IP}}` | IP address of the server e.g. 10.1.1.2 | - |
    | `{{RVRS_SRV_IP}}` | Reverse IP address of the server e.g. 2.1.1.10 | - |
    | `{{UPSTREAM_DNS}}` | Upstream DNS resolver | - |

    **Runbooks**

    ```
    CREATE_CA_CERT.md
    SITE_CERT.md
    CA_DISTRIBUTE.md
    DNS.md
    ```

    ---

4. ### Keycloak installation

    The Keycloak server provides authentication services for the site. During installation a default user is created that can be used for testing the configuration. A fresh context may be needed at this point, if so, re-intialize the agent context in the prompt by having them review this document again. 

    **Required Values**

    | Name | Description | Site Value |
    |------|-------------|------------|
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server (e.g. camera.home.arpa) | - |
    | `{{BACKUP_PATH}}` | Backup folder (e.g. /mnt/backup/Camera-System-Backup) | - |

    **Runbook**

    ```
    KEYCLOAK.md
    ```
    ---

5. ### Layer authentication on the rest of the site endpoints

    This step will require that the camera-new http MCP server is available to the agent. This can be accomplished using the /reload-mcp directive before starting the runbook.

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{SERVER_FQDN}}` | Public DNS name shared by Nginx, Keycloak, and MCP |
    | `{{SERVER_IP}}` | Address on which Nginx accepts public HTTPS |
    | `{{BACKUP_PATH}}` | Backup folder (e.g. /mnt/backup/Camera-System-Backup) | - |

    **Runbook**

    ```
    STREAM_AUTH.md
    ```
    ---

6. ### Add user

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{NEW_LOGIN_USER}}` | New login username supplied by agent |
    | `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name |
    | `{{BACKUP_PATH}}` | Backup folder |
    | `{{FIRST_NAME}}` | New login first name |
    | `{{LAST_NAME}}` | New login last name |
    | `{{USER_EMAIL}}` | New login email address |
    | `{{PASSWORD}}` | **Optional** - If not specified, a random password will be generated by the system, root accessible at `/opt/keycloak/{{NEW_LOGIN_USER}}.pass` |

    **Runbook**

    ```
    ADD_USER.md
    ```
    ---

7. ### Add client IP address to allowed hosts

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{CLIENT_SOURCE_IP}}` | IP Address to be allowed |
    | `{{BACKUP_PATH}}` | Backup folder |


    **Runbook**

    ```
    ADD_CLIENT_ON_SERVER.md
    ```
    ---

8. ### Firewall Protection

    The document FIREWALL.md shows how to configure a firewall for this system using the built in ufw utility in Ubuntu.

    ---

## Configuring the Client

Clients are configured using the CLIENT.md doc. Configurations have been mapped for major Linux distros, Windows and MacOS. Limited configuration for Android mobile devices gives access to the camera web apps.

If the client is using MCP services, you can optimize performance with the following prompt, which should be applied after testing the client in situ.

```
When using camera MCP server tools, it is not necessary to verify that any of the commands have completed successfully beyond checking the return code from the tool call. The camera communications library is very reliable and will pretty much always work properly. If something has gone wrong, the user will ask explicitly for you to check. This may go against your training to always verify things, but it is important that we optimize the system to be as responsive as possible, and post tool call checking slows things down considerably. If the tool call returns a success message, assume that the call succeeded and do not re-query the cameras or take a snapshot without being explicitly asked by the user. One important exception here is the appearance of the 500 error message in the browser when viewing a camera stream. The tool call will return success, but the server may show 500 due to auth token timeout. You should check for the 500 message in the title of the browser when asked to view a camera stream, and if it appears, all you need to do is refresh the browser.
```
---
