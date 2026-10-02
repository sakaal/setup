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

src=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# cloud.sh runs in place from a copy with no upstream, so its session-start
# runs neither fetch nor fast-forward the working copy under test.
cp -a "$src" "$tmp/setup"
git -C "$tmp/setup" branch --unset-upstream 2>/dev/null
root="$tmp/setup"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-$2}"; fi; }

home="$tmp/home"
repo="https://example.invalid/me/ws"
secret="s3cr3t-value-never-shown"
present="pr3sent-value-never-shown"
identity=(GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@example.invalid
          GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@example.invalid)

reset() {
  rm -rf "$home"
  mkdir -p "$home/.claude" "$home/ws/ai"
  git -C "$home/ws" init --quiet -b main
  git -C "$home/ws" remote add origin "$repo.git"
  git -C "$home/ws" -c user.name=t -c user.email=t@example.invalid \
    commit --quiet --allow-empty -m init
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
out=$(cloud "${identity[@]}" PRESENT_TOKEN="$present" -- "$repo"); rc=$?
check "exits 0" '[ $rc -eq 0 ]' "$out"
check "names a missing declared variable with its purpose" \
  'printf "%s" "$out" | grep -q "! missing environment variable DEMO_TOKEN — demo service API (read-only token)"' "$out"
check "a set variable is not reported missing" \
  '! printf "%s" "$out" | grep -q "missing environment variable PRESENT_TOKEN"' "$out"
check "a quoted empty value counts as a declaration" \
  'printf "%s" "$out" | grep -q "missing environment variable QUOTED — declared in .env.example"' "$out"
check "a committed value is an error" \
  'printf "%s" "$out" | grep -q "✗ .*declares LEAKED with a value"' "$out"
check "the committed value is never shown" '! printf "%s" "$out" | grep -q "$secret"' "$out"
check "an invalid line is reported and skipped" \
  'printf "%s" "$out" | grep -q "is not a NAME= declaration; skipped"' "$out"
check "the identity variables are not reported missing when set" \
  '! printf "%s" "$out" | grep -q "missing environment variable GIT_"' "$out"
check "the summary is the one last line, naming what loaded" \
  '[ "$(printf "%s\n" "$out" | grep -c "^→ loaded: ")" -eq 1 ] \
   && printf "%s\n" "$out" | tail -n 1 | grep -q "^→ loaded: $root [^;]*; $home/ws [0-9a-f]*; tools: claude-code; env: GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL, PRESENT_TOKEN$"' "$out"
check "no report line repeats, and ai-sync's tools line stays internal" \
  '[ -z "$(printf "%s\n" "$out" | sort | uniq -d)" ] && ! printf "%s\n" "$out" | grep -q "^tools: "' "$out"
check "no variable value appears in the output" '! printf "%s" "$out" | grep -q "$present"' "$out"
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
out=$(cloud "${identity[@]}" PRESENT_TOKEN="$present" -- --session-start "$repo"); rc=$?
check "session start exits 0 with JSON only" \
  '[ $rc -eq 0 ] && printf "%s" "$out" | python3 -c "import json,sys; json.load(sys.stdin)"' "$out"
check "session start gives the agent the summary, the missing names and the instruction" \
  'printf "%s" "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d[\"hookSpecificOutput\"][\"additionalContext\"].split(\"\\n\")
assert d[\"hookSpecificOutput\"][\"hookEventName\"]==\"SessionStart\"
assert c[0].startswith(\"Cloud-session setup (setup/cloud.sh) at session start: loaded: $root \")
assert any(l.startswith(\"! missing environment variable DEMO_TOKEN\") for l in c)
assert not any(l.startswith(\"! missing environment variable PRESENT_TOKEN\") for l in c)
assert c[-1].startswith(\"Tell the operator about these\")
"' "$out"
check "session start never shows the committed value" '! printf "%s" "$out" | grep -q "$secret"' "$out"
check "session start never shows a variable value" '! printf "%s" "$out" | grep -q "$present"' "$out"
check "warning start: the operator sees the summary line, then the warnings" \
  'printf "%s" "$out" | python3 -c "
import json,sys
m=json.load(sys.stdin)[\"systemMessage\"].split(\"\\n\")
assert m[0].startswith(\"loaded: $root \") and \"PRESENT_TOKEN\" in m[0] and \"DEMO_TOKEN\" not in m[0]
assert any(l.startswith(\"! missing environment variable DEMO_TOKEN\") for l in m[1:])
"' "$out"

rm "$home/ws/.env.example"
out=$(cloud "${identity[@]}" -- --session-start "$repo")
check "clean start: the one summary line, for the operator and the agent" \
  'printf "%s" "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert sorted(d)==[\"hookSpecificOutput\", \"systemMessage\"], d
m=d[\"systemMessage\"]
assert \"\\n\" not in m and m.startswith(\"loaded: $root \") and \"; $home/ws \" in m
assert m.endswith(\"; tools: claude-code; env: GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL\"), m
c=d[\"hookSpecificOutput\"][\"additionalContext\"]
assert c==\"Cloud-session setup (setup/cloud.sh) at session start: \"+m, c
"' "$out"

# ── A failed clone ───────────────────────────────────────────────────────────
# A git double fails every clone as an unauthorized fetch does, with
# credentials in the URL; every other git command runs the real git.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = clone ]; then
    echo "fatal: unable to access 'https://me:t0ken@example.invalid/me/ws.git/': The requested URL returned error: 403" >&2
    echo "second line" >&2
    exit 128
  fi
done
exec $(command -v git) "\$@"
EOF
chmod +x "$tmp/bin/git"

reset
rm -rf "$home/ws"
out=$(cloud "${identity[@]}" PATH="$tmp/bin:$PATH" -- "$repo"); rc=$?
check "failed clone: exits 0 with the first line of git's error" \
  '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "✗ could not clone $repo.git: fatal: unable to access .https://example.invalid/me/ws.git/.: The requested URL returned error: 403"' "$out"
check "failed clone: credentials in a URL are not shown" '! printf "%s" "$out" | grep -q t0ken' "$out"
check "failed clone: later error lines are left out" '! printf "%s" "$out" | grep -q "second line"' "$out"
check "failed clone: the hook is registered, so session start retries" \
  'grep -q "\"$root/cloud.sh --session-start $repo\"" "$home/.claude/settings.json"' \
  "$(cat "$home/.claude/settings.json" 2>&1)"
out=$(cloud "${identity[@]}" PATH="$tmp/bin:$PATH" -- --session-start "$repo")
check "failed clone: session start gives the agent the error" \
  'printf "%s" "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert \"403\" in d[\"hookSpecificOutput\"][\"additionalContext\"]
assert \"; $home/ws not loaded; \" in d[\"systemMessage\"].split(\"\\n\")[0]
"' "$out"

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
