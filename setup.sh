#!/usr/bin/env bash
#
# setup.sh — personal workspace bootstrap.
#
# Run on a fresh Mac or Linux to install developer tools, deploy SSH
# keys and credentials from Proton Pass, lay down the workspace
# manifest, and populate ~/workspace/ with project repos.
#
# Prerequisite: Proton Pass desktop app installed and signed in.
#
# Re-running is safe — existing state is detected and only what is
# missing or out of date is changed.
#
# Two invocation modes (both supported automatically):
#
#   1. One-liner (curl-piped, no git or CLT required upfront):
#        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/master/setup.sh)"
#      The script runs from stdin (never written to disk), installs
#      Command Line Tools (which provide git) on a fresh Mac, then
#      `git clone`s sakaal/setup into ~/workspace/setup so the canonical
#      install is always a git working copy. SETUP_REF=<tag> selects
#      the ref (default: master).
#
#   2. From a local git working copy (e.g. a dev clone):
#        cd <wherever> && ./setup.sh
#      Auto-relocates to ~/workspace/setup if not already there,
#      preserving the .git directory and any uncommitted changes.

set -uo pipefail

# ── Logging helpers ────────────────────────────────────────────────

err()  { printf '%s\n' "$*" >&2; }
info() { printf '  \xe2\x86\x92 %s\n' "$*"; }
ok()   { printf '  \xe2\x9c\x93 %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() { printf '  \xe2\x9c\x97 %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
setup.sh — personal workspace bootstrap.

Installs developer tools, deploys SSH keys and credentials from Proton
Pass, clones the workspace manifest, and populates ~/workspace/ with
project repos.

Prerequisite: Proton Pass desktop app installed and signed in.

Invocation modes:
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/master/setup.sh)"
                     One-liner; script runs from stdin, then git-clones
                     sakaal/setup into ~/workspace/setup
  ./setup.sh         From a local git working copy — auto-relocates to
                     ~/workspace/setup if not already there

Flags:
  --upgrade   Upgrade installed tools to their latest versions
  --dry-run   Print what would be done; make no changes
  --help      Show this help

Environment variables:
  SETUP_REF   Git ref to clone when self-bootstrapping (default: master)
EOF
}

# Show help from any invocation, before any side effects.
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
  esac
done

# ── Build-tools install (platform-gated) ──────────────────────────
#
# Ensures the platform's equivalent of "build tools + git" is present.
# Used during self-bootstrap (to make `git` available for the initial
# clone) and in the main flow (idempotent if already present).

detect_linux_distro_family() {
  [[ -r /etc/os-release ]] || { echo unknown; return; }
  ( . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
      *debian*|*ubuntu*)                          echo debian ;;
      *fedora*|*rhel*|*centos*|*rocky*|*alma*)    echo rhel ;;
      *arch*|*manjaro*)                           echo arch ;;
      *)                                          echo unknown ;;
    esac
  )
}

ensure_build_tools() {
  case "$(uname -s)" in
    Darwin)
      xcode-select -p >/dev/null 2>&1 && return 0
      info "Installing Command Line Tools (will prompt for sudo)..."
      sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
      local PROD
      PROD="$(softwareupdate -l 2>/dev/null \
              | grep "Command Line Tools" \
              | sort -V | tail -1 \
              | awk -F'*' '{print $2}' \
              | sed 's/^ *//')"
      [[ -n "$PROD" ]] || fail "Could not determine CLT update name from softwareupdate -l"
      sudo softwareupdate --install "$PROD" --verbose
      sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
      ok "Command Line Tools installed"
      ;;
    Linux)
      command -v git >/dev/null 2>&1 && return 0
      info "Installing git via distro package manager (will prompt for sudo)..."
      case "$(detect_linux_distro_family)" in
        debian) sudo apt-get update -qq && sudo apt-get install -y git ;;
        rhel)   sudo dnf install -y git ;;
        arch)   sudo pacman -S --noconfirm git ;;
        *)      fail "Linux distro not recognized. Install git manually and re-run." ;;
      esac
      ok "git installed"
      ;;
    *)
      fail "Unsupported platform: $(uname -s)"
      ;;
  esac
}

# ── Locate-and-relocate ───────────────────────────────────────────
#
# Three cases (all converge on $CANONICAL as a git working copy):
#
#   (1) Already at $CANONICAL — cd and continue.
#   (2) Local git working copy elsewhere — cp -R + mv (preserves .git
#       and any uncommitted changes), exec from canonical.
#   (3) Standalone (curl-piped, or local non-git copy, or non-existent
#       canonical) — install CLT for git, `git clone` sakaal/setup into
#       canonical, exec from there.
#
# This script may be running from stdin (no script file on disk) when
# curl-piped, which is exactly why we git-clone INTO the empty canonical
# directory rather than first writing this file there.

CANONICAL="$HOME/workspace/setup"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"

IS_LOCAL_GIT=false
if [[ -n "$SCRIPT_DIR" \
      && -f "$SCRIPT_DIR/setup.yaml" \
      && -f "$SCRIPT_DIR/hosts.yaml" \
      && -d "$SCRIPT_DIR/.git" ]]; then
  IS_LOCAL_GIT=true
fi

if [[ "$IS_LOCAL_GIT" == "true" && "$SCRIPT_DIR" == "$CANONICAL" ]]; then
  # Case 1: already at canonical.
  cd "$CANONICAL"

