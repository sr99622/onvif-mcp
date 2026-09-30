# System Installation Template

These are the full instructions to build the camera system. The table of Required Values are used throughout the Runbooks listed below. Execute the runbooks in order to completion.

**Required Values**

| Name | Value |
|---|---|
| `{{SMB_MOUNT}}`        | - |
| `{{SMB_USERNAME}}`     | - |
| `{{SMB_SERVER_FQDN}}`  | - |
| `{{PRVT_NET_EN_NAME}}` | - |
| `{{SERVER_FQDN}}`      | - |
| `{{CAMERA_USERNAME}}`  | - |
| `{{REPO_PATH}}`        | - |
| `{{SERVER_USER}}`      | - |
| `{{CA_ROOT_PATH}}`     | - |
| `{{BACKUP_PATH}}`      | - |
| `{{SERVER_IP}}`        | - |
| `{{RVRS_SRV_IP}}`      | - |
| `{{UPSTREAM_DNS}}`     | - |
| `{{GMAIL_ADDRESS}}`    | - |

**Runbooks**

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

[KEYCLOAK.md](docs/KEYCLOAK.md)

[STREAM_AUTH.md](docs/STREAM_AUTH.md)

[KEYCLOAK_EMAIL.md](docs/KEYCLOAK_EMAIL.md)
