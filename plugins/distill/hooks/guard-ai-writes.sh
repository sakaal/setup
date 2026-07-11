#!/bin/sh
# guard-ai-writes.sh — enforce §7 req 12 during a distillation session: the
# distiller stages proposals only and must not write the workspace repo's ai/
# sources. Scoped to active runs by a marker file the /distill command sets, so
# it never interferes with ordinary work. Fail-open: any error → allow.
#
# PreToolUse hook on Write/Edit/MultiEdit. Blocks (exit 2) a write whose target
# is a hub source under an ai/ directory while a distill session is active.

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

case "$path" in
  */ai/AGENTS.md|*/ai/mcp.json|*/ai/rules/*|*/ai/commands/*|*/ai/skills/*|*/ai/agents/*)
    echo "distill session: refusing to write workspace ai/ source ($path)." \
         "The distiller stages a proposal only; the operator applies" \
         "promotions by hand (threat model §7 req 12)." >&2
    exit 2
    ;;
esac
exit 0
