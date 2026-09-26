# Cloud sessions as a second target

Status: proposed.

Setup serves two targets. The **local host** is the operator's own Mac or
Linux machine, bootstrapped by the `setup.sh` one-liner in the README. A
**cloud session** is a hosted AI agent's container whose platform runs an
operator-supplied setup script before the agent starts (Claude Code on the web
is one such platform). This document specifies the cloud-session target: what
it delivers, its entry point, how it shares the wiring engine with the local
host, and where the operator's personal settings live.

## Scope

**CLOUD-SCOPE**: A cloud session receives the operator's AI-assistant
configuration and nothing else: the workspace repo, the `~/.config/ai/` hub
linked into its `ai/`, and user-scope wiring for every enrolled tool present in
the container. Everything else the local host receives — SSH keys, the GitHub
PAT, the vault password, packages, shell environment, the repos listed in
`workspace.repos` — stays with the local host, because the platform already
provides the container's tooling and GitHub access, and the session's own
repos are the ones the platform attaches.

The two targets are separate deliverables, as a workstation bootstrap and an
unattended provisioning path are, because they differ in scope, audience and
threat model:

| | Local host | Cloud session |
|---|---|---|
| Entry | `setup.sh` one-liner, run by the operator | stub in the platform's setup-script field |
| Runs | on demand, operator present | at container build, unattended |
| Secrets | Proton Pass, then Ansible Vault | none |
| GitHub access | SSH key and PAT from Pass | the platform's authenticated proxy |
| Installs | tools, packages, credentials | nothing |
| On divergence | halts and reports | reports and continues; the hook exits 0 |
| Delivers | the full environment | AI-assistant configuration only |

## Entry point

**CLOUD-ENTRY**: The platform's setup-script field holds a one-line stub that
fetches `cloud.sh` from this repo at a pinned ref, mirroring the local host's
fully pinned one-liner:

```bash
SETUP_REF=vX.Y.Z /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/vX.Y.Z/cloud.sh)"
```

An optional positional argument overrides the workspace repo, after a `$0`
placeholder as with `setup.sh`:

```bash
… cloud.sh)" cloud https://github.com/youruser/my-projects
```

The logic lives in the repo and evolves with `agent-map.json`; the stub
changes only to move to a newer tag.

**CLOUD-STEPS**: `cloud.sh` performs, in order:

1. Clone this repo at `SETUP_REF` into `$SETUP_DIR` (default `~/setup`), or
   fast-forward an existing clone of it; any other content at that path is
   reported and left alone.
2. Clone the workspace repo into `~/<workspace_dir>`, or fast-forward an
   existing clone whose origin matches, using the same `host/owner/repo`
   normalization as stage 06. The clone uses HTTPS, which the platform's proxy
   authenticates; an SSH-form repo argument or default is translated to its
   HTTPS equivalent. `WORKSPACE_DIR` overrides the directory name as on the
   local host.
3. Deploy `agent-map.json` into the hub and run the shared wiring engine
   (below) from the setup clone.
4. Report each outcome as `→` / `!` / `✗` lines and exit 0 on every path, so a
   problem is visible in the platform's setup log without blocking the
   session.

## Shared wiring engine

**CLOUD-WIRING**: The hub build and every distribute-lane wiring method run in
one engine, `ai-sync`, shared by both targets. At v2.6.0 the work is split:

- stage 09 (Ansible) links the hub (`09-ai-config.yml`) and applies the `link`
  and `import` entries (`09-ai-wire-one.yml`);
- `ai-sync` (stdlib Python) applies the `generate` and `wrap` entries.

`ai-sync` absorbs the hub build and the `link`/`import` methods with the same
decision table stage 09 applies: an absent target, or an empty file, is
created; the correct link or stub is a no-op; anything else is a conflict,
reported and never touched. Stage 09 keeps installing the tools and deploying
`ai-sync`, `ai-harvest`, `ai-distill` and the manifest, then calls `ai-sync`
and halts when it reports a conflict. `cloud.sh` calls the same `ai-sync` and
reports its conflicts without failing the hook.

