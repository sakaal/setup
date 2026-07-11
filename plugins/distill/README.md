# distill

Human-supervised distillation of harvested AI-tool knowledge into the shared
instruction sources, per the binding requirements in
[docs/ai-pipeline-threat-model.md](../../docs/ai-pipeline-threat-model.md) §7.

The plugin is the agent-session half of a hybrid: deterministic scripts do
the mechanical work, the session does the supervised judgment, and nothing
lands in the shared sources without human review.

- `~/bin/ai-harvest` — fresh catalog of the harvestable sources
- `~/bin/ai-distill` — deterministic *prepare* (read, verify, sanitize,
  exact-dedup, work package) and *accept* (schema, prose-only, identifier
  and secret scans, staging)
- this plugin — the inference middle (generalize → categorize → deduplicate
  → triage) as skills-guided, batched agent work with per-stage model tiers,
  followed by the operator's review of the staged proposal

The plugin's parts: `commands/distill.md` (the `/distill` entry),
`skills/distill/SKILL.md` (the runbook, with the language register and the
standards-based label vocabulary), `agents/extractor.md` and
`agents/merger.md` (the batched per-item and per-label-block subagents, each
with a configurable model tier), and `hooks/` (a session-scoped guard that
blocks writes to the workspace `ai/` sources during a run). It carries
mechanism only — no personal content, no model credentials; everything it
processes is read from local machine state at run time.

## Install

From a clone of this repo (see the top-level README's "Distilling learned
knowledge" for full usage):

    /plugin marketplace add sakaal/setup
    /plugin install distill@setup