elif [[ "$IS_LOCAL_GIT" == "true" ]]; then
  # Case 2: local git working copy at a non-canonical location.
  if [[ -e "$CANONICAL" ]]; then
    fail "Setup is canonically at $CANONICAL, but you ran $SCRIPT_DIR/setup.sh.
    Either run $CANONICAL/setup.sh directly, or remove $CANONICAL first to relocate this clone."
  fi
  info "Relocating local git working copy to $CANONICAL (preserves uncommitted changes)"
  mkdir -p "$HOME/workspace"
  TMP="$(mktemp -d)"
  cp -R "$SCRIPT_DIR/." "$TMP/"
  mv "$TMP" "$CANONICAL"
  info "Re-executing from $CANONICAL/setup.sh"
  exec bash "$CANONICAL/setup.sh" "$@"

else
  # Case 3: standalone (curl-piped or non-git local copy). Self-bootstrap
  # by `git clone`-ing sakaal/setup into the canonical location.
  if [[ -e "$CANONICAL" ]]; then
    info "Canonical $CANONICAL already exists — re-executing from there"
    exec bash "$CANONICAL/setup.sh" "$@"
  fi

  REF="${SETUP_REF:-master}"
  ensure_build_tools
  command -v git >/dev/null 2>&1 || fail "git not available; cannot self-bootstrap"

  info "Cloning sakaal/setup into $CANONICAL (ref: $REF)..."
  mkdir -p "$HOME/workspace"
  git clone --branch "$REF" https://github.com/sakaal/setup.git "$CANONICAL"
  info "Re-executing from $CANONICAL/setup.sh"
  exec bash "$CANONICAL/setup.sh" "$@"
fi

# ── Flag parsing (we are at $CANONICAL by this point) ─────────────

UPGRADE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade) UPGRADE=true ;;
    --dry-run) DRY_RUN=true ;;
    --help|-h) usage; exit 0 ;;   # already handled above; defensive
    *)
      err "Unknown argument: $1"
      err "Run with --help for usage."
      exit 1
      ;;
  esac
  shift
done

# Run a command unless --dry-run; for dry-run, log what would happen.
run() {
  if $DRY_RUN; then
    info "(dry-run) Would: $*"
  else
    "$@"
  fi
}

# ── Platform detection ────────────────────────────────────────────

case "$(uname -s)" in
  Darwin) PLATFORM=mac ;;
  Linux)  PLATFORM=linux ;;
  *)      fail "Unsupported platform: $(uname -s)" ;;
esac
ok "Platform: $PLATFORM"

# ── Build tools (idempotent — may have run during bootstrap) ──────

case "$PLATFORM" in
  mac)
    if xcode-select -p >/dev/null 2>&1; then
      ok "Command Line Tools present"
    else
      ensure_build_tools
    fi
    ;;
  linux)
    if command -v git >/dev/null 2>&1; then
      ok "git present"
    else
      ensure_build_tools
    fi
    ;;
esac

# ── Package manager (Homebrew on macOS) ───────────────────────────

ensure_brew_on_path() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
}

case "$PLATFORM" in
  mac)
    if command -v brew >/dev/null 2>&1; then
      ok "Homebrew present"
    else
      info "Installing Homebrew..."
      run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      ensure_brew_on_path
      command -v brew >/dev/null 2>&1 || fail "Homebrew not on PATH after install"
      ok "Homebrew installed"
    fi
    ensure_brew_on_path
    ;;
  linux)
    # Linux: package-manager bootstrap. Open question — Homebrew on
    # Linux (uniform with macOS) or distro-native (apt/dnf/pacman).
    # Not yet implemented.
    fail "Linux package-manager bootstrap: not yet implemented (macOS-only at this time)."
    ;;
esac

# ── Tools via Homebrew ────────────────────────────────────────────
#
# install_brew_tool BINARY [FORMULA]
#   BINARY  — name of the executable on PATH
#   FORMULA — Homebrew formula (defaults to BINARY); use tap/formula form
#             for tapped formulas (e.g. protonpass/tap/pass-cli)

install_brew_tool() {
  local bin="$1"
  local formula="${2:-$1}"
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin present"
    if $UPGRADE; then
      info "Upgrading $bin..."
      run brew upgrade "$formula" || warn "$bin: brew upgrade failed (continuing)"
    fi
  else
    info "Installing $bin..."
    if run brew install "$formula"; then
      ok "$bin installed"
    else
      warn "$bin: brew install failed (continuing)"
    fi
  fi
}

install_brew_tool git
install_brew_tool ansible
install_brew_tool gh
install_brew_tool pass-cli protonpass/tap/pass-cli

# ── Proton Pass authentication ────────────────────────────────────

if pass-cli vault list --output json >/dev/null 2>&1; then
  ok "Proton Pass session active"
else
  info "Logging in to Proton Pass (interactive)..."
  if ! $DRY_RUN; then
    pass-cli login || fail "pass-cli login failed"
  fi
  ok "Logged in to Proton Pass"
fi

# ── Hand off to Ansible ───────────────────────────────────────────

info "Running setup playbook..."
ANSIBLE_ARGS=(-i hosts.yaml setup.yaml)
if $DRY_RUN; then
  ANSIBLE_ARGS+=(--check)
fi
if ! ansible-playbook "${ANSIBLE_ARGS[@]}"; then
  fail "ansible-playbook failed; setup.sh halted before completing"
fi

ok "setup.sh complete"
