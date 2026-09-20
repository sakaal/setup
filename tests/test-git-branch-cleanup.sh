#!/usr/bin/env bash
#
# test-git-branch-cleanup.sh — exercises files/git-branch-cleanup against real
# repositories built in a mktemp dir. Self-contained; safe to run as-is.
#
# Two premise cases pin down why git's own merged check is the wrong tool in
# both directions: it accepts a branch that never reached the base (upstream
# match counts as merged), and it refuses one whose every line landed through
# a rebase. The rest cover each merge style, each way work can be lost, the
# fresh branch that content alone cannot tell from a merged one, -m with
# either commit the forge reports, the forge's record looked up through a gh
# double, a branch present on one side only, operands that are no branch,
# and the survey and multi-repository forms.

set -uo pipefail

script=$(cd "$(dirname "$0")/.." && pwd)/files/git-branch-cleanup
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

dir=''
run() { ( cd "$dir" && "$script" "$@" 2>&1 ); }
g()   { git -C "$dir" "$@"; }

# Accepts: exit 0 and the output mentions $2. Keeps: exit 1 and it mentions $2.
# Errors: exit 2 and it mentions $2.
expect_accept() { out=$(run -n "${@:3}"); [ $? -eq 0 ] && printf '%s' "$out" | grep -q "$2" && ok "$1" || bad "$1" "$out"; }
expect_keep()   { out=$(run -n "${@:3}"); [ $? -eq 1 ] && printf '%s' "$out" | grep -q "$2" && ok "$1" || bad "$1" "$out"; }
expect_error()  { out=$(run -n "${@:3}"); [ $? -eq 2 ] && printf '%s' "$out" | grep -q "$2" && ok "$1" || bad "$1" "$out"; }

commit() { echo "$1" > "$dir/$1.txt"; g add -A; g commit --quiet -m "$1"; }
has()    { g show-ref --verify --quiet "$1"; }

