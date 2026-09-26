# Cloud-session scenario

Status: proposed.

Setup serves two operating scenarios. The **local host** is the operator's own
Mac or Linux machine, bootstrapped by the `setup.sh` one-liner in the README. A
**cloud session** is a hosted AI agent's container whose platform runs an
operator-supplied setup script before the agent starts (Claude Code on the web
is one such platform); the agent's tool, enrolled in `agent-map.json`, is the
container's **owning tool**. This document specifies the cloud-session
scenario: what it delivers, its entry point, how it shares the wiring engine
with the local host, and where the operator's personal settings live.

## Scope

**CLOUD-SCOPE**: A cloud session receives the operator's AI-assistant
configuration and nothing else: the workspace repo, the `~/.config/ai/` hub
linked into its `ai/`, and user-scope wiring for every enrolled tool present in
the container, MCP servers excepted (CLOUD-MCP). Everything else the local host
receives — SSH keys, the GitHub PAT, the vault password, packages, shell
environment, the repos listed in `workspace.repos` — stays with the local host,
because the platform already provides the container's tooling and GitHub
access, and the session's own repos are the ones the platform attaches.

The two scenarios are separate deliverables, each with its own scope, audience
and threat model:

| | Local host | Cloud session |
|---|---|---|
| Entry | `setup.sh` one-liner, run by the operator | one-liner in the platform's setup-script field |
| Runs | on demand, operator present | at environment build and each session start, unattended |
| Secrets | Proton Pass, then Ansible Vault | none consumed |
| GitHub access | SSH key and PAT from Pass | the platform's authenticated proxy |
| Installs | tools, packages, credentials | nothing |
| On divergence | halts and reports | reports and continues; `cloud.sh` exits 0 |
| Delivers | the full environment | AI-assistant configuration only |

## Entry point

**CLOUD-ENTRY**: The platform's setup-script field holds a one-liner that
fetches `cloud.sh` from this repo at a pinned ref, mirroring the local host's
fully pinned one-liner:

```bash
SETUP_REF=vX.Y.Z /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/vX.Y.Z/cloud.sh)"
```

An optional positional argument overrides the workspace repo
(CLOUD-WORKSPACE-REPO), after a `$0` placeholder as with `setup.sh`:

```bash
SETUP_REF=vX.Y.Z /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sakaal/setup/vX.Y.Z/cloud.sh)" cloud https://github.com/youruser/my-projects
```

The logic lives in the repo and evolves with `agent-map.json`; the one-liner
changes only to move to a newer tag.

**CLOUD-STEPS**: `cloud.sh` performs, in order:

1. Clone this repo at `SETUP_REF` into `$SETUP_DIR` (default `~/setup`), or
   fast-forward an existing clone of it; any other content at that path is
   reported and left alone.
2. Clone the workspace repo into `~/<workspace_dir>`, or fast-forward an
   existing clone whose origin matches, comparing origins with the same
   `host/owner/repo` normalization as stage 06. The clone uses HTTPS, which the
   platform's proxy authenticates; an SSH-form repo argument or default is
   translated to its HTTPS equivalent. `WORKSPACE_DIR` overrides the directory
   name as on the local host.
3. Deploy `agent-map.json` into the hub and run the shared wiring engine
   (CLOUD-WIRING) from the setup clone; the wiring includes the session-start
   hook (CLOUD-REFRESH).
4. Check the expected variables (CLOUD-CREDENTIALS).
5. Report each outcome as `→` / `!` / `✗` lines, and exit 0 on every path so no
   problem blocks the session.

**CLOUD-REFRESH**: Every session start runs `cloud.sh` again from the setup
clone, through the owning tool's session-start hook. The platform runs the
setup script only when it builds an environment, and may reuse a built
environment across sessions; without the refresh, the workspace clone lags the
repo. The refresh is the same idempotent sequence: it fast-forwards both clones
(the setup clone stays at `SETUP_REF`), re-applies the wiring and re-checks the
variables, with network steps bounded by a timeout so a slow host delays the
session only briefly. The hub links into the workspace clone, so the
fast-forward refreshes every tool at once. Instructions a tool loads before its
session-start hook runs take effect from the following session; files the agent
reads on demand, such as the rules, are current at once.

