#!/usr/bin/env bash
set -euo pipefail

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
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
sudo rm -rf /opt/nvim-linux-x86_64
sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz
cat >>~/.bashrc <<'EOF'

export PATH="$PATH:/opt/nvim-linux-x86_64/bin"
export SUDO_EDITOR="nvim"

EOF
source ~/.bashrc
git clone https://github.com/LazyVim/starter ~/.config/nvim
rm -rf ~/.config/nvim.git
rm nvim-linux-x86_64.tar.gz
cat >>~/.config/nvim/init.lua <<'EOF'

vim.opt.autoread = true

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
  pattern = "*",
  command = "if mode() != 'c' | checktime | endif",
})

EOF
cat >>~/.config/nvim/lua/plugins/icons.lua <<'EOF'

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
echo The scipt has completed, press enter to exit the terminal
read </dev/tty
