---
status: accepted
date: 2026-09-10
supersedes: []
superseded-by: []
touches:
  - "scripts/_env.sh"
  - "scripts/ff-doctor.sh"
  - "SKILL.md"
---

# ADR-041: Lane Concurrency Is Sized From Commit Headroom, Re-Read Between Waves, and Advisory

## Decision (one sentence)

`ff-doctor --offline` reports a `lane-capacity` row — how many concurrent
lanes the machine's **commit** headroom supports right now,
`floor((commit_free − FLEETFLOW_MEMORY_RESERVE_MB) / FLEETFLOW_LANE_MEMORY_MB)`
clamped to `[1, FLEETFLOW_MAX_CONCURRENT]` — computed by one helper in
`_env.sh` (`ff_lane_capacity` over `ff_commit_headroom`), stated as
"not applicable" where the platform cannot be measured, and **advisory
always**: it sizes the orchestrator's next wave, it never gates a spawn.

## Context

fleetflow's fan-out doctrine (SKILL.md) sized waves on two axes: cores
(`min(16, cores−2)`, inherited from the native engine) and endpoint quota
(≤4–6 per provider, ≤2–3 for codex on Windows). Neither is the axis this
machine dies on.

Measured on TITAN (64 GB RAM, 136 GB commit limit = RAM + 8 GB C: pagefile +
64 GB D: pagefile) on 2026-09-10:

- Baseline before any lanes: **~70 GB committed** — 13 Claude Desktop session
  hosts at 771 MB (9.8 GB), one Vite dev server at 11.5 GB, Chrome 10 GB,
  kernel pool 10.6 GB, ~40 registered `.lab` services ~10 GB, maestro 3.7 GB.
- Per running lane: a headless `claude -p` worker averaged 652 MB (range
  650–930 MB); node tooling inside a lane worktree averaged 88 MB but reached
  359–369 MB where the lane drove its own vitest/tsc/language server.
- That leaves roughly 55–60 GB of headroom: a real ceiling near **35–45
  concurrent lanes**, before second-order growth.

And the failure mode is specifically *commit*, not RAM. When this box wedged
it had **0.2 GB of commit free with 28 GB of RAM still free** — a "free RAM"
reading would have reported healthy every single time. Two readings taken
minutes apart while writing this: commit free 61.6 GB, RAM free 33.1 GB.
Different numbers; only one of them is fatal.

Disk-resident lanes are cheap and running lanes are not: mapforge alone held
75 lane worktrees across 5 runs with only ~20 lane node processes alive. The
thing to size is **concurrency**, not the plan.

## Decision detail

1. **One helper, two layers.** `ff_commit_headroom` returns
   `free_mb / total_mb / source` per platform — Windows
   `Win32_OperatingSystem.FreeVirtualMemory` (the commit figures),
   Linux `MemAvailable + SwapFree`, macOS a documented `vm_stat` approximation
   — and **exits 3** where it cannot measure. `ff_lane_capacity` turns that
   into a lane count. Exit 3 must be read as *not applicable*, never as
   *plenty*: the same rule ADR-038 set for a missing services file.
2. **Advisory, never a gate.** The row informs the wave size the orchestrator
   picks by hand (`ff-run resume` is deliberately sequential; the orchestrator
   fans out). A hard refuse would be `--force`d into habit within a week —
   ADR-038's reasoning, unchanged.
3. **Floor of 1.** The formula may never reach "spawn nothing" on its own. A
   box with no headroom gets one lane and an `advisory` row saying so.
4. **Re-read between waves, not once per run.** Headroom drifts downward
   during a run as host watchers and MCP hosts accumulate — process count
   went 614 → 792 over one build. A run-start-only reading is stale by wave 3.
5. **Named next to `host-watchers`.** ADR-038's hazard grows *with* lane
   count: the Vite server that sat at 87.9 GB was being fed by the lanes
   themselves. Sizing that counts only worker cost still walks an unguarded
   repo into exhaustion, so the doctrine cites both rows together. They are
   one problem from two ends.

## Alternatives rejected

- **Calibrate `per_lane` from the running process table.** The obvious idea,
  and unsound on this data: 90 node processes averaging 262 MB with a single
  dev server at **11,943 MB**, and 53 claude processes averaging 335 MB most
  of which are idle session hosts rather than lane workers. A mean over that
  distribution is meaningless and a max is absurd. Honest calibration needs a
  per-lane peak recorded in the **journal** (ff-spawn sampling its own
  worker's peak private bytes at exit) — which does not exist yet, and is the
  natural follow-up. Until then the estimate is a documented, tunable
  constant that says it is an estimate, not a fabricated measurement.
- **Report free RAM.** Would have said "healthy" at 0.2 GB commit free. This
  is the single most important thing this ADR gets right.
- **Refuse to spawn below a threshold.** See decision 2.
- **Have `ff-spawn` enforce a global concurrency semaphore.** fleetflow spawns
  one lane per invocation by design and holds no cross-invocation state; a
  semaphore would need a lockfile and a reaper, and would fight the
  orchestrator rather than inform it. Out of scope, and probably not wanted:
  the operator throttling deliberately is a feature.

## Consequences

### Positive
- The axis that actually kills the box is now stated before a fan-out, in the
  same preflight that already reports providers and watchers.
- One helper serves any future consumer (a wave sequencer, a widget cell).
- Portable by construction: unmeasurable platforms say so.

### Negative
- `per_lane` is an estimate. A fan-out of browser-driving or test-runner lanes
  costs materially more than 1.5 GB each and the operator must raise it. The
  row prints the constant it used so the assumption is visible, not implied.
- The Windows reading spawns a PowerShell process (~1 s). Fine in a preflight
  row; it must never enter a per-lane loop.
- The number is a snapshot. Between reading it and spawning wave 3, another
  session may have taken the headroom — which is exactly why the doctrine says
  re-read, and why the figure is advice rather than a reservation.

## See also

- [ADR-038](ADR-038-lanes-are-inside-the-host-watch-scope.md) — the host
  watcher that grows with lane count; the other end of this problem
- [ADR-039](ADR-039-status-reads-lanes-in-parallel-order-is-journal-order.md)
  — `ff-status`'s own worker pool is itself a consumer of this headroom
- `~/.claude/rules/dev-servers.md` — why the ~40 registered services in the
  baseline are registered at all
- `tests/run.sh` — `doctor: lane-capacity`, and the helper's clamp/exit-3 cases
