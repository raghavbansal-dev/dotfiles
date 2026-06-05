#!/usr/bin/env bash
#
# bootstrap.sh — reproduce my dev environment + i3 rice on a fresh Linux distro.
#
# What it does (idempotent — safe to re-run):
#   1. Detects the distro's package manager (apt / dnf / pacman)
#   2. Installs system dev packages (compilers, clipboard, ssh, gh/glab...)
#   2b. [Arch] Installs the i3 rice: WM, bar, launcher, audio, file managers, VM utils
#   3. Builds Neovim from source (latest stable tag) + verifies vim.pack exists
#   4. Installs tools not in distro repos: lazygit, uv, Rust (rustup), pynvim, starship
#   4b. [Arch] Installs yay (AUR) + Brave
#   4c. [Arch] Installs the Tokyo Night GRUB theme (lives outside $HOME)
#   5. Installs JetBrainsMono Nerd Font
#   6. Sets git identity (name/email) if unset
#   7. Clones + checks out dotfiles (bare repo), adds GitLab remote
#   8. Prints manual next-steps (SSH keys, fstab share, host VM settings — NOT scripted)
#
# Usage:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh
#
# Re-running is safe: each step checks "is this already done?" and skips if so.

set -uo pipefail  # u: error on unset vars, o pipefail: catch errors in pipes
                  # NOT -e: we want to continue past non-fatal failures and report them

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — edit these to match your setup
# ─────────────────────────────────────────────────────────────────────────────
DOTFILES_REPO_SSH="git@github.com:raghavbansal-dev/dotfiles.git"
DOTFILES_REPO_GITLAB="git@gitlab.com:raghavbansal-dev/dotfiles.git"
NERD_FONT="JetBrainsMono"   # font zip name from nerd-fonts releases
NVIM_BRANCH="stable"        # 'stable' for latest release, or 'master' for bleeding edge

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$*"; }
err()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }  # is a command available?

# ─────────────────────────────────────────────────────────────────────────────
# 1. Detect package manager
# ─────────────────────────────────────────────────────────────────────────────
PM=""
if have apt;    then PM="apt";    fi
if have dnf;    then PM="dnf";    fi
if have pacman; then PM="pacman"; fi

if [ -z "$PM" ]; then
  err "No supported package manager found (need apt, dnf, or pacman)."
  exit 1
fi
log "Detected package manager: $PM"

# Wrapper: install packages for the detected PM.
pm_install() {
  case "$PM" in
    apt)
      sudo apt-get install -y "$@"
      ;;
    dnf)
      sudo dnf install -y "$@"
      ;;
    pacman)
      sudo pacman -S --needed --noconfirm "$@"
      ;;
  esac
}

pm_update() {
  case "$PM" in
    apt)    sudo apt-get update ;;
    dnf)    sudo dnf check-update || true ;;  # dnf returns 100 when updates exist
    # Arch: -Sy alone causes partial-upgrade breakage; Arch requires a full -Syu
    # before installing new packages. This does a full system upgrade.
    pacman) sudo pacman -Syu --noconfirm ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. System dev packages
# ─────────────────────────────────────────────────────────────────────────────
log "Updating package lists..."
pm_update

