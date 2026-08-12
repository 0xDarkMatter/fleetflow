---
status: accepted
date: 2026-08-12
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-spawn.sh"
  - "scripts/ff-clean.sh"
  - "scripts/ff-doctor.sh"
---

# ADR-022: raven-bus Integration Is Opt-In Telemetry, Not A Worker Topology Change

## Decision (one sentence)

fleetflow wires into raven-bus for exactly one thing — **additive,
opt-in worker telemetry** (`FLEETFLOW_BUS=1` adds a BUS HEARTBEAT
clause; `ff-clean` tears down the run's bus channels; `ff-doctor`
reports the binary as advisory) — while the `.ff-heartbeat` file stays
the canonical stall signal and hub-and-spoke (ADR-005) stands
unchanged.

## Context

raven-bus (the SQLite agent message bus at `X:\Forge\claude-bus`, CLI
`raven`, built in runs raven2-p1..p3 on 2026-08-12) addresses
`<role>@<run>` consumers on path-style channels — `run = run name,
role = lane id` maps exactly onto fleetflow lanes. ADR-005 named pigeon
for "where cross-worker signalling IS wanted", but pigeon addresses
*projects* (one mailbox per repo), the wrong granularity for lanes
inside one run. `raven tail --json` is a ready-made uniform live feed —
notably covering grok lanes, whose only liveness signal today is the
heartbeat file (ADR-008).

The heartbeat clause changes the effective prompt for guard+worktree
packets, and the journal cache key is a content hash of the prompt —
default-on would invalidate every such key on the machine in one
commit, for a signal nothing consumes yet. Hence opt-in.

Deferred, deliberately:

- **`ff-spawn --acp`** (lanes under `raven acp`, enabling mid-run
  steer/wind-down): the raven side is shipped and adversarially
  verified, but driving a claude lane over ACP requires a vetted ACP
  agent binary (`claude-code-acp` via npm — un-vetted; supply-chain
  rules apply). Plumbing that cannot be end-to-end tested does not
  land.
- **ff-status/dashboard reading the bus**: the file/transcript readers
  stay the single implementation of lane state (ADR-002/ADR-008
  discipline); a second liveness source merges registers with different
  truth values. Revisit with evidence from real `FLEETFLOW_BUS=1` runs.

## Alternatives considered

- **Default-on bus heartbeats** — machine-wide cache invalidation for
  an unconsumed signal; rejected.
- **Replacing the heartbeat file with the bus** — the file is what
  ff-status's stall detector reads (ADR-008); the bus binary's absence
  must never blind stall coverage; rejected.
- **Peer-to-peer worker channels** — explicitly out; ADR-005 stands and
  worker prompts gain no bus-READ instructions. Telemetry is not peer
  coordination.

## Consequences

- `FLEETFLOW_BUS=1` runs get live cross-model telemetry:
  `raven tail --channel run/<run>/telemetry`. Nothing changes for
  anyone else; without `raven` on PATH the clause tells workers to
  skip silently and the file heartbeat carries on alone.
- `ff-clean` on a machine with raven reclaims bus scratch state with
  the run — run channels are as disposable as lane worktrees
  (best-effort, never blocks the clean).
- ADR-005's "the tool is pigeon" pointer is superseded FOR IN-RUN
  signalling by raven-bus; pigeon remains the cross-project mailbox.

## See also

- [ADR-005](ADR-005-hub-and-spoke-worker-topology.md) — the topology
  this ADR deliberately does not change.
- [ADR-008](ADR-008-stall-detection-trusts-activity-not-state.md) — why
  the heartbeat FILE remains canonical.
- raven-bus decision log: `X:\Forge\claude-bus\docs\adr\` (ADR-001..006)
  and `docs/design/raven2-architecture.md` §8 (the P4 phase this
  implements).
