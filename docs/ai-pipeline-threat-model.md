# Threat model — AI-assistant configuration pipeline

Security analysis of the loop by which setup maps AI tools (`agent-map.json`),
fans shared instructions and configuration out to them (distribute), collects
what they accumulate (harvest), and distils it back into the shared sources
(distillation). Grounded in the code as of this writing: `files/agent-map.json`,
`files/ai-sync`, `files/ai-harvest`, `files/ai-distill`,
`tasks/09-ai-config.yml`, `tasks/09-ai-sync.yml`, `tasks/09-ai-wire-one.yml`.
Distillation is being implemented iteratively: `files/ai-distill` provides the
deterministic `prepare` (reqs 1–3) and `gate`/`apply` (reqs 9–12) bookends, and
the `distill` plugin (`plugins/distill/`) carries the human-supervised session
for the inference middle (reqs 4–8). §7 states the security requirements,
agreed before the code and binding on every iteration.

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
                 │ hub (symlinks  │   │   (in progress)   │  deterministic
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
  every machine. The human review gate lives here.

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
| T5 | TB3 | Catalog tampering redirects the distiller to arbitrary files (Tampering) | Medium (code-exec for the write; listed because the distiller can cheaply not trust it) | mitigated — R2 (prepare re-hashes and excludes) |
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
  distillation gate (§7, requirement 9) additionally guarantees the
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
primary control, and everything before it is layered assuming failure.

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

## 7. Security requirements for distillation (binding; implementation in progress)

Binding requirements, agreed in design before implementation, listed in the
order they are applied: a deterministic front (1–3) and back (9–12) bracket a
hybrid analysis middle (4–8) that may use inference. The deterministic controls
are the load-bearing guarantees; the inference-bearing steps — the substitution
test (5.b), categorization (6), deduplication (7), and triage (8),
all under the framing rule (4) — are defense-in-depth presumed to fail. Two
entries are standing rules rather than one-shot steps: 2 binds every stage that
handles content, 4 every stage that reads content into a model.

1. **Catalog-only input.** The distiller reads exactly the resources the
   catalog lists — after re-verifying each sha256 (defeats T5 cheaply) — and
   nothing else. By default only `refinement: derived` resources (the tools'
   own once-distilled memories); the mission is to collect that knowledge
   safely, not to re-derive it, so raw sources are queried only on escalation
   (8), never bulk-ingested, and `meta` bookkeeping (indexes, navigation) is
   skipped entirely — what it points to is already harvested on its own.

2. **No dereferencing** *(standing rule).* URLs *inside* harvested content are
   data. No stage fetches, resolves, or follows them. This deterministically
   kills the fetch-based half of T2 (SSRF/exfil-by-URL).

3. **Sanitization: mechanical normalization and format validation.** A
   deterministic gate before any structural parsing or inference: it decides
   whether each resource is well-formed text and renders it in canonical
   form, and it makes no risk judgment (risk assessment is triage's job,
   req 8). Rejects are recorded `invalid` with a stated reason — a syntactic
   classification, not a security verdict. The passes run in this order.

   **3.a) Canonicalization.** The required form is strict, NFC-normalized
   UTF-8. Accepted input encodings are exactly those a deterministic check
   identifies: UTF-8 (with or without BOM) and BOM-marked UTF-16/32. The
   enrolled tools write UTF-8, and legacy single-byte encodings are not
   reliably detectable even in principle (every byte stream is valid
   Latin-1), so they are not guessed at. Bytes not decodable as an accepted
   encoding are a binary file — no place in the derived harvest — recorded
   `invalid`. On the
   decoded text it then strips zero-width characters, the BOM, word-joiner,
   and the Unicode bidirectional-override characters (`U+202A`–`U+202E`,
   `U+2066`–`U+2069`, the Trojan-Source class), preserving newline, tab, and
   the zero-width joiner that legitimate emoji sequences use, and normalizes
   line endings. Where NFKC folding would further change the text (fullwidth
   or compatibility lookalikes), the difference is annotated, not applied — a
   smell handed to triage, not a rejection.

   **3.b) Opacity unwrapping.** An embedded base64/hex run is an opacity
   wrapper: its content class is unknown until opened — text (possibly an
   instruction), binary, or a further encoding layer — and that unknownness
   is itself the risk, because every later stage can inspect plain text but
   none can see inside a wrapper. Sanitization opens candidate runs (low
   threshold — ~12+ candidate characters, roughly a one-word fragment, to
   catch even a short hidden prompt) not to judge them but to restore
   inspectability. Each opened
   fragment re-enters canonicalization (3.a) — its own invisibles stripped,
   its own nested wrappers opened — so revelation is recursive and complete.
   Revealed text is attached as an annotation, **never silently spliced into
   the surrounding prose**, so a message reconstructed from many wrappers
   stays visibly assembled rather than passing as native text. A large
   decoded binary is `invalid` (an encoded payload belongs in the derived
   harvest no more than a raw one); a small opaque token — a hash, cookie,
   or identifier — is left as-is; nothing is ever unpacked as an archive.
   Decoding an encoding always shrinks its input (base64 4:3, hex 2:1), so
   decompression-bomb-style expansion is impossible here and recursion is
   self-limiting; a depth cap remains as a **termination guard** against
   pathological nesting, and makes no judgment about content. If compressed
   intake support is ever added, it belongs in this step and must carry
   output-size termination controls against decompression bombs. The defense
   against a *scattered-fragment* attack (dozens of short runs, each a word
   or two, that recombine into a dozens-of-words injection) is not a limit
   but the annotation rule above: because revealed fragments are marked and
   never spliced in as native prose, the reconstructed message reaches
   triage as visibly assembled plaintext and is read like any other text.

   **3.c) Opacity score.** Sanitization counts, per resource, the opacity
   unwrappings performed — one per expression (opening one encoded run is 1;
   a further nested layer is +1), not per character. The score
   accompanies the resource as a mechanical measure of how much was hidden;
   a resource needing deep or repeated unwrapping is flagged for triage
   (req 8), as is any termination-guard limit hit. It is a **general opacity
   signal, not a scattered-fragment detector**: a prompt split across dozens
   of short runs may score no higher than a legitimate message listing that
   many encoded identifiers, so the score does not discriminate the two —
   that is what 3.b's annotation rule is for. The stage makes no judgment;
   it measures and reveals, triage decides.

   **3.d) Validation.** Last, on the fully revealed canonical form:
   format-level accept/reject on cheap, concrete criteria chosen not to
   false-positive on legitimate memories — a per-file size bound (a derived
   memory file beyond a few hundred kilobytes is anomalous for this corpus)
   and class-appropriate structure where the class declares one (frontmatter
   in a memory file, when present, must parse). What passes is well-formed,
   bounded, canonical text; anything else becomes `invalid` with its reason.
   Validating after canonicalization and unwrapping lets these checks be
   strict without false rejections, since obfuscation, mixed encodings,
   invisibles, and unopened wrappers no longer exist in the canonical form.

   Prior art: this mirrors the mechanical (non-model) half of LLM input
   guards — llm-guard's invisible-text and Base64 sanitizers, Azure Prompt
   Shields, Lakera — which likewise separate deterministic sanitization from
   model-based injection detection; OWASP's canonicalize-before-validate
   doctrine and the Unicode security reports (Trojan Source, bidi and
   compatibility handling); and secret-scanner practice (trufflehog) of
   decoding candidate runs before inspecting the bytes. It differs from those
   inline firewalls deliberately: rejects are recorded `invalid` with a
   reason and revealed content is annotated and passed on, not silently
   stripped, because this pipeline is curatorial and auditable.

