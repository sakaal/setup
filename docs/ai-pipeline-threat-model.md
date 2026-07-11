# Threat model — AI-assistant configuration pipeline

Security analysis of the loop by which setup maps AI tools (`agent-map.json`),
fans shared instructions and configuration out to them (distribute), collects
what they accumulate (harvest), and distils it back into the shared sources
(distillation). Grounded in the code as of this writing: `files/agent-map.json`,
`files/ai-sync`, `files/ai-harvest`, `tasks/09-ai-config.yml`,
`tasks/09-ai-sync.yml`, `tasks/09-ai-wire-one.yml`. Distillation is not yet
implemented; §7 states the security requirements it must satisfy, agreed
before any code exists.

Publishing this document is deliberate (Kerckhoffs's principle — the repo
ships mechanism, never the operator's content; the security must not depend
on the mechanism being secret).

## 1. Scope and attacker model

**In scope: the content-borne attacker.** Someone who cannot run code as the
operator but can influence *content* the pipeline touches:

- text the AI tools ingest during normal use — fetched web pages, third-party
  README/code, package metadata, issue threads, tool output — all of which
  ends up verbatim in session transcripts and, after the tool's own
  summarization, in memory stores;
- files in repos the operator clones and works in (repo-scope instruction
  files, committed configuration);
- upstream content of the anchors (a compromised package, a poisoned gist
  behind a pasted URL).

**Out of scope: the code-execution attacker.** An attacker already running
arbitrary code as the operator's user owns the entire control plane —
`~/bin/ai-sync`, `~/bin/ai-harvest`, `~/.config/ai/`, the workspace clone,
the SSH keys — and needs none of this pipeline. Defending that position is
the job of the platform (OS hardening, endpoint security), not of these
scripts. Threats below that *require* user-level code execution are listed
only where the pipeline would make a bad situation durably worse
(persistence, propagation), and are marked accordingly.

**Also in scope:** integrity of the pipeline's own trust anchors (§6), since
the fan-out multiplies whatever they deliver.

## 2. System overview and trust boundaries

```
                        (private git host)
                 ┌────────────────────────────┐
                 │  workspace repo   ai/       │  AGENTS.md, mcp.json,
                 │  (single source of truth)   │  commands/ skills/ agents/
                 └──────┬─────────────▲───────┘
                 clone/pull│           │ reviewed commit only
                        TB1│           │TB4  (human gate)
                 ┌─────────▼──────┐   ┌┴─────────────────┐
                 │ ~/.config/ai/  │   │   distillation    │  hybrid: LLM +
                 │ hub (symlinks  │   │   (future)        │  deterministic
                 │ + agent-map)   │   └──────▲───────────┘  validation
                 └──────┬─────────┘          │ reads catalog + sources
             distribute │TB2                 │TB3
        playbook wiring │                    │
        + ~/bin/ai-sync ▼                    │
      ┌───────────────────────────┐   ┌──────┴───────────────────────┐
      │ per-tool config           │   │ ~/.local/state/ai/harvest/    │
      │ ~/.claude/…  ~/.codex/…   │   │ catalog-*.json (0600, URLs+   │
      │ ~/.gemini/…  ~/.cursor/…  │   │ sha256 only)  ~/bin/ai-harvest│
      └──────┬────────────────────┘   └──────▲───────────────────────┘
             │ tool runs; ingests            │ resolution only,
             ▼ UNTRUSTED WORLD CONTENT       │ read-only
      ┌───────────────────────────┐          │
      │ accumulated knowledge     ├──────────┘
      │ memory/, transcripts,     │   ◄── the poisoned-well zone
      │ history.jsonl             │
      └───────────────────────────┘
```

Trust boundaries:

- **TB1 — anchor → machine.** Git host, SSH key, and PAT deliver the
  workspace repo; the setup repo itself arrives by curl-then-clone. What
  crosses: the shared sources and the pipeline code.
- **TB2 — hub → tools.** Distribution writes into tool-owned paths. What
  crosses: instructions (prose) and MCP server definitions (**command
  lines — executable configuration**).
