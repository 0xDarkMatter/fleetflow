---
status: accepted
date: 2026-08-12
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-chip.sh"
  - "scripts/ff-run.sh"
---

# ADR-021: Chips Are Lanes, Not A Second Worker Class

## Decision (one sentence)

A manually spawned `spawn_task` chip is adopted as an ordinary fleetflow lane —
its own worktree, the guard preamble, a `started` record at open and a `result`
record at close — under the non-spawnable model alias `chip`, which `ff-run
resume` skips the way it skips `native`.

## Context

A chip is real parallel work that fleetflow could neither see nor protect
itself from. Two distinct problems, and the second is the dangerous one.

**It was invisible.** Nothing journalled a chip, so it contributed nothing to
`ff-status`, the dashboard, cost roll-ups, teardown, or the sweep. Work happened
on the machine that no fleetflow surface could account for.

**It was hostile.** Per [claude-code#64605](https://github.com/anthropics/claude-code/issues/64605)
a chip session starts in the **primary checkout on whatever branch is currently
out** — it does not get a worktree. So a chip dirties the exact tree
`ff-collect --check-main-clean` watches ([ADR-009](ADR-009-escape-guard-and-baseline.md)),
making the escape guard fire on friendly work; and two chips on one repo share a
single index, which is the write-time clash worktrees exist to prevent.

The fix is not a new worker class with its own telemetry, launcher, and
collector. It is giving the chip the lane a spawned worker already gets, and
journalling it identically — after which every existing surface works with no
knowledge that a chip was involved. `ff-collect` gates it, `ff-status` reports
it, `ff-clean` reclaims it, `ff-archive` records it, `ff-sweep` classifies it.

That is unusually cheap because of an existing property worth naming: **the live
telemetry in `ff-status` is gated on `state=="running"` and the worktree path,
not on the model.** A chip working in `.fleetflow/<run>/wt-<id>` writes its
session transcript to `~/.claude/projects/<encoded-workdir>/`, which is exactly
where `ff-status` already looks — so tokens, tools, density, `model_id` and
stall detection all arrive for free. The only thing a chip lacks is a wrapper
process to journal its exit, which is precisely what `ff-chip close` supplies.
`started` with no `result` is what makes the lane read running; that single
asymmetry is the whole mechanism.

Building it surfaced one genuine defect. A freshly opened lane read **`stalled`
on the very first poll**: with no transcript and no heartbeat, `last_activity_s`
falls back to a garbage epoch (~33 days, measured) and trips the detector
immediately. Spawned workers never expose this because they start writing within
seconds — the chip is the first lane class where the gap between *lane created*
and *work started* is human-scale, because a person has to click. `ff-chip open`
therefore seeds `.ff-heartbeat`, which starts the activity clock at open and
makes the eventual stall honest rather than noisy: a chip lane still silent past
`FLEETFLOW_STALL_SECONDS` is one nobody ever clicked, and that is worth seeing.

`chip` stays **unspawnable** (`ff-spawn` rejects it, as it rejects `native`)
because fleetflow cannot launch a chip — a human clicks it. `ff-run resume`
therefore reports chip packets as skipped rather than pretending to replay them,
the same terminal-fact treatment `ff-import` gives native Workflow results
([SKILL.md § Importing a native Workflow run](../../SKILL.md)). A cache key is
still computed, for shape compatibility with every reader, but it can never be
acted on.

## Alternatives considered

- **Seed the chip prompt with `git switch -c <slug>` instead of a worktree.**
  Rejected: that still runs in the primary checkout, so concurrent chips collide
  on one index and the branch under the orchestrator's feet changes. The lane
  must be a separate working tree, which is the same conclusion
  `worktree-boundaries` reaches for every other parallel writer.
- **A `chip` worker that fleetflow launches itself.** Rejected: it would be a
  headless `claude -p`, i.e. exactly `ff-spawn --model sonnet`. The point of a
  chip is that a human drives it; automating it deletes the thing being adopted.
- **Adopt the chip's branch after the fact (pure `ff-import` style).** Rejected
  as the only mode: post-hoc adoption cannot prevent the primary-checkout
  collision, which is the actual harm. Opening the lane first is what protects
  the tree; `close` is the adoption half.
- **Have `close` trust the chip's self-reported outcome.** Rejected: commits and
  a dirty tree are facts the lane cannot misstate, and a gate that believes a
  worker's prose is the failure mode structured verdict metadata exists to
  avoid. `close` measures.
- **Let the lane read `stalled` until the chip is clicked.** Rejected: an amber
  "wedged" pip for a lane that is merely waiting on a human trains the operator
  to ignore the stall signal, which is the one signal ADR-008 exists to keep
  trustworthy.

## Consequences

### Positive
- Chips stop dirtying the primary checkout, so the escape guard's signal stays
  meaningful and concurrent chips no longer share an index.
- Chip work appears in status, the dashboard, cost roll-ups, archives and the
  sweep with no per-surface changes.
- Live telemetry and stall detection apply to chips at no implementation cost.

### Negative
- `close` is a manual step. A chip that is never closed leaves its lane reading
  running, then stalled — visible and honest, but it needs a human.
- fleetflow cannot measure a chip's cost independently; it reads whatever the
  session transcript reports, like any claude-family lane.
- Two ways to create a lane now exist (`ff-spawn`, `ff-chip open`), so lane
  creation logic lives in two places and must stay in step.

### Non-goals
- Does not make chips replayable, schedulable, or spawnable.
- Does not change `spawn_task` behaviour or work around claude-code#64605 —
  it routes around the consequence.

## See also

- [ADR-005](ADR-005-hub-and-spoke-worker-topology.md) — a chip returns its
  result through adoption, not a side channel
- [ADR-008](ADR-008-stall-detection-trusts-activity-not-state.md) — the
  activity-not-state rule the heartbeat seed preserves
- [ADR-009](ADR-009-escape-guard-and-baseline.md) — the guard a chip in the
  primary checkout was breaking
- `scripts/ff-chip.sh`; `scripts/ff-run.sh` (the resume skip)
