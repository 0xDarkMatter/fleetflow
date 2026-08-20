---
status: accepted
date: 2026-08-20
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-plan.sh"
  - "scripts/ff-doctor.sh"
---

# ADR-030: The Plan Lint Gates The Spawn, Runs Inside Doctor, And Reports Armed/Disarmed Per Check

## Decision (one sentence)

`ff-plan lint` (scope-conflict matrix with `registries:` single-writer as a
HARD finding, dependency-edge and DAG checks, packet-contract checks, ADR
BLUF presence via `adr-touching`, routing sanity, barrier justification,
declared bounds) exits 10 on findings and is the gate before `ff-spawn`; it
also runs as a section of `ff-doctor --offline` so a fleet cannot be blessed
with a conflicted plan, and every check reports `armed` or
`disarmed(reason)` — a silently skipped check is itself a failure mode.

## Context

The lint mechanises what were planning *conventions*: Axiom retrofitted a
mechanical enqueue-time conflict gate after overlap incidents (its
owns/modifies matrix ports here directly), and its shared-registry incidents
(parallel parcels racing on `pyproject.toml`) justify treating `registries:`
overlap as HARD, not WARN (open question 3) — a registry merge conflict
costs an integration lane, not a re-run. The armed/disarmed requirement is
bought experience from fleet-ops (postmortem 2026-07-28): config keys read
in the wrong case meant the landing test gate *silently never ran* on any
repo while reporting green; a gate must therefore distinguish "checked and
passed" from "did not check".

Placing the lint inside `ff-doctor --offline` (open question 2) follows
doctor's charter — refuse to bless a fleet that cannot succeed — and costs
nothing offline: every input is a local file.

## Alternatives considered

- **Advisory lint (warnings, spawn proceeds).** Rejected: Axiom's history is
  the counter-example — plan-time prose checks were advisory and overlap
  shipped anyway; the mechanical gate is the part that worked.
- **`registries:` overlap as WARN.** Rejected: WARN-and-proceed on shared
  registries is exactly the failure Axiom recorded; `--force` remains for
  the orchestrator's deliberate override.
- **Pass/fail only, no armed status.** Rejected: the fleet-ops incident
  shows a disarmed gate is indistinguishable from a passing one, for weeks.
- **Lint only in doctor (no standalone).** Rejected: the authoring loop
  wants sub-second re-lints without a full preflight.

## Consequences

### Positive
- Disjointness, deps, constraints, and routing become spawn preconditions;
  `--json` gives the orchestrator structured findings to act on.

### Negative
- One more doctor section to keep fast; frontmatter-less legacy packets
  lint as `disarmed(no frontmatter)` rather than failing — graceful
  degradation mirrors Axiom's backfill path, at the cost of a weaker verdict
  on old runs.

## See also

- [ADR-020](ADR-020-sweep-reclaims-only-archived-and-landed.md) — the
  prove-before-acting register this joins
- [FFPLAN-2026-08](../plans/FFPLAN-2026-08.md) §6 — the full check catalogue
