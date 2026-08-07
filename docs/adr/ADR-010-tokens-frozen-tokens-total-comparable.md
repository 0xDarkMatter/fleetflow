---
status: accepted
date: 2026-08-01
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-status.sh"
  - "assets/ff-dashboard.html"
  - "assets/ff-monitor.html"
---

# ADR-010: `tokens` Is Frozen as Inconsistent; the `tokens_total` Family Is the Comparable

## Decision (one sentence)

The legacy `tokens` field is frozen (kept for `ff-monitor.html` compatibility,
never used for cross-model comparison) and cross-model accounting uses the
`tokens_in` / `tokens_cached` / `tokens_out` / `tokens_total` family, with
`cost_usd` understood as partial by construction.

## Context

`tokens` is model-INCONSISTENT: codex reports a grand total, claude-family
models report output only. Comparing them is a category error with real
consequences — a codex lane's 5.4M against a GLM lane's 42.6k reads as a
100× cost difference, but measured consistently that GLM lane had consumed
4.5M. The field could not be fixed in place because `ff-monitor.html` renders
it and historical journals carry it; changing its meaning would silently
re-interpret every existing record. So it was frozen, and `ff-status` grew a
parallel family that means the same thing for every model.

Cost inherits the same honesty problem: claude-family workers self-report
`total_cost_usd`; codex and grok report none; GLM's self-reported figure is
the CLI's Anthropic-rate estimate, not the z.ai invoice — a magnitude, not an
amount owed. **Cost is therefore partial by construction**, and the surfaces
encode that: plain `$x` is self-reported, `≈$x` contains estimates, `*` means
uncosted lanes remain, and nothing is ever presented as an invoice. (The
dashboard's own rate-card estimation layered on top of this is ADR-015.)

## Alternatives considered

- **Redefine `tokens` to mean total everywhere.** Rejected: silently changes
  the meaning of every historical journal record and the monitor's rendering
  — the classic "fix" that corrupts the archive.
- **Per-model normalisation at read time (keep one field).** Rejected: the
  raw per-model figure is itself information (it is what the CLI reported);
  normalisation belongs in *additional* fields, not in overwriting the
  original.
- **Drop cost display until every model reports it.** Rejected: partial cost
  with explicit markers (`≈`, `*`) is more useful than none, provided the
  marking is enforced (tests assert estimates carry `≈`).

## Consequences

### Positive
- Cross-model comparisons are meaningful; the dashboard's cost story stops
  being a category error.
- Historical records keep their original meaning; readers pick the family by
  need.

### Negative
- Two token vocabularies coexist forever; every new surface must know to
  reach for `tokens_total`, not `tokens`.

### Non-goals
- Does not decide pricing/rate-card mechanics — that is ADR-015.
- Does not backfill archived lanes that never carried an input/cache split
  (they fall back to reported-or-nothing).

## See also

- SKILL.md — "Compare runs with `tokens_total`, not `tokens`"
- `scripts/ff-status.sh` — the emitting side; `assets/ff-dashboard.html` —
  the marker conventions
- ADR-015 — the pricing-basis layer built on these counts
