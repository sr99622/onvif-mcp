
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
git config --global core.editor "vi"
git config --global user.email "sr99622@gmail.com"
git config --global user.name "Stephen Rhodes"
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

```
wget -P ~/.local/share/fonts https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/JetBrainsMono.zip && cd ~/.local/share/fonts && unzip JetBrainsMono.zip && rm JetBrainsMono.zip && fc-cache -fv
```

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

If you are using agents to modify code, it helps to have nvim auto refresh to stay in sync. Add this to the init.lua in the nvim configuration

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
exit
uv
```

<h2>Install pipx</h2>

```
sudo apt install pipx
pipx ensurepath
```

<h2>Install onvif-tui and validate cameras</h2>

```
pipx install onvif-tui
onvif-tui -u admin -p admin123
```

<h2>Install Hermes</h2>

```
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

Use the minimal configuration and add the LLM model of your choice.

<h2>Give Hermes sudo privilege</h2>

```
nvim $HOME/.hermes/.env
```

Add this line to the file

```
SUDO_PASSWORD=<your_sudo_password>
```

<h2>Set a static IP</h2>

use these commands in the Hermes prompt to tell it what to do.

```
please show the ethernet port configuration on this machine 
```

You will get back a listing of the ports. Pick out the one that is currently connected to your LAN and note the interface name, it will be something like `enp86s0` but will vary. Tell Hermes to configure that specific port to have a static IP address that you have chosen based on your network topology, and to use the current Gateway and DNS settings. This will work best if you explicitly state the Gateway and DNS values.

<h2>Assign a host name to the computer</h2>

The name should have the format `<your_server_name>.home.arpa` which uses the reserved `arpa` domain for resolution on the local network only.

If you have a DNS sever on the local network, you can add this hostname and static IP to the DNS address mappings. If not, just add the name to your /etc/hosts file for now. At a later stage in the configuration, the DNS server issue will become more prominent, and you can add the DNS serving capability to the machine for use by other machines on the local network for local name resolution. Depending on your network topology, it may be preferable to use hosts files on client computers rather than local DNS resolution. This topic will be explored in detail later.