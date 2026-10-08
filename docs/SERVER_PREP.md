# Server Preparation

This is a suggested configuration for the server. The best way to build this system is to start with a fresh Ubuntu 26.04 installation on a dedicated machine. After installation of the Operating System, you will be prompted to update to get the latest versions of tools, which may require a reboot.

The camera system requires a static IP address on the LAN. You may need to consult your router settings to know what the range of acceptable static IP addresses is available on your LAN. These will usually be at the bottom and top of the range of the last dot number of the IP address between 0 and 255. The x.x.x.1 address is usually reserved for the router. The script that sets the static IP address will preserve the settings from the default address assigned by your router when the system is first started, so the only thing you need to provide is the static IP. If you run the command `ip a` or `nmcli dev show` you should be able to identify the current IP address. When prompted to enter the static IP address, you re-use the first three dot numbers of the existing default address and change only the last number. If you are unsure what to use for the last dot number, .4 is a good guess. The script will prompt you for the address when it runs.

The scripts below configure the server in preparation for the installation of the camera system. The scripts are broken up into two parts because it is necessary to re-start the terminal to install the font library needed for LazyVim. The scripts perform these functions needed for proper operation of the camera system

* Essential dependencies needed for Hermes and LazyVim
* SSH server for remote access, enabled and started
* Clone the github repository that includes code that will be installed as part of the camera system
* Enable passwordless sudo so that Hermes agent has proper access to root functions needed
* Set a static IP address on the machine
* Install the uv python management system
* Download Nerd Fonts for LazyVim
* Refresh the font cache, which may require a second attempt for successful completion
* The terminal will exit to install the Nerd Fonts, continue with the second part of the script in a new terminal
* The second part of the script installs LazyVim and Hermes
* Hermes requires a model that it can run, you can use you ChatGPT, Claude, Local or other model

**NOTE**: The document assumes that all commands are run from the $HOME directory.

##  Part 1. Install dependencies and set static IP

This script will exit the terminal when done. Re-open the terminal and run the second part.

```
sudo apt install git curl tar xz-utils build-essential ripgrep wl-clipboard xclip xsel openssh-server -y
sudo systemctl enable --now ssh
git clone https://github.com/sr99622/onvif-mcp
sudo env USER="$USER" onvif-mcp/scripts/enable-nopasswd.sh
sudo onvif-mcp/scripts/static-ip.sh
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc
uv
wget -P ~/.local/share/fonts https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/JetBrainsMono.zip && cd ~/.local/share/fonts && unzip JetBrainsMono.zip && rm JetBrainsMono.zip
cd
bash -c '
for attempt in 1 2 3; do
    if fc-cache -f -v; then
        printf "Font cache updated successfully.\n"
        exit 0
    fi
    printf "Font cache update failed (attempt %s of 3).\n" "$attempt" >&2
    if [ "$attempt" -lt 3 ]; then
        sleep 2
    fi
done
printf "Font cache update failed after 3 attempts.\n" >&2
exit 1
'
exit
```

## Part 2. Install LazyVim and Hermes

```
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
sudo rm -rf /opt/nvim-linux-x86_64
sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz
cat >> ~/.bashrc <<'EOF'

export PATH="$PATH:/opt/nvim-linux-x86_64/bin"
export SUDO_EDITOR="nvim"

EOF
source ~/.bashrc
git clone https://github.com/LazyVim/starter ~/.config/nvim
rm -rf ~/.config/nvim.git
rm nvim-linux-x86_64.tar.gz
cat >> ~/.config/nvim/init.lua <<'EOF'

vim.opt.autoread = true

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
  pattern = "*",
  command = "if mode() != 'c' | checktime | endif",
})

EOF
cat >> ~/.config/nvim/lua/plugins/icons.lua <<'EOF'

return {
  {
    "nvim-mini/mini.icons",
    opts = {
      extension = {
        toml = { glyph = "", hl = "MiniIconsGrey" },
        lock = { glyph = "", hl = "MiniIconsBlue" },
      },
    },
  },
}
EOF
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

&nbsp;

<details><summary><b>Optional Developer Tools</b></summary>

## (Optional) configure git user

```
git config --global core.editor "nvim"
bash -c '
printf "Configure git with your email address, enter your email address:\n"
read -r git_email </dev/tty
printf "Configure git with your name, enter your full name:\n"
read -r git_name </dev/tty
git config --global user.email "$git_email"
git config --global user.name "$git_name"
'
```

## (Optional) Install VS Code

VS Code can be useful when editing markdown files. Open this link in the browser to download the .deb file installer

```bash
https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64
```

Then run the install, replacing the filename with the actual name in the Downloads folder

```
sudo apt install ./Downloads/code*.deb
```
</details>