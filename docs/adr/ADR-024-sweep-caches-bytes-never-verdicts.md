---
status: accepted
date: 2026-08-14
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-sweep.sh"
---

# ADR-024: A Sweep Caches Bytes, Never Verdicts

## Decision (one sentence)

`ff-sweep` caches only display data (byte counts; reused discovery paths); the eligibility classification is computed live from git on every invocation and is never cached.

## Context

The performance report ([SWEEP-PERF-2026-08](../reports/SWEEP-PERF-2026-08.md))
timed `ff-sweep --list` machine-wide and attributed the cost stage by stage.
The verdict work, the per-lane git and jq classification, is **4.8%** of the
per-run loop; the two display columns that fill the byte count and the age,
both full recursive tree walks, are most of the rest, and the only one this
decision caches is the byte count, with those two columns together at **93%**
of the per-run work. Caching that one field removes most of the cost; caching
the verdict would remove almost none of it.

The asymmetry that picks which of the two may be cached is safety, not speed.
A stale byte count prints a wrong number in a display column and nothing
else: `bytes` is not read by `classify()`, not by the `eligible` test, not by
`--older-than`, and is not passed to `ff-clean`. A stale verdict is a
different category of harm, because the predicate decides deletion: a cached
`reclaimable` served past the moment its lane gained a tracked modification
or an unmerged commit would delete work that exists nowhere else. The report
(§6) records a run dir whose classification moved between measurement passes
from activity inside its lane worktrees alone, with no change to the run
dir's own direct children, which is precisely the case a verdict cache keyed
on a shallow fingerprint would get wrong.

## Alternatives considered

- **Cache the classification keyed on the repo HEAD.** A `git rev-parse HEAD`
  advances on commit, so the cache would invalidate whenever a lane commits.
  Rejected because HEAD movement does not capture the dangerous state. An
  uncommitted tracked modification, a new untracked file, or an in-flight lane
  with no commit flips `reclaimable` to `holds-work` without advancing HEAD,
  and catching any of them cheaply would need either a recursive walk (the
  cost this decision removes) or a per-lane `git status` (which is the
  classification).
- **A TTL-based verdict cache.** Rejected because any TTL, however short, is a
  window in which a run whose lane changed after the cache write can be read
  `reclaimable` and then deleted on the next reclaim. The bound we want on the
  verdict is "always fresh"; a TTL bounds it to "fresh within N seconds", a
  strictly weaker guarantee for the one datum whose staleness deletes work.

## Consequences

- A machine-wide sweep is bounded by `git` speed, not by `du`: once the byte
  count is cached or skipped, the recursive tree walks that dominated the cost
  are gone, and what remains is the live git classification of each lane.
- `--no-size` is the zero-state escape hatch: it skips `du` entirely, prints
  `-` in the bytes column, and omits the on-disk roll-up, so a sweep can run
  with no cache file present and no size computation at all.
- The classification stays the part that cannot be made free, since it is
  recomputed from live `git` on every invocation; a sweep across many roots
  is therefore slower than a dashboard poll. This is inherited from ADR-020
  and is acceptable for a housekeeping command an operator runs deliberately.
- A future verdict cache, if one is ever warranted, must carry its own safety
  story (the report's re-classify-before-delete step is the mechanism that
  would make one safe); this decision sets no precedent for one and adds no
  such cache.

## See also

- [SWEEP-PERF-2026-08](../reports/SWEEP-PERF-2026-08.md): the measurement and
  proposal this decision graduates; §6 is the case against caching the
  classification.
- [ADR-020](ADR-020-sweep-reclaims-only-archived-and-landed.md): the safety
  predicate this decision does not change, whose live classification is the
  datum this decision never caches.
