## ONVIF MCP

This project builds a secure IP camera network with enterprise grade OAuth authentication and isolated private network ONVIF cameras. Cameras can be configured such that there is no direct access between the cameras and the local network or wider internet. All camera network traffic is proxied by a single secure server. The system includes web based switchboard apps that can select single camera views or multi-camera views of live streams. Streams are continuously recorded and available for immediate playback.

The system employs a Hermes Agent with elevated privileges to build and manage the system. The configurations described here have been tested using a locally hosted instance of Qwen3.8-Flash-Next inference model as the source of intelligence. If inference is locally hosted, the system is fully autonomous and does not require any external internet connection to function once it has been set up.

Clients can connect to the camera web apps without further configuration beyond importing the CA certificate and entering authorization credentials. Hermes can be configured on the client side to give the agent full control over camera operation including PTZ functions with additional security safeguards.

## System Requirements

* Server

    The system requires a server with dual network interface adapters. A LAN facing adapter connects to the local network and is accessible by other computers on the LAN. A second interface is configured as the DHCP controller providing a private isolated network hosting the cameras. The documentation has been developed and tested against an Ubuntu 26.04 Operating System installed on the server. A freshly installed, dedicated bare metal server is recommended. Computing requirements for the server are modest, a reasonably powered mini pc is ideal for the application.

* Cameras

    ONVIF compatible cameras are required for the system. Cameras manufactured by Hikvision, Dahua, Amcrest, Axis, Speco, Trendnet, Tapo, Lorex have been tested with this system. Many other cameras that support the ONVIF standard and can be expected to work. The level of compliance may vary across different brands, but most will follow the spec in general terms. Some configuration of the camera may be required to enable ONVIF compatibility, please consult the camera documentation for details.