Tool selection stays data-driven: an entry applies when its tool's `detect`
directory exists, so a container is wired for whichever enrolled agent owns it.
The container needs no Ansible, since `ai-sync` depends only on Python's
standard library.

Workspace-scope entries do not apply in a cloud session: the platform checks
the session's repos out outside `~/<workspace_dir>`, so no workspace-root
instruction file sits above them. The user-scope instruction entry carries
`AGENTS.md`, which points the agent at the rules under `~/.config/ai/rules/`.

## Operator settings

**CLOUD-IDENTITY**: The git author and committer identity is set per cloud
environment, through the platform's environment variables:

```
GIT_AUTHOR_NAME=<name>
GIT_AUTHOR_EMAIL=<email>
GIT_COMMITTER_NAME=<name>
GIT_COMMITTER_EMAIL=<email>
```

These variables take precedence over every git configuration file, which makes
them the one setting that survives the platform's own git configuration: on
Claude Code on the web, as observed on 2026-09-26, the container rewrites
`~/.gitconfig` with the platform's identity at container start and again when
a session resumes, and a resume does not re-run the setup script. The
precedence also scopes the identity to the environment, which matches how an
operator separates identity contexts: one environment per context (personal,
each employer), each authoring under its own name.

The values are personal content, so this repo names the variables and nothing
more; the README's cloud section shows them with placeholders. `cloud.sh`
reports a warning when the variables are unset, since commits would then carry
the platform's identity.

**CLOUD-WORKSPACE-REPO**: The workspace repo defaults to the same repo as on
the local host (`workspace_repo` in `setup.yml`), overridden by the stub's
positional argument.

## Invariants

How the cloud target keeps each invariant in `AGENTS.md`:

1. **Single source for secrets** — it consumes no secrets; GitHub access is the
   platform's.
2. **Non-destructive & idempotent** — the same detect → decide → never-clobber
   decision table; re-running changes only what is missing or stale.
3. **Anchor only upstream** — it depends on the git host and the hosting
   platform, neither of which it configures.
4. **No fixed home** — `SETUP_DIR` and `WORKSPACE_DIR` apply as on the local
   host.
5. **Public mechanism, private content** — `cloud.sh` and the stub are
   mechanism; the workspace repo and the identity values stay private.
6. **Cross-platform, side by side** — containers are Linux, and the target
   installs nothing.
7. **Personal scale** — severity-tagged console output only.
8. **Data-driven where open-ended** — tools and their wiring come from
   `agent-map.json`; no tool is named in `cloud.sh`.
9. **Complete, lane-categorized coverage** — unchanged: the manifest describes
   the tools, not the targets. Harvest has nothing to collect in a cloud
   session, since the container, with every store the tools kept in it, is
   discarded when the session ends.

The mission statement in `AGENTS.md` and the README's overview widen from "a
fresh personal Mac or Linux machine" to include cloud sessions.

## Changes

- `cloud.sh` — the cloud entry point, beside `setup.sh`.
- `files/ai-sync` — hub build and the `link`/`import` methods; a conflict
  yields a non-zero exit.
- `tasks/09-ai-config.yml`, `tasks/09-ai-sync.yml`, `tasks/09-ai-wire-one.yml`
  — hub and wiring replaced by a call to `ai-sync`; tool installs and deploys
  unchanged.
- `tests/test-ai-sync.sh` — the decision table and the hub build, in a mktemp
  home, alongside the existing script tests.
- `AGENTS.md` and `README.md` — the two targets, the cloud stub, and the
  identity variables.

## Open questions

**OPEN-FRESHNESS**: The platform may reuse a built environment across sessions,
and the setup script runs only when the environment is built, so the workspace
clone can lag the repo. The hub links into the clone, so a fast-forward
refreshes every tool at once. Whether that fast-forward also needs to run at
each session start — through a session-start hook the platform offers — is
open.

**OPEN-MCP**: The `mcp.json` servers are configured for the local host and may
depend on binaries or credentials a container lacks; wiring them into a cloud
session would start servers that fail. Whether the cloud target skips the MCP
entries, or the manifest marks servers per target, is open.

**OPEN-ENTRY-NAME**: `cloud.sh` names the entry point by its target; whether
another name serves better beside `setup.sh` is open.
