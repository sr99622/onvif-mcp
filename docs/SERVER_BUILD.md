
<h2>Update System and Enable Remote Access</h2>

After installing Ubuntu, update the system and install SSH so you can remote into the machine.

```
sudo apt update
sudo apt upgrade
sudo apt install openssh-server -y
sudo systemctl enable --now ssh
```

<h2>Install git</h2>

We will need git for next steps, so install and configure.

```
sudo apt install git
git config --global core.editor "nvim"
git config --global user.email <your email>
git config --global user.name <your name>
```

<h2>Github CLI</h2>

Integrate github to the desktop, first set up archive 

```
sudo mkdir -p -m 755 /etc/apt/keyrings && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
```

create installation artifacts

```
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
```

install and login 

```
sudo apt update && sudo apt install gh -y
gh auth login
```

<h2>Install LazyVim Editing Tool</h2>

You can run the rest of the configuration from remote. We want to install an editor that will work from the remote terminal. We will be installing LazyVim. The first step is to install the latest version of neovim.

```
sudo apt install curl
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
sudo rm -rf /opt/nvim-linux-x86_64
sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz
```

We need to add the nvim directory to the PATH, and conifgure sudoedit so we can use this for elevated privilege files. Open the .bashrc

```
vi .bashrc
```

And add the environment variables

```
export PATH="$PATH:/opt/nvim-linux-x86_64/bin"
export SUDO_EDITOR="nvim"
```

And now activate the environment

```
source ~/.bashrc
```

LazyVim uses development tools to configure itself, so add these with the build-essential package. It also will need ripgrep.

```
sudo apt install build-essential
sudo apt install ripgrep
```

LazyVim needs a font package, JetBrains is widely used.

#### On MacOS, 

```
brew install --cask font-jetbrains-mono-nerd-font
```

Then open terminal, go to Terminal → Settings → Profiles → Text → Font → Change

Select:

JetBrainsMono Nerd Font Mono

Quit terminal and reopen to get the font.

#### On Ubuntu

```
wget -P ~/.local/share/fonts https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/JetBrainsMono.zip && cd ~/.local/share/fonts && unzip JetBrainsMono.zip && rm JetBrainsMono.zip
cd
```

Register the font in the cache 

* ### Check the exit code to make it completed succesfully, you may need to run this twice. For some reason it often fails on the first run. 

```
fc-cache -f -v 
```

Close and re-open the terminal then select Preferences from the hamburger icon in the upper right corner. Scroll down a bit and unselect 'Use Sytem Font', then use the menu to select the 'JetBrainsMono Nerd Font Mono' type of your choice.

#### Install LazyVim

Here we install the LazyVim package. The git configuration is removed in case you want to archive your own conifguration on git somewhere.

```
git clone https://github.com/LazyVim/starter ~/.config/nvim
rm -rf ~/.config/nvim.git
nvim
```

LazyVim will configure itself on the first nvim run.

Access system clipboard

```
sudo apt install wl-clipboard xclip xsel
```

Auto Refresh

If you are using agents to modify code, it helps to have nvim auto refresh to stay in sync. Add this to the init.lua in the nvim configuration. First open the configuration file

```
nvim .config/nvim/init.lua
```

Insert the following text into the file.

```
vim.opt.autoread = true

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
  pattern = "*",
  command = "if mode() != 'c' | checktime | endif",
})
```

<h2>Install tmux</h2>

tmux lets you split the screen into different prompts. This makes it super easy to run multiple prompts from the remote terminal.

```
sudo apt install tmux
```

The default tmux bindings can be awkword, so we customize.

```
nvim .tmux.conf
```

Add the follwing into the configuration file

```
unbind C-b
set-option -g prefix C-a
bind-key C-a send-prefix
bind | split-window -h
bind - split-window -v
unbind '"'
unbind %
bind-key X kill-pane
```

Now, to split a screen horizontally, Ctl+a |, vertically, Ctl+a -

<h2>Install uv</h2>

This will be needed for the camera MCP server.

```
curl -LsSf https://astral.sh/uv/install.sh | sh
source .bashrc
uv
```


<h2>Install onvif-tui and validate cameras</h2>

```
uv tool install onvif-tui
onvif-tui -u admin -p admin123
```

<h2>Download onvif-mcp repository</h2>

```
git clone https://github.com/sr99622/onvif-mcp
```

<h2>Install VS Code</h2>

```
https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64
```

<h2>Install Hermes</h2>

```
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

Use the minimal configuration and add the LLM model of your choice.

Edit the .hermes/config.yaml to set up the camera MCP stdio, replacing the values in {{ }} double curly braces to fit your own configuration. 

The STREAM_SERVER_URL should be something like `<hostname>.home.arpa`, where .arpa is the reserved DNS domain name for internal servers. If you have a DNS sever on the local network, you can add this hostname and static IP to the DNS address mappings. If not, just add the name to your /etc/hosts file for now. At a later stage in the configuration, the DNS server issue will become more prominent, and you can add the DNS serving capability to the machine for use by other machines on the local network for local name resolution. Depending on your network topology, it may be preferable to use hosts files on client computers rather than local DNS resolution. This topic will be explored in detail later.

```
mcp_servers:
  camera:
    command: uv
    args:
    - --directory
    - {{HOME}}/onvif-mcp/packages/stdio/src
    - run
    - camera.py
    enabled: true
    env:
      CAMERA_USERNAME: {{USERNAME}}
      CAMERA_PASSWORD: {{PASSWORD}}
      STREAM_SERVER_URL: {{SERVER_FQDN}}
```

You can test the camera MCP using the prompt

```
use the camera MCP server to get its version
```

It should reply with both the MCP version and the libonvif version.

<h2>Give Hermes sudo privilege</h2>

from inside the onvif-mcp repository,

```
sudo env USER="$USER" onvif-mcp/docs/scripts/enable-nopasswd.sh
```

<h2>Set a static IP</h2>

use these commands in the Hermes prompt to tell it what to do.

```
please show the ethernet port configuration on this machine, including Gateway and DNS information
```

You will get back a listing of the ports. Pick out the one that is currently connected to your LAN and note the interface name, it will be something like `enp86s0` but will vary. Tell Hermes to configure that specific port to have a static IP address that you have chosen based on your network topology, and to use the current Gateway and DNS settings. This will work best if you explicitly state the Gateway and DNS values.

```
set a static IP address on <adapter name> to be <static IP>, Gateway <existing gateway>, DNS <existing DNS>
```

Reboot the machine to verify that settings are correct and survive reboot.