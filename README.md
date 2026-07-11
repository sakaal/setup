# setup

Personal workspace bootstrap for a fresh Mac or Linux machine — developer
tools, keys, projects, and every AI coding agent configured from one command.

Installs the toolchain, deploys SSH keys and credentials from Proton Pass,
populates the workspace directory (`~/<repo-name>/`) with your project
repos, and gives your agentic AI tools — Claude Code, Codex CLI, Gemini CLI,
Cursor, GitHub Copilot — one shared, agent-neutral configuration: a single
`AGENTS.md` for instructions and a single `mcp.json` for MCP servers,
version-controlled in your private workspace repo and linked into each
tool's own config location. Use any agent, or all of them side by side —
they read the same brief. Adopt a new one or drop one without reconfiguring
anything.

Your agent brief stays private: the instructions and server list live in
your own repo, not in public dotfiles — this repo ships only the mechanism.

It also closes the loop: a harvest-and-distill workflow turns what your
agents *learn* — the memories and notes they accumulate as you work — back
into that shared brief, as reusable, generalized instructions. See
[Distilling learned knowledge](#distilling-learned-knowledge) below.

## Quick start

Prerequisite: install the Proton Pass desktop app and sign in.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/master/setup.sh)"
```

That one line:
1. Fetches `setup.sh` over HTTPS from `raw.githubusercontent.com` and
   runs it from stdin (the script is never written to disk in this
   form).
2. On a fresh Mac, installs Command Line Tools (one sudo prompt) so
   that `git` is available, then clones the repo to `~/setup` (see
   below to choose another location). The install is therefore always
   a real git working copy — `git pull`, `git status`, `git tag
   --verify` work as standard.
3. Re-executes from the clone and continues with the remaining
   prereqs, Pass authentication, and the ansible playbook.

Then type your Proton Pass master password + TOTP once when prompted
(plus your sudo password on a fresh Mac if Command Line Tools need
installing). After that, the bootstrap runs unattended.

Re-running with the same one-liner is safe and idempotent — existing
state is detected and only what is missing or out of date is changed.

### Using a different workspace repo

To use your own manifest repo instead of the default, pass its remote as an
optional argument. The repo lands under your home directory by its own name
(basename minus `.git`, like `git clone`). Through the curl one-liner the
argument goes after a `$0` placeholder (here `setup`):

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/master/setup.sh)" setup https://github.com/youruser/my-projects.git
```

Any transport git understands works — SSH (`git@host:owner/repo.git`) or
HTTPS. The bootstrap assumes your git/SSH client is already configured to
reach it; it just hands git the reference.

### Choosing the install location

The one-liner installs its clone to `~/setup`. If that path is already
occupied by something else, the script halts without touching it. Set
`SETUP_DIR` at the front of the line to install elsewhere:

```sh
SETUP_DIR=~/workspace/setup /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/master/setup.sh)"
```

Multiple environment variables combine space-separated on the same line:

```sh
SETUP_DIR=~/workspace/setup SETUP_REF=v2.2.1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/master/setup.sh)"
```

### Pinning to a release tag

`SETUP_REF` pins what gets installed: the entry script clones that ref
and re-executes from the clone, so everything past the initial
bootstrap runs the pinned version:

```sh
SETUP_REF=v2.2.1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/master/setup.sh)"
```

The ref in the URL (`master` above) selects only the entry script
itself, which cannot know which URL it came from — so pinning the URL
alone still installs `master`. For an end-to-end pin, including the
entry script, set both to the same tag:

```sh
SETUP_REF=v2.2.1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/v2.2.1/setup.sh)"
```

Tags are immutable refs. When a release is GPG-signed, you can
`curl … sha256sums.txt` (or equivalent) and verify the entry script's
hash before running. Both pinning and signature verification rest on
the git host's own conventions — no extra tooling in this repo.

### Local clone (alternative entry)

