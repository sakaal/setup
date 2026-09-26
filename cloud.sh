#!/bin/bash
# cloud.sh — set up a cloud session: a hosted AI agent's container whose
# platform runs an operator-supplied setup script (the cloud-session scenario,
# docs/designs/cloud-sessions.md). It delivers the operator's AI-assistant
# configuration only — the workspace repo, the ~/.config/ai hub, and wiring for
# the enrolled tools present — and names the expected environment variables the
# environment lacks. It consumes no secrets, installs nothing, and always exits
# 0, so a problem is reported without blocking the session.
#
# The platform's setup-script field holds the pinned one-liner:
#   SETUP_REF=vX.Y.Z /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/vX.Y.Z/cloud.sh)" [cloud <workspace-repo>]
# It clones setup into $SETUP_DIR (default ~/setup) and re-runs from there.
# The wiring registers "<clone>/cloud.sh --session-start" as the owning tool's
# session-start hook; that run refreshes the same state and returns its report
# to the tool as JSON, for the agent's context.
#
# Environment: SETUP_DIR, SETUP_REF (default master), WORKSPACE_DIR (the
# workspace repo's directory under $HOME; default its basename).
set -uo pipefail

export GIT_TERMINAL_PROMPT=0
SETUP_URL="https://github.com/sakaal/setup.git"
SETUP_DIR="${SETUP_DIR:-$HOME/setup}"

SESSION_START=false
if [[ "${1:-}" == "--session-start" ]]; then
  SESSION_START=true
  shift
fi
WORKSPACE_ARG="${1:-}"
ARGS=()
$SESSION_START && ARGS+=(--session-start)
[[ -n "$WORKSPACE_ARG" ]] && ARGS+=("$WORKSPACE_ARG")

# ── Reporting: every line is kept for the session-start JSON ────────────────
LINES=()
report() {
  LINES+=("$1")
  $SESSION_START || printf '%s\n' "$1"
}
info() { report "→ $*"; }
warn() { report "! $*"; }
err()  { report "✗ $*"; }

finish() {
  if $SESSION_START; then
    emit_session_start_json
  fi
  exit 0
}

