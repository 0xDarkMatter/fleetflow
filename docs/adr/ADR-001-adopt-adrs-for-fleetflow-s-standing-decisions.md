---
status: accepted
date: 2026-08-07
supersedes: []
superseded-by: []
touches:
  - "docs/adr/**"
  - "SKILL.md"
  - "AGENTS.md"
  - "tests/run.sh"
---

# ADR-001: Adopt ADRs for Fleetflow's Standing Decisions

## Decision (one sentence)

Fleetflow records its architecturally significant decisions as append-only ADRs
under `docs/adr/` (adr-ops canonical format, lint-gated by `tests/run.sh`),
while SKILL.md/AGENTS.md stay the operational layer and cite the ADRs instead
of owning the archaeology.

## Context

Fleetflow's own SKILL.md ships "The docs contract — plans cite, ADRs own,
reference states" (commit 6c3cbcb, 2026-08-07) as doctrine for repos that
fleetflow runs build. The observed failure mode that motivated the contract
(ga4-port, ATDW-MCP) is documentary drift: a decision restated in a plan or a
prose doc drifts from the record that owns it. Fleetflow itself had accumulated
its decisions as dense prose in SKILL.md and AGENTS.md Landmines — rich in
"learned YYYY-MM-DD" archaeology but with no append-only record, no
`touches:` discovery surface, and no machine gate. A repo that prescribes the
contract should follow it.

## Alternatives considered

- **Keep everything in SKILL.md/AGENTS.md prose.** That is the status quo the
  docs contract names as the failure mode: prose is mutable, so a later edit
  can silently rewrite a decision's rationale, and there is no `adr-touching`
  answer to "what governs the file I'm about to change".
- **Convert the prose wholesale into ADRs.** Rejected — SKILL.md is the
  operational playbook agents actually execute from; gutting it would trade
  drift risk for a worse working surface. The model is extract-and-cite: the
  ADR carries the archaeology, the prose keeps the directive plus a pointer.
- **A single DECISIONS.md log.** No per-decision lifecycle (supersession),
  no `touches:` frontmatter, no lint — the same drift problem in one bigger
  file.

## Consequences

### Positive
- Each standing decision has one append-only owner with dated context,
  alternatives, and consequences; supersession is explicit and bidirectional.
- `adr-touching.py` works against this repo: packet authors and future
  sessions can ask what governs a path before changing it.
- `adr-lint --strict` runs inside `tests/run.sh`, so a malformed or one-sided
  record fails the same gate as everything else.

### Negative
- Two layers to keep coherent: a decision change now means a superseding ADR
  *and* a prose touch-up in the same commit.
- The backfilled records (ADR-002 onward) date their decisions from the
  "learned/settled" markers in the prose, not from when the ADR file was
  written — readers must not read file mtime as decision date.

### Non-goals
- Not a rule that every landmine or test-enforced invariant becomes an ADR —
  the sprawl guard in SKILL.md's docs contract still applies (module-level
  choices stay guard comments; test-enforced invariants stay landmines).
- Does not restructure `references/` (living reference docs stay as they are).

## See also

- SKILL.md § "The docs contract — plans cite, ADRs own, reference states"
- adr-ops skill (`~/.claude/skills/adr-ops/`) — format, scripts, lint
- `tests/run.sh` — the gate that runs `adr-lint --strict`
