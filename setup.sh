#!/usr/bin/env bash
#
# setup.sh — personal workspace bootstrap.
#
# Run on a fresh Mac or Linux to install developer tools, deploy SSH
# keys and credentials from Proton Pass, lay down the workspace
# manifest, and populate the workspace directory with project repos.
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
#      clones the repo to $SETUP_DIR (default ~/setup) — so the install
#      is always a git working copy — and re-execs from the clone.
#      SETUP_REF=<tag> selects the ref (default: master).
#
#   2. From a local git working copy (e.g. a dev clone):
#        ./setup.sh
#      Runs in place, wherever the clone lives.
#
# Optional positional argument: the workspace manifest repo; overrides the
# default. It lands at ~/<repo-name>/ (basename minus .git, like `git clone`).
# Any transport git understands works (SSH or HTTPS); we assume the caller's
# git/SSH is already set up to reach it. Through the curl one-liner, pass it
# after a $0 placeholder:
#   /bin/bash -c "$(curl -fsSL …/setup.sh)" setup https://github.com/you/workspace.git
#
# WORKSPACE_DIR (env): check the workspace out at ~/<WORKSPACE_DIR>/ instead of
# the repo basename — for when the remote's repo name can't be your preferred
# local directory name (e.g. a Bitbucket slug projects-sakari.maaranen you want
# as ~/projects). Must be a plain directory name (no slashes) and set on every
# run: it decides where setup looks for the workspace, so idempotency depends on
# it. Don't rename the directory after cloning — set WORKSPACE_DIR instead, or a
# re-run recreates the basename directory and drifts.

set -uo pipefail

# ── Logging helpers ────────────────────────────────────────────────

