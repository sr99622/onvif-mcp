# Server Preparation

This is a suggested configuration for the server. The best way to build this system is to start with a fresh Ubuntu installation on a dedicated machine. Update the system after installation to get the latest versions of tools.

This two-part script installs and enables SSH server, LazyVim and Hermes. 

**NOTE**: The document assumes that all commands are run from the $HOME directory.

##  Part 1. Install dependencies

Run this script, it will exit the terminal when done. Re-open the terminal and run the second part.

```
sudo apt install git curl tar xz-utils build-essential ripgrep wl-clipboard xclip xsel openssh-server -y
sudo systemctl enable --now ssh
git config --global core.editor "nvim"
git clone https://github.com/sr99622/onvif-mcp
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

## (Optional) configure git user

```
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
sudo apt install ./Downloads/<code.....deb>
```

&nbsp;

# Essential Configurations

## Set a static IP

Use the GUI tool in the Settings app. Go to Network and find your Adapter. Assuming that you are on the wired network (you should be), click the gear wheel in the panel, which will pop up a dialog. **Remove Connection Profile...** to get rid of the default DHCP setting. After removing the profile, Click the '+' for Wired to get a new profile. Click the IPv4 tab to get the settings tab and Select the Manual radio button. Set your Address, Netmask, Gateway and DNS, the click Apply. Reboot to make sure the settings took hold, do not take anything on faith.

