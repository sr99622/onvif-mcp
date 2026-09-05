## ONVIF MCP

This project builds a secure IP camera network with enterprise grade OAuth authentication and isolated private network ONVIF cameras. Cameras can be configured such that there is no direct access between the cameras and the local network or wider internet. All camera network traffic is proxied by a single secure server. 

The system employs a Hermes Agent with elevated privileges to build and manage the system. The configurations described here have been tested using a locally hosted instance of Qwen3.8 27B inference model as the source of intelligence. The system is fully autonomous and does not require any external internet connection to function once it has been set up.

## System Requirements

* Server

    The system requires a server with dual network interface adapters. A LAN facing adapter connects to the local network and is accessible by other computers on the LAN. A second interface is configured as the DHCP controller providing a private isolated network hosting the cameras. The documentation has been developed and tested against an Ubuntu 26.04 Operating System installed on the server. A freshly installed, dedicated bare metal server is recommended. Computing requirements for the server are modest, a reasonably powered mini pc is ideal for the application. Reference SERVER_BUILD.md in the docs folder for the recommended server configuration.

* AI Provider

    A source of intelligence is required for the system. This configuration was developed and tested using Qwen3.8 27B model running on a NVIDIA 4500 with 32GB VRAM. This arrangement provides sufficient compute to efficiently build and run the system. A full build out will require about three hours for the agent to complete. Run time operation is sufficiently responsive that the system provides operational characteristics on par with legacy deterministic camera management systems. Lower powered compute arrangements can provide acceptable performance as well in accordance with their capability. Note that during build out, context on the order of 90k tokens is needed to avoid context compression events.

* Agent 

    This system is designed and tested around the Hermes Agent. This agent has many characteristics that make it ideal for this application. The MCP server is hosted locally and therefore incompatible with ChatGPT and Claude Agents. OpenClaw was found to be less capable than Hermes in this scenario, and is not recommended. The Hermes Agent will require sudo privileges in order to operate reasonably.

* Clients

    Configurations are documented for clients using Windows, Mac and Linux distros Ubuntu, Fedora and Cachy OS. Other distros can be easily adopted by following the instructions for the documented distro families. For example, Omarchy is easily configured using the instructions for Cachy OS. Clients can access camera feeds using the included web applications with minimal configuration. Hermes can be used on the client for AI enhanced operation including camera configuration and control. Hermes on the client can operate with full capabilities without elevated privileges.

## Security Features

The documentation includes instructions for creating and maintaining a private Certificate Authority in order to provide certificates for HTTPS encrytption. Keycloak is used for the OAuth server and provides short-lived JWT token authentication for both the camera MCP server and the camera stream apps. Cameras are isolated on a private network accessible only by proxy behind the protected server. Per-user credentials are securely stored and can be revoked at any time.

## Building the Server

The server is built in four stages, Server host configuratiom, Plain HTTP that sets up the services without encryption, HTTPS that creates the certificate and maps the endpoints for protection, and Authentication that implements the Keycloak server for login credential requirements.

1. ### Server Configuration

    Follow the SERVER_BUILD.md document in the docs folder after installing Ubuntu 26.04 on the host. The top section of the document installs several quality of life features that help manage the server, but are not strictly required for operation. The Essential Configurations section describes critical installations required for operation.

2. ### HTTP Services

    This is a baseline configuration required before layering encryption and authentication on the server. All essential services are initially configured here without encyption. This could theoretically be considered a fully functional unsecured system. The Hermes agent is used to perform the configuration and can be prompted to follow this document and implement the steps as described in the runbook referenced below. Values required for implementation are listed in the table, edit this document with your own site values and Hermes can implement the configuration autonomously.

    After following the instructions in SERVER_BUILD.md, attach the cameras to the second ethernet adapter. Prompt the agent with the required values and the list of runbooks to make the build. The runbooks to implement the configuration are found in the `{{REPO_PATH}}/onvif-mcp/docs` directory. The runbooks are intended to be executed in the order listed.


    **Required Values**

    | Name | Description | Site Value |
    |------|-------------|------------|
    | `{{EN_NAME}}` | Ethernet adpater hosting the private camera network | - |
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server, e.g. camera.home.arpa | - |
    | `{{USERNAME}}` | Common username for cameras | - |
    | `{{PASSWORD}}` | Common password for cameras | - |
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