The hook is registered by a distribute entry per tool in `agent-map.json`:
class `session-start`, method `generate`, whose shared source is the refresh
command rather than a hub file, with an `ai-sync` emitter for the tool's
settings format (for Claude Code, a `SessionStart` hook matching `startup` and
`resume` in `~/.claude/settings.json`). The entry carries `scenarios:
["cloud"]`. The `scenarios` field names the scenarios an entry applies to —
`local` for the local host, `cloud` for a cloud session — and an entry without
it applies to both. The refresh hook is cloud-only because on the local host
the workspace clone is the operator's working copy. A platform that skips
session-start hooks still gets the build-time run; Claude Code on the web
documents, as read on 2026-09-26, that it skips them in sessions with more than
one repository.

## Shared wiring engine

**CLOUD-WIRING**: The hub build and every distribute-lane wiring method run in
one engine, `ai-sync`, shared by both scenarios. At v2.6.0 the work is split:

- stage 09 (Ansible) links the hub (`09-ai-config.yml`) and applies the `link`
  and `import` entries (`09-ai-wire-one.yml`);
- `ai-sync` (stdlib Python) applies the `generate` and `wrap` entries.

`ai-sync` absorbs the hub build and the `link`/`import` methods with the same
decision table stage 09 applies: an absent path, or an empty file, is created;
the correct link or stub is a no-op; anything else is a conflict, reported and
never touched. Stage 09 keeps installing the tools and deploying `ai-sync`,
`ai-harvest`, `ai-distill` and the manifest, then calls `ai-sync` and halts
when it reports a conflict. `cloud.sh` calls the same `ai-sync` and reports its
conflicts, still exiting 0.

Tool selection stays data-driven: an entry applies when its tool's `detect`
directory exists and its `scenarios` include the running one, so a container is
wired for whichever enrolled tools it has. The container needs no Ansible,
since `ai-sync` depends only on Python's standard library.

**CLOUD-MCP**: The MCP entries (class `mcp`) carry `scenarios: ["local"]`, so a
cloud session starts without the servers in `mcp.json`. Those servers are
configured for the local host and may depend on binaries or credentials a
container lacks, and a server that cannot start fails again in every session.
The hub still links `mcp.json`; no tool in a cloud session is wired to it.

Workspace-scope entries do not apply in a cloud session: the platform clones
the session's repos outside `~/<workspace_dir>`, so no workspace-root
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

These variables take precedence over every git configuration file, so they
survive the platform's own git configuration: on Claude Code on the web, as
observed on 2026-09-26, the container rewrites `~/.gitconfig` with the
platform's identity at container start and again when a session resumes, and a
resume does not re-run the setup script. The precedence also scopes the
identity to the environment, which matches how an operator separates identity
contexts: one environment per context (personal, each employer), each authoring
under its own name.

The values are personal content, so this repo names the variables and nothing
more; the README's cloud section shows them with placeholders. The four are
always expected variables (CLOUD-CREDENTIALS), since commits made without them
carry the platform's identity.

**CLOUD-CREDENTIALS**: Each run names every expected variable the environment
lacks, so that before making a request the operator knows which requests will
fail for want of access, and which variable to add. The expected set is the
four identity variables (CLOUD-IDENTITY) and the credential variables the
workspace repo declares in a `.env.example` at its root, the dotenv convention
for listing a project's variables; the platform's environment-variable field
takes the same `NAME=value` format, so the file doubles as the checklist for
filling it in. Each declaration is a `NAME=` line, and the comment line
directly above it states what the credential grants:

```
# GitHub API for the gh CLI (read-only token)
GH_TOKEN=
```