If you've already cloned the repo — anywhere you like, including inside
your workspace directory — `./setup.sh` runs in place. There is no fixed
install location; `SETUP_DIR` only tells the one-liner where to put (or
find) its own clone, and is ignored when you run from a working copy.

## What it does

1. Installs the platform's build tools if missing — Command Line Tools on
   macOS, `git` via the distro package manager on Linux.
2. Installs the tool chain per platform:
   - **macOS**: Homebrew, then `git`, `gh`, `pass-cli`, and `pipx` via brew.
   - **Linux** (Fedora-family / dnf primary; apt and pacman also handled):
     `git`, `gh`, `pipx`, and base packages via the distro manager, and
     `pass-cli` via Proton's official installer into `~/.local/bin`.
   - **Both**: Ansible is installed via `pipx` (`--include-deps`), so it
     always ships the `community.general` collection the playbook needs.
3. Logs in to Proton Pass via `pass-cli login` (interactive, one-time).
4. Discovers items in your `Setup Keys` Pass vault and deploys them:
   - `id_*` items → SSH keypairs in `~/.ssh/`
   - `github-pat` → GitHub PAT helper for `git` and `gh`
   - `vault_pass-*` items → Ansible Vault password identity (script-based)
5. Lays the workspace manifest repo onto `~/<repo-name>/` (the optional
   argument overrides the default repo).
6. Clones the repos listed in `workspace.repos` as siblings inside the
   workspace directory.
