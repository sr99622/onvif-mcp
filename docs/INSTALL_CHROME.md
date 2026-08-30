## Fedora

### Install Chrome browser

```bash
sudo dnf install fedora-workstation-repositories
sudo dnf config-manager setopt google-chrome.enabled=1
sudo dnf install google-chrome-stable
```

### Install certificate

```bash
curl -O http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem
sudo mv camera-system-root-ca.crt.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

## Ubuntu

### Install Chrome browser

```bash
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt install ./google-chrome-stable_current_amd64.deb
```

### Install certificate

```bash
curl -O http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem
sudo mv camera-system-root-ca.crt.pem /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

### Configure Chrome to accept certificate

Three-dot-button upper right corner

Settings -> Privacy and Security -> Security -> Advanced Import Certificates -> Custom Installed by you [Import] -> /usr/local/share/ca-certificates -> camera-system-root-ca.crt.pem

## Sign on the cameras web page

### Login to the server

Open the chrome browser and navigate to the cameras page on the server

```http
https://{{SERVER_FQDN}}/cameras
```

You will be presented a login screen. Sign in using the {{MCP_LOGIN_USER}} credentials, which will be the username {{MCP_LOGIN_USER}}, and the password which can be retrieved using the command 

```
ssh -t {{SERVER_USER}}@{{SERVER_FQDN}} 'sudo cat /opt/keycloak/{{MCP_LOGIN_USER}}.pass
```

This will register and save the credentials in the browser, and you should be able to observe the camera streams.

### Configure the MCP server

Edit `~/.hermes/config.yaml` and add the following towards the end of the file above the comments and replace the {{...}} fields with your local values:

```yaml
mcp_servers:
  {{HERMES_SERVER_NAME}}:
    url: https://{{SERVER_FQDN}}/mcp
    ssl_verify: {{CA_CERT_PATH}}
    connect_timeout: 30.0
    auth: oauth
    enabled: true
```

Get you IP address using the command

```bash
nmcli dev show
```

The command will show all of your IP addresses, pick out the one that is used to communicate to the server. Most commonly, only one interface will have an address. Attempt a login which will fail. This creates an entry on the server side that can be used to verify the IP address you are using.

```bash
hermes mcp login {{HERMES_SERVER_NAME}}
```

The command will fail with a 403 error. From the server, start hermes and prompt

```prompt
execute /home/{{SERVER_USER}}/onvif-mcp/docs/ADD_CLIENT_ON_SERVER.md using {{CLIENT_SOURCE_IP}} <ip-address>
```

This will register your IP address with the server to allow access. You should see confirmation that the IP address attempted to access.

Run the login command again, this time it should launch a browser that you have already used to login to the cameras web page and ask you to allow Hermes agent to authenticate to which you should reply yes.

```bash
hermes mcp login {{HERMES_SERVER_NAME}}
```

You can get the list of available tools from the server

```bash
hermes mcp test {{HERMES_SERVER_NAME}}
```

Keep this command handy, you may need it to login to the server when you start a new hermes session.

## Configure the browser CLI

```bash
hermes tools enable browser --platform cli
hermes config set browser.cdp_url http://127.0.0.1:9222
hermes config set browser.allow_private_urls true
```

