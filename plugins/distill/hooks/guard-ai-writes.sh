#!/bin/sh
# guard-ai-writes.sh — enforce §7 req 12 during a distillation session: the
# session must not freehand-edit the live workspace ai/ (what the tools read).
# It edits the run's worktree instead; apply merges that in. Scoped to active
# runs by a marker the /distill command sets, so it never interferes with
# ordinary work. Fail-open: any error → allow.
#
# PreToolUse hook on Write/Edit/MultiEdit. Blocks (exit 2) a write whose target
# is under the live workspace ai/ — but NOT the run's worktree, which lives
# under ~/.local/state/ai/distill/ and is where the session is meant to write.

marker="${HOME}/.local/state/ai/distill/.session-active"
[ -f "$marker" ] || exit 0   # no active distill session → do nothing

# Bound a leaked marker: if a session aborted without clearing it, the guard
# must not fail closed forever. Treat a marker older than 2h as stale — clear
# it and allow, so ordinary ai/ edits are never permanently blocked.
if [ -n "$(find "$marker" -mmin +120 2>/dev/null)" ]; then
    rm -f "$marker" 2>/dev/null
    exit 0
fi

input=$(cat 2>/dev/null) || exit 0
path=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print((d.get("tool_input") or {}).get("file_path", ""))
except Exception:
    pass
' 2>/dev/null) || exit 0

# The live workspace ai/ (default ~/workspace/ai). Worktrees under the distill
# state dir are a different path and stay allowed.
live_ai="${AI_WORKSPACE_DIR:-${HOME}/workspace}/ai"
case "$path" in
  "$live_ai"|"$live_ai"/*)
    echo "distill session: refusing to write the live workspace ai/ ($path)." \
         "Edit the run's worktree instead; 'ai-distill apply' merges it into" \
         "the live tree on your approval (threat model §7 req 12)." >&2
    exit 2
    ;;
esac
exit 0
