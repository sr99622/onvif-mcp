
## 13. Configure and verify Hermes Agent

On the Hermes host, verify Hermes and the CA file:

```bash
hermes --version
test -r /path/to/private-root-ca.crt.pem \
  && echo "CA file readable" \
  || echo "CA file missing"
```

Use a new server name during migration so an existing deployment is not
overwritten:

```bash
hermes mcp add camera-new \
  --url "https://{{SERVER_FQDN}}/mcp" \
  --auth oauth \
  --connect-timeout 30
```

The first connection can fail before the private CA path is configured. Save
the entry if prompted. Edit `~/.hermes/config.yaml`, set the new entry to
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

Preserve unrelated server entries. Never display files under
`~/.hermes/mcp-tokens/`.

## 17. User Confirmation

Prompt the user to follow these instructions, then quit. Do not wait for the user to verify, they will contact you if anything is needed.

Get user password:

```bash
sudo cat /opt/keycloak/mcp-user.pass
```

Start login:

```bash
hermes mcp login camera-new
```

Log in as the MCP login user and approve consent for `mcp:tools`. Then test
saved OAuth state:

```bash
hermes mcp test camera-new
```

Success means Hermes reconnects without another browser login and discovers
the expected MCP tools.

This concludes this portion of the configuration.