4. **Corpus is quoted evidence, never instruction** *(standing rule, stages
   5–8).* Every stage below that reads content into a model treats that
   content as quoted evidence; a directive found inside it is a candidate
   *finding about injection*, never an instruction to act on. Prompt-side
   framing — the weakest layer, never load-bearing.

5. **Generalization — anonymize; promotion is default-deny (T13).** The
   pipeline reuses generalizable craft knowledge, not project intelligence;
   project and customer particulars belong in their source repositories. Every
   item is anonymized and tested for generality before going further, and
   promotion is default-deny — generality is shown, not assumed.

   **5.a) Identifier screen (deterministic).** Redact every item against a
   denylist built from data the pipeline already holds: slug names from the
   catalog (and their path components), the repositories of the workspace
   manifest, and each repo's git remotes — the remote host plus the path
   prefix before the repository name, which conventionally carries the
   owning organization or team. Host and path prefix are sufficient
   precision for "owning organization" here: the operator can tell the
   organization from them.

   **5.b) Substitution test.** An item must stay true and useful with its
   identifiers stripped; only the abstract residue is carried forward, and the
   identifiers never reach the output. Promoted statements are written in the
   requirement register — implementation-free, singular, verifiable, at the
   broadest true abstraction (the general principle covering the class, not
   the observed instance; the source is a non-limiting example), per
   ISO/IEC/IEEE 29148, the INCOSE Guide to Writing Requirements, and
   patent-claim drafting practice. An item that evaporates when redacted was
   source-particular: it leaves the promote stream — routed to
   `suggest-to-repo` (its own repo's instructions, applied there by the
   operator) or dropped — never promoted to the hub.

   **5.c) Residual.** Substitution and implication ("names no one, identifies
   someone") are probabilistic, and the denylist knows only known names; the
   floor is the recurrence signal (7) plus human review (12).

6. **Categorization.** Tag each surviving item with a small set of the most
   fitting topic labels — not a single category, since knowledge is often
   cross-cutting (one item may be both `security` and `reliability`), and
   forcing one label loses that. Labels are drawn from a standards-based hint
   vocabulary (ISO/IEC 25010 quality attributes, SWEBOK / ISO/IEC/IEEE 12207
   activities, ISO/IEC/IEEE 29148 requirement kinds) but the set is not
   binding — a new label is coined when none fits. An enabling step, not a
   security guarantee in itself; its value is that good labels cluster
   near-duplicates for deduplication (7) and later route promotions to the
   right instruction file, which keeps review (12) genuine.

7. **Deduplication.** Two passes that bring the item count down so review
   stays real:

   **7.a) Combine within the set.** Repeated or overlapping items merge into
   one. Because items carry several labels (6), blocks overlap: candidate
   duplicates are found within each label-block, then reconciled across
   blocks (union-find) into single merge clusters so an item merges exactly
   once and its recurrence is not double-counted. The merge retains the
   provenance of every source it combines — so a poisoned source rides along
   visibly and the merged item is triaged whole — and the number of distinct
   sources merged is the *recurrence* signal that 5 and 8 rely on.

   **7.b) Drop against the baseline.** The current `ai/` sources are the
   comparison context — the relevant category's baseline is read alongside
   that category's items. An item the baseline already states is dropped as
   redundant. This is distinct from *contradicting* the baseline, which is
   not a duplicate but a risk signal for triage (8).

