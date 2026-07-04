# setup — Claude Code Context

Personal workspace bootstrap for a fresh Mac or Linux machine.
User-facing description in [README.md](README.md). This file carries the
hidden constraints and gotchas Claude needs to be useful here.

## Two-layer secret model

1. **Proton Pass vault `Setup Keys`** (master, manually unlocked once per machine)
2. **Ansible Vault** — its password is one of the items in `Setup Keys`,
   exposed via `~/.ansible/vault-password.sh` so any vault-encrypted
   file decrypts transparently after bootstrap.

Bootstrap reads from Pass and deploys to disk; never the reverse. The
unattended path consumes only Pass-resident truth — nothing on disk is
authoritative without a Pass-side counterpart.

## `Setup Keys` discovery dispatch table

Items are dispatched by name pattern. The discovery stage extracts only
titles (passwords stay inside `pass-cli`) so register variables and
ansible callback plugins never carry secrets.

| Item-name pattern   | Pass type | Deploy target |
|---------------------|-----------|---------------|
| `id_*`              | SshKey    | `~/.ssh/<title>` (mode 0600) + `<title>.pub` (0644) |
| `github-pat`        | Login     | `~/bin/git-credential-github` + git config + `gh auth login --with-token` |
| `vault_pass-*`      | Login     | `~/.ansible/vault-password.sh` (parameterized) + `~/.ansible.cfg` `vault_identity_list` |
| _anything else_     | —         | ignored; logged as a warning |

Vault ID for `vault_pass-*` items is the title with the `vault_pass-`
prefix stripped (`vault_pass-sam_setup_26` → vault id `sam_setup_26`).

## Invocation modes and self-bootstrap

`setup.sh` supports two invocation modes, both reaching the same end state:

1. **Curl-piped one-liner** (`/bin/bash -c "$(curl -fsSL …/setup.sh)"`)
   — primary entry. The script runs from stdin (never written to
   disk). It installs Command Line Tools on a fresh Mac (sudo prompt)
   so `git` is available, then clones the repo to `$SETUP_DIR`
   (default `~/setup`) and re-execs from the clone. An existing
   `$SETUP_DIR` is reused only if it is a setup working copy; anything
   else halts, telling the user to set `SETUP_DIR`. `SETUP_REF` env
   var selects the git ref (default `master`).
2. **Local clone** (`./setup.sh` from any directory with the playbook
   alongside) — runs in place, wherever the clone lives; `SETUP_DIR`
   is ignored.

There is no fixed install location — both modes end running from **a
real git working copy**, and everything downstream is location-agnostic.

`setup.sh` also takes one **optional positional argument** overriding the
default workspace manifest repo (any SSH/HTTPS transport git understands).
It lands at `~/<repo-basename>/`, derived once as `workspace_dir` in
`setup.yml`; stages 06/07/09 build every path from it. The argument is
forwarded verbatim through the self-bootstrap re-exec (`"$@"`) and passed to
Ansible as the `workspace_repo` extra-var (highest precedence). Through the
curl one-liner it goes after a `$0` placeholder: `… setup.sh)" setup <repo>`.
Stage 06 normalizes both the desired repo and any existing origin to
`host/owner/repo` before comparing, so the trust/halt decision is
transport-agnostic.

**Why git clone (after CLT) and not curl + tar**: the user wants the
install to be a real git working tree so `git pull`, `git status`, and
`git tag --verify` work as standard operations on it. The entry
transport is curl (so the one-liner needs no git), but once running we
install CLT (whose git is sufficient for the clone) and use it. Sources
stay in a git repo on github.com; tag pinning and GPG-signed tags work
via standard git operations on the resulting working copy.

## Location independence

All playbook deploy targets are absolute (`$HOME/<workspace_dir>/`,
`$HOME/.ssh/`, `$HOME/.ansible/`, `$HOME/bin/`). The playbook's only
self-reference is `playbook_dir` (stage 02's origin switch on the
running clone), so the stages are unaffected by where setup lives.
The whitelist `.gitignore` in the workspace repo ignores every sibling
directory, so a setup clone placed inside the workspace directory is
invisible to its git tracking.

When working in this repo, do not introduce paths or assumptions that
require setup to live at any particular spot. If you need the script's
own directory, use `$SCRIPT_DIR` (resolved early in `setup.sh`).