log "Installing system dev packages..."
# Package names differ slightly across distros — handle per-PM.
case "$PM" in
  apt)
    pm_install \
      build-essential cmake gettext ninja-build \
      git curl unzip \
      clang clangd clang-format \
      python3 python3-venv \
      default-jdk \
      ripgrep fd-find \
      xclip wl-clipboard \
      bear \
      konsole \
      nodejs npm \
      openssh-client gh
    # Debian/Ubuntu install fd as 'fdfind'; telescope/configs expect 'fd'.
    if have fdfind && ! have fd; then
      mkdir -p "$HOME/.local/bin"
      ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
      ok "Symlinked fdfind -> fd in ~/.local/bin"
    fi
    # tree-sitter-cli isn't reliably packaged on apt; install via npm if missing.
    if ! have tree-sitter; then
      sudo npm install -g tree-sitter-cli >/dev/null 2>&1 \
        && ok "tree-sitter-cli installed via npm" \
        || warn "tree-sitter-cli install failed (run :TSUpdate may need it)"
    fi
    ;;
  dnf)
    pm_install \
      gcc gcc-c++ make cmake gettext ninja-build \
      git curl unzip \
      clang clang-tools-extra \
      python3 python3-virtualenv \
      java-latest-openjdk-devel \
      ripgrep fd-find \
      xclip wl-clipboard \
      bear \
      konsole \
      nodejs npm \
      openssh gh tree-sitter-cli
    ;;
  pacman)
    # On Arch: 'clang' includes clangd + clang-format (no separate packages).
    # 'python' includes venv in stdlib (no python-virtualenv needed).
    # 'fd' is named 'fd' (no fdfind symlink needed, unlike Debian).
    # 'github-cli' is the gh package name; glab is in extra.
    # (konsole comes from the rice block in 2b below.)
    pm_install \
      base-devel cmake gettext ninja \
      git curl unzip \
      clang \
      python \
      jdk-openjdk \
      ripgrep fd \
      xclip wl-clipboard \
      bear \
      nodejs npm \
      openssh tree-sitter-cli \
      github-cli glab
    ;;
esac
ok "System dev packages installed."

# ─────────────────────────────────────────────────────────────────────────────
# 2b. Desktop / i3 rice packages   (Arch only — the rice is configured for Arch)
# ─────────────────────────────────────────────────────────────────────────────
# Reproduces the i3 desktop the dotfiles configs drive: WM, X server, bar,
# launcher, notifications, wallpaper, PDF viewer, system monitor, the PipeWire
# audio stack, file managers, and VirtualBox guest integration.
# Grouped into separate install calls so one bad package can't abort the rest.
if [ "$PM" = "pacman" ]; then
  log "Installing desktop / i3 rice packages (Arch)..."

  # WM + X server + core rice. xorg-xinit gives startx; xrandr/xprop are used
  # by the resize keybind and window-class lookups; konsole is the terminal.
  pm_install \
    i3-wm i3status i3lock \
    xorg-server xorg-xinit xorg-xrandr xorg-xprop \
    polybar rofi dunst feh \
    zathura zathura-pdf-mupdf \
    btop pacman-contrib wmctrl \
    konsole gnome-themes-extra \
    && ok "WM + X + bar + core rice installed." \
    || warn "Some rice packages failed — check output above."

  # Audio: PipeWire stack. Without pipewire-pulse + wireplumber the polybar
  # VOL module silently shows nothing (pactl has no server to talk to).
  pm_install \
    pipewire pipewire-pulse wireplumber pavucontrol libpulse \
    && ok "PipeWire audio stack installed." \
    || warn "Audio packages failed — VOL module may not work."

  # Enable PipeWire user services. --now may fail during bootstrap if there's
  # no active user session bus yet, so this enables them for next login.
  systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null \
    && ok "PipeWire services enabled (start on next login)." \
    || warn "Couldn't enable PipeWire now — after first login run:
      systemctl --user enable --now pipewire pipewire-pulse wireplumber"

  # File managers: yazi (TUI) + thunar (GUI) + thumbnailers.
  pm_install \
    yazi thunar gvfs tumbler ffmpegthumbnailer \
    && ok "File managers installed." \
    || warn "File manager packages failed."

  # Desktop portals + user dirs. Without the portal backend, Chromium/Brave's
  # download & upload file pickers silently fail on a no-DE setup. xdg-user-dirs
  # creates ~/Downloads, ~/Documents, etc. so downloads have somewhere to go.
  pm_install xdg-desktop-portal xdg-desktop-portal-gtk xdg-user-dirs \
    && ok "Portals + user dirs installed." \
    || warn "Portal/user-dirs packages failed (Brave downloads may fail)."
  command -v xdg-user-dirs-update >/dev/null 2>&1 && xdg-user-dirs-update

  # VirtualBox guest integration: shared folders (vboxsf), clipboard, resize.
  pm_install virtualbox-guest-utils \
    && ok "VirtualBox guest utils installed." \
    || warn "virtualbox-guest-utils failed."
  sudo systemctl enable --now vboxservice 2>/dev/null \
    && ok "vboxservice enabled (resize + shared clipboard)." \
    || warn "Couldn't enable vboxservice (fine if not in a VM)."

  # Add user to vboxsf so shared folders (e.g. notes-share) are accessible.
  # Takes effect on next LOGIN, not in this shell.
  if getent group vboxsf >/dev/null 2>&1 && ! id -nG "$USER" | grep -qw vboxsf; then
    sudo usermod -aG vboxsf "$USER" \
      && ok "Added $USER to vboxsf group (re-login required)." \
      || warn "Couldn't add to vboxsf group."
  fi
