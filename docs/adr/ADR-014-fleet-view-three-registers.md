---
status: accepted
date: 2026-08-01
supersedes: []
superseded-by: []
touches:
  - "assets/ff-dashboard.html"
---

# ADR-014: The Fleet View Keeps Spec, Observed, and Capacity as Three Separate Registers

## Decision (one sentence)

The dashboard's Fleet view presents capability as three deliberately separate
registers — **spec** (hand-maintained doctrine, the `HARNESS` matrix, changed
in the same commit as a contract change), **observed** (measured from runs and
history), and **capacity** (a point-in-time `ff-doctor` probe, always shown
with its age) — and they are never merged.

## Context

"What can this box run?" has three answers with different truth values.
*Spec* is doctrine: sandbox posture, whether a model may self-commit,
concurrency ceilings — contracts that live in SKILL.md prose and in no run
artifact, so no scan can derive them. *Observed* is measurement: lanes,
tokens, cost, failures per harness across every run under the roots plus
archived history. *Capacity* is a probe: what `ff-doctor` found when it last
ran, true at that instant only. Merging them is how a dashboard starts lying —
a probe result presented next to doctrine without an age reads as a standing
fact; an observed failure rate presented as spec reads as a contract.

The cost of keeping spec truthful is accepted explicitly: the `HARNESS`
matrix is **hand-maintained**, transcribed from SKILL.md and
`references/worker-contracts.md`, with a same-commit rule — when a model's
contract changes in SKILL.md, the matrix changes in the same commit. Two
mechanical backstops keep the hand-maintenance honest: a test asserts every
spawnable model appears in the matrix, and capacity is always stamped with
the probe's age because it is a point-in-time claim.

## Alternatives considered

- **Derive spec from run artifacts.** Impossible: nothing a run emits records
  "Codex may not self-commit" or a concurrency ceiling — these are contracts,
  not observations.
- **One merged capability table.** Rejected as the core failure mode: it
  erases the distinction between "we promise", "we measured", and "we probed
  at 14:02".
- **Auto-generate the matrix from SKILL.md prose.** Rejected: parsing
  doctrine prose is brittle; the same-commit rule plus the
  every-model-present test is the cheaper reliable contract.

## Consequences

### Positive
- Each figure on the Fleet view carries its epistemic status; stale capacity
  is visibly stale rather than silently wrong.
- Contract drift between SKILL.md and the UI is bounded by the same-commit
  rule and caught by the spawnable-model test.

### Negative
- Hand-maintenance is a standing tax: every contract change is a two-place
  edit, and the same-commit rule relies on authors knowing it (the test
  catches missing models, not stale cell values).

### Non-goals
- Does not decide the probe's spend gating — that is ADR-004.
- Does not extend the same-commit rule beyond `HARNESS` (the `PRICING`
  registry has its own record, ADR-015).

## See also

- SKILL.md § "The machine-wide dashboard" — "The Fleet view answers …"
- AGENTS.md Landmines — the `HARNESS` matrix entry
- `tests/run.sh` — every-spawnable-model-in-HARNESS assertion