## Repo layout

```
setup.sh           Bash entry point — installs prereqs, hands off to ansible
setup.yml          Ansible orchestrator — imports tasks/01..09 sequentially
hosts.yml          Localhost-only inventory
tasks/NN-name.yml  Per-stage task files; numbered with two digits
files/             Static files deployed verbatim by stages
keys/              Manually-triggered utility scripts (NOT in unattended path)
legacy/            2018 version of this repo; preserved for reference; do not modify
README.md          User-facing
.gitignore         Minimal
```

## Conventions

- **Shell**: `set -uo pipefail` only (deliberately *not* `-e` — it conflicts
  with error isolation in batch tool installs)
- **Console output**: severity-tagged (`FATAL` / `ERROR` / `WARN` / `INFO`)
  prefixed with `✗ / ! / →` — no JSON, no OTel, no run-id correlation
- **Task files**: two-digit numbering (`01-discover.yml`, `02-ssh-keys.yml`, ...)
- **Ansible modules**: FQCN (`ansible.builtin.command`, `community.general.ini_file`)
- **Secrets**: `no_log: true` on every task that touches a secret value
- **YAML files**: end with `...` (document end marker; makes truncation visible)

## Releases

Annotated tags carry the release notes — no CHANGELOG file, no GitHub
Release objects (GitHub renders the tag message). Semver `vMAJOR.MINOR.PATCH`.

1. Bump the pinned-version examples in README.md to the new tag.
2. Commit; push master.
3. `git tag -a vX.Y.Z` (notes in the message); `git push origin vX.Y.Z`.

Entry URL per ref (deterministic, live once the tag is pushed):
`https://raw.githubusercontent.com/sakaal/setup/<ref>/setup.sh`

## Safety stance

The bootstrap is non-destructive by default. Detect → decide → never
blanket-overwrite:

- **SSH keys**: if the local file's public key matches Pass, no-op. If it
  differs, halt and report — never replace.
- **Git working trees**: `git fetch` and `git status`; never `git reset --hard`,
  never `force: yes`. Locally-evolved state is the user's.
- **Existing config files** (`~/.ansible.cfg`, shell rc, etc.): edit
  in-place via `community.general.ini_file` or block-marker patterns —
  never overwrite with full-file templates that would clobber user content.
- **The workspace dir's `.git`** has three-case logic in stage 06: trust if
  pointing at the expected remote; lay down if absent (non-destructively
  onto a populated dir); fatal-bail on unexpected remote.

## `keys/` scripts vs `setup.sh`

`setup.sh` is the unattended bootstrap. `keys/*.sh` are manually triggered
utilities that *populate* or *rotate* the contents of `Setup Keys`:

- `rotate-github-pat.sh` — open browser, mint new PAT, store in Pass
- `rotate-vault-password.sh` — generate new ansible-vault password, store in Pass
- `adopt-ssh-keys.sh` — copy local SSH keys (matching the naming policy) into Pass

Each is self-documenting via `--help`. They are never invoked from the
bootstrap flow — operations that require human input (browser PAT mint,
generation choices) belong here, not in `setup.sh`.

## What NOT to add

- **No org-grade observability** — JSON Lines logging, OTel fields,
  run-id correlation. Personal scope; severity-tagged console output is enough.
- **No automatic key generation, PAT rotation, or vault-password rotation
  in the bootstrap path** — those are explicit, manual operations under `keys/`.
- **No references to other organizations or projects** — this repo stands
  alone. Conventions cherry-picked from elsewhere are adopted on their
  own merit, without attribution.
- **No platform-default modifications** — never edit system Python or system
  bash. Install side-by-side: Homebrew on macOS; the distro-native manager
  (dnf/apt/pacman) plus user-isolated `pipx` on Linux. Ansible is a pipx app
  on both platforms (never system-Python site-packages), and `pass-cli` on
  Linux lands in `~/.local/bin` via Proton's installer — nothing touches the
  system interpreter. Adding a vendor repo where a tool has no base-repo
  package (GitHub CLI on Fedora-family) is acceptable and best-effort.
- **No bootstrap dependency on user-managed services** — bootstrap entry
  points anchor only on external services (`github.com`, Proton, Apple,
  Homebrew, the distro's package mirrors). Anything the bootstrap configures
  downstream cannot be upstream of it.