- **TB3 — accumulated knowledge → distillation.** Everything below this line
  is presumed attacker-influenced: transcripts contain the world's text
  verbatim. This is the poisoned well and the pipeline's principal trust
  boundary.
- **TB4 — distillation → workspace `ai/`.** The only writer to the source of
  truth. What crosses here becomes a standing instruction to every tool on
  every machine. The human review gate lives here and is the hard control.

## 3. Assets

| Asset | Why it matters |
|---|---|
| Workspace `ai/` sources | Instruction-level control of every enrolled AI tool, every machine, every future session |
| `ai/mcp.json` → tool MCP configs | **Arbitrary command execution** — an MCP server entry is a command line every tool will run |
| `agent-map.json` (manifest) | Controls what is distributed where and what is harvested |
| `~/bin/ai-sync`, `~/bin/ai-harvest` | Pipeline code, runs as the operator |
| Harvest stores (memory, transcripts, history) | Contain secrets pasted or ingested in sessions; also the distillation corpus |
| Harvest catalog | Steers what the distiller reads |
| SSH keys, PAT, Pass vault | Anchors; out of pipeline scope but adjacent (see §6) |
| Repos the operator commits to (some public) | Repo-scope distribution writes files that get committed — an exfiltration surface |

## 4. The central risk: the loop is an amplifier

The architecture is a feedback loop: world content → tool sessions → harvest
stores → distillation → workspace `ai/` → distribution → *every* tool's
standing instructions → future sessions. Two properties make this the
dominant risk, ahead of any single component:

1. **Amplification.** A single injected instruction that survives
   distillation stops being a one-session prompt injection and becomes
   persistent, cross-tool, cross-machine policy. It also compounds: poisoned
   instructions shape future sessions, whose transcripts are harvested in
   turn.
2. **Exfiltration on the way back out.** Repo-scope distribution lands
   `AGENTS.md` / `CLAUDE.md` / MCP files inside working trees, some of which
   are public. A distilled instruction of the form "always include X in
   generated configuration" is a data channel from the private corpus to
   public repos that never touches the network directly.

Amplification also works without any attacker: promotion is a scope
transition, and a customer particular that rides along on a promoted item is
replayed into every future context by the same fan-out (T13) — the pipeline
working as built on misclassified content.

Every control in §5 and §7 exists to break this loop at TB3/TB4; the
deterministic controls are the guarantees, the probabilistic ones
(prompt-side framing, model judgment) are best-effort and assumed to fail.

## 5. Threat register

Severity = impact × likelihood, qualitative. "Code-exec" marks threats
requiring the out-of-scope attacker (listed for persistence/propagation
relevance only).

| ID | Boundary | Threat (STRIDE) | Severity | Status |
|---|---|---|---|---|
| T1 | TB3/TB4 | Prompt injection in harvested content survives distillation into `ai/` (Tampering, EoP) | **High** | mitigations required — §7 |
| T2 | TB4 | Distillate exfiltrates corpus secrets via repo-scope files in public repos (Info disclosure) | **High** | mitigations required — §7 |
| T3 | TB2 | Poisoned `ai/mcp.json` fans out as command execution in every tool (EoP) | **High** | partially mitigated — §5.1 |
| T4 | TB3 | Symlink planted in a harvest store pulls out-of-scope files (e.g. `~/.ssh`) into the catalog and distillation corpus (Info disclosure) | Medium | mitigated — §5.2 |
| T5 | TB3 | Catalog tampering redirects the distiller to arbitrary files (Tampering) | Medium (code-exec for the write; listed because the distiller can cheaply not trust it) | mitigations required — §7 (R2) |
| T6 | TB4 | An AI agent (itself a user-level process) writes workspace `ai/` directly, bypassing distillation review (EoP, self-modification) | Medium | convention only — R3 |
| T7 | TB1 | Compromised anchor (git host account, SSH key, PAT) rewrites `ai/` or the pipeline code at the source (Spoofing, Tampering) | High impact / low likelihood | §6 |
| T8 | TB1 | One compromised machine pushes poisoned `ai/`; every other machine pulls it (propagation) | Medium | git history + R3 |
| T9 | TB2 | Distribution clobbers or hijacks operator content at tool paths (Tampering) | Low | mitigated — §5.1 |
| T10 | TB3 | Harvest itself executes or is exploited by hostile content (booby-trapped payloads) | Low | mitigated — §5.2 |
| T11 | — | Catalog/harvest metadata leaks (hashes of secret files enable verification of guesses) | Low | mitigated (0700/0600), residual accepted |
| T12 | TB2 | TOCTOU between the wiring's stat/slurp and its write (Tampering) | Negligible (code-exec, single-user machine) | accepted |
| T13 | TB4 | Project/customer particulars promoted into shared scope; fan-out replays them into every future context, including other customers' work (Info disclosure) | **High** — no attacker needed, only misclassification | mitigations required — §7 |

