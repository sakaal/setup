# setup — agent context

Personal workspace bootstrap for a fresh Mac or Linux machine. User-facing
description in [README.md](README.md). This is the agent-neutral context an
agent needs to work in this repo well; `CLAUDE.md` is a one-line `@import` of
it (the repo dogfooding the very pattern it ships).

## Goal

**Mission.** One command turns a fresh personal Mac or Linux machine into the
operator's full development environment — tools, credentials, project repos,
and AI-assistant configuration — and re-running it is always safe.

These invariants generate the design; keep them true. Everything below is how
they are realized here, and cites them rather than restating them.

1. **Single source for secrets.** Proton Pass is the master; secrets are
   fetched on demand and nothing on disk is authoritative without a Pass-side
   counterpart. The unattended path consumes only Pass-resident truth.
2. **Non-destructive & idempotent.** Detect → decide → never blanket-overwrite;
   on unexpected divergence, halt and report rather than "fix." Re-running
   changes only what is missing or stale.
3. **Anchor only upstream.** Depend solely on external services (git host,
   Proton, Apple, OS package sources). Nothing the bootstrap configures may be
   a dependency of the bootstrap.
4. **No fixed home.** Run from wherever the working copy lives. The curl
   one-liner's `~/setup` is a default, not a required location; a local clone
   runs in place.
5. **Public mechanism, private content.** This repo is safe to publish: only
   *how*, never the operator's *what*. Personal content lives in a separate
   private repo referenced by convention.
6. **Cross-platform, side by side.** macOS and Linux (Fedora-family first).
   Never modify system interpreters or package-manager defaults — install
   alongside.
7. **Personal scale.** No org-grade machinery (structured logging, run-ids,
   telemetry); severity-tagged console output is enough.
8. **Data-driven where open-ended.** Where the set is unbounded (which AI
   tools, which servers), one manifest describes it and the code loops
   generically — adding one is a data edit, not code.
9. **Complete, lane-categorized coverage.** Every local store an enrolled AI
   tool keeps — configuration, data, or runtime state — is represented in
   `agent-map.json`, under its lane:
   - **distribute** — one shared source fanned out to many tools (instructions,
     MCP, commands, skills, agents); applied automatically by the sync engine.
   - **harvest** — knowledge the tool accumulates (memory, session history);
     cataloged read-only by `~/bin/ai-harvest`, then distilled *up* into the
     distribute sources by human-curated runs, never pushed down.
   - **non-reusable** — settings, model, toggles; being tool-bound wouldn't
     stop translation, but this content has no meaning outside its tool, so we
     don't try. An explicit record that it is intentionally left alone.

   Entries are grouped by lane in the manifest, so the lane is structural; only
   distribute entries carry a `sync` mechanism. Coverage is **exhaustive and
   explicit**: every store an enrolled tool keeps locally is accounted for —
   never left to a default. Distribute and harvest entries are individual and
   **take precedence**, so a tool's non-reusable remainder is a single bare
   wildcard over its dir (`<dir>/**` = everything not already carved out) — not
   a file-by-file list. Call out an individual non-reusable path only when it
   needs a flag (e.g. a secret).

**Boundaries (do not add):**

- No key, PAT, or vault-password generation or rotation in the unattended path
  — those are explicit, human-triggered utilities under `keys/`.
- No destructive git (`reset --hard`, `force: yes`).
- No references to other organizations or projects — this repo stands alone;
  conventions adopted from elsewhere carry no attribution.

## Two-layer secret model (realizes 1)

1. **Proton Pass vault `Setup Keys`** (master, manually unlocked once per machine).
2. **Ansible Vault** — its password is one of the items in `Setup Keys`,
   exposed via `~/.ansible/vault-password.sh` so any vault-encrypted file
   decrypts transparently after bootstrap.

## `Setup Keys` discovery dispatch table

Items are dispatched by name pattern. The discovery stage extracts only titles
(passwords stay inside `pass-cli`) so register variables and ansible callback
plugins never carry secrets.

| Item-name pattern   | Pass type | Deploy target |
|---------------------|-----------|---------------|
| `id_*`              | SshKey    | `~/.ssh/<title>` (mode 0600) + `<title>.pub` (0644) |
| `github-pat`        | Login     | `~/bin/git-credential-github` + git config + `gh auth login --with-token` |
| `vault_pass-*`      | Login     | `~/.ansible/vault-password.sh` (parameterized) + `~/.ansible.cfg` `vault_identity_list` |
| _anything else_     | —         | ignored; logged as a warning |

Vault ID for `vault_pass-*` items is the title with the `vault_pass-` prefix
stripped (`vault_pass-<id>` → vault id `<id>`).

## Invocation modes and self-bootstrap (realizes 4)

`setup.sh` supports two invocation modes, both reaching the same end state:

