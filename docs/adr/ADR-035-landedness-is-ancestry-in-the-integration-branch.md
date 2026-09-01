---
status: accepted
date: 2026-09-02
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-clean.sh"
  - "scripts/ff-sweep.sh"
  - "scripts/ff-chip.sh"
  - "tests/run.sh"
---

# ADR-035: Landedness Is Ancestry In The Integration Branch, Not A Count From Base

## Decision (one sentence)

Every "does this lane still hold work" question is answered against the
**integration branch** — the manifest `base` when it names a live branch, else
`main`, else `master`, else the main repo's HEAD, always resolved to a sha in
the main repo before any lane-side git call — never by counting commits from
the manifest's recorded base, which on real runs is a sha frozen before the
run started.

## Context

This amends [ADR-020](ADR-020-sweep-reclaims-only-archived-and-landed.md). Its
decision — a sweep reclaims only what is archived and landed, tracked and
untracked dirt are separate verdicts, no `--landed` flag on `ff-clean` — all
stands. One factual claim in its Context does not: that
`rev-list --count $BASE..HEAD` "is **0 for a landed lane** — the same question
as `git merge-base --is-ancestor`". The two are the same question only when
`$BASE` names a live branch, because a branch ref tracks the integration tip.

Real manifests do not hold a branch name. `ff-plan` records
`git rev-parse HEAD` at authoring time (ADR-026), so `base` is a sha frozen
before the run — and a landing never makes a lane's commits reachable from a
commit that predates them. After a `--no-ff` merge landing, `BASE..HEAD`
counts the lane's own commits forever; even a fast-forward landing leaves them
unreachable from the pre-run sha. Observed 2026-09-01 (run `studio-live`,
repo ATDW-Mirror): `git rev-list --count main..fleetflow/studio-live/serve-swr-fix`
was 0 — fully landed — yet `ff-clean` reported "kept 3 commits" for every
merge-landed lane and reclaimed nothing, with or without `--force`.

The claim survived because the test pinning "the equivalence" tested a
different expression than the script ran: the fixture asserted
`rev-list main..LANE_HEAD == 0` (integration branch — true) while `ff-clean`
computed `BASE..HEAD` (recorded base), and the fixture manifest said
`base:"main"` — a branch name no production manifest contains. Fixture and
production diverged exactly where it mattered. The fixtures now record frozen
shas, and the suite pins the **in**equivalence: for a merge-landed lane,
`BASE..HEAD != 0` while `merge-base --is-ancestor <lane> main` holds.

The same frozen-sha-versus-branch-name confusion had two further victims, both
via the `show-ref refs/heads/$BASE || BASE="HEAD"` idiom, which rejects a sha
(never a branch ref) and then resolves the bare string `HEAD` *inside the lane
worktree* as a self-compare (`HEAD..HEAD` = 0): `ff-chip close` recorded
`commits: 0` for every chip on a sha-based run, and `ff-chip open` forked the
lane from the wrong commit while writing the literal string `"HEAD"` into
fresh manifests. This is the identical trap that destroyed a 2-commit lane via
`ff-clean` on 2026-08-25 — the fix generalises it: **a symbolic ref is
resolved to a sha in the main repo, or not used at all.**

Mechanically, `ff-clean` now resolves the integration ref once per run and
counts `rev-list --count INTEG_SHA..HEAD` per lane: count 0 is exactly
`merge-base --is-ancestor`, so the "zero commits + clean → removed" row
reclaims landed lanes regardless of landing style, and a kept lane reports its
true *unmerged* count. `ff-sweep`'s `classify()` already asked the ancestry
question; its fallback (main-repo HEAD) now matches `ff-clean`'s resolution
order so the two can never disagree about what "landed" means — which also
repairs `ff-sweep --reclaim`, whose correctly-classified reclaimable runs were
surviving teardown because the `ff-clean` it shells out to refused them.
`ff-status` already hard-codes `main..HEAD` and needed nothing.

An unresolvable integration ref keeps every lane ("kept for safety") — an
empty left side of the range would read as `HEAD..HEAD` = 0 and remove
everything, so the failure mode stays fail-closed.

## Alternatives considered

- **Keep base-counting and special-case merge landings** (e.g. also test
  `is-ancestor` when the count is nonzero). Rejected: two predicates that can
  disagree invite exactly the drift this ADR corrects; and base-counting is
  wrong for *every* landing style once the base is a frozen sha, not just
  merges — there is no correct case left to preserve.
- **Record the branch name instead of a sha in the manifest.** Rejected:
  ADR-012 needs the frozen sha for cache-key purity and replay, and old
  manifests exist; readers must handle the sha shape regardless.
- **`merge-base --is-ancestor` per lane in `ff-clean` instead of a count.**
  Functionally identical for the reclaim decision, but the count also feeds
  the "kept (N unmerged commits)" detail the operator acts on; one rev-list
  yields both.
- **Resolve the integration branch from `origin/HEAD`.** Rejected: fleets run
  in local-only repos and worktree-hosted checkouts where no remote exists;
  branch-name resolution (`base`→`main`→`master`→HEAD) needs no network and
  matches what landing actually targets on this machine.
- **Leave `ff-chip` alone** (its counts are telemetry, not deletion).
  Rejected: `commits: 0` on every sha-based run is precisely the "measured,
  never self-reported" record lying, and the fix is the same three lines.

## Consequences

### Positive
- Merge-landed lanes reclaim again — the 2026-09-01 `studio-live` shape (every
  lane "kept N commits", nothing reclaimable) cannot recur, and
  `ff-sweep --reclaim` completes instead of reporting survivors.
- The kept detail now says what it means: "N *unmerged* commits".
- Chip close records measure real commit counts on production-shaped runs.
- One resolution order, shared by clean and sweep, written down once (here).

### Negative
- A lane landed by **squash or cherry-pick** still counts its (rewritten-away)
  commits as unmerged and is kept — unchanged from before, inherent to
  sha-identity, and the safe direction; `--force` remains the manual override
  after the operator confirms the squash landed.
- Repos whose integration branch is neither the manifest base, `main`, nor
  `master` fall back to the main repo's HEAD — correct on this machine (main
  checkouts stay parked on the integration branch) but a silent assumption
  elsewhere.

### Non-goals
- No change to what is *eligible* for sweeping (ADR-020's predicate, archive
  ordering, and tracked/untracked split are untouched).
- No new flags anywhere.

## See also

- [ADR-020](ADR-020-sweep-reclaims-only-archived-and-landed.md) — the decision
  this amends; its reclaim predicate stands, its equivalence claim is refuted
- [ADR-026](ADR-026-ff-plan-authors-the-manifest-spawn-consumes-it.md) — why
  the manifest base is a frozen sha
- [ADR-011](ADR-011-archive-before-remove.md) — the archive-before-remove
  ordering the reclaim path still honours
- `tests/run.sh` — the inequivalence pin, the sha-base fixtures (`mkrun`,
  `sw`, `chsha`), and the 2026-08-25 bare-HEAD destroyer test