3. ### HTTPS Encryption

    Included are runbooks for generating and distributing a Certificate Authority (CA) and site certificate locally. The endpoints are re-mapped to provide encryption for the suite of services. The instructions include a backup to an SMB shared drive, so there should be one available on the local network to hold the certificates in the case of server failure. The backup can be skipped if necessary, but that is obviously not recommended.

    During execution of the `CREATE_CA_CERT.md` runbook, you will be prompted for passwords three times. Firstly you will be prompted for the gpg key generation, use a key that you can remember to protect the certificate. The second prompt occurs during the backup and testing, use the option to save the key in the store when prompted to minimize the possibility of a stranded key. After the procedure has completed, you will be prompted to export the GPG keys, follow the agent instructions.

    Following completion of this section, nginx will be serving the endpoints under SSL encryption and clients will need to authorize the keys from their certificate store. Instructions for client configuration are in the `CLIENT.md` runbook. The site certificate can be accessed through the unencrypted endpoint on the server at `http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem`. Note that some browsers may not accept server domain names with http, you may be able to circumvent that limitation by using the numeric IP address of the server.

    Prompt the agent with the required values and the list of 

    **Required Values**

    | Name | Description | Site Value |
    |------|-------------|------------|
    | `{{CA_ROOT_PATH}}` | Private CA root directory (e.g. $HOME/Private-CA) | - |
    | `{{SMB_PATH}}` | SMB shared drive to be created on the local host (e.g. `/mnt/backup`) | - |
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server, e.g. camera.home.arpa | - |
    | `{{SERVER_IP}}` | The IP address of the server | - |
    | `{{SERVER_USER}}` | Account name on the server under which Hermes is run | - |
    | `{{REPO_PATH}}` | Parent directory of this repository | - |

    **Runbooks**

    ```
    CREATE_CA_CERT.md
    SITE_CERT.md
    CA_DISTRIBUTE.md
    ```

4. ### Install the Chrome Browser and make it the default

    #### Install Chrome browser

    ```bash
    wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo apt install ./google-chrome-stable_current_amd64.deb
    ```

    #### Install certificate

    ```bash
    curl -O http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem
    sudo mv camera-system-root-ca.crt.pem /usr/local/share/ca-certificates/
    sudo update-ca-certificates
    ```

    #### Configure Chrome to accept certificate

    ```
    sudo apt install libnss3-tools
    mkdir -p "$HOME/.pki/nssdb"
    chmod 700 "$HOME/.pki/nssdb"
    certutil -d "sql:$HOME/.pki/nssdb" -N
    certutil -d "sql:$HOME/.pki/nssdb" -A -t "CP,CP," -n "Camera CA Certificate" -i /usr/local/share/ca-certificates/camera-system-root-ca.crt.pem
    ```

    Launch the Chrome Browser and accept the prompt to make it the default browser. This will be important later the the MCP server is configured, as it uses the credentials from the default browser. Navigate to the cameras page at https://{{SERVER_FQDN}}/cameras to verify the working installation.

5. ### Keycloak installation

    The Keycloak server provides authentication services for the site. During installation a default user is created that can be used for testing the configuration. 

    **Required Value**

    | Name | Description | Site Value |
    |------|-------------|------------|
    | `{{SERVER_FQDN}}` | Fully Qualified Domain Name of the server (e.g. camera.home.arpa) | - |

    **Runbook**

    ```
    KEYCLOAK.md
    ```
6. ### MCP user verification

    Configure Hermes for the HTTP version of the camera MCP server using a different name than the currently existing stdio version of the server.

    ```
    nvim .hermes/config.yaml
    ```

    add the following in the mcp-servers section underneath the existing camera configuration, replace the {{SERVER_FQDN}} with your servers name.

    ```
      camera-new:
        url: https://{{SERVER_FQDN}}/mcp
        ssl_verify: /usr/local/share/ca-certificates/camera-system-root-ca.crt.pem
        connect_timeout: 30.0
        auth: oauth
        enabled: true
    ```

    Get the default user password saved in the root protected file:

    ```
    sudo cat /opt/keycloak/mcp-user.pass
    ```

    Copy this password to your system clipboard so it is ready when you login. The login has a short time limit and you will need this to be ready to avoid timeout. Run the login command from the terminal:

    ```
    hermes mcp login camera-new
    ```

    This will launch the browser and it will show the login form, enter mcp-user for the username and the copied password, then authorize the application. You may have to do this twice, it is not unusual. When you are done, run the test command:

    ```
    hermes mcp test camera-new
    ```

    You will see a list of the available camera commands.

7. ### Layer authentication on the rest of the site endpoints

    **Required Values**

    | Name | Description |
    |---|---|
    | `{{SERVER_FQDN}}` | Public DNS name shared by Nginx, Keycloak, and MCP |
    | `{{SERVER_IP}}` | Address on which Nginx accepts public HTTPS |

    **Runbook**

    ```
    STREAM_AUTH.md
    ```
8. ### Add user

    **Required Values**

    | Name | Description | Site Value |
    |------|-------------|------------|
    | `{{NEW_LOGIN_USER}}` | New login username supplied by agent, e.g. `mcp-user2` | - |
    | `{{SERVER_FQDN}}` | Server Fully Qualified Domain Name e.g. `camera.home.arpa` | - |

    **Runbook**

    ```
    ADD_USER.md
    ```