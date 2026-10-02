#!/usr/bin/env bash
#
# test-cloud.sh — exercises cloud.sh in a mktemp home with a workspace clone
# that already matches, so no network is used. Self-contained; safe to run
# as-is.
#
# Covers the expected-variable check (missing, present, a committed value, an
# invalid line) with no value ever in the output, the session-start JSON, the
# registered hook, and the refusals that keep other content untouched.

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
repo="https://example.invalid/me/ws"
secret="s3cr3t-value-never-shown"
identity=(GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@example.invalid
          GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@example.invalid)

reset() {
  rm -rf "$home"
  mkdir -p "$home/.claude" "$home/ws/ai"
  git -C "$home/ws" init --quiet -b main
  git -C "$home/ws" remote add origin "$repo.git"
  echo "# shared" > "$home/ws/ai/AGENTS.md"
  cat > "$home/ws/.env.example" <<EOF
# demo service API (read-only token)
DEMO_TOKEN=

export PRESENT_TOKEN=
not a declaration
LEAKED=$secret
QUOTED=""
EOF
}

# cloud [ENV=VALUE...] -- [ARGS...] — run cloud.sh in place with a clean
# environment plus the given variables.
cloud() {
  local vars=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift
  env -i PATH="$PATH" HOME="$home" "${vars[@]}" bash "$root/cloud.sh" "$@" 2>&1
}

# ── Build run ────────────────────────────────────────────────────────────────
reset
out=$(cloud "${identity[@]}" PRESENT_TOKEN=x -- "$repo"); rc=$?
check "exits 0" '[ $rc -eq 0 ]' "$out"
check "names a missing declared variable with its purpose" \
  'printf "%s" "$out" | grep -q "! missing environment variable DEMO_TOKEN — demo service API (read-only token)"' "$out"
check "a set variable is not reported" '! printf "%s" "$out" | grep -q "PRESENT_TOKEN"' "$out"
check "a quoted empty value counts as a declaration" \
  'printf "%s" "$out" | grep -q "missing environment variable QUOTED — declared in .env.example"' "$out"
check "a committed value is an error" \
  'printf "%s" "$out" | grep -q "✗ .*declares LEAKED with a value"' "$out"
check "the committed value is never shown" '! printf "%s" "$out" | grep -q "$secret"' "$out"
check "an invalid line is reported and skipped" \
  'printf "%s" "$out" | grep -q "is not a NAME= declaration; skipped"' "$out"
check "the identity variables are not reported when set" '! printf "%s" "$out" | grep -q GIT_' "$out"
check "the workspace is wired (CLAUDE.md stub)" \
  '[ "$(cat "$home/.claude/CLAUDE.md" 2>/dev/null)" = "@$home/.config/ai/AGENTS.md" ]' "$out"
check "the refresh hook re-runs this clone with the workspace repo" \
  'grep -q "\"$root/cloud.sh --session-start $repo\"" "$home/.claude/settings.json"' \
  "$(cat "$home/.claude/settings.json" 2>&1)"

out=$(cloud -- "$repo")
check "unset identity variables are each named" \
  '[ "$(printf "%s" "$out" | grep -c "missing environment variable GIT_")" -eq 4 ]' "$out"

rm "$home/ws/.env.example"
out=$(cloud "${identity[@]}" -- "$repo")
check "all set: says so" 'printf "%s" "$out" | grep -q "all 4 expected environment variables are set"' "$out"

# ── Session start ────────────────────────────────────────────────────────────
reset
out=$(cloud "${identity[@]}" PRESENT_TOKEN=x -- --session-start "$repo"); rc=$?
check "session start exits 0 with JSON only" \
  '[ $rc -eq 0 ] && printf "%s" "$out" | python3 -c "import json,sys; json.load(sys.stdin)"' "$out"
check "session start gives the agent the missing names" \
  'printf "%s" "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d[\"hookSpecificOutput\"][\"additionalContext\"]
assert d[\"hookSpecificOutput\"][\"hookEventName\"]==\"SessionStart\"
assert \"DEMO_TOKEN\" in c and \"PRESENT_TOKEN\" not in c and d[\"systemMessage\"]
"' "$out"
check "session start never shows the committed value" '! printf "%s" "$out" | grep -q "$secret"' "$out"

rm "$home/ws/.env.example"
out=$(cloud "${identity[@]}" -- --session-start "$repo")
check "session start prints nothing when all is well" '[ -z "$out" ]' "$out"

# ── Refusals ─────────────────────────────────────────────────────────────────
reset
git -C "$home/ws" remote set-url origin https://example.invalid/other/repo.git
out=$(cloud "${identity[@]}" -- "$repo"); rc=$?
check "a workspace dir with another origin is left alone, exit 0" \
  '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "✗ .*is not a clone of $repo.git; left as is"' "$out"
check "nothing is wired from a foreign workspace" '[ ! -e "$home/.config/ai/AGENTS.md" ]'

reset
mkdir -p "$tmp/occupied" && echo keep > "$tmp/occupied/file"
out=$(cd "$root" && env -i PATH="$PATH" HOME="$home" SETUP_DIR="$tmp/occupied" \
  bash -c "$(cat "$root/cloud.sh")" cloud "$repo" 2>&1); rc=$?
check "piped: never runs in place from the working directory" \
  '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "✗ .*occupied exists but is not a setup working copy"' "$out"
check "piped: the occupied SETUP_DIR is untouched" \
  '[ "$(ls "$tmp/occupied")" = file ] && [ ! -e "$home/.config/ai" ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
