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

Please note that if your default browser is something other than Chrome, you will need to install the certificate manually to that browser in order for the camera MCP server to be able to login. The MCP server authentication is routed through the default browser.

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

#### 1. Install libnss
```
sudo apt install libnss3-tools
```

#### 2. Create the database directory (if it doesn't exist)
```
mkdir -p "$HOME/.pki/nssdb"
chmod 700 "$HOME/.pki/nssdb"
```

#### 3. Initialize a clean NSS database (press Enter twice to leave the password blank)
```
certutil -d "sql:$HOME/.pki/nssdb" -N
```

#### 4. Import the certificate
```
certutil -d "sql:$HOME/.pki/nssdb" -A -t "CP,CP," -n "Camera CA Certificate" -i /usr/local/ca-certificates/camera-system-root-ca.crt.pem
```

### Alternate manual certificate configuration

Three-dot-button upper right corner

Settings -> Privacy and Security -> Security -> Advanced Import Certificates -> Custom Installed by you [Import] -> /usr/local/share/ca-certificates -> camera-system-root-ca.crt.pem

## Mac OS

### Install Chrome browser

```
https://www.google.com/chrome
```

### Install the CA Certificate

* Open Spotlight by pressing Command + Space, type Keychain Access, and press Return.

* Select the System keychain in the left-hand sidebar.

* Drag and drop your certificate file (.pem) directly into the Keychain Access window.

* Enter your Mac’s administrator username and password when prompted to authorize the addition.

### Trust the Certificate

* Find and highlight your newly added certificate in the list.

* Double-click the certificate to open its details window.

* Click the triangle next to Trust to expand the trust policy menu.

* Change Secure Sockets Layer (SSL) (or When using this certificate) to Always Trust.

* Close the window and enter your administrator password again to confirm and save the changes.

## Windows

### Install Hermes

```powershell
iex (irm https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1)
```

### Install the ceritificate

```powershell
curl -O http://{{SERVER_FQDN}}/ca/camera-system-root-ca.crt.pem 
openssl x509 -outform der -in camera-system-root-ca.crt.pem -out camera-system-root-ca.crt
```

* ### If you don't have openssl installed:

  ```powershell
  winget install ShiningLight.OpenSSL.Light

  $opensslBin = "C:\Program Files\OpenSSL-Win64\bin"
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")

  if (($userPath -split ";") -notcontains $opensslBin) {
      [Environment]::SetEnvironmentVariable(
          "Path",
          ($userPath.TrimEnd(";") + ";" + $opensslBin),
          "User"
      )
  }
  ```

#### Open the Certificate Manager
Press Windows + R, type:

```
certmgr.msc
```

#### Access the Trusted Root Store

In the left pane, expand Trusted Root Certification Authorities.

#### Import the Certificate

* Right-click Certificates under Trusted Root Certification Authorities.

* Select All Tasks > Import.

* Follow the Certificate Import Wizard:

* Click Next.

* Choose Browse local files and select your .crt or .cer file.

* Click Next.

* Ensure Place all certificates in the following store is set to Trusted Root Certification Authorities.

* Click Next, then Finish.

#### Verify Installation

* In the MMC, expand Trusted Root Certification Authorities.

* Your new CA certificate should now appear in the list. You can right-click it to view details or remove it if needed.

#### Restart if Needed

* Some applications may require a restart to recognize the new trusted CA.

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