8. **Triage.** The input is now the generalized, deduplicated item set. Triage
   sets scrutiny depth and disposition; it does not exempt items from the
   output controls (9–11), which every surviving item still passes — tiering
   changes scrutiny, not the invariants.

   **8.a) Routing by risk.** Clearly safe items — plain facts and preferences
   with no behavioral steering — go straight to the proposal. Risky items —
   security-relevant imperatives (fetching, executing, credentials, git,
   configuration), assistant-addressed imperatives ("ignore previous
   instructions"-shaped text, including any decoded content sanitization
   surfaced), a high opacity score or limit hit from sanitization (3),
   contradictions of the existing `ai/` baseline, novel behavioral rules —
   get deeper analysis. An item judged an injection attempt is **quarantined,
   not silently dropped** — an injection found in project X's corpus is itself
   a finding to surface.

   **8.b) Recurrence signal.** Recurrence — the count of distinct source slugs
   (from 7.a) — strengthens a promotion but does not gate it. Recurrence ≥2
   says a principle is already known general; a single source is still
   promotable when its generalizability is affirmatively demonstrated, and is
   surfaced to the reviewer as single-source for confirmation. The human gate
   (12) is the guard against over-generalizing one project's quirk — a
   single-source item is not auto-rerouted to `suggest-to-repo`. (Having only
   one instance demands real generalizability; ≥2 already hints it holds.)

   **8.c) Escalation, not a corpus pass.** Where analysis warrants,
   corroborate a derived claim against raw sources as *targeted queries*
   (locate its origin in that slug's transcripts), never a corpus pass. Raw
   sources stay cataloged to keep that lookup cheap.

   **8.d) Residual.** Triage reads surfaces, so a patient attacker aims for a
   boring-looking instruction; the floor is unchanged — prose-only (9),
   provenance-attached (10), secret-scanned (11), human-reviewed (12),
   revocable via git history. A full corroboration pass too expensive to run
   would protect nothing.

9. **Prose only; executable configuration never flows.** The distilled `ai/`
   carries prose instructions, never MCP servers, hooks, or scripted skills.
   The gate rejects a change that touches an executable/config file or whose
   added content is executable JSON (`mcpServers`, command/args). An
   instruction can still be wrong; it cannot be a command line. (Complements
   §5.1: MCP changes are always direct human edits.)