else
  warn "Non-Arch system: skipping i3 rice (rice packages are Arch-only)."
  warn "Dev toolchain still installs; set up your desktop manually."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Neovim from source
# ─────────────────────────────────────────────────────────────────────────────
if have nvim; then
  ok "Neovim already installed ($(nvim --version | head -1)). Skipping build."
else
  log "Building Neovim from source (branch: $NVIM_BRANCH)..."
  NVIM_SRC="$HOME/.local/src/neovim"
  mkdir -p "$(dirname "$NVIM_SRC")"
  if [ -d "$NVIM_SRC/.git" ]; then
    git -C "$NVIM_SRC" fetch --tags origin
  else
    git clone https://github.com/neovim/neovim.git "$NVIM_SRC"
  fi
  (
    cd "$NVIM_SRC" || exit 1
    git checkout "$NVIM_BRANCH"
    make distclean
    make CMAKE_BUILD_TYPE=Release
    sudo make install
  ) && ok "Neovim built and installed." || err "Neovim build failed — check output above."
fi

# Verify the built nvim actually has vim.pack (your plugin manager).
# vim.pack is a built-in added in Neovim 0.12 — older 'stable' tags lack it,
# which would silently break your entire plugin config on first launch.
# Run with -u NONE so your config doesn't load (clean capability test).
if have nvim; then
  if nvim --headless -u NONE -c 'lua os.exit(vim.pack and 0 or 1)' 2>/dev/null; then
    ok "Neovim has vim.pack (your config will load) ✓"
  else
    warn "This Neovim build LACKS vim.pack — your config needs Neovim 0.12+."
    warn "Plugins will NOT load. Rebuild from a newer tag/master:"
    warn "  rm \"\$(command -v nvim)\" && NVIM_BRANCH=master ./bootstrap.sh"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Tools not in distro repos
# ─────────────────────────────────────────────────────────────────────────────

# --- lazygit ---
if have lazygit; then
  ok "lazygit already installed. Skipping."