* AI Provider

    A source of intelligence is required for the system. Excellent results have been achieved using the [Strata](https://github.com/Niko1221/Strata) project hosting the Qwen3.8-Flash-Next model locally. This arrangement provides sufficient compute to efficiently build and run the system. Run time operation is sufficiently responsive that the system provides operational characteristics on par with legacy deterministic camera management systems. Strata can support lower powered compute arrangements and provide acceptable performance. Cloud based AI works as well, use a lower tier model to conserve token usage.

* Agent 

    This system is designed and tested around the Hermes Agent. This agent has many characteristics that make it ideal for this application. Hermes implements the full OAuth stack for MCP security and does not require any cloud access to operate. The MCP server is hosted locally and therefore not fully compatible with ChatGPT and Claude Agents, both of which require connection to their cloud servers for MCP operation. OpenClaw was found to be less capable than Hermes in this scenario, and is not recommended. The Hermes Agent will require sudo privileges to build the server, the configuration includes passwordless sudo.

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

The Hermes agent is used to perform the configuration by running the plan set in the INSTALL.md runbook. Required Values needed for the installation are set in the tables prior to asking Hermes to configure the system.

Be mindful of model context size when running the configurations shown below. Starting a fresh context after it reaches 50 percent is advised. Runbooks can be executed individually on systems with modest context if necessary. The runbooks can be found in the `{{REPO_PATH}}/docs` directory. The runbooks are intended to be executed in the order listed.

1. ### Server Preparation

  Follow the [SERVER_PREP.md](docs/SERVER_PREP.md) document in the docs folder after installing Ubuntu 26.04 on the host.

2. ### Choose a Backup Path

  Read the [BACKUP.md](docs/BACKUP.md) and establish a backup path appropriate for your situation.

3. ### Supply Required Values and install

  Enter Required Values into the tables in [INSTALL.md](INSTALL.md), including users and allowed machine IP addresses.

  * `{{SERVER_IP}}`

    The static IP address of the server set during the server preparation step.

  * `{{SERVER_FQDN}}` 

    The Fully Qualified Domain Name of the server. It should end in .home.arpa, which is the reserved domain name for private servers. An example might be `camera.home.arpa`.

  * `{{PRVT_NET_EN_NAME}}`

    The name of the ethernet adapter used for hosting the private camera subnet. The adapter should first be connected to the switch, then run the `nmcli dev show` command to look for the unconnected ethernet adapter. There should be one connected adapter that has the static IP address set earlier during server preparation, which should be left undisturbed.

  * `{{CAMERA_USERNAME}}`

    The common ONVIF username used by the cameras. Typically this will be `admin`.

  * `{{REPO_PATH}}`

    The full pathname of the onvif-mcp repository, which will be $HOME/onvif-mcp as configured during server preparation. Use the actual pathname rather than the environment variable.

  * `{{SERVER_USER}}`

    The actual name of the user account in which the server is installed, it corresponds to the environment variable $USER.

  * `{{CA_ROOT_PATH}}`

    A storage location for the CA certificate artifacts. A good choice is $HOME/Private-CA, where the actual path name is used rather than the environment variable.

  * `{{BACKUP_PATH}}`

    The backup path as determined from [BACKUP.md](docs/BACKUP.md)

  * `{{GMAIL_ADDRESS}}`

    A Gmail address that can be used by the server to send out subscription emails for system users to sign up for a password to allow access. Please refer to [KEYCLOAK_EMAIL.md](docs/KEYCLOAK_EMAIL.md) for more details. The salient point here is that the google email account needs an App Password set that allows the script to automatically send the subscription email. Note that the App Password setting will require two factor authentication for the google account. Sign up for a gmail account and follow the instructions at [Google app passwords](https://support.google.com/accounts/answer/185833) and [Gmail SMTP settings](https://support.google.com/mail/answer/7104828).

  Start the hermes agent and prompt it

  ```
  Execute the runbook onvif-mcp/INSTALL.md
```

  The installation will require you to perform several actions in a separate terminal to initialize and manage the passwords used by the system. Watch for prompts from the agent and copy the commands it generates for you into your terminal and then copy paste the results back to the agent. One of the things it will ask you to do is to generate a gpg key password using the PinEntry program which is a text interface. There are a number of variable selections for which you should accept the default choice by pressing the Enter key. After the certificate expiration is set to Never, the application will ask you to confirm, and the default choice is No, so type y to accept the choice.  After creating the encrypted key certificate, it will ask you to create a password. Enter the password once, then press the Tab key to advance to the second password entry, then press the Enter key to finish.

  After the Phase 1 actions are completed, the agent will prompt you to check the available context. In most cases, the context will have been used to a significant degree and should be cleared for the next phase, which again requires significant context. Type `/new` in the hermes prompt window to clear the context, then prompt it to continue configuration.

```
Continue executing the runbook onvif-mcp/INSTALL.md starting with Phase 2
```

  Upon completion of Phase 2, the system is ready for client access. The agent will prompt you to check the available context again, it can be safely cleared as before using the `/new` directive in the agent prompt. Assuming that the user information has been filled out in the Required Values table, prompt the agent

```
Execute Phase 3 of the runbook onvif-mcp/INSTALL.md
```

  This will send an email to the user. They should configure the client as described in [CLIENT.md](docs/CLIENT.md), most importantly the browser configuration to trust the Camera System CA certificate. The user should then click the link in the email to set up an account password on the camera server. At that point the camera apps should be available to the user at https://{{SERVER_FQDN}}/cameras.

  Upon completion of user configuration and successful login, prompt the agent to backup the Keycloak authorization server.

  If a user wants to access the camera MCP server to use advanced features and recording playback, a further configuration step is required. The system must register the IP address of the client to allow access. Verify the client machine IP address as described in the [CLIENT.md](docs/CLIENT.md#Get-client-IP-address-for-MCP-access) document and enter that value into the Required Value table for Phase 4 then prompt the agent

```
Execute Phase 4 of the runbook onvif-mcp/INSTALL.md
```

