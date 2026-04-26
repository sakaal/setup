# setup

Personal workspace bootstrap for a fresh Mac or Linux machine.

Installs developer tools, deploys SSH keys and credentials from Proton Pass,
clones the workspace manifest, and populates `~/workspace/` with the user's
project repos.

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
   that `git` is available, then `git clone`s sakaal/setup into
   `~/workspace/setup`. The canonical install is therefore always a
   real git working copy — `git pull`, `git status`, `git tag --verify`
   work as standard.
3. Re-executes from `~/workspace/setup/setup.sh` and continues with the
   remaining prereqs, Pass authentication, and the ansible playbook.

Then type your Proton Pass master password + TOTP once when prompted
(plus your sudo password on a fresh Mac if Command Line Tools need
installing). After that, the bootstrap runs unattended.

Re-running with the same one-liner is safe and idempotent — existing
state is detected and only what is missing or out of date is changed.

### Pinning to a release tag

Both the entry script and the tarball it fetches are addressed by git
ref. To pin both to a specific tag, set `SETUP_REF` and use the matching
URL:

```sh
SETUP_REF=v1.0 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/v1.0/setup.sh)"
```

Tags are immutable refs. When a release is GPG-signed, you can
`curl … sha256sums.txt` (or equivalent) and verify the entry script's
hash before running. Both pinning and signature verification rest on
the git host's own conventions — no extra tooling in this repo.

### Local clone (alternative entry)

If you've already cloned the repo (e.g. for development), `./setup.sh`
inside the clone works too. It detects whether it's at the canonical
location (`~/workspace/setup`) and auto-relocates if not, preserving
any uncommitted changes during the move.

You'll be prompted once for your Proton Pass master credentials and (on a
fresh Mac) once for your sudo password. After that the script runs
unattended.

Re-running `setup.sh` is safe and idempotent — it detects existing state
and only fills in what's missing or out of date.

## What it does

1. Installs Command Line Tools (macOS) if missing.
2. Installs Homebrew if missing.
3. Installs `git`, `ansible`, `gh`, `pass-cli` via Homebrew.
4. Logs in to Proton Pass via `pass-cli login` (interactive, one-time).
5. Discovers items in your `Setup Keys` Pass vault and deploys them:
   - `id_*` items → SSH keypairs in `~/.ssh/`
   - `github-pat` → GitHub PAT helper for `git` and `gh`
   - `vault_pass-*` items → Ansible Vault password identity (script-based)
6. Lays the workspace manifest repo onto `~/workspace/`.
7. Clones the repos listed in `workspace.repos` as siblings under `~/workspace/`.

## Repository layout

```
setup.sh           Entry point — installs prerequisites, hands off to ansible
setup.yaml         Ansible orchestrator — imports tasks/01..06 sequentially
hosts.yaml         Localhost-only inventory
tasks/             Per-stage task files (01-discover ... 06-repos)
templates/         Jinja2 templates rendered by stages
keys/              Manually-triggered utility scripts (rotate-github-pat,
                   rotate-vault-password, adopt-ssh-keys)
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
