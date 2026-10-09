# System Installation Template

These are the full instructions to build the camera system. The table of Required Values are used throughout the Runbooks listed below. Execute the runbooks in order to completion starting with Phase 1, then stop and prompt the user to check for available context. In many cases, the user will need to reset the context before continuing with Phase 2. The runbooks can be found in the docs/ folder.

Do not obsess over every camera detail. Many cameras have bugs that will cause them to behave poorly in response to commands. If a camera feature is not working after a couple of attempts, assume that the camera does not implement the feature properly and continue configuration without that feature. If a camera advertises several streams or snapshot endpoints and some do not work, just use existing streams or endpoints that are known to work.


**Required Values**

| Name | Value |
|---|---|
| `{{PRVT_NET_EN_NAME}}` | enx50a0300e6cb1 |
| `{{SERVER_FQDN}}`      | nuc.home.arpa |
| `{{CAMERA_USERNAME}}`  | admin |
| `{{REPO_PATH}}`        | /home/stephen |
| `{{SERVER_USER}}`      | stephen |
| `{{CA_ROOT_PATH}}`     | /home/stephen/Private-CA |
| `{{BACKUP_PATH}}`      | /mnt/camera-backup |
| `{{SERVER_IP}}`        | 10.1.1.6 |
| `{{RVRS_SRV_IP}}`      | 6.1.1.10 |
| `{{UPSTREAM_DNS}}`     | 192.168.68.1 |
| `{{GMAIL_ADDRESS}}`    | keycloak.admin.sample@gmail.com |

**Runbooks**

### Phase 1

[GPG_KEY.md](docs/GPG_KEY.md)

[DHCP.md](docs/DHCP.md)

[MCP_HTTP.md](docs/MCP_HTTP.md)

[MEDIAMTX.md](docs/MEDIAMTX.md)

[SNAPSHOT.md](docs/SNAPSHOT.md)

[APPS.md](docs/APPS.md)

[CREATE_CA_CERT.md](docs/CREATE_CA_CERT.md)

[SITE_CERT.md](docs/SITE_CERT.md)

[CA_DISTRIBUTE.md](docs/CA_DISTRIBUTE.md)

[DNS.md](docs/DNS.md)

At the completion of Phase 1, pause and allow the user to check for available context before continuing with Phase 2.

### Phase 2

[KEYCLOAK.md](docs/KEYCLOAK.md)

[STREAM_AUTH.md](docs/STREAM_AUTH.md)

[KEYCLOAK_EMAIL.md](docs/KEYCLOAK_EMAIL.md)
