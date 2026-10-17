# System Installation Template

These are the full instructions to build the camera system. The table of Required Values are used throughout the Runbooks listed below. Execute the runbooks in order to completion starting with Phase 1, then stop and prompt the user to check for available context. In many cases, the user will need to reset the context before continuing with Phase 2. The runbooks can be found in the docs/ folder. Upon completion of Phase 2 stop and prompt the user to check for available context again. Users can then be added to the system by executing Phase 3. Allowed machine IP addresses can be configured in Phase 4. 

This computer has been configured so that you have passwordless sudo privileges as $USER.

Do not obsess over every camera detail. Many cameras have bugs that will cause them to behave poorly in response to commands. If a camera feature is not working after a couple of attempts, assume that the camera does not implement the feature properly and continue configuration without that feature. If a camera advertises several streams or snapshot endpoints and some do not work, just use existing streams or endpoints that are known to work.

As you work through the scripts, keep an audit log in the folder that holds the script. Please suppress the echo to terminal when writing the logs so that the file edits do not display in the user interface, which is very distracting to the user. Record any files that are downloaded with the exact url used to download the file. Any programs that are installed, record the name and the version of the program. If errors or issues are encountered, record the error and the steps used to overcome it. The log should  be written to the same folder in the scripts/ directory as the script itself and have the same name root as the script with a .log extension, e.g. onvif-mcp/scripts/GPG_KEY/gpg_key_runbook.log.

**Required Values**

| Name | Value |
|---|---|
| `{{PRVT_NET_EN_NAME}}` | enp2s0 |
| `{{SERVER_FQDN}}`      | $HOSTNAME.home.arpa |
| `{{CAMERA_USERNAME}}`  | admin |
| `{{REPO_PATH}}`        | $HOME/onvif-mcp |
| `{{SERVER_USER}}`      | $USER |
| `{{CA_ROOT_PATH}}`     | $HOME/Private-CA |
| `{{BACKUP_PATH}}`      | $HOME/camera-backup |
| `{{SERVER_IP}}`        | 10.1.1.3 |
| `{{GMAIL_ADDRESS}}`    | keycloak.admin.sample@gmail.com |

**Runbooks**

### Phase 1

[GPG_KEY.md](docs/GPG_KEY.md)

[DNS.md](docs/DNS.md)

[DHCP.md](docs/DHCP.md)

[MCP_HTTP.md](docs/MCP_HTTP.md)

[MEDIAMTX.md](docs/MEDIAMTX.md)

[SNAPSHOT.md](docs/SNAPSHOT.md)

[APPS.md](docs/APPS.md)

[CREATE_CA_CERT.md](docs/CREATE_CA_CERT.md)

[SITE_CERT.md](docs/SITE_CERT.md)

[CA_DISTRIBUTE.md](docs/CA_DISTRIBUTE.md)

[FIREWALL.md](docs/FIREWALL.md)

At the completion of Phase 1, pause and allow the user to check for available context before continuing with Phase 2.

### Phase 2

[KEYCLOAK.md](docs/KEYCLOAK.md)

[STREAM_AUTH.md](docs/STREAM_AUTH.md)

[KEYCLOAK_EMAIL.md](docs/KEYCLOAK_EMAIL.md)

The system is now installed, pause and allow the user to check for available context. Continue with Phase 3 to add users by adding entries to the table below. 

### Phase 3.

Required Values 

| Name | Description |
|---|---|
| `{{NEW_USER_LOGIN}}` | stephen |
| `{{FIRST_NAME}}` | Stephen |
| `{{LAST_NAME}}` | Rhodes |
| `{{USER_EMAIL}}` | sr99622@gmail.com |

Runbook

[ADD_USER_EMAIL](docs/ADD_USER_EMAIL)

### Phase 4.

Required Values

| Name | Description |
|---|---|
| `{{CLIENT_SOURCE_IP}}` | 192.168.68.57 |

Runbook

[ADD_CLIENT_ON_SERVER](docs/ADD_CLIENT_ON_SERVER)



