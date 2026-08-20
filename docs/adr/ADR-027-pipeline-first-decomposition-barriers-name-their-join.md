---
status: accepted
date: 2026-08-20
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-plan.sh"
  - "assets/plan.tmpl.md"
---

# ADR-027: Plans Decompose Pipeline-First; Every Barrier Must Name What It Joins

## Decision (one sentence)

A fleet plan is a dependency DAG in which each lane flows to its own
downstream (its Adversary, its fix loop) independently, and a barrier — a
point where a stage waits for *all* prior lanes — is legal only when the plan
names what the barrier joins (integrated-tree refute, cross-lane dedup,
land), with an unjustified barrier being an `ff-plan lint` finding.

## Context

Axiom's parcel system assigned work to lockstep waves: wave N+1 waited for
all of wave N. That shape is easy to reason about and was right for one
operator watching ~8 parcels, but it is barriers *everywhere* — the slowest
lane in each wave holds the whole fleet hostage, and at fleetflow scale
(20-lane fan-outs) the idle cost dominates. The native Workflow tool's
control-flow doctrine is the corrective, and it ports cleanly
([native-workflow-insights §3](../../references/native-workflow-insights.md)):
pipeline is the default, `parallel()` is a barrier that must be justified,
and the smell test — barrier → pure transform → barrier means the middle
never needed the barrier — applies verbatim to lane DAGs.

Failure isolation comes with the shape: one lane failing gates out at
collect while its siblings proceed; a wave model instead converts one
failure into a fleet-wide stall.

## Alternatives considered

- **Keep wave assignment (Axiom Step 5).** Rejected: correct for its era's
  serial-attention constraint, wasteful under fleetflow's collect-as-they-
  finish gate; ADR-018's wave *pipeline* is a different thing (sequenced
  finder passes, each internally parallel) and keeps its name.
- **Free-form DAG with no barrier rule.** Rejected: barriers silently creep
  back in ("wait for everything, then verify") because they are easier to
  write; requiring a named join makes the cost visible at plan review.
- **Forbid barriers outright.** Rejected: integrated-tree refutation and
  landing are genuine all-lanes joins; the rule is *name it*, not *never*.

## Consequences

### Positive
- Wall-clock approaches slowest-chain rather than sum-of-slowest-per-wave;
  Adversaries start on the first finished lane, not the last.
- Plan review sees every synchronisation point with its justification.

### Negative
- DAGs are harder to eyeball than wave tables; the plan template compensates
  with the dependency sketch + prose-per-edge requirement.

## See also

- [references/native-workflow-insights.md](../../references/native-workflow-insights.md) §3 — the ported doctrine
- [ADR-018](ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md) — the post-build wave pipeline (sequenced passes, not lockstep build waves)
- [FFPLAN-2026-08](../plans/FFPLAN-2026-08.md) §3.2, §6(f)