A variable counts as present when it is set and non-empty. The check reads
presence only; no value is printed or logged. Each missing variable is reported
as `! missing environment variable NAME — <purpose>`, the purpose taken from
its comment. A declaration line carrying a value is reported as an error,
without echoing the value, because the file is committed; a line whose name is
not a valid variable name is reported and skipped. An environment whose
one-liner names a different workspace repo checks that repo's declarations, so
each identity context declares its own expected set.

The report reaches the operator by two paths. The build-time run writes it to
the platform's setup log. The session-start run returns it to the owning tool
as context for the agent — the documented channel (for Claude Code, the hook's
`additionalContext`) — and as a user-facing message where the client displays
one. With the missing names in context, the agent tells the operator at the
start of the session and names the missing variable when a request depends on
it. A variable added in the environment's settings reaches sessions started
afterwards, whose check then passes.

**CLOUD-WORKSPACE-REPO**: The workspace repo defaults to the same repo as on
the local host (`workspace_repo` in `setup.yml`), overridden by the one-liner's
positional argument.

## Invariants

How the cloud-session scenario keeps each invariant in `AGENTS.md`:

1. **Single source for secrets** — it consumes no secrets; GitHub access is the
   platform's, and the credential check reads only whether a variable is set.
2. **Non-destructive & idempotent** — the same detect → decide → never-clobber
   decision table; re-running changes only what is missing or stale.
3. **Anchor only upstream** — it depends on the git host and the hosting
   platform, neither of which it configures.
4. **No fixed home** — `SETUP_DIR` and `WORKSPACE_DIR` apply as on the local
   host.
5. **Public mechanism, private content** — `cloud.sh` and the one-liner are
   mechanism; the workspace repo and the values of the identity and credential
   variables stay private.
6. **Cross-platform, side by side** — containers are Linux, and `cloud.sh`
   installs nothing.
7. **Personal scale** — severity-tagged console output only.
8. **Data-driven where open-ended** — tools and their wiring come from
   `agent-map.json`; no tool is named in `cloud.sh`.
9. **Complete, lane-categorized coverage** — each tool's session-start hook
   joins the distribute lane as a cloud-only entry, the MCP entries are
   local-only, and every other entry applies to both scenarios. Harvest has
   nothing to collect in a cloud session, since the container, with every store
   the tools kept in it, is discarded when the session ends.

The mission statement in `AGENTS.md` and the README's overview widen from "a
fresh personal Mac or Linux machine" to include cloud sessions.

## Changes

- `cloud.sh` — the cloud entry point, beside `setup.sh`.
- `files/ai-sync` — hub build, the `link`/`import` methods, a session-start
  hook emitter, and scenario selection; a conflict yields a non-zero exit.
- `files/agent-map.json` — the `session-start` class and the `scenarios` field
  in the legend, a hook entry per tool that offers one, and `scenarios:
  ["local"]` on the MCP entries.
- `tasks/09-ai-config.yml`, `tasks/09-ai-sync.yml`, `tasks/09-ai-wire-one.yml`
  — hub and wiring replaced by a call to `ai-sync`; tool installs and deploys
  unchanged.
- `tests/test-ai-sync.sh` — the decision table, the hub build, scenario
  selection and the hook emitter, in a mktemp home, alongside the existing
  script tests.
- `tests/test-cloud.sh` — the credential check (missing, present, a committed
  value, an invalid name) with no value ever in the output.
- `AGENTS.md` and `README.md` — the two scenarios, the cloud one-liner, the
  identity variables and `.env.example`, and the verification commands for the
  new tests.
- The workspace repo — a `.env.example` declaring its expected credentials,
  and its whitelist entry in `.gitignore`.

## Open questions

**OPEN-USER-SETTINGS**: CLOUD-REFRESH relies on the owning tool honoring
user-level settings that the setup script writes inside the container before
the tool starts. Claude Code's documentation, as read on 2026-09-26, states
that the operator's machine-level settings do not carry over to cloud sessions,
and does not cover a settings file created inside the container. The first
implementation step verifies it; if the tool ignores such a file, the refresh
has no hook, and the build-time run remains the only one.
