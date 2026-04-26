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
   so `git` is available, then `git clone`s `sakaal/setup` into
   `~/workspace/setup` and re-execs from there. `SETUP_REF` env var
   selects the git ref (default `master`).
2. **Local clone** (`./setup.sh` from any directory with the playbook
   alongside) — auto-relocates to `~/workspace/setup` via `cp -R` + `mv`
   if not already there, preserving any uncommitted changes and the
   `.git` directory.

Both modes converge on `~/workspace/setup` as the canonical home, **as
a real git working copy**, and re-exec from there. The rest of the
script always runs at the canonical location.

**Why git clone (after CLT) and not curl + tar**: the user wants
`~/workspace/setup` to be a real git working tree so `git pull`,
`git status`, and `git tag --verify` work as standard operations on
the canonical install. The entry transport is curl (so the one-liner
needs no git), but once running we install CLT (whose git is
sufficient for the clone) and use it. Sources stay in a git repo on
github.com; tag pinning and GPG-signed tags work via standard git
operations on the resulting working copy.

## Location independence

All playbook deploy targets are absolute (`$HOME/workspace/`,
`$HOME/.ssh/`, `$HOME/.ansible/`, `$HOME/bin/`). Nothing in the
playbook references the setup repo's location after self-bootstrap, so
the playbook stages are unaffected by where setup originally landed.
The whitelist `.gitignore` in `sakaal/workspace` ignores every sibling
directory, so even if setup lives at `~/workspace/setup/`, it's
invisible to the workspace's git tracking.

When working in this repo, do not introduce paths or assumptions that
require setup to live at any particular spot. If you need the script's
own directory, use `$SCRIPT_DIR` (resolved early in `setup.sh`).

## Repo layout

```
setup.sh           Bash entry point — installs prereqs, hands off to ansible
setup.yaml         Ansible orchestrator — imports tasks/01..06 sequentially
hosts.yaml         Localhost-only inventory
tasks/NN-name.yml  Per-stage task files; numbered with two digits
templates/         Jinja2 templates rendered by stages
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
- **`~/workspace/.git`** has three-case logic in stage 05: trust if
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
- **No platform-default modifications** — never edit system Python, system
  bash, or the platform's package manager configuration. Install
  side-by-side via Homebrew.
- **No bootstrap dependency on user-managed services** — bootstrap entry
  points anchor only on external services (`github.com`, Proton, Apple,
  Homebrew). Anything the bootstrap configures downstream cannot be
  upstream of it.
