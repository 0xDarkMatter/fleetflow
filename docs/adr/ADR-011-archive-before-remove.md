---
status: accepted
date: 2026-08-01
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-clean.sh"
  - "scripts/ff-archive.sh"
---

# ADR-011: `ff-clean` Archives Before It Removes

## Decision (one sentence)

`ff-clean` calls `ff-archive` (appending a compact run summary to
`~/.fleetflow/history.jsonl`, outside every repo) **before** its removal loop,
and only `--no-archive` opts out — the archive step must never be reordered
below removal.

## Context

Teardown is the last moment the run's data exists. Before this design, a run
vanished entirely once `ff-clean` deleted its `.fleetflow/<run>/` directory —
its lanes, models, token counts, and outcomes were simply gone, and the
machine-wide dashboard could show no history for exactly the runs that had
finished cleanly enough to be cleaned. The fix is an ordering invariant, not a
feature: archive first, remove second, because any failure between the two
steps then errs on the side of "archived twice" rather than "existed never".

The archive is deliberately an *index, not a backup*: a compact record (lanes,
models, states, elapsed, tokens, commits, cost) appended to a JSONL file that
lives outside every repo, so it survives repo deletion too. Prompts, diffs,
and transcripts are not copied. A cleaned run keeps its dashboard card from
this record alone.

## Alternatives considered

- **Archive as a separate manual step.** Rejected: the moment it is optional
  and separate, the runs that most need archiving (casually cleaned ones) are
  the ones that skip it.
- **Full backup of the run dir.** Rejected: run dirs contain worktrees,
  transcripts, and cache litter — copying them defeats cleanup and duplicates
  data git already holds for committed lanes.
- **Archive inside the repo (e.g. `.fleetflow/history/`).** Rejected: the
  record must survive the repo's own deletion, and per-repo history fragments
  the machine-wide view.

## Consequences

### Positive
- No run disappears without a trace; the dashboard's history section is
  populated as a side effect of normal hygiene.
- The ordering makes data loss require an explicit flag (`--no-archive`)
  rather than an oversight.

### Negative
- `history.jsonl` grows without bound (compact records make this slow) and is
  a machine-local single file — it is not synced or backed up by any repo.

### Non-goals
- Not a backup: prompts, diffs, and transcripts are deliberately excluded;
  recovery of committed lane work remains git's job.
- Does not decide retention/rotation of `history.jsonl`.

## See also

- AGENTS.md Landmines — "`ff-clean` archives before it removes"
- `scripts/ff-clean.sh` — the ordering; `scripts/ff-archive.sh` — the record
  shape (`--dry-run` prints without appending)
- SKILL.md § "The machine-wide dashboard" — "History survives cleanup"
