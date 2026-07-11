#!/usr/bin/env bash
#
# test-ai-harvest.sh — fixture test for files/ai-harvest. Builds a scratch
# HOME with legitimate harvest content, decoys, and planted symlinks pointing
# outside the declared roots (threat T4, docs/ai-pipeline-threat-model.md),
# runs the collector against it, and asserts exactly the right files are
# cataloged. Self-contained; touches nothing outside its mktemp dir.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARVEST="$SCRIPT_DIR/../files/ai-harvest"
MANIFEST="$SCRIPT_DIR/../files/agent-map.json"

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
H="$FIXTURE/home"
OUTSIDE="$FIXTURE/outside"

mkdir -p "$H/.config/ai" \
         "$H/.claude/projects/-p-foo/memory" \
         "$H/.claude/projects/-p-bar" \
         "$H/.claude/memory" \
         "$OUTSIDE"
cp "$MANIFEST" "$H/.config/ai/agent-map.json"

# Legitimate content — must be cataloged.
echo '# fact' > "$H/.claude/projects/-p-foo/memory/MEMORY.md"
echo '{}' > "$H/.claude/projects/-p-foo/session.jsonl"
echo '{}' > "$H/.claude/projects/-p-bar/session.jsonl"
echo '# global' > "$H/.claude/memory/global.md"

# Fully literal path that is an operator-managed symlink — followed by
# design (the literal prefix is operator trust); must be cataloged.
echo '{}' > "$OUTSIDE/history-real.jsonl"
ln -s "$OUTSIDE/history-real.jsonl" "$H/.claude/history.jsonl"

# Decoy — must not be cataloged (no manifest entry matches it).
echo 'x' > "$H/.claude/projects/-p-bar/notes.txt"

# A directory whose name matches the leaf glob — a leaf glob matches files
# only, so nothing inside it may be cataloged.
mkdir -p "$H/.claude/projects/-p-foo/evil-dir.jsonl"
echo 'x' > "$H/.claude/projects/-p-foo/evil-dir.jsonl/leak.txt"

# Planted symlinks — must never be cataloged (T4).
echo 'SECRET' > "$OUTSIDE/id_secret"
mkdir -p "$OUTSIDE/dir"; echo 'SECRET' > "$OUTSIDE/dir/leak.jsonl"
ln -s "$OUTSIDE/id_secret" "$H/.claude/projects/-p-foo/memory/evil-file"
ln -s "$OUTSIDE/id_secret" "$H/.claude/projects/-p-foo/evil.jsonl"
ln -s "$OUTSIDE/dir"       "$H/.claude/projects/-p-evil-slug"
ln -s "$OUTSIDE/dir"       "$H/.claude/projects/-p-foo/memory/evil-dir"

# Literal segment below a dynamic one, symlinked — attacker-influenceable
# territory, must be refused even though the segment is literal.
mkdir -p "$H/.claude/projects/-p-evil-lit"
ln -s "$OUTSIDE/dir" "$H/.claude/projects/-p-evil-lit/memory"

HOME="$H" python3 "$HARVEST" >/dev/null 2>&1 || {
  echo "✗ ai-harvest exited non-zero"; exit 1; }

python3 - "$H" <<'EOF'
import json, os, sys

home = sys.argv[1]
with open(os.path.join(home, ".local/state/ai/harvest/latest")) as fh:
    catalog = json.load(fh)
urls = sorted(r["url"] for r in catalog["resources"])

expected_suffixes = sorted([
    "/.claude/projects/-p-foo/memory/MEMORY.md",
    "/.claude/projects/-p-foo/session.jsonl",
    "/.claude/projects/-p-bar/session.jsonl",
    "/.claude/memory/global.md",
    "/.claude/history.jsonl",
])

failures = []
if len(urls) != len(expected_suffixes):
    failures.append("expected %d resources, got %d" % (len(expected_suffixes), len(urls)))
for suffix in expected_suffixes:
    if not any(u.endswith(suffix) for u in urls):
        failures.append("missing legitimate resource: %s" % suffix)
for token in ("SECRET", "evil", "notes.txt", "outside"):
    for u in urls:
        if token in u:
            failures.append("cataloged forbidden path: %s" % u)

refinement_by_class = {"memory": "derived", "memory-global": "derived",
                       "history": "raw", "transcripts": "raw"}
for r in catalog["resources"]:
    expected = refinement_by_class.get(r["class"])
    if r.get("refinement") != expected:
        failures.append("%s: refinement %r, expected %r"
                        % (r["url"], r.get("refinement"), expected))

if failures:
    for f in failures:
        print("✗ %s" % f)
    print("cataloged:")
    for u in urls:
        print("  %s" % u)
    sys.exit(1)
print("→ ok: %d legitimate resources cataloged, no symlink escapes, no false hits"
      % len(urls))
EOF
