## ONVIF MCP

This project builds a secure IP camera network with enterprise grade OAuth authentication and isolated private network ONVIF cameras. Cameras can be configured such that there is no direct access between the cameras and the local network or wider internet. All camera network traffic is proxied by a single secure server protected by firewall and encrypted by TLS with a private CA certificate. Camera live streams can be accessed remotely by mobile devices using a secured Tailscale connection in addition to the protections already provided.

A Hermes agent is used to build out the server and network so only a minimal level of technical expertise is required to build and maintain the system. Hermes will create a skill set for itself as it builds the system so that it becomes your resident expert system adminstrator with all the specialized knowledge required to maintain the system once it is up and running. Advanced system features can be developed by the agent by prompting, so you can expand and customize the system to your requirements without specialized technical expertise.

## How it works

Take a freshly installed Ubuntu computer with at least two network adapters, and plug in your cameras to one ethernet interface and your LAN to the other. If your machine has only one ethernet adapter, you can add one with a USB adapter, or use the wireless connection. Wireless is not as reliable as wired connections, so keep that in mind. Run the SERVER_PREP script on the computer, which installs all the necessary software, including Hermes. You will need a source of intelligence such as a cloud model provider or local LLM. Hermes will guide you through the installation of the model.

During installation, you will be prompted to enter a static IP address for the server. You will need to know what the range of available static IP addresses you can use on your LAN. Consult your router for this data in the DHCP section of the settings. Usually, this will be reserved addresses at the lower or higher range of the .0 to .255 address span.

When server preparation is complete, fill out the INSTALL.md document so Hermes will have the information it needs for the installation. An important piece you need to know is the name of the ethernet adapter to which the camera are connected. Use the command `nmcli dev show` to get a list of adapters. You should see one that has the static IP you configured during installation and another that is not connected. The one that is not connected is your camera interface and will be configured by Hermes to control the camera network, this it the one you want as {{PRVT_NET_EN_NAME}}. The {{SERVER_IP}} is the static IP set during installation.

