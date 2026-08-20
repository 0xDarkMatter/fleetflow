---
status: accepted
date: 2026-08-20
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-plan.sh"
  - "assets/roles/adversary.role.md"
---

# ADR-028: The Plan Is Refuted Cross-Provider Before The Fleet Spawns

## Decision (one sentence)

`ff-plan refute` spawns one cross-provider Adversary lane — defaulting to a
provider with no build seat in the run, falling back to Pi when every fixed
provider builds — prompted to attack the decomposition (hidden coupling,
unserialised shared writers, unfrozen contracts, unjustified or missing
barriers, unowned spec requirements) before any build lane spawns, with
findings entering the run ledger under wave `plan` and at most two refute
rounds before escalation to a human.

## Context

fleetflow's thesis is that independent cross-provider dissent catches what
same-model review misses, and the repo applies it to code (Adversary lanes),
tests (blind-written, then refuted), and docs (doc-parity refuters). The
plan was the only artifact in the pipeline exempt from its own doctrine —
and it is the highest-leverage artifact to attack: a bad decomposition
caught at the cost of one cheap lane beats eight build lanes colliding at
land. Axiom reached the same conclusion structurally (its planning lane
mandated gate criteria and risk registers) but had no adversarial check;
the native Workflow tool's adversarial-verify pattern supplies the stance
(attack, default-refute on uncertainty), applied here to a plan instead of
a finding.

The two-round cap mirrors ADR-018's fix-loop rule: a plan refuted twice has
a disagreement a human should arbitrate, not a loop to grind.

## Alternatives considered

- **Same-provider plan review (orchestrator re-reads its own plan).**
  Rejected: the author's blind spots are the thing being hunted; a
  self-review shares them by construction.
- **Judge panel over N candidate plans.** Rejected as the default: N full
  decompositions cost real orchestrator attention; the panel remains
  available via `--shape` archetypes for genuinely wide solution spaces.
- **Refute after spawn, alongside the build.** Rejected: findings about
  packet boundaries arrive after the boundaries are running; the cheapest
  moment to move a file between packets is before either lane exists.
- **Fixed Adversary provider.** Rejected (open question 4): the seat's value
  is independence from the builders; "no build seat in this run, else Pi"
  keeps the dissent property as the fleet's composition varies.

## Consequences

### Positive
- Decomposition errors surface at plan cost, not fleet cost; the findings
  ledger and triage machinery are reused unchanged.

### Negative
- One more pre-spawn step and one more cheap lane per run; `--attend none`
  runs may skip it explicitly (skips are reported, never silent — the
  no-silent-caps rule).

## See also

- [ADR-018](ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md) — the fix-loop escalation rule this mirrors
- [references/native-workflow-insights.md](../../references/native-workflow-insights.md) §6 — the adversarial-verify pattern
- [FFPLAN-2026-08](../plans/FFPLAN-2026-08.md) §9