err()  { printf '%s\n' "$*" >&2; }
info() { printf '  \xe2\x86\x92 %s\n' "$*"; }
ok()   { printf '  \xe2\x9c\x93 %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() { printf '  \xe2\x9c\x97 %s\n' "$*" >&2; exit 1; }

# maybe_ff_update <repo-dir> <branch>
# Fast-forward update of a local working copy *only* when it is safe:
# repo is a git working tree, fetch succeeds, working tree is clean, HEAD
# is on the named branch, HEAD is an ancestor of origin/<branch>, and
# there's actually something to advance. If any check fails (dirty,
# detached, on a different branch, non-FF, fetch failure), accept the
# working copy as-is and return silently.
maybe_ff_update() {
  local repo="$1"
  local branch="$2"
  [[ -d "$repo/.git" ]] || return 0
  git -C "$repo" fetch --quiet origin "$branch" 2>/dev/null || return 0
  git -C "$repo" diff-index --quiet HEAD 2>/dev/null || return 0
  [[ "$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)" == "$branch" ]] || return 0
  git -C "$repo" merge-base --is-ancestor HEAD "origin/$branch" 2>/dev/null || return 0
  local local_sha remote_sha
  local_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
  remote_sha="$(git -C "$repo" rev-parse "origin/$branch" 2>/dev/null)"
  [[ "$local_sha" == "$remote_sha" ]] && return 0
  info "Fast-forwarding $repo → origin/$branch"
  git -C "$repo" merge --ff-only "origin/$branch" --quiet 2>/dev/null || return 0
}

usage() {
  cat <<'EOF'
setup.sh — personal workspace bootstrap.

Installs developer tools, deploys SSH keys and credentials from Proton
Pass, clones the workspace manifest, and populates the workspace
directory (~/<repo-name>/) with project repos.

Prerequisite: Proton Pass desktop app installed and signed in.

Usage:
  setup.sh [FLAGS] [WORKSPACE_REPO]

Invocation modes:
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/master/setup.sh)"
                     One-liner; script runs from stdin, then clones the
                     repo to $SETUP_DIR (default ~/setup)
  ./setup.sh         From a local git working copy — runs in place

Arguments:
  WORKSPACE_REPO   Optional. Remote of the workspace manifest repo; lands at
                   ~/<repo-name>/ (basename minus .git, like git clone). Any
                   transport git understands (SSH or HTTPS); assumes your
                   git/SSH is already configured to reach it.
                   Default: git@github.com:sakaal/workspace.git
                   To pass it through the curl one-liner, add a $0 placeholder:
                     /bin/bash -c "$(curl -fsSL …/setup.sh)" setup <WORKSPACE_REPO>

Flags:
  --upgrade   Upgrade installed tools to their latest versions
  --dry-run   Print what would be done; make no changes
  --help      Show this help

Environment variables:
  SETUP_DIR   Where the one-liner installs its clone (default: ~/setup).
              Ignored when running from an existing working copy.
  SETUP_REF   Git ref to clone when self-bootstrapping (default: master)
  WORKSPACE_DIR
              Local directory name for the workspace, under ~/ (default: the
              workspace repo's basename). Use when the remote repo name can't
              be your preferred local dir — e.g. a Bitbucket slug
              projects-sakari.maaranen checked out as ~/projects. Must be a
              plain name (no slashes) and passed on every run: it decides
              where setup looks for the workspace, so idempotency depends on it.
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
        debian) sudo apt-get update -qq && sudo apt-get install -y git && APT_UPDATED=1 ;;
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

# ── Locate ────────────────────────────────────────────────────────
#
# Two cases:
#
#   (1) Running from a git working copy of setup (a dev clone or a prior
#       install, anywhere) — run in place.
#   (2) Standalone (curl-piped, or a non-git copy) — ensure a working copy
#       at $SETUP_DIR (default ~/setup) and exec from it. An existing
#       $SETUP_DIR is used only if it actually is a setup working copy;
#       anything else halts — set SETUP_DIR to install elsewhere.
#
# This script may be running from stdin (no script file on disk) when
# curl-piped, which is exactly why we git-clone INTO $SETUP_DIR rather
# than first writing this file there.

SETUP_DIR="${SETUP_DIR:-$HOME/setup}"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"

# is_setup_clone DIR — true if DIR is a git working copy of this repo.
is_setup_clone() {
  [[ -n "$1" && -f "$1/setup.yml" && -f "$1/hosts.yml" && -d "$1/.git" ]]
}

if is_setup_clone "$SCRIPT_DIR"; then
  # Case 1: run in place.
  cd "$SCRIPT_DIR"

elif [[ -e "$SETUP_DIR" ]]; then
  # Case 2, destination occupied: use it only if it is a setup clone.
  if ! is_setup_clone "$SETUP_DIR"; then
    fail "$SETUP_DIR exists but is not a setup working copy. Refusing to touch it.
    Set SETUP_DIR=<path> to install elsewhere, or move the existing directory."
  fi
  maybe_ff_update "$SETUP_DIR" master
  info "Re-executing from $SETUP_DIR/setup.sh"
  exec bash "$SETUP_DIR/setup.sh" "$@"

else
  # Case 2, destination free: self-bootstrap by cloning into $SETUP_DIR.
  REF="${SETUP_REF:-master}"
  ensure_build_tools
  command -v git >/dev/null 2>&1 || fail "git not available; cannot self-bootstrap"

  info "Cloning setup into $SETUP_DIR (ref: $REF)..."
  mkdir -p "$(dirname "$SETUP_DIR")"
  git clone --branch "$REF" https://github.com/sakaal/setup.git "$SETUP_DIR" \
    || fail "git clone of the setup repo into $SETUP_DIR failed"
  info "Re-executing from $SETUP_DIR/setup.sh"
  exec bash "$SETUP_DIR/setup.sh" "$@"
fi

# ── Flag parsing (running from the working copy by this point) ────

UPGRADE=false
DRY_RUN=false
# Workspace manifest repo. The optional positional argument overrides
# the default. Any transport git understands works
# (git@host:owner/repo, https://…, ssh://…) — we assume the caller's git/SSH
# is already configured to reach it.
WORKSPACE_REPO="git@github.com:sakaal/workspace.git"
workspace_repo_set=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade) UPGRADE=true ;;
    --dry-run) DRY_RUN=true ;;
    --help|-h) usage; exit 0 ;;   # already handled above; defensive
    -*)
      err "Unknown option: $1"
      err "Run with --help for usage."
      exit 1
      ;;
    *)
      if $workspace_repo_set; then
        err "Unexpected extra argument: $1"
        err "Only one positional argument (the workspace repo) is accepted."
        err "Run with --help for usage."
        exit 1
      fi
      if [[ -z "$1" ]]; then
        err "The workspace repo argument must not be empty."
        err "Run with --help for usage."
        exit 1
      fi
      WORKSPACE_REPO="$1"
      workspace_repo_set=true
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

