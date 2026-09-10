---
status: accepted
date: 2026-09-10
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-status.sh"
  - "scripts/ff-doctor.sh"
  - "tests/run.sh"
---

# ADR-039: ff-status Reads Lanes in Parallel; Order Is Journal Order; Verdicts Are Reduced

## Decision (one sentence)

`ff-status` computes lane records in `FLEETFLOW_STATUS_WORKERS` forked
subshells (default `nproc`, capped at 8) over round-robin chunks of the
journal rows, each lane writing its own record file and stall marker under a
per-emit temp dir; `emit` then reduces the markers into `STALL_ANY` and
concatenates the records **by journal index**, so the JSON document, its lane
order and its exit codes are identical at every worker count.

## Context

Every process spawn on this box costs ~150 ms (Windows, MSYS). A lane costs
several — jq over its event stream or result envelope, `git` for a worktree
lane, `awk` over `.err`, and for an in-flight lane a `tasklist` probe — so a
lane cost ~360 ms serially and the 140-lane godaddy-build took 56–99 s.
`ff-aggregate.py` calls `ff-status` once per run under a 180 s timeout, which
put a hard ceiling near 500 lanes on the machine-wide dashboard, and the
suite's 200-lane fixture alone took 69 s.

The serial loop already had three load-bearing shapes that any parallel
version had to keep: lane records go through a **file**, never a growing
argv (the 2026-09-09 argv-overflow incident); the journal rows are
`0x1f`-separated because tab is IFS whitespace and `read` collapses empty
columns; and the `--exit-stalled` verdict is a global `STALL_ANY` set inside
the loop and read after `emit` returns.

## Decision

- **Workers are forked subshells, not `xargs bash -c`.** A `( … ) &` fork
  inherits the primed `MT` stat cache, every function and the run-level
  context (`RUNDIR`, `now`, `WT_INTENT`, `integ_sha`, `base_sha`) for free.
  A fresh `bash` per lane would pay a spawn just to start and then re-stat
  the run dir, and `export -f` cannot carry an associative array at all. The
  extra processes are bounded at the worker count per emit, not per lane.
- **Round-robin dealing, not contiguous blocks.** In-flight lanes cost more
  than finished ones and cluster at the journal's tail; contiguous chunks
  would hand one worker every expensive row.
- **One file per lane, named by zero-padded journal index.** Two workers
  appending to one file interleave past the pipe buffer and tear records.
  The assembly walks the index with bash builtins — not `cat *.json`, which
  is locale-collated and hands N paths to one argv.
- **Verdicts travel as marker files.** A worker's `STALL_ANY=1` dies with its
  subshell; `emit` ORs the `<idx>.stalled` markers after `wait`. A stalled
  lane still exits 14 under `--exit-stalled` at any worker count — the suite
  pins it.
- **Completeness is checked by count.** A worker that dies mid-chunk leaves a
  gap; `emit` fails rather than emit a partial document that exits 0 — the
  exact silent failure the argv incident taught.
- **Cap at 8.** Measured 2026-09-10 (32 cores): the 200-lane fixture went
  69 s → 20 s → 11.8 s → 10.8 s at 1 / 4 / 8 / 16 workers. Past 8 the box is
  contending on the disk and on MSYS fork cost, not on lane work.
- **Cleanup on every path.** `--watch` calls `emit` per tick, so the temp dir
  is per emit and removed on success, on failure, and by an EXIT trap that
  kills the workers first (an async subshell inherits SIGINT ignored, so a
  ctrl-c would otherwise let it finish into a dir that is already gone).

## Alternatives rejected

- **`xargs -P` / GNU `parallel` invoking a per-lane `bash -c`.** One bash
  start per lane on Windows is most of what the serial loop was paying for
  already, and the per-lane body reads a dozen run-level variables plus an
  associative array that no `export` can carry. Rejected on cost and on
  plumbing.
- **A single shared NDJSON file with `flock`.** MSYS `flock` is unreliable
  across forks on NTFS, and even a correct lock serialises the write while
  leaving completion order — not journal order — as the file order. Per-lane
  files make ordering a property of the *name*, which needs no lock.
- **Carry the stall verdict inside the lane record.** Would work, but the
  record's field set is frozen by `ff-monitor.html` and the 592-assertion
  suite; a marker file changes nothing a consumer sees.
- **A Python rewrite of `ff-status`.** Would remove the spawn cost outright,
  but the script embeds the stall doctrine (ADR-008), abandonment (ADR-025),
  landedness (ADR-035) and the final-reply contract, each with WHY comments
  at the site. Porting is a separate decision with its own risk; this one
  keeps every line of that logic where it is.

## Consequences

### Positive
- 200-lane fixture 69 s → 11.8 s; godaddy-build 56 s → 12.8 s. The
  aggregator's 180 s ceiling moves from ~500 lanes to well past 2,000.
- The per-lane body is a named function with a stated file contract, which
  is easier to test and to read than a 330-line loop body.
- Byte-identical output at every worker count is asserted, not assumed.

### Negative
- The loop body now runs in a subshell, so a future field that needs to flow
  back to `emit` must go through a file too. The contract comment on
  `lane_record` says so; forgetting it fails silently (the variable is set
  and lost), which is why the suite compares serial and parallel records.
- Up to 8 concurrent `git` / `jq` processes per status call. On a run with
  many worktree lanes that is 8 concurrent `git log` walks against the same
  object store; measured fine here, but a shared-drive checkout may want
  `FLEETFLOW_STATUS_WORKERS=2`.

### Non-goals
- Parallelising the run-level work (manifest, journal query, orchestrator
  lookup). Those are a handful of spawns per emit and do not scale with lane
  count.
- Changing what a lane record contains. Same fields, same order, same
  semantics.

## See also

- [ADR-008](ADR-008-stall-detection-trusts-activity-not-state.md) — the
  stall verdict this reduces
- [ADR-025](ADR-025-abandonment-demotes-silent-inflight-lanes.md) — abandonment, the
  other `STALL_ANY` source
- `scripts/ff-status.sh` — the `lane_record` contract block and the worker
  driver's guard comments
- `tests/run.sh` — `status: 200-lane run in Ns (budget)`, `journal
  first-appearance order`, `--exit-stalled exits 14 with parallel workers`
