---
status: accepted
date: 2026-09-09
supersedes: []
superseded-by: []
touches:
  - "assets/guard-preamble.txt"
  - "assets/roles/adversary.role.md"
  - "scripts/ff-doctor.sh"
  - "scripts/ff-plan.sh"
---

# ADR-037: A Rule That Must Hold Across the Fleet Is Carried in the Guard Preamble; Implicit Harness Rules Reach Nobody Else

## Decision (one sentence)

Any rule that every worker must follow regardless of provider is **pasted
into `assets/guard-preamble.txt` as a tagged block** (`[fleet-rule: NAME]`),
declared in `FLEETFLOW_FLEET_RULES` (default `agentic-quality`), and checked
by `ff-doctor --offline` (a `fail` row when a declared rule has no block) and
`ff-plan lint` (a `warn` finding when the target repo's `AGENTS.md` carries
neither the doctrine nor a pointer to it) — because the rules Claude Code
loads implicitly from `~/.claude/rules/` and `CLAUDE.md` are **invisible to
every other harness**.

## Context

The GoDaddy port (run `godaddy-build`, 133 lanes across Codex, GLM and
Sonnet) ran every builder on the same packet template, the same contracts and
the same refuter lens. Measured afterwards on the landed tree, comment density
by creating lane:

| lane class | harness | density | contract block |
|---|---|---|---|
| FormaTSX template seed | — | 21% | 56/71 files |
| GLM group lanes | `claude -p` → z.ai | 14–16% | 35/35 files |
| Codex group lanes | `codex exec` | 1–3% | 9/32 files; `hosting.ts` 775 lines, zero comments |

Nothing in the packets said "comment like this". The GLM lanes did it anyway
because `claude -p` loads `~/.claude/CLAUDE.md` and all thirteen
`~/.claude/rules/*.md` — including `agentic-quality.md`, which *is* the
commenting doctrine — into every lane implicitly. `codex exec` lanes get the
packet, the guard preamble and the repo's `AGENTS.md`, and none of the three
carried it. Codex did exactly what it was asked. No gate measured the shape,
so nothing caught it until a human read the diff.

This is the same failure class fleetflow has traded with FORMA before: the
standard existed; its *scope* did not include the workers doing most of the
writing.

## Decision

1. **The preamble is the channel.** `ff-spawn` already prepends
   `guard-preamble.txt` to every guarded lane of every provider. A fleet-wide
   rule is written there as a compressed block headed by a
   `[fleet-rule: NAME]` tag naming its `~/.claude/rules/NAME.md` source. The
   tag is what the checks look for; the prose is a compression the tag names.
2. **The declared list is explicit.** `FLEETFLOW_FLEET_RULES` (comma-separated
   rule names, default `agentic-quality`) is the set every provider must see.
3. **`ff-doctor --offline` reports the asymmetry before a spawn.** Row
   `fleet-rules`: `ok` when every declared rule has its tag, `fail` otherwise
   (a fail here is precisely the GoDaddy defect, caught earlier). Row
   `rule-inheritance`: how many rule files Claude-family lanes inherit
   implicitly versus how many fleet rules reach the other harnesses through
   the preamble.
4. **`ff-plan lint` checks the one channel every harness reads.** Check
   `fleet-rules`: the preamble tags, plus a `warn` finding when the target
   repo's `AGENTS.md` contains neither the doctrine block nor a pointer to it
   (`fleet-rule:`, `CODE DOCTRINE`, or `agentic-quality`). `AGENTS.md` covers
   any harness added later without another preamble change.
5. **The Adversary role card carries a shape lens** so cross-provider
   refuters catch the failure where no mechanical gate exists, using the same
   thresholds as the GoDaddy gate (`check-comment-doctrine.mjs`): 40-line
   minimum, contract block in the first 30 lines, marker at 400, section map
   at 800 — plus the half a gate cannot measure (open five blocks at random;
   the cited owner must say what the block claims).

## Alternatives rejected

- **Copy the full rule files into every packet at `ff-plan draft` time.**
  `agentic-quality.md` alone is ~200 lines; times twelve rule files, times a
  hundred lanes, it is real token spend on the cheapest models and a drift
  hazard (a packet is frozen; the rule is not). The preamble is prepended once
  per lane by the spawner and edited in one place.
- **Ask each harness to load `~/.claude/rules/`.** Not a knob codex, grok or
  pi expose, and fleetflow does not own their configuration.
- **Rely on the refuter lens alone.** A judgment spot-check (rubric A5) is what
  existed, and it missed 23 files with no contract block. Lenses catch what
  gates cannot measure; they are not a substitute for the gate.
- **Make the lint finding `hard`.** A missing `AGENTS.md` pointer is a
  property of the target repo, not of the plan; blocking a plan on it would
  push orchestrators to disable the check. `warn` surfaces it every lint;
  `ff-doctor` owns the `fail`.

## Consequences

### Positive
- The doctrine reaches every provider through a channel the spawner already
  owns, and its absence is a doctor `fail`, not a post-port autopsy.
- The asymmetry is *stated* on every `ff-doctor --offline`, so an orchestrator
  reading the preflight sees what the non-Claude lanes will and will not know.
- `AGENTS.md` as the fallback channel means a fourteenth harness needs no
  fleetflow change to inherit the doctrine.

### Negative
- Two copies of the doctrine (rule file, preamble block) can drift; the tag
  names the source, and `agentic-quality.md`'s own directive text is the one
  to reconcile against. A content-hash check was considered and rejected as
  brittle — the block is a compression, not a copy.
- The preamble grows by ~10 lines per fleet rule, paid on every guarded lane.

## See also

- [ADR-031](ADR-031-role-cards-own-stance-packets-own-task.md) — the role
  card roster the shape lens is added to
- `~/.claude/rules/agentic-quality.md` — the rule the default block compresses
- `X:\Roam\GoDaddy\scripts\check-comment-doctrine.mjs` — the mechanical gate
  whose thresholds the lens mirrors (also `roamhq/godaddy-mcp` at `810fabd`)
- `tests/run.sh` — `doctor: fleet-rules`, `ff-plan: lint fleet-rules`,
  `adversary card carries the shape lens`
