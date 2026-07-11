#!/bin/sh
# guard-ai-writes.sh — defense-in-depth for §7 req 12 during a distillation
# session: keep the session from freehand-editing the live workspace ai/ (what
# the tools read) via the ordinary write tools. It edits the run's worktree
# instead; apply merges that in. Scoped to active runs by a marker the /distill
# command sets, so it never interferes with ordinary work. Fail-open: any error
# → allow.
#
# PreToolUse hook on Write/Edit/MultiEdit. It cannot see Bash, so it is a guard
# on the primary write path, not a hard boundary — a session determined to write
# the live ai/ another way is the T6 residual, carried by the ai/ git history
# and R3 (review-visibility by convention), not by this hook. The primary
# control remains that apply merges only the gated, reviewed branch.

marker="${HOME}/.local/state/ai/distill/.session-active"
[ -f "$marker" ] || exit 0   # no active distill session → do nothing

# Bound a leaked marker: a session that aborted without clearing it must not
# block ai/ edits forever. If the marker has seen no distill activity for 2h,
# treat it as stale — clear it and allow. An active session refreshes it on
# every guarded write (below), so a long supervised review never trips this.
if [ -n "$(find "$marker" -mmin +120 2>/dev/null)" ]; then
    rm -f "$marker" 2>/dev/null
    exit 0
fi

input=$(cat 2>/dev/null) || exit 0

# Resolve both the guarded live ai/ and the write target to CANONICAL absolute
# paths, then compare by path prefix — so '.', '//', a trailing '/', '..', or a
# symlinked spelling cannot slip a live-ai write past a literal glob. The
# workspace root is read from the marker (written at session start by /distill,
# the same dir ai-distill guards), falling back to $AI_WORKSPACE_DIR then
# ~/workspace so a bare `touch` marker still works.
# The JSON input arrives on stdin; the program comes via -c so stdin stays free
# to read it (a heredoc would shadow it). realpath resolves .., //, trailing /,
# and symlinks — the final component need not exist (a create).
verdict=$(printf '%s' "$input" | AI_MARKER="$marker" AI_HOME="$HOME" python3 -c '
import json, os, sys
home = os.environ.get("AI_HOME") or os.path.expanduser("~")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)                                  # unparseable -> allow (fail-open)
path = ((d.get("tool_input") or {}).get("file_path") or "").strip()
if not path:
    sys.exit(0)
root = ""
try:
    with open(os.environ["AI_MARKER"], encoding="utf-8") as fh:
        root = fh.read().strip()
except Exception:
    root = ""
root = root or os.environ.get("AI_WORKSPACE_DIR") or os.path.join(home, "workspace")
live = os.path.realpath(os.path.join(root, "ai"))
target = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
target = os.path.realpath(target)
if target == live or target.startswith(live + os.sep):
    print("BLOCK")
' 2>/dev/null) || exit 0

if [ "$verdict" = "BLOCK" ]; then
    echo "distill session: refusing to write the live workspace ai/." \
         "Edit the run's worktree instead; 'ai-distill apply' merges it into" \
         "the live tree on your approval (threat model §7 req 12)." >&2
    exit 2
fi

# Refresh the marker so an active session stays past the 2h stale bound (that
# bound only exists to recover from an aborted run, not to time out live work).
touch "$marker" 2>/dev/null
exit 0