# emit_session_start_json — the hook's output: the warnings and errors, as
# context for the agent and as a message for the operator; nothing when clean.
emit_session_start_json() {
  local notable=() line
  for line in "${LINES[@]}"; do
    [[ "$line" == "!"* || "$line" == "✗"* ]] && notable+=("$line")
  done
  ((${#notable[@]})) || return 0
  printf '%s\n' "${notable[@]}" | python3 -c '
import json, sys
lines = sys.stdin.read().rstrip("\n")
context = ("The cloud-session setup (setup/cloud.sh) reported at session start:\n"
           + lines + "\nTell the operator which environment variables are "
           "missing: requests that need them fail until they are added in the "
           "cloud environment settings, which new sessions pick up.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                         "additionalContext": context},
                  "systemMessage": lines}))
' 2>/dev/null || true
}

# net CMD... — a network step, bounded so a slow host delays the session only
# briefly.
net() {
  local limit=120
  $SESSION_START && limit=20
  if command -v timeout >/dev/null 2>&1; then
    timeout "$limit" "$@"
  else
    "$@"
  fi
}

# maybe_ff DIR — fast-forward DIR's current branch to its upstream when the
# working tree is clean and the move is a fast-forward; anything else (dirty,
# detached at a tag, diverged, offline) leaves the working copy as it is.
maybe_ff() {
  local repo="$1" branch upstream
  branch="$(git -C "$repo" symbolic-ref --short -q HEAD)" || return 0
  upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || return 0
  net git -C "$repo" fetch --quiet origin "$branch" 2>/dev/null \
    || { warn "could not fetch $repo; using it as is"; return 0; }
  git -C "$repo" diff-index --quiet HEAD 2>/dev/null || return 0
  git -C "$repo" merge-base --is-ancestor HEAD "$upstream" 2>/dev/null || return 0
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$(git -C "$repo" rev-parse "$upstream")" ]] && return 0
  if git -C "$repo" merge --ff-only --quiet "$upstream" 2>/dev/null; then
    info "fast-forwarded $repo"
  else
    warn "could not fast-forward $repo; using it as is"
  fi
}

is_setup_clone() {
  [[ -n "$1" && -f "$1/setup.yml" && -f "$1/cloud.sh" && -f "$1/files/ai-sync" && -d "$1/.git" ]]
}

# ── The setup clone: run in place only when started as a file ───────────────
# Piped from curl there is no script file; the working directory is never taken
# for the clone, since a cloud session's checkout of this repo is the agent's
# working branch, not the pinned setup.
SELF="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
[[ -n "$SELF" && -f "$SELF" ]] && SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"

if ! is_setup_clone "$SCRIPT_DIR"; then
  if [[ -e "$SETUP_DIR" ]] && ! is_setup_clone "$SETUP_DIR"; then
    err "$SETUP_DIR exists but is not a setup working copy; left as is (set SETUP_DIR to use another path)"
    finish
  fi
  if [[ ! -e "$SETUP_DIR" ]]; then
    ref="${SETUP_REF:-master}"
    mkdir -p "$(dirname "$SETUP_DIR")"
    if ! net git clone --quiet --branch "$ref" "$SETUP_URL" "$SETUP_DIR" 2>/dev/null; then
      err "could not clone setup ($ref) into $SETUP_DIR"
      finish
    fi
    info "cloned setup ($ref) into $SETUP_DIR"
  else
    maybe_ff "$SETUP_DIR"
  fi
  exec bash "$SETUP_DIR/cloud.sh" "${ARGS[@]}"
fi

if $SESSION_START && [[ -z "${CLOUD_SH_REEXEC:-}" ]]; then
  before="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)"
  maybe_ff "$SCRIPT_DIR"
  if [[ "$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)" != "$before" ]]; then
    CLOUD_SH_REEXEC=1 exec bash "$SCRIPT_DIR/cloud.sh" "${ARGS[@]}"
  fi
fi

# ── The workspace repo ───────────────────────────────────────────────────────
# normalize URL — host/owner/repo, transport-agnostic (as stage 06 compares).
normalize() {
  local u="$1"
  u="${u#*://}"
  [[ "$u" == *@* && "${u%%@*}" != */* ]] && u="${u#*@}"
  [[ "$u" != */*:* && "$u" == *:* ]] && u="${u/:/\/}"
  u="${u%/}"
  printf '%s' "${u%.git}"
}

default_repo="$(sed -n 's/^[[:space:]]*workspace_repo:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$SCRIPT_DIR/setup.yml" | head -1)"
repo="${WORKSPACE_ARG:-$default_repo}"
norm="$(normalize "$repo")"
https_url="https://$norm.git"
ws_name="${WORKSPACE_DIR:-${norm##*/}}"
if [[ -z "$norm" || -z "$ws_name" || "$ws_name" == */* || "$ws_name" == .* ]]; then
  err "workspace repo '$repo' (WORKSPACE_DIR '${WORKSPACE_DIR:-}') gives no usable directory name"
  finish
fi
ws="$HOME/$ws_name"

# ws_ok: only a clone of the workspace repo is wired from.
ws_ok=false
if [[ ! -e "$ws" ]]; then
  if net git clone --quiet "$https_url" "$ws" 2>/dev/null; then
    info "cloned $https_url into $ws"
    ws_ok=true
  else
    err "could not clone $https_url; the shared AI instructions are not loaded"
  fi
elif [[ -d "$ws/.git" && "$(normalize "$(git -C "$ws" remote get-url origin 2>/dev/null)")" == "$norm" ]]; then
  maybe_ff "$ws"
  ws_ok=true
else
  err "$ws exists but is not a clone of $https_url; left as is"
fi

# ── Wiring: the shared engine, cloud scenario ────────────────────────────────
hook_cmd="$(printf '%q' "$SCRIPT_DIR/cloud.sh") --session-start"
[[ -n "$WORKSPACE_ARG" ]] && hook_cmd+=" $(printf '%q' "$WORKSPACE_ARG")"
[[ -n "${WORKSPACE_DIR:-}" ]] && hook_cmd="WORKSPACE_DIR=$(printf '%q' "$WORKSPACE_DIR") $hook_cmd"

if $ws_ok; then
  if ! { mkdir -p "$HOME/.config/ai" \
         && cp "$SCRIPT_DIR/files/agent-map.json" "$HOME/.config/ai/agent-map.json"; }; then
    warn "could not deploy the sync manifest into ~/.config/ai"
  fi
  sync_out="$(python3 "$SCRIPT_DIR/files/ai-sync" --scenario cloud \
    --manifest "$SCRIPT_DIR/files/agent-map.json" --workspace "$ws" \
    --session-start-command "$hook_cmd" 2>&1)"
  sync_rc=$?
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      →*|!*|✗*) report "$line" ;;
      *) report "! $line" ;;
    esac
  done <<<"$sync_out"
  ((sync_rc == 0 || sync_rc == 2)) || err "ai-sync failed (exit $sync_rc)"
fi

# ── Expected environment variables ───────────────────────────────────────────
# Presence only: a value is never printed, logged or compared beyond "empty".
EXPECTED=()
PURPOSE=()
expect() {
  local name="$1" purpose="$2" n
  for n in "${EXPECTED[@]}"; do [[ "$n" == "$name" ]] && return 0; done
  EXPECTED+=("$name")
  PURPOSE+=("$purpose")
}
for name in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
  expect "$name" "git identity; commits otherwise carry the platform's"
done

declared="$ws/.env.example"
if $ws_ok && [[ -f "$declared" ]]; then
  comment=""
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    if [[ -z "${line//[[:space:]]/}" ]]; then
      comment=""
    elif [[ "$line" =~ ^[[:space:]]*#[[:space:]]?(.*)$ ]]; then
      comment="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      name="${BASH_REMATCH[2]}"
      value="${BASH_REMATCH[3]//[[:space:]]/}"
      if [[ -n "$value" && "$value" != '""' && "$value" != "''" ]]; then
        err "$declared:$lineno declares $name with a value; the file is committed, so remove the value (not shown)"
      fi
      expect "$name" "${comment:-declared in .env.example}"
      comment=""
    else
      warn "$declared:$lineno is not a NAME= declaration; skipped"
      comment=""
    fi
  done <"$declared"
fi

missing=0
for i in "${!EXPECTED[@]}"; do
  name="${EXPECTED[$i]}"
  if [[ -z "${!name:-}" ]]; then
    warn "missing environment variable $name — ${PURPOSE[$i]}"
    missing=$((missing + 1))
  fi
done
((missing)) || $SESSION_START || info "all ${#EXPECTED[@]} expected environment variables are set"

finish