# ── Package managers and tool installation ────────────────────────
#
# Tooling is provisioned per platform, but two things are unified across
# both: pipx (installed via the platform package manager) and Ansible
# (installed via pipx, so it always bundles the community.general collection
# the playbook needs). On macOS the platform package manager is Homebrew; on
# Linux it is the distro-native manager (dnf on Fedora-family, apt on
# Debian-family, pacman on Arch). Homebrew is not used on Linux.

ensure_brew_on_path() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
}

# install_brew_tool BINARY [FORMULA]  (macOS only)
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

# linux_pkg_install PKG...  — install packages via the distro-native manager.
# The apt metadata refresh runs once per process (APT_UPDATED guard), not on
# every call.
linux_pkg_install() {
  case "$LINUX_FAMILY" in
    debian)
      if [[ -z "${APT_UPDATED:-}" ]]; then
        run sudo apt-get update -qq || return 1
        APT_UPDATED=1
      fi
      run sudo apt-get install -y "$@" ;;
    rhel)   run sudo dnf install -y "$@" ;;
    arch)   run sudo pacman -S --needed --noconfirm "$@" ;;
    *)      warn "Unknown Linux family; install manually: $*"; return 1 ;;
  esac
}

# ensure_pipx — install pipx via the platform package manager. Falls back to a
# user-level pip install on Linux distros that don't package it (pipx lives
# only in EPEL on some RHEL-family releases).
ensure_pipx() {
  if command -v pipx >/dev/null 2>&1; then
    ok "pipx present"
    return 0
  fi
  info "Installing pipx..."
  case "$PLATFORM" in
    mac) install_brew_tool pipx ;;
    linux)
      case "$LINUX_FAMILY" in
        arch) linux_pkg_install python-pipx ;;
        *)    linux_pkg_install pipx ;;
      esac
      if ! command -v pipx >/dev/null 2>&1; then
        warn "pipx not available from the distro; installing at user level via pip"
        run python3 -m pip install --user pipx \
          || run python3 -m pip install --user --break-system-packages pipx \
          || fail "could not install pipx"
      fi
      ;;
  esac
  hash -r 2>/dev/null || true
  command -v pipx >/dev/null 2>&1 || $DRY_RUN || fail "pipx not on PATH after install"
  run pipx ensurepath >/dev/null 2>&1 || true
  ok "pipx installed"
}

# ensure_ansible — install Ansible via pipx on both platforms. --include-deps
# is required: ansible's console scripts (ansible-playbook, ansible-vault, …)
# are provided by its ansible-core dependency, so without it pipx exposes no
# commands. The top-level `ansible` package bundles community.general
# (git_config, ini_file), which the playbook uses.
ensure_ansible() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    ok "ansible present"
    if $UPGRADE; then
      info "Upgrading ansible..."
      run pipx upgrade ansible || warn "ansible: pipx upgrade failed (continuing)"
    fi
    return 0
  fi
  info "Installing ansible via pipx..."
  if run pipx install --include-deps ansible; then
    hash -r 2>/dev/null || true
    ok "ansible installed"
  else
    fail "ansible install via pipx failed"
  fi
}