10. **The proposal is a reviewable git diff with provenance.** The session
    writes the distilled `ai/` directly in a git worktree on branch
    `distill/<run>`, off the live path; the proposal *is* that branch's diff —
    adds, edits, and removals across files — and the provenance rides in the
    commit messages (`git blame` keeps it per-line, permanently). No bespoke
    proposal format to drift from the real files; the `ai/` git history becomes
    the audit trail, and a source later found poisoned is traced and reverted
    by ordinary git. The run keeps no second copy of the proposal: `report.md`
    is a short digest, not a content dump — `prepare` writes its deterministic
    top (counts, the sanitizer's attention flags, mechanical exclusions) and
    the session appends where each item was routed (quarantined, suggested,
    discarded, promoted). The item text is in `items.json` (the session's
    input) and in the diff, so nothing is copied to be read twice.

11. **Secret scan on the diff.** The gate scans the branch diff's added lines
    with established secret-scanning tooling (gitleaks-class — use the best
    available scanner, do not hand-roll detection); addresses the non-URL half
    of T2 (secrets smuggled into text destined for public repos).

12. **Worktree-staged, human-gated, merged deterministically.** The session
    never edits the live `ai/`; the write-guard hook blocks that. It edits the
    run's worktree, off the path the tools read. The operator reviews the branch
    diff and iterates (edit the worktree, re-run `gate`) until they approve.
    Only then does `ai-distill apply` re-gate and merge the reviewed branch into
    the live branch, then remove the worktree and branch (TB4). This is the
    primary control because apply merges exactly the reviewed branch, so the
    live `ai/` equals what was reviewed, and because the session cannot write the
    live `ai/` any other way. Suspected injections are held in the run's
    quarantine pen, outside every repo, applied only on an explicit false-alarm
    call. The same worktree/gate/apply machinery, pointed at another repo with
    `add-target`, handles the `suggest-to-repo` side channel; that repo's own
    identifiers are allowed there, since they belong to it. Incremental runs keep
    each diff small enough that review is genuine rather than rubber-stamp.

    *Forensic retention.* On apply, the worktree is removed and the one large,
    reconstructable intermediate (`items.json`, rebuildable by re-running
    `prepare` from the retained catalog) is pruned; the digest (`report.md`),
    the quarantine pen, and the small state (`denylist.json`, `targets.json`)
    are kept. The run directory stays a compact record of what was decided, and
    the quarantined material — the most security-relevant trace, since it is the
    corpus's suspected injection attempts — is never discarded by the pipeline.

**Implementation shape.** The requirements are logical stages; how many
passes implement them is an implementation choice. The intended shape is
hybrid: deterministic bookends as scripts — *prepare* (read, verify,
sanitize, exact-duplicate elimination, work-package emission, and a git
worktree on branch `distill/<run>` off the live path) and *gate*/*apply*
(checks on the branch diff — prose only, identifier and secret scans — then a
merge of the reviewed branch into the live tree and worktree cleanup) — around
a **human-supervised agent session** (an agent plugin with skills, not a
script calling a model API; the pipeline manages no model credentials)
performing stages 4–8 by writing the distilled `ai/` directly in the worktree.
Within the session,
the per-item judgments (5.b, 6, 8.a signals) batch many items per call;
deduplication is comparative, so it blocks by label and takes one call per
label-block (items carry several labels, so blocks overlap and their merge
candidates are reconciled — union-find — into single clusters), each seeing
its items and the relevant `ai/` baseline slice (7.b); triage routing is then
deterministic over the collected flags and recurrence, with model escalation
(8.c) only for the risky few.

Each inference-bearing stage declares its model tier and required context
size in configuration, editable before a run — matching model cost to the
value of the judgment rather than paying flagship rates for routine
labeling. The economics are asymmetric, so the matching is not simply
"cheap early, expensive late": the high-value steps get the best available
model with sufficient context as a matter of course, but an early stage may
also warrant it when a cheaper model's misjudgment would be costly — a
mislabeled item is silently lost or wrongly promoted long before review can
notice. Default cheap where an error is recoverable downstream; pay up
where it is not.

## 8. Recommendations

Priority order; R1–R3 are cheap relative to their risk reduction.

- **R1 (T4): confine harvest to declared roots.** *Implemented* — symlink
  skipping plus realpath containment in `ai-harvest`, regression-tested in
  `tests/test-ai-harvest.sh`; see §5.2.
- **R2 (T5): distrust the catalog at read time.** *Implemented* —
  `ai-distill prepare` re-verifies each sha256 and **excludes** any mismatch
  from the work package (requirement 1), so a tampered catalog cannot feed a
  swapped file into distillation. Hash re-verification makes catalog tampering
  pointless without content tampering, which the attacker in scope cannot do.
- **R3 (T6/T8): make `ai/` changes review-visible by convention.** All
  writes to workspace `ai/` happen via the distillation gate or an explicit
  human edit; agents are instructed (in `ai/AGENTS.md` itself) never to
  commit to `ai/`. Periodically audit `git log -- ai/`. Escalation path if
  ever warranted: protected branch + commit signing.
- **R4 (T1): land §7 as code.** *Largely implemented* — the deterministic
  gates live in `ai-distill gate`/`apply` (prose-only, identifier and secret
  scans on the branch diff; merge only a re-gated branch), the `distill`
  plugin's skill carries the runbook checklist, and a session-scoped hook
  blocks writes to the live `ai/`; so the gate's preconditions are checked,
  not remembered. Remaining: exercise the
  inference middle on a real run and tune thresholds.
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