### 5.1 Distribution (TB1→TB2): controls in place

- **Non-destructive by construction.** Wiring classifies each target as
  noop / create / conflict and writes only when the target is absent or an
  empty file; anything with real content is recorded and the play halts
  (`09-ai-wire-one.yml`, `09-ai-sync.yml`). The hub layer likewise halts on
  a non-symlink at a hub path. Addresses T9.
- **Add-only rendering.** `ai-sync` merges MCP entries; it never edits or
  deletes an existing entry and reports a same-named divergent entry as a
  conflict rather than resolving it. A content-borne attacker cannot use the
  sync engine to *replace* a server definition — only a new name can arrive
  (T3 residual: additions are still executions; see below).
- **Atomic writes** (`write_atomic`) — no partially-written tool config.
- **T3 residual:** `mcp.json` is executable
  configuration by design; distribution faithfully fans out whatever the
  workspace repo says. The control is therefore *upstream integrity*: the
  repo is private, reached only via SSH/PAT from Pass, and every change to
  `ai/` is a git commit the operator made or can audit. What the pipeline
  guarantees is that nothing edits `ai/mcp.json` on the way through — the
  distillation gate (§7, requirement 4) additionally guarantees the
  *pipeline* never proposes MCP changes at all. An MCP addition is always a
  human act in the workspace repo.

### 5.2 Harvest (TB3, collection): controls in place

- **Resolution, never discovery.** A file enters the catalog iff a manifest
  harvest entry names it and it exists — no scanning, no content sniffing.
  Placeholder (`{slug}`) and glob segments expand only against directory
  listings at fixed positions. False positives are excluded by construction,
  which matters because anything cataloged is corpus.
- **Read-only, inert.** `ai-harvest` opens content solely to hash it; it
  never parses, executes, renders, or fetches, and never writes to a tool
  path. A booby-trapped transcript has no code path to detonate in (T10).
  Verbatim `://` values are listed as opaque strings, never dereferenced.
- **Contained output.** Catalog dir `0700`, catalog `0600`; URLs and
  integrity metadata only, no content duplication (limits blast radius of a
  catalog leak — though see T11: a sha256 of a low-entropy secret file
  permits offline verification of guesses; accepted at these permissions).
- **Symlink containment (T4).** Symlinks are refused, and each refusal
  reported, wherever content is attacker-influenceable: segments expanded
  from a placeholder or glob, literal segments below one, and everything
  inside the directory walk. The manifest-declared literal prefix is
  operator trust — a fully literal harvest path may itself be an
  operator-managed symlink (e.g. dotfile-synced) and is followed. As a
  backstop, every cataloged file's `realpath` must remain under the
  `realpath` of the entry's declared root — escapes are reported and
  skipped. A link planted inside a harvest store therefore cannot pull an
  out-of-scope file into the catalog or corpus. The refusal layer is
  regression-tested with planted symlinks in `tests/test-ai-harvest.sh`
  (the pre-fix collector demonstrably cataloged them); the `realpath`
  backstop is defense-in-depth behind it. Residual: hardlinks are not
  detectable via `realpath`, and a check-to-hash race (TOCTOU) can swap a
  verified path — both require local code execution, which is out of
  scope.

### 5.3 The loop as a whole (T1, T6, T8)