# ensure_gh — GitHub CLI. brew on macOS; distro package (via the official
# GitHub repo on Fedora-family) on Linux. Best-effort: gh only powers the
# convenience `gh auth login` in stage 03; git auth itself goes through the
# credential helper, so a gh failure must not abort the bootstrap.
ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    ok "gh present"
    if [[ "$PLATFORM" == mac ]] && $UPGRADE; then
      info "Upgrading gh..."
      run brew upgrade gh || warn "gh upgrade failed (continuing)"
    fi
    return 0
  fi
  info "Installing gh (GitHub CLI)..."
  case "$PLATFORM" in
    mac) install_brew_tool gh ;;
    linux)
      case "$LINUX_FAMILY" in
        rhel)
          run sudo dnf install -y 'dnf-command(config-manager)' || true
          run sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null \
            || run sudo dnf config-manager addrepo --overwrite --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null \
            || warn "could not add GitHub CLI repo (continuing)"
          run sudo dnf install -y gh || warn "gh install failed (continuing)"
          ;;
        debian)
          run sudo apt-get install -y gh \
            || warn "gh not in base repos; see https://github.com/cli/cli/blob/trunk/docs/install_linux.md (continuing)"
          ;;
        arch)
          linux_pkg_install github-cli || warn "gh install failed (continuing)"
          ;;
      esac
      ;;
  esac
  if command -v gh >/dev/null 2>&1; then
    ok "gh installed"
  else
    warn "gh unavailable — stage 03 will skip gh auth (git credential helper still works)"
  fi
}

# ensure_pass_cli — Proton Pass CLI. brew tap on macOS; Proton's official
# installer (into ~/.local/bin) on Linux, since there is no native package.
ensure_pass_cli() {
  if command -v pass-cli >/dev/null 2>&1; then
    ok "pass-cli present"
    if $UPGRADE; then
      case "$PLATFORM" in
        mac)   info "Upgrading pass-cli..."; run brew upgrade pass-cli || warn "pass-cli upgrade failed (continuing)" ;;
        linux) info "Upgrading pass-cli..."; run pass-cli update || warn "pass-cli update failed (continuing)" ;;
      esac
    fi
    return 0
  fi
  info "Installing pass-cli..."
  case "$PLATFORM" in
    mac) install_brew_tool pass-cli protonpass/tap/pass-cli ;;
    linux)
      # Official cross-platform installer; drops the binary in ~/.local/bin
      # (already on PATH for this run, persisted by stage 08). Needs curl+jq.
      run bash -c 'curl -fsSL https://proton.me/download/pass-cli/install.sh | bash' \
        || fail "pass-cli install failed"
      ;;
  esac
  hash -r 2>/dev/null || true
  command -v pass-cli >/dev/null 2>&1 || $DRY_RUN || fail "pass-cli not on PATH after install"
  ok "pass-cli installed"
}

# ── Provision package manager + base packages ─────────────────────

case "$PLATFORM" in
  mac)
    if command -v brew >/dev/null 2>&1; then
      ok "Homebrew present"
    else
      info "Installing Homebrew..."
      run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      ensure_brew_on_path
      command -v brew >/dev/null 2>&1 || $DRY_RUN || fail "Homebrew not on PATH after install"
      ok "Homebrew installed"
    fi
    ensure_brew_on_path
    ;;
  linux)
    LINUX_FAMILY="$(detect_linux_distro_family)"
    [[ "$LINUX_FAMILY" == unknown ]] \
      && fail "Unrecognized Linux distro. Supported families: Fedora/RHEL (dnf), Debian (apt), Arch (pacman)."
    ok "Linux family: $LINUX_FAMILY"
    # Base packages the later stages shell out to: the pass-cli installer
    # needs curl+jq; the playbook uses python3, git, and OpenSSH client tools.
    info "Ensuring base packages..."
    case "$LINUX_FAMILY" in
      debian) linux_pkg_install git curl jq python3 openssh-client ;;
      rhel)   linux_pkg_install git curl jq python3 openssh-clients ;;
      arch)   linux_pkg_install git curl jq python  openssh ;;
    esac || warn "base package install had issues (continuing)"
    ;;
