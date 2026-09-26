#!/usr/bin/env bash
#
# test-ai-sync.sh — exercises files/ai-sync against the real manifest in a
# mktemp home with a fake workspace repo. Self-contained; safe to run as-is.
#
# Covers the hub build, the link/import decision table (create, no-op, empty
# file, conflict), the scenario filter (MCP local-only, the session-start hook
# cloud-only), the session-start emitter, and --dry-run.

# check() evaluates its condition string when called: the single quotes are
# meant, and the variables it names are read there.
# shellcheck disable=SC2016,SC2034

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-$2}"; fi; }

home="$tmp/home"
ws="$home/workspace"
hub="$home/.config/ai"
hook="/opt/setup/cloud.sh --session-start"

sync() {
  HOME="$home" python3 "$root/files/ai-sync" --manifest "$root/files/agent-map.json" \
    --workspace "$ws" "$@" 2>&1
}

reset() {
  rm -rf "$home"
  mkdir -p "$ws/ai/rules" "$home/.claude" "$home/.gemini"
  echo "# shared" > "$ws/ai/AGENTS.md"
  echo "# rule" > "$ws/ai/rules/shell.md"
  printf '{"mcpServers": {"demo": {"command": "demo-mcp"}}}\n' > "$ws/ai/mcp.json"
}

# ── Hub and link/import ──────────────────────────────────────────────────────
reset
out=$(sync); rc=$?
check "first run exits 0" '[ $rc -eq 0 ]' "$out"
check "hub links AGENTS.md into the workspace" \
  '[ "$(readlink "$hub/AGENTS.md")" = "$ws/ai/AGENTS.md" ]' "$out"
check "hub links rules/" '[ "$(readlink "$hub/rules")" = "$ws/ai/rules" ]' "$out"
check "hub skips sources the workspace lacks" '[ ! -e "$hub/commands" ] && [ ! -L "$hub/commands" ]'
check "CLAUDE.md is the @import stub" \
  '[ "$(cat "$home/.claude/CLAUDE.md")" = "@$hub/AGENTS.md" ]' "$(cat "$home/.claude/CLAUDE.md" 2>&1)"
check "no tool link to a source the hub lacks" '[ ! -L "$home/.claude/commands" ]'

out=$(sync); rc=$?
check "second run changes nothing" \
  '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "already in sync" && ! printf "%s" "$out" | grep -q changed:' "$out"

reset
: > "$home/.claude/CLAUDE.md"
out=$(sync)
check "an empty CLAUDE.md becomes the stub" \
  '[ "$(cat "$home/.claude/CLAUDE.md")" = "@$hub/AGENTS.md" ]' "$out"

reset
echo "my notes" > "$home/.claude/CLAUDE.md"
out=$(sync); rc=$?
check "CLAUDE.md with content is a wiring conflict (exit 2)" \
  '[ $rc -eq 2 ] && printf "%s" "$out" | grep -q "conflict: .*CLAUDE.md"' "$out"
check "the conflicting CLAUDE.md is untouched" '[ "$(cat "$home/.claude/CLAUDE.md")" = "my notes" ]'

reset
mkdir -p "$hub" && echo "local" > "$hub/AGENTS.md"
out=$(sync); rc=$?
check "a real file at a hub path is a wiring conflict (exit 2)" \
  '[ $rc -eq 2 ] && printf "%s" "$out" | grep -q "conflict: .*config/ai/AGENTS.md"' "$out"
check "the real hub file is untouched" '[ ! -L "$hub/AGENTS.md" ] && [ "$(cat "$hub/AGENTS.md")" = "local" ]'

reset
mkdir -p "$hub" && ln -s "$tmp/elsewhere" "$hub/AGENTS.md"
out=$(sync)
check "a hub symlink leading elsewhere is repointed" \
  '[ "$(readlink "$hub/AGENTS.md")" = "$ws/ai/AGENTS.md" ]' "$out"

# ── Scenarios ────────────────────────────────────────────────────────────────
reset
out=$(sync --scenario local --session-start-command "$hook")
check "local: MCP servers merged for a present tool" \
  'grep -q demo-mcp "$home/.gemini/settings.json" 2>/dev/null' "$out"
check "local: no session-start hook" '[ ! -e "$home/.claude/settings.json" ]' "$out"

reset
out=$(sync --scenario cloud --session-start-command "$hook"); rc=$?
check "cloud: exits 0" '[ $rc -eq 0 ]' "$out"
check "cloud: no MCP servers" '[ ! -e "$home/.gemini/settings.json" ]' "$out"
check "cloud: SessionStart hook registered for startup and resume" \
  'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
g=d[\"hooks\"][\"SessionStart\"][0]
assert g[\"matcher\"]==\"startup|resume\" and g[\"hooks\"][0][\"command\"]==sys.argv[2]
" "$home/.claude/settings.json" "$hook"' "$out"

out=$(sync --scenario cloud --session-start-command "$hook")
check "cloud: the hook is not added twice" \
  '[ "$(grep -c session-start "$home/.claude/settings.json")" -eq 1 ] && ! printf "%s" "$out" | grep -q changed:' "$out"

reset
printf '{"model": "x", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "/old/cloud.sh --session-start"}]}]}}\n' \
  > "$home/.claude/settings.json"
before=$(cat "$home/.claude/settings.json")
out=$(sync --scenario cloud --session-start-command "$hook"); rc=$?
check "cloud: an earlier registration is reported, exit 0" \
  '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "conflict: .*SessionStart runs /old/cloud.sh"' "$out"
check "cloud: the earlier registration is untouched" \
  '[ "$(cat "$home/.claude/settings.json")" = "$before" ]'

reset
printf '{"model": "x"}\n' > "$home/.claude/settings.json"
out=$(sync --scenario cloud --session-start-command "$hook")
check "cloud: other settings are kept when the hook is merged in" \
  'python3 -c "
import json,sys
d=json.load(open(sys.argv[1])); assert d[\"model\"]==\"x\" and d[\"hooks\"][\"SessionStart\"]
" "$home/.claude/settings.json"' "$out"

# ── Dry run ──────────────────────────────────────────────────────────────────
reset
out=$(sync --dry-run); rc=$?
check "dry run reports what would change" \
  '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "would change: .*config/ai/AGENTS.md"' "$out"
check "dry run writes nothing" '[ ! -e "$hub" ] && [ ! -e "$home/.claude/CLAUDE.md" ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
