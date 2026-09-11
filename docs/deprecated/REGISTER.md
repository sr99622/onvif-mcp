
## Configure and verify Hermes Agent

Edit `~/.hermes/config.yaml`, set the new entry to
enabled, and add:

```yaml
mcp_servers:
  camera-new:
    url: https://{{SERVER_FQDN}}/mcp
    ssl_verify: /path/to/private-root-ca.crt.pem
    connect_timeout: 30.0
    auth: oauth
    enabled: true
```

Get user password:

```bash
sudo cat /opt/keycloak/mcp-user.pass
```

Start login:

```bash
hermes mcp login camera-new
```

Log in as the MCP login user (mcp-user) and approve consent for `mcp:tools`. Then test
saved OAuth state:

```bash
hermes mcp test camera-new
```
Success means Hermes reconnects without another browser login and discovers
the expected MCP tools.