1. **Curl-piped one-liner** (`/bin/bash -c "$(curl -fsSL …/setup.sh)"`) — primary
   entry. The script runs from stdin (never written to disk). It installs
   Command Line Tools on a fresh Mac (sudo prompt) so `git` is available, then
   clones the repo to `$SETUP_DIR` (default `~/setup`) and re-execs from the
   clone. An existing `$SETUP_DIR` is reused only if it is a setup working copy;
   anything else halts, telling the user to set `SETUP_DIR`. `SETUP_REF` selects
   the git ref (default `master`).
2. **Local clone** (`./setup.sh` from any directory with the playbook alongside)
   — runs in place, wherever the clone lives; `SETUP_DIR` is ignored.

`setup.sh` also takes one **optional positional argument** overriding the
default workspace manifest repo (any SSH/HTTPS transport git understands). It
lands at `~/<repo-basename>/`, derived once as `workspace_dir` in `setup.yml`;
stages 06/07/09 build every path from it. The argument is forwarded verbatim
through the self-bootstrap re-exec (`"$@"`) and passed to Ansible as the
`workspace_repo` extra-var (highest precedence). Through the curl one-liner it
goes after a `$0` placeholder: `… setup.sh)" setup <repo>`. Stage 06 normalizes
both the desired repo and any existing origin to `host/owner/repo` before
comparing, so the trust/halt decision is transport-agnostic.

**Why git clone (after CLT) and not curl + tar**: the install must be a real git
working tree so `git pull`, `git status`, and `git tag --verify` work as
standard operations. The entry transport is curl (so the one-liner needs no
git); once running we install CLT (whose git suffices for the clone) and use it.
Tag pinning and GPG-signed tags then work via standard git.

## Location independence (realizes 4)