T1 is analyzed as the composition of: attacker text enters a session (easy —
any fetched page) → tool stores it (certain — transcripts are verbatim) →
harvest catalogs it (certain and *intended*; harvest's job is location, not
judgment) → distillation promotes it (the contested step — §7) → distribution
installs it (certain, by design). The pipeline concentrates all defense at
the single contested step, which is why TB4's human gate is designated the
hard control and everything before it is layered assuming failure.

T6 is the loop's blind spot: the agents being configured are themselves
user-level processes that can write the workspace repo directly, skipping
TB4 entirely. A session hijacked by prompt injection doesn't need to survive
distillation if it can `git commit` to `ai/`. At personal scale the control
is convention plus auditability (R3), not enforcement — enforcement
(protected branches, signed commits with an offline key) is available if the
risk profile changes. T8 is the multi-machine variant of the same bypass — a
poisoned commit pushed from one machine is pulled by the rest — and rides
the same controls: the `ai/` git history and R3.

## 6. Anchors (TB1) — adjacent but load-bearing

The pipeline inherits the bootstrap's trust roots; compromise of any is T7:

- **Setup repo delivery**: curl-then-clone from the public repo; `SETUP_REF`
  allows pinning to a GPG-signed annotated tag verified with standard git.
  Unpinned `master` is a convenience/exposure trade-off the operator chooses.
- **Workspace repo**: private; reached via SSH key or PAT, both resident in
  Proton Pass (single source for secrets — invariant 1). The git history of
  `ai/` is the audit log for everything TB4 admits.
- **Pass vault**: master secret store, manually unlocked; discovery-stage
  design keeps secret values out of Ansible registers and logs
  (`no_log: true`, titles-only discovery).

## 7. Security requirements for distillation (not yet implemented)

Binding requirements, agreed in design before implementation. The deterministic
ones (1, 2, 4, 5, 6, 9, 10.c) are the load-bearing controls; the
probabilistic ones (3, 7, 8, 10.a) are defense-in-depth presumed to fail.

1. **Catalog-only input.** The distiller reads exactly the resources the
   catalog lists — after re-verifying each sha256 (defeats T5 cheaply) —
   and nothing else.
2. **No dereferencing.** URLs *inside* harvested content are data. The
   distiller never fetches, resolves, or follows them. This deterministically
   kills the fetch-based half of T2 (SSRF/exfil-by-URL).
3. **Sanitization before inference.** Unicode normalization; strip zero-width
   and control characters (hidden-text injection); flag encoded blobs and
   assistant-addressed imperatives. Flagged content is **quarantined, not
   silently dropped** — an injection attempt found in project X's transcripts
   is itself a finding the operator wants surfaced.
4. **Prose only; executable configuration never flows.** The distiller's
   output schema has no representation for MCP servers, hooks, or scripted
   skills. An instruction can still be wrong; it cannot be a command line.
   (Complements §5.1: MCP changes are always direct human edits.)
5. **Itemized, provenance-carrying proposals.** Output is a list of items —
   statement, disposition (`promote-global` / `suggest-to-repo` /
   `discard-trivial` / `discard-specific` / `quarantine`), and the catalog
   URLs it derived from — validated against schema and allowed target paths
   before a human ever sees it. Provenance makes review real and enables
   retroactive revocation when a source is later found poisoned.
6. **Secret scan on the proposal.** Pattern-based (gitleaks-class) scan of
   every proposed item before review; addresses the non-URL half of T2
   (secrets smuggled into text destined for public repos).
7. **Corpus is quoted evidence, never instruction.** Prompt-side framing;
   directives found in the corpus are candidate *findings about injection*.
   Acknowledged weakest layer; never load-bearing.
8. **Derived-first ingestion with tiered scrutiny.** The distiller's default
   input is derived content only (`refinement: derived` in the catalog):
   the mission is to collect the tools' memories *safely*, not to re-derive
   them, so corroboration is risk management, not a default pass.

   **8.a) Unconditional checks.** Every item clears 3, 5, and 6 regardless
   of tier.

   **8.b) Triage.** Clearly safe items — plain facts and preferences with
   no behavioral steering — go straight to the reviewed proposal. Risky
   items — security-relevant imperatives (fetching, executing, credentials,
   git, configuration), contradictions of the existing `ai/` baseline,
   novel single-source behavioral rules — get deeper analysis.

   **8.c) Escalation, not a corpus pass.** Where the analysis warrants,
   corroborate against raw sources as *targeted queries* (locate this
   claim's origin in that slug's transcripts). Raw sources stay cataloged
   precisely to keep that lookup cheap.

   **8.d) Residual.** Triage reads surfaces, so a patient attacker aims
   for a boring-looking instruction; the floor is unchanged — prose-only,
   provenance-attached, human-reviewed, revocable via git history. A full
   corroboration pass too expensive to run would protect nothing.
