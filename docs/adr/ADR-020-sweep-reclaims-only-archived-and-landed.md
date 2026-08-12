---
status: accepted
date: 2026-08-12
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-sweep.sh"
---

# ADR-020: A Sweep Reclaims Only What Is Archived And Landed

## Decision (one sentence)

`ff-sweep` may delete a run directory only when its record already exists in the
history store **and** every lane's commits are an ancestor of the run's base;
lanes with tracked modifications or unmerged commits are never eligible, and
untracked leftovers are a separate verdict that must be opted into after their
paths have been printed — all of which is decided in `ff-sweep`, which adds no
flag to and changes no behaviour of `ff-clean`.

## Context

`ff-clean` answers "tear down *this* run". Nothing answered "what is still on
disk across this machine", and its decision table never auto-removed a committed
lane — correct while the work is unlanded, wrong forever afterwards. Every
successful run therefore accumulated silently: measured 2026-08-12, one repo held
**1.6 GB across 12 never-cleaned runs**, 27 stale `fleetflow/*` branches, and 6
still-registered worktrees. Because `.fleetflow/` is gitignored, `git status`
could not see any of it either.

The first design added a `--landed` flag to `ff-clean`, on the premise that its
decision table never removed a committed lane. **That premise was wrong, and the
flag was built and then deleted.** `ff-clean` counts commits as
`git rev-list --count $BASE..HEAD`, which is **0 for a landed lane** — the same
question `git merge-base --is-ancestor` asks. Its existing "zero commits +
clean → removed" row therefore already reclaims landed lanes. The accumulated
disk was never `ff-clean` refusing to act; it was `ff-clean` never being run,
because nothing on the machine reported that these runs existed. **Visibility was
the gap, not a teardown rule** — which is why this ADR touches only `ff-sweep`.

The distinction that *is* missing is not in teardown but in classification:
"landed" versus "still holds work" is not visible anywhere before you decide to
delete something. `merge-base --is-ancestor` is the right primitive for it —
better than a proxy like a branch-name match or a raw commit count, which break
under rebase and squash-merge, changing the sha without changing the fact.

Building it revealed a second distinction that decides whether the tool is usable
at all. On first run the safe predicate reclaimed **nothing**: both large runs
were blocked by dirty trees. Inspection showed the dirt was *one untracked path
per lane* — a plan doc, a screenshots directory — with zero tracked
modifications. Collapsing "tracked" and "untracked" into one notion of dirty is
technically safe and practically useless, so they are separated: tracked changes
are work the base does not have and are never swept; untracked leftovers are
usually litter, occasionally not, and so get their own verdict whose paths are
always listed before anything is removed.

Discovery, teardown, and state are not reimplemented. Root resolution mirrors
`ff-aggregate.py`'s precedence so the sweep and the dashboard cannot disagree
about which repos exist, and reclaiming shells out to `ff-clean`, which already
owns the NTFS retry, cache-dir removal, and reap anchors.

The tracked-vs-untracked check lives in `ff-sweep`, deliberately **not** in
`ff-clean --force`. `--force` is documented to discard a failed lane's dirty
working tree, and that is its whole purpose — a worker that edited files and
never committed is exactly what it exists to clear. Hardening it would break the
contract its callers rely on. `ff-sweep` is new automation with no such callers,
so the restraint belongs there: it passes `--force` only for runs it has already
proven carry zero tracked modifications.

## Alternatives considered

- **Age-based reclaim ("delete runs older than N days").** Rejected as the
  predicate: age is uncorrelated with whether work was preserved, so it deletes
  unlanded lanes from an abandoned run — precisely the case where the lane is the
  only copy. Age survives as an optional *filter* on top of the safe predicate.
- **Reclaim anything with commits, trusting the branch to hold the work.**
  Rejected: `ff-clean` deletes the branch along with the worktree, so an unmerged
  branch is not a safety net, it is the thing being destroyed.
- **Report only, never delete.** Rejected as the sole design — it leaves the
  1.6 GB to a manual `--force` whose blast radius is larger than the sweep's.
  Retained as the *default mode*: `--list` is what runs without flags.
- **Sweeping `.claude/worktrees/` too.** Rejected outright: those are Claude Code
  session state, not fleetflow's to reap, and one that looks abandoned may be a
  live session. The walk descends *through* them to find runs hosted inside a
  session worktree, but only ever acts on the `.fleetflow` directory it finds.
- **Requiring the operator to archive first.** Rejected: archiving is
  non-destructive and is the property the whole safety story rests on, so
  `--reclaim` performs it and refuses to remove anything if it fails.
- **A `--landed` flag on `ff-clean`.** Built, then deleted — see Context. It was
  redundant with the existing zero-commit row, and a redundant flag that *looks*
  load-bearing is worse than no flag: the next reader would trust it to be the
  thing protecting landed lanes. A test now pins the equivalence
  (`rev-list --count BASE..HEAD == 0` ⟺ `merge-base --is-ancestor`) so this is
  not rediscovered the hard way.
- **Hardening `ff-clean --force` against tracked modifications.** Rejected:
  discarding a failed lane's dirty tree is precisely what `--force` is for, and
  existing callers depend on it. The restraint belongs in the new automation.

## Consequences

### Positive
- Reclaiming is provably non-destructive: everything removed is either already
  in the base or already in the history store, usually both.
- The machine-wide view exists at all — "what has fleetflow left on this box"
  was previously unanswerable.
- `--include-untracked` recovers the large runs, but only after their untracked
  paths have been shown.

### Negative
- A run whose worker died without journalling a `result` reads `active` forever
  and is never reclaimed. Deliberate — the failure mode errs toward keeping.
- Verdicts are computed by walking worktrees and running `git` per lane, so a
  sweep across many roots is slower than a dashboard poll. It is a housekeeping
  command, not a monitoring one.
- The history store still grows without bound (inherited from ADR-011); this
  decision does not address retention.

### Non-goals
- Does not touch `.claude/worktrees/`, branches outside `fleetflow/<run>/*`, or
  any repo's tracked content.
- Does not decide when a run *should* be swept — no scheduling, no automatic
  invocation. The operator runs it.

## See also

- [ADR-011](ADR-011-archive-before-remove.md) — the archive-before-remove
  ordering this decision depends on for its safety story
- `scripts/ff-sweep.sh` — discovery + policy; `scripts/ff-clean.sh` — the
  `--landed` row and the tracked-vs-untracked rule
- AGENTS.md Landmines — the `.claude/worktrees/` boundary