All playbook deploy targets are absolute (`$HOME/<workspace_dir>/`, `$HOME/.ssh/`,
`$HOME/.ansible/`, `$HOME/bin/`). The playbook's only self-reference is
`playbook_dir` (stage 02's origin switch on the running clone), so the stages
are unaffected by where setup lives. The whitelist `.gitignore` in the workspace
repo ignores every sibling directory, so a setup clone placed inside the
workspace directory is invisible to its git tracking. If you need the script's
own directory, use `$SCRIPT_DIR` (resolved early in `setup.sh`).

## AI-assistant configuration (realizes 5, 8, 9)

The enrolled tools are installed by `tasks/09-ai-tools.yml`, which imports one
file per tool (`09-ai-tool-<name>.yml`) — each an idempotent, install-if-missing
step preferring the tool's official installer — immediately before
`09-ai-config.yml`. The configuration stage wires a tool once its config
directory exists (which its `detect` entry keys on), so wiring lands the same
run for a tool whose installer creates that directory and the next run
otherwise; the playbook is idempotent either way.

`agent-map.json` is the authoritative, data-driven sync manifest: entries are
grouped by **lane** (`distribute` / `harvest` / `non-reusable`); each
distribute entry carries its path, `sync` method
(`link`/`import`/`generate`/`wrap`/`ignore`), and — where it has a working
hook — a `source`/`format`. The manifest also defines the `scope`/`subscope`
vocabulary (`user`/`workspace`, `:path`) and the `{slug}` placeholder
convention (path values are RFC 6570-style URI templates); that legend is
authoritative, so consult it rather than duplicating it here.

Shared, agent-neutral content (`AGENTS.md`, `mcp.json`, and future
`commands/`, `skills/`, `agents/`, `rules/`) lives in the private workspace
repo's `ai/`; `~/.config/ai/` is a stable hub of symlinks to it, and tools
are wired to the hub.

**distribute.** Both the playbook (stage 09, via `include_vars`) and
`~/bin/ai-sync` (stdlib `json`) read this lane, matching scope by its base
(`user`), and loop generically — no tool is enumerated in code.

*Reference in place, don't copy.* The default is to point a tool at the
shared source where it already lives — a symlink (`link`) to the hub at user
scope, or, for workspace-scope sources referenced from the workspace root, the
tool's own config pointed at that in-tree path. The copy/transform methods
(`import`/`generate`/`wrap`) are the exception, only for tools that cannot
read the shared set natively (e.g. a flat instruction file that must be
composed from `AGENTS.md` plus the `rules/` files — something a symlink can't
do). Workspace-scope entries are applied at the workspace root and inherited by
the projects inside it, not by the user-global sync (stage 09 currently wires
user scope only); the manifest records their locations and methods.

**harvest.** These entries locate the knowledge a curation run distils
upward. `~/bin/ai-harvest` (deployed by stage 09, run manually at curation
time) resolves them deterministically — a `{slug}` segment expands to the
directories present at that point, a glob segment to matching files, a `://`
value is a verbatim URL, never expanded or dereferenced — and writes a
catalog of absolute URLs with size/mtime/sha256 under
`~/.local/state/ai/harvest/` (`latest` points at the newest run). Collection
reads content only to hash it and never writes to tool paths.

**non-reusable.** A decision record; neither this lane nor harvest is ever
machine-applied.

**Distillation** is hybrid: deterministic `ai-distill` scripts
(`prepare`/`gate`/`apply`) bracket a human-supervised agent session for the
inference middle, with no model API calls or credentials in the pipeline. It
runs sanitize → generalize → categorize → deduplicate → triage, and lands
reviewed output in the workspace repo's `ai/`. `prepare` opens a git worktree
of the workspace repo on branch `distill/<run>`, off the live path; the
session writes the distilled `ai/` directly in that worktree; `gate` checks
the branch diff; and on the operator's approval `apply` merges the branch into
the live `ai/` and removes the worktree. The branch diff is the review
artifact, so nothing reaches the live `ai/` un-reviewed. The session half ships
as the `distill` plugin (this repo is its own Claude Code plugin marketplace,
`.claude-plugin/marketplace.json` and `plugins/distill/`), tool-specific
packaging around agent-neutral process content, as `ai-sync` has per-tool
emitters. Three principles:

- **Derived-first.** The default input is the knowledge the tools already
  distilled once (`refinement: derived` — memories, not transcripts); the
  mission is to collect that knowledge safely, not to re-derive it. Tool
  bookkeeping (`refinement: meta`, e.g. a memory index) is cataloged but
  never distilled — what it points to is harvested on its own.
- **Tiered screening.** Clearly safe items pass through; risky ones get
  deeper analysis, escalating if necessary to targeted corroboration against
  the raw sources — so raw content stays cataloged as a reference index,
  never bulk-ingested.
- **Generalizable only.** Project or customer particulars are never promoted
  — they belong in their source repositories and are routed there
  (`suggest-to-repo`); promotion to the hub is default-deny, with generality
  demonstrated by recurrence across repos and identifier-free rewrite.

Threat model and requirements: `docs/ai-pipeline-threat-model.md`.

## Platform handling (realizes 6)

Install side by side, never touching the system interpreter: Homebrew on macOS;
the distro-native manager (dnf/apt/pacman) plus user-isolated `pipx` on Linux.
Ansible is a pipx app on both platforms (never system-Python site-packages), and
`pass-cli` on Linux lands in `~/.local/bin` via Proton's installer. Adding a
vendor repo where a tool has no base-repo package (GitHub CLI on Fedora-family)
is acceptable and best-effort.

## Safety stance (realizes 2)

Concretely, how detect → decide → never-clobber shows up:

- **SSH keys**: if the local file's public key matches Pass, no-op; if it
  differs, halt and report — never replace.
- **Git working trees**: `git fetch` and `git status`; never `git reset --hard`,
  never `force: yes`. Locally-evolved state is the operator's.
- **Existing config files** (`~/.ansible.cfg`, shell rc, etc.): edit in place via
  `community.general.ini_file` or block-marker patterns — never overwrite with
  full-file templates that would clobber user content.
- **The workspace dir's `.git`**: three-case logic in stage 06 — trust if it
  points at the expected remote; lay down if absent (non-destructively onto a
  populated dir); fatal-bail on unexpected remote.

## `keys/` scripts vs `setup.sh`

`setup.sh` is the unattended bootstrap. `keys/*.sh` are manually triggered
utilities that *populate* or *rotate* the contents of `Setup Keys` (per the
boundary above, never invoked from the bootstrap flow):

- `rotate-github-pat.sh` — open browser, mint new PAT, store in Pass
- `rotate-vault-password.sh` — generate new ansible-vault password, store in Pass
- `adopt-ssh-keys.sh` — copy local SSH keys (matching the naming policy) into Pass

Each is self-documenting via `--help`. Operations needing human input (browser
PAT mint, generation choices) belong here, not in `setup.sh`.

## Conventions

- **Shell**: `set -uo pipefail` only (deliberately *not* `-e` — it conflicts
  with error isolation in batch tool installs).
- **Console output**: severity-tagged, prefixed `✗ / ! / →`.
- **Task files**: two-digit numbering (`01-discover.yml`, `02-ssh-keys.yml`, …).
- **Ansible modules**: FQCN (`ansible.builtin.command`, `community.general.ini_file`).
- **Secrets**: `no_log: true` on every task that touches a secret value.
- **YAML files**: end with `...` (document-end marker; makes truncation visible).
- **Commit authorship**: authors are responsible for their commits, not the
  tools used to produce them — no AI co-authorship lines. Enforced by
  `.githooks/commit-msg`; after cloning, run
  `git config core.hooksPath .githooks` once to activate it.

## Releases

Annotated tags carry the release notes — no CHANGELOG file, no GitHub Release
objects (GitHub renders the tag message). Semver `vMAJOR.MINOR.PATCH`.

1. Bump the pinned-version examples in README.md to the new tag.
2. Commit; push master.
3. `git tag -a vX.Y.Z` (notes in the message); `git push origin vX.Y.Z`.

Entry URL per ref (deterministic, live once the tag is pushed):
`https://raw.githubusercontent.com/sakaal/setup/<ref>/setup.sh`

## Notes

- `legacy/` is a frozen 2018 snapshot, kept for reference only — leave it
  untouched.