You will need an email account for the server so that it can send out invitations to users to set thier passwords for access to the system. This can be done with a Google account that you can configure for this purpose. You will need to add an App Password that allows the script to automatically send the subscription email. Note that the App Password setting will require two factor authentication for the Google account. To set this up, refer to [Google app passwords](https://support.google.com/accounts/answer/185833) and [Gmail SMTP settings](https://support.google.com/mail/answer/7104828).

A backup location is needed for the system. For simplicity, you can just make a local folder as the backup. Please refer to the BACKUP.md instructions for details.

Once you have the necessary information, kick off the installation by prompting the Hermes agent. It will prompt you to set up a GPG key to protect your passwords, then ask you to enter a password for the cameras. This is done to prevent your passwords from entering into the agent context, which is important for security. You will need a second terminal open to do these things. Watch the model output and follow the instuctions, pasting the repsonse to the commands it gives you so it knows how to proceed. Passwords are never included in the responses, so pasting is a safe operation.

The process of setting up the system requires significant model context. The agent will pause during the setup and ask you to check your available context at certain points during the installation. It is a good idea to use the `/new` directive in the agent prompt to clear context during these breaks to prevent context overflow. A good minimum context of at least 128k is recommended.

At some point during the server configuration, you will be asked for gmail App password that you created when you signed up for the gmail account for the server. This will be entered into your second terminal in response to a command that the agent will provide for you. The App password is a 16 character string separated by spaces at each four character grouping. The command to enter it does not echo the characters, just tell the Hermes agent that it was entered, and it can check for validity.

At the completion of this process, you can start adding users to the system. It will send an email to the address that you provide. Users will need the Camera CA certificate trusted on their browser in order to use the link in the email. Please refer to the CLIENT.md instructions for your operating system to trust the certificate. Once you have set the password, you will be able to access the live camera streams using the browser address {{SERVER_FQDN}}.home.arpa/cameras, where {{SERVER_FQDN}} is the address you set in the INSTALL.md document.

Remote access is enabled using Tailscale. The agent can make some of the configurations if you prompt it to follow the TAILSCALE.md runbook. It will prompt you to make some configurations yourself using the Tailscale admin console in your web browser. To use a mobile device remotely, you will need to make some configurations on your phone, please consult the CLIENT.md document for instructions.

For advanced applications using the camera MCP server, you will need to register the client IP address with the server. It is a good idea to set a static IP address on the client for this capability similar to what was done during server preparation. Setting a static IP address will depend on your operating system, you can ask the agent for instructions.

For detailed step by step instuctions of the process desribed here, please review the [Building The Server](#building-the-server) section of this document.

## System Requirements

* Server

    The system requires a server with dual network interface adapters. A LAN facing adapter connects to the local network and is accessible by other computers on the LAN. A second interface is configured as the DHCP controller providing a private isolated network hosting the cameras. The documentation has been developed and tested against an Ubuntu 26.04 Operating System installed on the server. A freshly installed, dedicated bare metal server is recommended. Computing requirements for the server are modest, a reasonably powered mini pc is ideal for the application.

* Cameras

    ONVIF compatible cameras are required for the system. Cameras manufactured by Hikvision, Dahua, Amcrest, Axis, Speco, Trendnet, Tapo, Lorex have been tested with this system. Many other cameras that support the ONVIF standard and can be expected to work. The level of compliance may vary across different brands, but most will follow the spec in general terms. Some configuration of the camera may be required to enable ONVIF compatibility, please consult the camera documentation for details.

* AI Provider

    A source of intelligence is required for the system. Excellent results have been achieved using the [Strata](https://github.com/Niko1221/Strata) project hosting the Qwen3.8-Flash-Next model locally. This arrangement provides sufficient compute to efficiently build and run the system. Run time operation is responsive and provides operational characteristics on par with legacy deterministic camera management systems. Strata can support lower powered compute arrangements and provide acceptable performance. Cloud based AI works as well, use a lower tier model to conserve token usage.

* Agent 

    This system is designed and tested around the Hermes Agent. This agent has many characteristics that make it ideal for this application. Hermes implements the full OAuth stack for MCP security and does not require any cloud access to operate. The MCP server is hosted locally and therefore not fully compatible with ChatGPT and Claude Agents, both of which require connection to their cloud servers for MCP operation. OpenClaw was found to be less capable than Hermes in this scenario, and is not recommended. The Hermes Agent will require sudo privileges to build the server, the configuration includes passwordless sudo.

* Clients

    Configurations are documented for clients using Windows, Mac and Linux distros Ubuntu, Fedora and Cachy OS. Other distros can be easily adopted by following the instructions for the documented distro families. For example, Omarchy is easily configured using the instructions for Cachy OS. Android clients can be configured for access to the camera web apps. Hermes can be used on the client for AI enhanced operation including camera configuration and control. Hermes on the client can operate with full capabilities without using elevated privileges.

## Security Features

The documentation includes instructions for creating and maintaining a private Certificate Authority in order to provide certificates for HTTPS encryption. Keycloak is used for the OAuth server and provides short-lived JWT token authentication for both the camera MCP server and the camera m apps. Cameras are isolated on a private network accessible only by proxy through the protected server. Per-user credentials are securely stored and can be revoked at any time.

Clients using only the camera apps do not require any additional configuration. Clients that intend to use MCP services need to be registered with the server by IP address, which implies that they will need to have a static IP. If this requirement is overly strict, the authentication can be set to looser restriction by IP subnet, allowing a range of device IPs from the designated subnet.

## Agentic Server Administration

The Hermes agent is capable of managing most server functionality autonomously. This is a very powerful mechanism that enables control over a server without requiring that the user have deep expertise in the nuances of different server programs and protocols. For most well documented server functions, current agents have sufficient understanding to manage and maintain programs and processes without significant external guidance. 

This arrangement raises some questions regarding the permissions that should be given to the agent. While in theory it seems possible to force the agent to request sudo access each time it needs to execute a root function, in practice this strategy has been found to be unreliable and will most often produce unsatisfactory results. This leads to the recommendation that the agent be given passwordless sudo access. Enabling this access involves creating a root protected file that gives the user account with which the agent is associated particular assigned privileges. For the sake of simplicity, the file is formatted in this case to allow full sudo access to all features, but could be implemented in a stricter sense, confining the agent to a limited set of allowed commands. This functionality is implemented in the enable-nopasswd.sh script. To revoke access, simply delete the file in the /etc/sudoers.d folder.

The Agent will require passwords to access cameras and services during buildout. This process is handled securely using a gpg key lock combined with the built in Linux password manager. All password protected transactions are handled in a separate terminal by the user so that the agent context never sees any sensitive password information. 

## Backup Strategies

A complex system in a production environment requires a robust backup strategy to avoid excessive downtime in the event of a server failure. The system is designed to support incremental backups as it is installed and maintained. Backup data can be held in a shared SMB folder, a mounted external drive, or a local filesystem folder. Whichever storage type is chosen, the backup location must enforce the same permission model the SMB mount enforced: mode 0700 owned by the runbook user, files 0600, no extra ACL entries. Please refer to the [BACKUP.md](docs/BACKUP.md) document for further details on the strategies.

* Local filesystem folder

    A folder on the local filesystem is also accepted as `{{BACKUP_PATH}}`, provided it enforces the permission model above. Note that a local folder does not provide off-host redundancy, it is intended for staging, testing, or single-machine arrangements.

* Mounted external drive

    This is a simpler strategy that involves only a mounted external drive accessible to the agent. This will be a common arrangement in many systems and avoids the complexity of setting up a shared SMB folder.

* Shared SMB folder

    The agent is capable of configuring both the server and client sides of a shared SMB folder for backup purposes. In order for the agent to be able to work on the server side of the external host, it must be configured with SSH access and have been set up with passwordless sudo as describe above in Agentic Server Administration. In this configuration, the camera host, on which the agentic administrator resides, is the SMB client.

## Building the Server

The Hermes agent is used to perform the configuration by running the plan set in the [INSTALL.md](docs/INSTALL.md) runbook. Required Values needed for the installation are set in the tables prior to asking Hermes to configure the system. Default values are prefilled in the table, values showing as `---` need to be entered by the user based on site specific requirements.

Be mindful of model context size when running the configurations shown below. Starting a fresh context after it reaches 50 percent is advised. Runbooks can be executed individually on systems with modest context if necessary. The runbooks can be found in the `{{REPO_PATH}}/docs` directory. The runbooks are intended to be executed in the order listed.

1. ### Server Preparation

  Follow the [SERVER_PREP.md](docs/SERVER_PREP.md) document in the docs folder after installing Ubuntu 26.04 on the host.

2. ### Choose a Backup Path

  Read the [BACKUP.md](docs/BACKUP.md) and establish a backup path appropriate for your situation.

3. ### Supply Required Values and install

  Enter Required Values into the tables in [INSTALL.md](INSTALL.md), including users and allowed machine IP addresses.

  * `{{PRVT_NET_EN_NAME}}`

    The name of the ethernet adapter used for hosting the private camera subnet. The adapter should first be connected to the switch, then run the `nmcli dev show` command to look for the unconnected ethernet adapter. There should be one connected adapter that has the static IP address set earlier during server preparation, which should be left undisturbed.

  * `{{SERVER_IP}}`

    The static IP address of the server set during the server preparation step.

  * `{{GMAIL_ADDRESS}}`

    A Gmail address that can be used by the server to send out subscription emails for system users to sign up for a password to allow access. Please refer to [KEYCLOAK_EMAIL.md](docs/KEYCLOAK_EMAIL.md) for more details. The salient point here is that the google email account needs an App Password set that allows the script to automatically send the subscription email. Note that the App Password setting will require two factor authentication for the google account. To set this up, sign up for a gmail account and follow the instructions at [Google app passwords](https://support.google.com/accounts/answer/185833) and [Gmail SMTP settings](https://support.google.com/mail/answer/7104828).

  * `{{SERVER_FQDN}}` 

    The Fully Qualified Domain Name of the server. It should end in .home.arpa, which is the reserved domain name for private servers. An example might be `camera.home.arpa`. The default value is the computer name set in the Ubuntu installation process corresponding to the environment variable $HOSTNAME.

  * `{{CAMERA_USERNAME}}`

    The common ONVIF username used by the cameras. Typically this will be `admin`.

  * `{{REPO_PATH}}`

    The full pathname of the onvif-mcp repository, which will be $HOME/onvif-mcp as configured during server preparation.

  * `{{SERVER_USER}}`

    The actual name of the user account in which the server is installed, it corresponds to the environment variable $USER.

  * `{{CA_ROOT_PATH}}`

    A storage location for the CA certificate artifacts. The default is $HOME/Private-CA.

  * `{{BACKUP_PATH}}`

    The backup path as determined from [BACKUP.md](docs/BACKUP.md). 

4. ### Start the hermes agent and prompt it

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

Following successful login to the MCP server, prompt the agent again, telling it that the operation was successful and to backup the Keycloak authentication server.