esac

# ── pass-cli C-library pre-check (Linux) ──────────────────────────
#
# Proton's pass-cli is a prebuilt binary linked against a fairly recent glibc.
# On a Linux system whose glibc is older than it needs, the binary can't run —
# so rather than fail, warn and skip credential provisioning (Proton Pass
# discovery, SSH keys, tokens, vault); the rest of setup still runs. macOS uses
# a Homebrew build and is unaffected.
SKIP_CREDENTIALS=false
PASS_CLI_MIN_GLIBC=2.29   # bump if Proton raises the floor

glibc_version() { ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | tail -1; }
ver_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }

if [[ "$PLATFORM" == linux ]]; then
  _glibc="$(glibc_version)"
  if [[ -n "$_glibc" ]] && ! ver_ge "$_glibc" "$PASS_CLI_MIN_GLIBC"; then
    SKIP_CREDENTIALS=true
    warn "System C library (glibc $_glibc) is older than the Proton pass-cli binary needs."
    warn "Skipping credential provisioning from Proton Pass; the rest of setup still runs."
    warn "To provision credentials too, run setup on a more recent OS distribution version."
  fi
fi

# User-local binaries (pipx apps, pass-cli) install into ~/.local/bin. Put it
# on PATH for the rest of THIS run so freshly-installed tools resolve; stage
# 08 persists it for future shells.
export PATH="$HOME/.local/bin:$PATH"
hash -r 2>/dev/null || true

# ── Install tools ─────────────────────────────────────────────────

ensure_pipx

case "$PLATFORM" in
  mac)   install_brew_tool git ;;
  linux) command -v git >/dev/null 2>&1 && ok "git present" || linux_pkg_install git ;;
esac

ensure_gh
$SKIP_CREDENTIALS || ensure_pass_cli
ensure_ansible

# ── Proton Pass authentication ────────────────────────────────────

if $SKIP_CREDENTIALS; then
  info "Skipping Proton Pass login (credential provisioning disabled)."
elif pass-cli vault list --output json >/dev/null 2>&1; then
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
ok "Workspace repo: $WORKSPACE_REPO"
ANSIBLE_ARGS=(-i hosts.yml setup.yml -e "workspace_repo=$WORKSPACE_REPO")
# When the C-library pre-check disabled credentials, tell the playbook to skip
# its credential stages (discovery, SSH keys, GitHub PAT, vault password).
if $SKIP_CREDENTIALS; then
  ANSIBLE_ARGS+=(-e skip_credentials=true)
  info "Credential stages will be skipped (incompatible C library)."
fi
# Optional override of the local workspace directory name (default: the repo
# basename, derived in setup.yml). Must be a plain name — it becomes ~/<name>.
WORKSPACE_DIR="${WORKSPACE_DIR:-}"
case "$WORKSPACE_DIR" in
  '')       : ;;  # unset — setup.yml derives it from the repo basename
  .|..|*/*) fail "WORKSPACE_DIR must be a plain directory name (no '/', not '.'/'..'): '$WORKSPACE_DIR'" ;;
  *)        ANSIBLE_ARGS+=(-e "workspace_dir=$WORKSPACE_DIR")
            ok "Workspace dir: ~/$WORKSPACE_DIR (override)" ;;
esac
if $DRY_RUN; then
  ANSIBLE_ARGS+=(--check)
fi
if $DRY_RUN && ! command -v ansible-playbook >/dev/null 2>&1; then
  info "(dry-run) Would: ansible-playbook ${ANSIBLE_ARGS[*]}"
elif ! ansible-playbook "${ANSIBLE_ARGS[@]}"; then
  fail "ansible-playbook failed; setup.sh halted before completing"
fi

ok "setup.sh complete"