# A double for gh, first on PATH: answers `pr list --head <branch>` from
# GH_PR_LIST — lines of "<branch> <number> <sha>" — as the helper's --jq
# would print them, and nothing for any other branch. Only a repository made
# to look like github.com below ever reaches it.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
head=''
while [ $# -gt 0 ]; do
    [ "$1" = --head ] && head=$2
    shift
done
printf '%s\n' "${GH_PR_LIST-}" | awk -v h="$head" '$1 == h { print $2, $3 }'
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# An origin with main, a feature branch of one commit, both pushed, and main
# moved on afterwards so a replayed commit lands on a different parent and so
# gets a different SHA — without that a cherry-pick can come out byte-identical
# to the original and the rebase cases stop being rebases.
new_repo() {
    dir="$tmp/$1"
    git init --quiet --bare "$dir.git"
    git init --quiet -b main "$dir"
    g config user.email t@example.com
    g config user.name Test
    g remote add origin "$dir.git"
    commit base
    g push --quiet -u origin main 2>/dev/null
    g checkout --quiet -b feature
    commit work
    g push --quiet -u origin feature 2>/dev/null
    g checkout --quiet main
    commit moved
    g push --quiet origin main 2>/dev/null
}

# Make origin look like github.com while the local bare repository keeps
# serving it, so the helper asks the gh double.
as_github() {
    g config "url.$dir.git.insteadOf" "https://github.com/test/$1"
    g remote set-url origin "https://github.com/test/$1"
}

# Land feature on main by rebase (a cherry-pick is one), leaving the branch.
land_by_rebase() {
    g cherry-pick --quiet feature >/dev/null
    g push --quiet origin main 2>/dev/null
}

# Land feature on main by squash, leaving the branch. The forge reports the
# squash commit as the merge, and it has no ancestry to the branch at all.
land_by_squash() {
    g merge --quiet --squash feature >/dev/null 2>&1
    g commit --quiet -m squashed
    g push --quiet origin main 2>/dev/null
}

# --- premise: what git's own check does -------------------------------------
new_repo premise-accepts
if g branch -d feature >/dev/null 2>&1; then
    ok "premise: git branch -d deletes an unmerged branch (upstream match)"
else
    bad premise-accepts "git branch -d refused; this premise no longer holds"
fi

new_repo premise-refuses
land_by_rebase
g push --quiet origin --delete feature 2>/dev/null
g fetch --prune --quiet origin
if g branch -d feature >/dev/null 2>&1; then
    bad premise-refuses "git branch -d accepted; this premise no longer holds"
else
    ok "premise: git branch -d refuses a rebase-merged branch"
fi

# --- unmerged: kept ---------------------------------------------------------
new_repo unmerged
expect_keep "unmerged: kept, where git branch -d would have deleted it" 'does not' feature

# --- rebase merge: proven by content, then deleted --------------------------
new_repo rebase
land_by_rebase
expect_accept "rebase: proven merged" 'already holds' feature
run feature >/dev/null
has refs/heads/feature          && bad rebase-delete "local branch survived"  || ok "rebase: local branch deleted"
has refs/remotes/origin/feature && bad rebase-delete "remote branch survived" || ok "rebase: remote branch deleted"

# --- squash of several commits: patch ids cannot prove it, content can ------
new_repo squash
g checkout --quiet feature
commit second
g push --quiet origin feature 2>/dev/null
g checkout --quiet main
land_by_squash
if [ "$(g cherry origin/main feature | grep -c '^+')" -eq 2 ]; then
    ok "squash: premise — patch ids report both commits unmerged"
else
    bad squash-premise "cherry no longer sees the squash as unmerged"
fi
expect_accept "squash: proven merged by content" 'already holds' feature
expect_accept "squash: -m with the merge commit the forge reports" 'on the forge' -m "$(g rev-parse main)" feature
expect_accept "squash: -m with the pull request's head" 'on the forge' -m "$(g rev-parse feature)" feature

# --- merge commit: no commits of its own, told apart by topology ------------
new_repo mergecommit
g merge --quiet --no-ff -m merged feature >/dev/null 2>&1
g push --quiet origin main 2>/dev/null
expect_accept "merge commit: proven merged" 'already holds' feature
expect_accept "merge commit: -m with the merge commit" 'on the forge' -m "$(g rev-parse main)" feature
expect_accept "merge commit: -m with the pull request's head" 'on the forge' -m "$(g rev-parse feature)" feature

# --- fresh branch: no commits of its own, no merge absorbed it — kept -------
new_repo fresh
g checkout --quiet -b fresh-idea
g push --quiet -u origin fresh-idea 2>/dev/null
g checkout --quiet main
expect_keep "fresh: a branch with no commits is kept" 'has not started' fresh-idea
commit later
g push --quiet origin main 2>/dev/null
expect_keep "fresh: still kept once the base has moved on" 'has not started' fresh-idea

# --- base moved across the branch's lines after the merge: doubt, unless -m -
new_repo conflict
land_by_squash
echo rewritten > "$dir/work.txt"
g add -A
g commit --quiet -m rewritten
g push --quiet origin main 2>/dev/null
expect_keep "conflict: kept when the base rewrote the branch's lines" 'does not' feature
expect_accept "conflict: -m with the merge commit proves it regardless" 'on the forge' -m "$(g rev-parse main~1)" feature

# --- rebase-only forge: remote branch deleted on merge, no ancestry left ----
new_repo rebased
land_by_rebase
g push --quiet origin --delete feature 2>/dev/null
g fetch --prune --quiet origin
merge_commit=$(g rev-parse main)              # what the forge reports as mergeCommit
head=$(g rev-parse feature)                   # what it reports as headRefOid
expect_accept "rebase: -m with the merge commit the forge reports" 'on the forge' -m "$merge_commit" feature
expect_accept "rebase: -m with the pull request's head" 'on the forge' -m "$head" feature
echo rewritten > "$dir/work.txt"
g add -A
g commit --quiet -m rewritten
g push --quiet origin main 2>/dev/null
expect_keep "rebase, base edited over: content alone cannot prove it" 'does not' feature
expect_accept "rebase, base edited over: -m with the merge commit proves it" 'on the forge' -m "$merge_commit" feature
expect_accept "rebase, base edited over: -m with the head proves it" 'on the forge' -m "$head" feature
as_github rebased
export GH_PR_LIST="feature 7 $head"
expect_accept "forge: the merged pull request proves it, unasked" 'pull request #7' feature
export GH_PR_LIST="other 8 $head"
expect_keep "forge: no merged pull request from the branch keeps it" 'no merged pull request' feature
g checkout --quiet feature
commit afterwards
g checkout --quiet main
export GH_PR_LIST="feature 7 $head"
expect_keep "forge: work past the merged pull request's head keeps it" 'no merged pull request' feature
unset GH_PR_LIST

# --- forge: the pull request's head never reached this clone ---------------
new_repo behind
other="$dir-other"
git clone --quiet "$dir.git" "$other" 2>/dev/null
o() { git -C "$other" "$@"; }
o config user.email t@example.com
o config user.name Test
o checkout --quiet feature 2>/dev/null
echo more > "$other/more.txt"; o add -A; o commit --quiet -m more
head=$(o rev-parse feature)
o push --quiet origin feature:refs/pull/9/head 2>/dev/null
o checkout --quiet main
o cherry-pick --quiet feature~1 feature >/dev/null   # a rebase merge of both commits
echo rewritten > "$other/work.txt"; o add -A; o commit --quiet -m rewritten
o push --quiet origin main 2>/dev/null
o push --quiet origin --delete feature 2>/dev/null
as_github behind
export GH_PR_LIST="feature 9 $head"
if g rev-parse --verify --quiet "$head^{commit}" >/dev/null; then
    bad behind-premise "the pull request's head is already in the clone"
else
    ok "forge: premise — the pull request's head is not in this clone"
fi
expect_accept "forge: the head is fetched from the pull request's ref and proves the branch" 'pull request #9' feature
unset GH_PR_LIST

# --- -m: the forge's merge commit, and what it still cannot vouch for -------
new_repo forge
land_by_squash
merged=$(g rev-parse main)
g checkout --quiet feature
commit unpushed
g checkout --quiet main
expect_keep "-m: unpushed local work past the merge is kept" 'after the merge' -m "$merged" feature

new_repo forge-remote
land_by_squash
merged=$(g rev-parse main)
g checkout --quiet feature
commit late-push
g push --quiet origin feature 2>/dev/null
g checkout --quiet main
g branch --quiet -D feature
expect_keep "-m: work pushed after the merge is kept" 'after the merge' -m "$merged" feature

new_repo forge-behind
g checkout --quiet feature
commit more
g push --quiet origin feature 2>/dev/null
g checkout --quiet main
land_by_squash
merged=$(g rev-parse main)
g checkout --quiet feature
g reset --quiet --hard HEAD~1
g checkout --quiet main
expect_accept "-m: a local branch behind the merge is accepted" 'on the forge' -m "$merged" feature

new_repo forge-unrelated
land_by_squash
g checkout --quiet -b other main
commit other
g checkout --quiet main
expect_keep "-m: a commit the branch does not reach is no proof" 'neither on' -m "$(g rev-parse other)" feature

# --- one side only ----------------------------------------------------------
new_repo only-local                       # the forge deleted the remote on merge
land_by_rebase
g push --quiet origin --delete feature 2>/dev/null
g fetch --prune --quiet origin
expect_accept "only local: proven, and only the local branch is named" 'would delete the local branch$' feature

new_repo only-remote                      # this clone never had it
land_by_rebase
g branch --quiet -D feature
expect_accept "only remote: proven, and only the remote is named" 'would delete origin/feature$' feature
run feature >/dev/null
has refs/remotes/origin/feature && bad only-remote-delete "remote survived" || ok "only remote: deleted"

# --- -a: survey, then act ---------------------------------------------------
new_repo survey
land_by_rebase                            # feature: merged
g checkout --quiet -b pending
commit pending                            # pending: unmerged
g push --quiet -u origin pending 2>/dev/null
g checkout --quiet -b idea                # idea: fresh, no commits
g push --quiet -u origin idea 2>/dev/null
g checkout --quiet main
out=$(run -a -n); rc=$?
if [ $rc -eq 0 ] \
    && printf '%s\n' "$out" | grep -q '^→ feature:' \
    && printf '%s\n' "$out" | grep -q '^! keeping pending' \
    && printf '%s\n' "$out" | grep -q '^! keeping idea' \
    && ! printf '%s\n' "$out" | grep -qE '^(→|! keeping) main'; then
    ok "-a -n: one deletable, two kept, base excluded, exit 0"
else
    bad survey "$out"
fi
out=$(run -a); rc=$?
if [ $rc -eq 0 ] && ! has refs/heads/feature && has refs/heads/pending && has refs/heads/idea; then
    ok "-a: deletes only the proven branch"
else
    bad survey-act "$out"
fi

# --- -a across repositories -------------------------------------------------
new_repo multi-one; a=$dir; land_by_rebase
new_repo multi-two; b=$dir; land_by_rebase
out=$("$script" -a -n "$a" "$b" 2>&1); rc=$?
if [ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^→ feature:')" -eq 2 ] \
    && printf '%s\n' "$out" | grep -q "^→ $a"; then
    ok "-a dir...: surveys each repository and names it"
else
    bad multi "$out"
fi

# --- several named branches: exit 1 when any is kept or never found ---------
new_repo named
land_by_rebase
g checkout --quiet -b pending
commit pending
g push --quiet -u origin pending 2>/dev/null
g checkout --quiet main
out=$(run -n feature pending); rc=$?
if [ $rc -eq 1 ] && printf '%s\n' "$out" | grep -q '^→ feature:' && printf '%s\n' "$out" | grep -q '^! keeping pending'; then
    ok "branch...: verdict for each, exit 1 because one was kept"
else
    bad named "$out"
fi
out=$(run -n featrue feature); rc=$?
if [ $rc -eq 1 ] && printf '%s\n' "$out" | grep -q '^! featrue: never found' && printf '%s\n' "$out" | grep -q '^→ feature:'; then
    ok "branch...: a name never found is said so, the rest still considered, exit 1"
else
    bad named-unknown "$out"
fi

# --- usage ------------------------------------------------------------------
new_repo usage
out=$(run);                       [ $? -eq 2 ] && ok "usage: no operand is refused"           || bad usage-none "$out"
out=$(run -a -m abc);             [ $? -eq 2 ] && ok "usage: -m with -a is refused"           || bad usage-am "$out"
out=$(run -m abc feature pending); [ $? -eq 2 ] && ok "usage: -m with two branches is refused" || bad usage-m2 "$out"
expect_error "usage: an empty operand is refused, not silently done" 'no branch name' ''
expect_error "usage: an empty operand with -m is refused" 'no branch name' -m abc1234 ''
expect_error "usage: a list passed as one operand is refused" 'no branch name' 'feature pending'
out=$(run -a '');                 [ $? -eq 2 ] && ok "usage: an empty directory operand is refused" || bad usage-empty-dir "$out"
expect_keep "usage: a misspelt name is reported never found, not already gone" 'never found' featrue

# --- -b and -r: another base on another remote; --help ----------------------
new_repo other-base
g remote rename origin upstream
g checkout --quiet -b develop main
g push --quiet -u upstream develop 2>/dev/null
g cherry-pick --quiet feature >/dev/null
g push --quiet upstream develop 2>/dev/null
g checkout --quiet main
expect_accept "-b -r: proven against develop on upstream" 'already holds' -r upstream -b develop feature
expect_keep "-b -r: unmerged against main on upstream" 'does not' -r upstream -b main feature
out=$(run --help); [ $? -eq 0 ] && printf '%s' "$out" | grep -q '^Usage:' && ok "usage: --help prints the reference" || bad usage-help "$out"

# --- guards -----------------------------------------------------------------
new_repo guards
expect_keep "guard: the base branch is refused" 'base branch' main
g checkout --quiet feature
expect_keep "guard: a checked-out branch is refused" 'checked out' feature

new_repo guard-literal
g checkout --quiet -b fix/v1x2
g checkout --quiet -b fix/v1.2
g push --quiet -u origin fix/v1.2 2>/dev/null
g checkout --quiet fix/v1x2
expect_keep "guard: a dot in the name is not a wildcard" 'has not started' fix/v1.2

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