7. Configures a machine-local baseline: global gitignore, `~/.local/bin` on
   PATH, and AI-assistant wiring. The agent-neutral sources — `ai/AGENTS.md`
   (instructions) and `ai/mcp.json` (MCP server list) — live in the private
   workspace repo, not here; `~/.config/ai/` holds stable symlinks to them.
   A single data-driven manifest, `agent-map.json`, maps every tool/class to
   its path and sync method; both the playbook and `~/bin/ai-sync` read it and
   loop generically, so adding a tool is a manifest edit, not code. Present
   tools are pointed at the hub via symlink/`@import` stub, and `ai-sync`
   renders the MCP list into each tool's own format — add-only, never
   overwriting existing entries. Companions `~/bin/ai-harvest` and
   `~/bin/ai-distill` (deployed, never run by the bootstrap) support the
   learning loop — cataloging each tool's accumulated knowledge and distilling
   it back into the shared sources under human review. See
   [Distilling learned knowledge](#distilling-learned-knowledge).

## Distilling learned knowledge

As you work, your AI tools accumulate knowledge — memories, notes, session
transcripts. Most of it is specific to one project, but some is generalizable
craft ("prefer retry-with-backoff behind gateway APIs", "state a requirement's
standing justification") that would help everywhere. The **distill** workflow
turns that scattered, project-specific knowledge into a small set of reusable,
generalized instructions in your shared agent brief — reviewed by you, never
promoted automatically.

It is a three-part pipeline, all human-gated:

1. **Harvest** — `~/bin/ai-harvest` reads the manifest and catalogs every
   local store your tools keep (memory, transcripts) as a read-only index of
   URLs with checksums under `~/.local/state/ai/harvest/`. It reads content
   only to hash it and writes nothing back.
2. **Distill** — `~/bin/ai-distill prepare` sanitizes and de-duplicates the
   harvested memories into a work package and opens a git worktree of your
   workspace repo on branch `distill/<run>`, off the live path. A
   **human-supervised agent session** (the `distill` plugin) generalizes,
   categorizes, de-duplicates, and triages them, and writes the distilled
   instructions directly into that worktree's `ai/`, refining, adding
   scoped `rules/` files, reorganizing. `~/bin/ai-distill gate` checks the
   branch diff (prose only, no secrets, no leaked project identifiers).
3. **Review & apply** — the git diff of that branch *is* the proposal. You
   review it (approve, or ask for edits the agent makes in the worktree and
   re-gates), and on approval `~/bin/ai-distill apply` merges the branch into
   your live `ai/` and removes the worktree. Nothing
   reaches the live `ai/` un-reviewed, and because apply merges exactly the
   reviewed branch, what lands is exactly what you saw. Suspected injections
   are held in a quarantine pen outside every repo; genuinely valuable
   source-specific finds can be sent to their own repo via the same worktree
   flow (`add-target`).

The scripts are the deterministic guarantees; the plugin is the supervised
judgment in between. The full design and its threat model are in
[`docs/ai-pipeline-threat-model.md`](docs/ai-pipeline-threat-model.md).

### It needs the workspace repo's `ai/`

Distillation writes into the **same private workspace repo** that holds your
shared agent brief — its `ai/` directory (`ai/AGENTS.md`, `ai/rules/…`), the
sources that `setup` distributes to every tool. That is the whole loop: your
tools accumulate knowledge → distill lifts the general part into `ai/` →
`setup` fans `ai/` back out to every tool. So the distill workflow only makes
sense once `setup` has laid down your workspace repo; promotions have nowhere
to land without it.

### Installing the `distill` agent

The distillation session ships as a Claude Code plugin, and this repo is its
marketplace. From a clone of this repo (the `setup` bootstrap leaves one):

```sh
/plugin marketplace add sakaal/setup
/plugin install distill@setup
```

The plugin carries only mechanism — no personal content, no model credentials;
everything it processes is read from your local machine state at run time. Its
inference stages are agent-neutral process wrapped in Claude-specific
packaging (like the per-tool emitters `ai-sync` uses), so the same scripts and
runbook could back a wrapper for another tool later.

### Using it

Run a distillation whenever your tools have accumulated enough new knowledge to
be worth curating:

```
/distill
```

The session runs harvest → prepare, works through the generalize/categorize/
deduplicate/triage stages under the runbook, and writes the distilled `ai/` in
the run's worktree. It then shows you the branch diff (`git -C <worktree>
diff`) — the proposal. You review it interactively (approve, or ask for edits
the agent makes in the worktree and re-gates), and on approval it runs
`ai-distill apply`, which merges the branch into your live `ai/` and cleans up
the worktree. The run is complete when that merge lands; the next `setup` run
(or `ai-sync`) distributes it to every tool.

You can also drive the deterministic parts directly — `ai-harvest`, then
`ai-distill prepare` / `gate` / `apply` (and `discard`, `add-target`) — for
inspection or scripting; the plugin is only needed for the inference stages in
the middle.

## Repository layout

```
setup.sh           Entry point — installs prerequisites, hands off to ansible
setup.yml          Ansible orchestrator — imports tasks/01..09 sequentially
hosts.yml          Localhost-only inventory
tasks/             Per-stage task files (01-discover ... 09-ai-config)
files/             Static files deployed verbatim by stages — includes the
                   agent-map.json manifest and the ai-sync / ai-harvest /
                   ai-distill helper scripts
keys/              Manually-triggered utility scripts (rotate-github-pat,
                   rotate-vault-password, adopt-ssh-keys)
docs/              Design docs (ai-pipeline-threat-model.md)
.claude-plugin/    Marketplace manifest — this repo is a Claude Code marketplace
plugins/distill/   The distill agent plugin (command, skill, agents, hooks)
tests/             Fixture tests for ai-harvest and ai-distill
legacy/            Earlier (2018) version of this repo, kept for reference
```

## Manual operations

The `keys/` directory contains scripts that are *not* part of the unattended
bootstrap path. They're for one-off operations like rotating a credential.
Each script is self-documenting via `--help`.

## Safety

The bootstrap is non-destructive. It will not overwrite SSH keys whose
fingerprints differ from what's in Pass, will not `git reset --hard` over
local changes, and will halt-and-report on any unexpected divergence rather
than silently fixing it. Re-running after fixing a flagged issue picks up
where the previous run left off.
