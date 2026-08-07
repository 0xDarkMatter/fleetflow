---
status: accepted
date: 2026-08-05
supersedes: []
superseded-by: []
touches:
  - "assets/ff-dashboard.html"
---

# ADR-015: Cost Uses a Hand-Maintained `PRICING` Registry With a Per-Model Basis, and Plan Costs Are Blended — Never $0

## Decision (one sentence)

The dashboard carries a hand-maintained `PRICING` registry (per-model $/MTok
rates verified against provider pricing pages, verification date stamped in
the file) with an operator-chosen per-model basis — `api` (compute from token
counts), `plan` (a subscription tier's monthly fee **blended** across that
month's plan-basis lanes by API-notional share, so a month sums to exactly
the fee and a lane is never $0), or `report` (trust the CLI's figure) — and
every figure is marked for what it is (`$` reported, `≈$` estimated, `*`
uncosted lanes remain).

## Context

ADR-010 established that self-reported cost is partial and inconsistent:
codex/grok report nothing, and GLM's figure is the CLI's Anthropic-rate
estimate — a magnitude, not the z.ai invoice. The only way to a comparable
cost story is for the dashboard to price token counts itself, which requires a
rate card. No API provides one, so `PRICING` is hand-maintained like
`HARNESS` (ADR-014), with the discipline made explicit: rates verified
against Anthropic/z.ai/OpenAI/xAI published pricing, the verification date
stamped in the file, and updates land in the same commit as a new model or a
provider rate change — a stale rate silently mis-prices every ≈ estimate.

Subscription lanes posed the honesty problem in reverse: a lane run on a flat
plan (Claude Max, GLM Coding, ChatGPT/Codex) has no marginal price, and
showing it as $0 is a lie that compounds — a fleet routed entirely through
plans would appear free, which is exactly the misreading that leads to
misrouting. The blended model fixes this: each calendar month's plan fee is
allocated across that month's plan-basis lanes proportionally to their
API-notional cost (what they *would* have cost at published rates), so a
month's blended costs sum to exactly the fee and every lane carries a
non-zero share. Tiers are picked per provider group in the costs modal
(Claude Max 5×/$100 or 20×/$200, GLM Coding Lite/Pro/Max, ChatGPT
Plus/Codex $100/Pro); the basis choice persists under `ffd.pricing`. Nothing
is ever presented as an invoice. Tests pin the load-bearing edges: every
spawnable model has a `PRICING` entry, GLM is priced at z.ai rates (not
Anthropic's), and estimates carry the `≈` marker.

## Alternatives considered

- **Show $0 for plan lanes.** Rejected: systematically understates fleet cost
  and biases routing decisions toward "free" lanes.
- **Show the full plan fee on every lane (or ignore plans, price everything
  at API rates).** Rejected: over-counts as badly as $0 under-counts; the
  blend is the only allocation whose monthly total equals what was actually
  paid.
- **Trust self-reported cost everywhere (`report` as the only basis).**
  Rejected per ADR-010's evidence — GLM's report is wrong-currency, codex and
  grok report nothing. `report` survives as an operator-selectable basis, not
  the default.
- **Fetch rates from provider pages at runtime.** Rejected: violates the
  zero-external-references invariant (ADR-003) and trades a visible staleness
  discipline for silent scraping fragility.

## Consequences

### Positive
- Cross-provider cost becomes comparable, and the plan-vs-API trade-off is
  visible instead of hidden behind $0s.
- Marker conventions (`≈`, `*`) keep estimated and partial figures honest.

### Negative
- A standing hand-maintenance tax with a silent failure mode when rates go
  stale — mitigated only by the stamped verification date and the same-commit
  rule.
- Multiple concurrent subscriptions of one tier are not yet modelled;
  archived lanes without an input/cache split cannot be re-estimated and fall
  back to reported-or-nothing.

### Non-goals
- Does not change the token-count vocabulary (ADR-010 owns that).
- Does not attempt invoice reconciliation — every figure is explicitly an
  estimate or a self-report.

## See also

- SKILL.md — the `tokens_total`/pricing passage; AGENTS.md Landmines — the
  `PRICING` registry entry
- `tests/run.sh` — pricing assertions (entries, z.ai rates, `≈` marker)
- ADR-010 (token comparability), ADR-014 (the hand-maintained-registry
  pattern), ADR-003 (why no runtime rate fetch)
