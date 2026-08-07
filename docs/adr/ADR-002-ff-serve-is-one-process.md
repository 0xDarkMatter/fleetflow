---
status: accepted
date: 2026-08-01
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-serve.py"
---

# ADR-002: `ff-serve` Is One Process With Request-Driven Rebuilds

## Decision (one sentence)

The dashboard server (`scripts/ff-serve.py`) is deliberately a single process
that rebuilds its aggregate on request — non-blocking, no detached watcher, no
sidecar rebuild daemon.

## Context

The predecessor dashboards paired a static page with a detached watcher process
that rebuilt the data file on a timer. The watcher died silently — nothing
supervised it, the page kept rendering the last snapshot as if it were live,
and the numbers were stale with no signal. That single failure made the
predecessor dashboards untrustworthy: a dashboard that can silently stop
updating is worse than none, because it converts "no data" into "wrong data
presented confidently".

`ff-serve.py` was designed against exactly that failure when the machine-wide
dashboard landed (2026-08-01). The server that answers the HTTP request is the
same process that decides whether the aggregate needs rebuilding; a rebuild is
triggered by the request (kicked off in a background thread so responses stay
non-blocking) rather than by a standing timer loop. If the process dies, the
page's fetch fails and the UI says so in red with the snapshot's age — the
failure is visible at the surface, not hidden in a dead sidecar.

## Alternatives considered

- **Server + detached watcher (the predecessor design).** Rejected on direct
  evidence: the watcher's silent death is the exact failure mode this design
  removes. Two processes means two things to supervise and one of them had no
  health surface.
- **Cron/scheduled rebuild writing a static file.** Same staleness problem in
  different clothes — the page cannot distinguish "fresh" from "the rebuilder
  stopped running".
- **In-process `setInterval`-style rebuild timer.** Better than a sidecar but
  still burns rebuild work while nobody is looking, and a wedged timer thread
  is as silent as a dead watcher. Request-driven means work happens exactly
  when someone is watching.

## Consequences

### Positive
- One PID to supervise; Process Compose probes `/api/health` and the whole
  surface's liveness is that one check.
- Unreachable server → visible red state + snapshot age on the page; stale
  data can never masquerade as live.
- No rebuild churn on an idle machine.

### Negative
- The first request after a long idle pays the rebuild latency (mitigated by
  the run cache: ~15 ms steady-state, seconds when a live run changed).
- Everything rides on one process — a wedge in the server blocks both serving
  and rebuilding (accepted: that state is visible, unlike the watcher's).

### Non-goals
- Does not constrain the single-run `ff-monitor.html` flow, which deliberately
  uses an external `ff-status --watch` writer plus any static server.
- Does not decide the caching strategy (see the run-cache notes in SKILL.md).

## See also

- Contract block at the top of `scripts/ff-serve.py` (the in-file guard)
- AGENTS.md Landmines — "ff-serve.py is deliberately ONE process"
- SKILL.md § "The machine-wide dashboard" — "Rebuilds are request-driven"