else
  log "Installing lazygit..."
  LG_VER=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" \
            | grep -Po '"tag_name": "v\K[^"]*')
  if [ -n "$LG_VER" ]; then
    TMP=$(mktemp -d)
    curl -Lo "$TMP/lg.tar.gz" \
      "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LG_VER}_Linux_x86_64.tar.gz"
    tar -xf "$TMP/lg.tar.gz" -C "$TMP" lazygit
    sudo install "$TMP/lazygit" /usr/local/bin
    rm -rf "$TMP"
    ok "lazygit $LG_VER installed."
  else
    err "Couldn't fetch lazygit version. Skipping."
  fi
fi

# --- uv ---
if have uv; then
  ok "uv already installed. Skipping."
else
  log "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh \
    && ok "uv installed (restart shell or source env to use)." \
    || err "uv install failed."
fi

# --- Rust (rustup) ---
# Your blink.cmp uses fuzzy = 'prefer_rust'. It fetches a PREBUILT binary so
# rustup isn't strictly required, but having the toolchain guarantees the rust
# matcher (and any future rust-based plugins/tools) always work.
if have cargo; then
  ok "Rust (cargo) already installed. Skipping."
else
  log "Installing Rust via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && ok "Rust installed (restart shell or source ~/.cargo/env to use)." \
    || err "Rust install failed."
fi

# --- pynvim (Neovim's Python provider, via uv tool) ---
# Lets Neovim run Python-based plugins/remote-plugins. Most of your plugins are
# Lua so this is optional, but cheap to include for completeness.
if have uv; then
  if uv tool list 2>/dev/null | grep -q pynvim; then
    ok "pynvim already installed (uv tool). Skipping."
  else
    log "Installing pynvim via uv tool..."
    uv tool install pynvim >/dev/null 2>&1 \
      && ok "pynvim installed." \
      || warn "pynvim install failed (non-critical — most plugins are Lua)."
  fi
fi

# --- Starship (prompt) ---
if have starship; then
  ok "Starship already installed. Skipping."
else
  log "Installing Starship prompt..."
  curl -sS https://starship.rs/install.sh | sh -s -- -y \
    && ok "Starship installed." \
    || err "Starship install failed."
fi
# Ensure bash is hooked to starship (idempotent — only adds the line once)
if ! grep -q 'starship init bash' "$HOME/.bashrc" 2>/dev/null; then
  echo 'eval "$(starship init bash)"' >> "$HOME/.bashrc"
  ok "Added starship init to .bashrc"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4b. AUR helper + Brave   (Arch only)
# ─────────────────────────────────────────────────────────────────────────────
# Brave ships via the AUR (brave-bin); installing it needs an AUR helper (yay).
# makepkg must NOT run as root, so this runs as your user (it sudos internally
# only for the final pacman install step).
if [ "$PM" = "pacman" ]; then
  if ! have yay; then
    log "Installing yay (AUR helper)..."
    TMP=$(mktemp -d)
    if git clone https://aur.archlinux.org/yay.git "$TMP/yay" 2>/dev/null; then
      ( cd "$TMP/yay" && makepkg -si --noconfirm ) \
        && ok "yay installed." \
        || err "yay build failed (you can build it manually later)."
    else
      err "Couldn't clone yay from AUR."
    fi
    rm -rf "$TMP"
  else
    ok "yay already installed. Skipping."
  fi

  if have yay; then
    if have brave; then
      ok "Brave already installed. Skipping."
    else
      log "Installing Brave (brave-bin from AUR)..."
      yay -S --needed --noconfirm brave-bin \
        && ok "Brave installed." \
        || warn "Brave install failed (retry: yay -S brave-bin)."
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4c. GRUB theme   (Arch only, GRUB systems only)
# ─────────────────────────────────────────────────────────────────────────────
# The Tokyo Night GRUB theme lives in /boot and /etc — OUTSIDE $HOME, so the
# dotfiles repo cannot track it. This function is the ONLY place it gets
# reproduced. Guard: skip if /boot/grub is absent (e.g. systemd-boot systems),
# so it can never touch a non-GRUB bootloader.
install_grub_theme() {
  [ "$PM" = "pacman" ] || return 0
  [ -d /boot/grub ] || { warn "No /boot/grub (systemd-boot?) — skipping GRUB theme."; return 0; }

  if [ ! -d /boot/grub/themes/tokyo-night ]; then
    log "Installing Tokyo Night GRUB theme..."
    TMP=$(mktemp -d)
    if git clone https://github.com/mino29/tokyo-night-grub.git "$TMP/tng" 2>/dev/null; then
      sudo cp -r "$TMP/tng/tokyo-night" /boot/grub/themes/
    else
      err "Couldn't clone GRUB theme. Skipping."
      rm -rf "$TMP"; return 0
    fi
    rm -rf "$TMP"
  else
    ok "GRUB theme already present. Skipping clone."
  fi

  # Point GRUB at the theme (handles commented, already-set, or absent line).
  if grep -qE '^#?GRUB_THEME=' /etc/default/grub; then
    sudo sed -i 's#^#\?GRUB_THEME=.*#GRUB_THEME="/boot/grub/themes/tokyo-night/theme.txt"#' /etc/default/grub
  else
    echo 'GRUB_THEME="/boot/grub/themes/tokyo-night/theme.txt"' | sudo tee -a /etc/default/grub >/dev/null
  fi

  sudo grub-mkconfig -o /boot/grub/grub.cfg \
    && ok "GRUB theme applied (visible on next boot)." \
    || err "grub-mkconfig failed — check output above."
}
install_grub_theme

# ─────────────────────────────────────────────────────────────────────────────
# 5. Nerd Font
# ─────────────────────────────────────────────────────────────────────────────
FONT_DIR="$HOME/.local/share/fonts"
if fc-list 2>/dev/null | grep -qi "${NERD_FONT}.*Nerd Font"; then
  ok "${NERD_FONT} Nerd Font already installed. Skipping."
else
  log "Installing ${NERD_FONT} Nerd Font..."
  mkdir -p "$FONT_DIR"
  TMP=$(mktemp -d)
  if curl -fLo "$TMP/font.zip" \
      "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${NERD_FONT}.zip"; then
    unzip -o "$TMP/font.zip" -d "$FONT_DIR" >/dev/null
    rm -rf "$TMP"
    fc-cache -f >/dev/null 2>&1
    ok "${NERD_FONT} Nerd Font installed. (Set it as Konsole's profile font.)"
  else
    err "Font download failed. Skipping."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Git identity (needed before any commits work)
# ─────────────────────────────────────────────────────────────────────────────
# Not a secret — safe to set. Only prompts if not already configured.
if [ -z "$(git config --global user.name 2>/dev/null)" ]; then
  warn "Git user.name not set. Set it now (or Ctrl-C and set manually later)."
  read -rp "  Git user.name: " GIT_NAME
  [ -n "$GIT_NAME" ] && git config --global user.name "$GIT_NAME"
fi
if [ -z "$(git config --global user.email 2>/dev/null)" ]; then
  read -rp "  Git user.email: " GIT_EMAIL
  [ -n "$GIT_EMAIL" ] && git config --global user.email "$GIT_EMAIL"
fi
ok "Git identity: $(git config --global user.name) <$(git config --global user.email)>"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Dotfiles (bare repo)
# ─────────────────────────────────────────────────────────────────────────────
DOTGIT="$HOME/.dotfiles"
dotfiles() { /usr/bin/git --git-dir="$DOTGIT" --work-tree="$HOME" "$@"; }

if [ -d "$DOTGIT" ]; then
  ok "Dotfiles repo already present at $DOTGIT. Pulling latest..."
  dotfiles pull origin main 2>/dev/null || warn "Pull failed (SSH key set up yet?). You can pull later."
else
  log "Cloning dotfiles (bare repo)..."
  if git clone --bare "$DOTFILES_REPO_SSH" "$DOTGIT" 2>/dev/null; then
    dotfiles config --local status.showUntrackedFiles no

    # Try checkout; if existing files conflict, back them up and retry.
    if ! dotfiles checkout 2>/dev/null; then
      warn "Checkout conflicts with existing files. Backing them up to ~/.config-backup ..."
      mkdir -p "$HOME/.config-backup"
      dotfiles checkout 2>&1 | grep -E "^\s+\." | awk '{print $1}' | while read -r f; do
        mkdir -p "$HOME/.config-backup/$(dirname "$f")"
        mv "$HOME/$f" "$HOME/.config-backup/$f" 2>/dev/null
      done
      dotfiles checkout
    fi

    # Add the GitLab remote so dotsync can push to both.
    # (Remotes live in local repo config and do NOT travel with a clone —
    #  a fresh clone only gets 'origin', so the gitlab remote must be re-added.)
    dotfiles remote add gitlab "$DOTFILES_REPO_GITLAB" 2>/dev/null || true

    ok "Dotfiles checked out."
  else
    err "Dotfiles clone failed. Likely no SSH key on this machine yet."
    warn "Set up SSH (see next steps), then re-run this script — it'll pick up here."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. Manual next-steps (secrets + boot-risky edits — deliberately NOT scripted)
# ─────────────────────────────────────────────────────────────────────────────
cat <<'NEXTSTEPS'

────────────────────────────────────────────────────────────
  BOOTSTRAP COMPLETE
────────────────────────────────────────────────────────────

  If you set up your SSH key BEFORE running this (recommended),
  your dotfiles are already cloned and you're nearly done:

  1. RELOAD SHELL — open a new terminal (or: source ~/.bashrc)
     so the dotfiles .bashrc (dotfiles alias, dotsync, starship,
     yazi y() function) and new tools (uv, cargo) are on PATH:
       type dotfiles && dotfiles status

  2. NEOVIM — launch `nvim` once:
       • vim.pack downloads plugins (wait for it)
       • :Mason  → confirm LSPs installed
       • :TSInstall markdown markdown_inline  (render-markdown needs these)
       • :TSUpdate  → compile treesitter parsers
       • :qa and reopen, then :checkhealth

  3. TERMINAL — Konsole is installed. Set your Tokyo Night profile as
     default (Konsole → Settings → Manage Profiles → mark as default) if
     it's tracked in your dotfiles (~/.local/share/konsole/, ~/.config/konsolerc).
     Set the profile font to "JetBrainsMono Nerd Font". Starship works in any terminal.

  3b. START THE DESKTOP — verify ~/.xinitrc sources /etc/X11/xinit/xinitrc.d
      (imports DISPLAY into systemd so Brave's download/upload file-picker works)
      and ends with `exec i3`. Then run `startx`. Your dotfiles .xinitrc already
      has both — just confirm it checked out:
      cat ~/.xinitrc
      Workspaces should auto-open: Konsole on 1:CODE, Brave on 2:WEB, btop on 3:SYS,
      and your reference PDF on 4:REF.

  4. PROJECT CODE — clone your repos (NOT in dotfiles):
       mkdir -p ~/Developer
       git clone git@github.com:raghavbansal-dev/cs50.git ~/Developer/cs50

  ── VM (VirtualBox) integration ──
   • RE-LOGIN or reboot so the vboxsf group takes effect (needed for shared folders).
   • notes-share is NOT auto-configured — fstab edits can break boot, so it's manual.
     To mount your NOTES shared folder, add ONE line to /etc/fstab (all on one line!),
     adjusting the share name and uid/gid (check with `id`):
       NOTES /home/<you>/notes-share vboxsf uid=1000,gid=1000,dmode=0755,fmode=0644,nofail 0 0
     Then:
       sudo mkdir -p ~/notes-share && sudo systemctl daemon-reload && sudo mount -a
     Verify it's ONE line and `mount -a` errors nothing before you reboot.
   • HOST-side (cannot be scripted): in VirtualBox →
       Devices → Shared Folders   → add NOTES, Auto-mount OFF (fstab handles it)
       Devices → Shared Clipboard → Bidirectional
       View → Auto-resize Guest Display OFF (stops fractional resolutions / wallpaper tiling)

  ── If the dotfiles clone FAILED above (no SSH key yet) ──
     Set up the key, then re-run this script (it picks up here):
       ssh-keygen -t ed25519 -C "your.email@example.com"
       cat ~/.ssh/id_ed25519.pub     # add to BOTH GitHub + GitLab
       ssh -T git@github.com         # test each separately
       ssh -T git@gitlab.com

  ── Optional CLI auth (gh/glab are installed; auth only if needed) ──
       gh auth login        # choose SSH
       glab auth login

────────────────────────────────────────────────────────────

NEXTSTEPS

ok "Done. Welcome to your new environment."
