#!/usr/bin/env bash
#
# bootstrap.sh — reproduce my dev environment on a fresh Linux distro.
#
# What it does (idempotent — safe to re-run):
#   1. Detects the distro's package manager (apt / dnf / pacman)
#   2. Installs system packages (compilers, clipboard, ripgrep/fd, build deps...)
#   3. Builds Neovim from source (latest stable tag)
#   4. Installs tools not in distro repos: lazygit, uv, Rust (rustup), pynvim, starship
#   5. Installs JetBrainsMono Nerd Font + Kitty terminal
#   6. Sets git identity (name/email) if unset
#   7. Clones + checks out dotfiles (bare repo), adds GitLab remote
#   8. Prints manual next-steps (SSH keys, gh/glab auth — NOT scripted: secrets)
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
# 2. System packages
# ─────────────────────────────────────────────────────────────────────────────
log "Updating package lists..."
pm_update

log "Installing system packages..."
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
      kitty \
      nodejs npm
    # Debian/Ubuntu install fd as 'fdfind'; telescope/configs expect 'fd'.
    if have fdfind && ! have fd; then
      mkdir -p "$HOME/.local/bin"
      ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
      ok "Symlinked fdfind -> fd in ~/.local/bin"
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
      kitty \
      nodejs npm
    ;;
  pacman)
    # On Arch: 'clang' includes clangd + clang-format (no separate packages).
    # 'python' includes venv in stdlib (no python-virtualenv needed).
    # 'fd' is named 'fd' (no fdfind symlink needed, unlike Debian).
    pm_install \
      base-devel cmake gettext ninja \
      git curl unzip \
      clang \
      python \
      jdk-openjdk \
      ripgrep fd \
      xclip wl-clipboard \
      bear \
      kitty \
      nodejs npm
    ;;
esac
ok "System packages installed."

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
    ok "${NERD_FONT} Nerd Font installed. (Kitty picks it up from kitty.conf in your dotfiles.)"
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
    dotfiles remote add gitlab "$DOTFILES_REPO_GITLAB" 2>/dev/null || true

    ok "Dotfiles checked out."
  else
    err "Dotfiles clone failed. Likely no SSH key on this machine yet."
    warn "Set up SSH (see next steps), then re-run this script — it'll pick up here."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. Manual next-steps (secrets — deliberately NOT scripted)
# ─────────────────────────────────────────────────────────────────────────────
cat <<'NEXTSTEPS'

────────────────────────────────────────────────────────────
  BOOTSTRAP COMPLETE — manual steps remain (these are secrets,
  intentionally not automated):
────────────────────────────────────────────────────────────

  1. SSH KEY (needed for dotfiles push/pull over SSH):
       ssh-keygen -t ed25519 -C "your.email@example.com"
       cat ~/.ssh/id_ed25519.pub
     Add that public key to:
       • GitHub → Settings → SSH and GPG keys
       • GitLab → Preferences → SSH Keys
     Test:
       ssh -T git@github.com
       ssh -T git@gitlab.com

  2. If dotfiles didn't clone (no SSH key earlier), re-run THIS script
     after step 1 — it will clone now.

  3. TERMINAL: Kitty is installed and reads its config from
     ~/.config/kitty/kitty.conf (in your dotfiles) — font and theme are
     already set there, nothing to configure. Just launch Kitty.
     (If the distro's default terminal opens instead, set Kitty as default
     in Settings -> Default Applications, or just launch `kitty`.)

  4. OPTIONAL CLI auth (only if you use gh/glab API features):
       gh auth login        # choose SSH
       glab auth login

  5. NEOVIM: launch `nvim` once — vim.pack downloads plugins,
     Mason installs LSPs. Wait for it to finish, then restart.

  6. Reload your shell so new tools (uv, etc.) are on PATH:
       source ~/.bashrc

────────────────────────────────────────────────────────────

NEXTSTEPS

ok "Done. Welcome to your new environment."