9. **Staged, sandboxed, human-gated.** The distiller writes proposals to a
   staging area only; it has no write access to workspace `ai/`. A human
   reviews the itemized diff and commits (TB4). Incremental runs (catalog
   high-water mark) keep diffs small enough that review is genuine rather
   than rubber-stamp — a review gate that always shows 400 items is a
   rubber stamp with extra steps.
10. **Scope-of-validity gate: promotion is default-deny (T13).** The
    pipeline exists to reuse generalizable craft knowledge, not project
    intelligence; project and customer particulars belong in their source
    repositories. An item is project-specific until generalization is
    affirmatively demonstrated:

    **10.a) Substitution test.** The item must remain true and useful with
    every identifier stripped — promotion rewrites the abstract residue;
    the identifiers never reach the output.

    **10.b) Recurrence evidence.** Observed in independent slugs;
    single-slug items route to `suggest-to-repo` no matter how general they
    sound, which also guards against over-generalizing one project's quirk.

    **10.c) Identifier screen (deterministic backstop).** Every
    promote-global item is screened against a denylist built from data the
    pipeline already holds (slug names, workspace repo names, git
    hosts/orgs); any hit quarantines the item.

    **10.d) Routed, not deleted.** Useful particulars get
    `suggest-to-repo`: addressed to their own repo's instruction files,
    applied there by the operator, never written by the pipeline.

    **10.e) Residual.** Substitution and implication ("names no one,
    identifies someone") are probabilistic, and the denylist knows only
    known names; the floor is recurrence plus review.

## 8. Recommendations

Priority order; R1–R3 are cheap relative to their risk reduction.

- **R1 (T4): confine harvest to declared roots.** *Implemented* — symlink
  skipping plus realpath containment in `ai-harvest`, regression-tested in
  `tests/test-ai-harvest.sh`; see §5.2.
- **R2 (T5): distrust the catalog at read time.** Distillation requirement 1
  already covers this; keep it when implementing — hash re-verification
  makes catalog tampering pointless without content tampering, which the
  attacker in scope cannot do.
- **R3 (T6/T8): make `ai/` changes review-visible by convention.** All
  writes to workspace `ai/` happen via the distillation gate or an explicit
  human edit; agents are instructed (in `ai/AGENTS.md` itself) never to
  commit to `ai/`. Periodically audit `git log -- ai/`. Escalation path if
  ever warranted: protected branch + commit signing.
- **R4 (T1): when implementing distillation, land §7 as code + a checklist**
  in the runbook, so the gate's preconditions (validator ran, secret scan
  clean, diffs small) are checked, not remembered.
- **R5 (T11, hygiene): treat harvest stores as secret-bearing.** They
  already sit under `~/.claude` with default permissions; consider
  tightening the state dir's parents and excluding known-secret paths from
  cataloging if any ever land inside a declared root.

## 9. Accepted risks and non-goals

- **No integrity signing of catalogs or distillates.** Personal scale
  (invariant 7); the code-exec attacker who could forge them is out of scope,
  and R2 removes the incentive.
- **No sandboxing of the enrolled tools themselves.** The tools execute MCP
  servers and shell commands by design; their runtime containment is the
  tools' and platform's concern, not this pipeline's.
- **Unpinned `master` bootstrap** remains available; the operator can pin to
  signed tags when the trade-off warrants.
- **TOCTOU in wiring (T12)** — exploitation requires local code execution on
  a single-user machine; accepted.
- **Availability** — every stage is re-runnable and idempotent; worst-case
  DoS is a re-run after reconciliation. Not further analyzed.
