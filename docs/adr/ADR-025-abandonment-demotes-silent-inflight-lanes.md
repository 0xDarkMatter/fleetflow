---
status: accepted
date: 2026-08-20
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-status.sh"
  - "scripts/ff-aggregate.py"
  - "scripts/ff-widget.sh"
  - "assets/ff-runcard.js"
  - "assets/ff-dashboard.html"
  - "assets/ff-monitor.html"
---

# ADR-025: Silence Past An Abandonment Threshold Demotes An In-Flight Lane To `abandoned`

## Decision (one sentence)

A `running` or `stalled` lane whose `last_activity_s` exceeds
`FLEETFLOW_ABANDON_SECONDS` (default 21600 = 6 h) is demoted to a new FINAL
state `abandoned` — applied in `ff-status` regardless of `live_signal`, ranked
between `failed` and `done`, and excluded from every "in flight"/"live"
definition — so runs walked away from weeks ago stop rendering as live,
animating, and re-polling forever.

## Context

`started`-without-`result` is the definition of `running` (ADR-021 depends on
that asymmetry), and the stall detector (ADR-008) can only escalate it to
`stalled` — a state that is still *in flight*. Neither state had any exit that
did not require a journalled `result` or a teardown. Measured 2026-08-20 on
this machine: 5 lanes `running` 4.8 days after their last activity, lanes
`stalled` for 19 and even **42 days**, all counted in `live_runs`, all pulsing
in the dashboard's "live now" section, all burning the aggregator's graduated
re-read timer at its 15-minute cap — forever. Two distinct leaks fed this:

- **Stalled is a snapshot verdict with no expiry.** ADR-008 deliberately made
  it "wedged right now"; nothing ever concluded "and nobody is coming back".
- **`live_signal: false` lanes can never even stall.** ADR-008's false-positive
  guard (no live stream → no stall verdict) is correct at the minute scale it
  was built for, but it left uncovered lanes reading `running` for 19+ days.

The insight that unlocks a verdict for both: `last_activity_s` is already a
true lower bound on total silence for *every* lane — it folds in the artifact,
`.err`, and result-envelope mtimes ("a write there IS real activity",
ADR-008) and falls back to the lane's own start time. What it cannot support
is a *minute*-scale claim ("wedged mid-work"); a 6-hour claim ("nothing at
all has been written and there is no result — this was walked away from") is
decisive even without a live stream. No worker turn on this fleet legitimately
writes nothing to disk for six hours. So abandonment trusts the same activity
clock as ADR-008, at a timescale where "cannot tell" collapses into "dead".

Placement: the demotion lives in `ff-status.sh` because lane state has exactly
one owner — `ff-aggregate.py`'s contract block forbids reimplementing it, and
a dashboard-side cosmetic fix would have left `live_runs`, the tab-title
badge, the re-read timer, and `ff-widget` all still lying.

`STATE_RANK` position: after `failed`, before `done`. Abandonment is stale
news, not live risk (never outranks `stalled`/`running`), but a run that
quietly died must never headline as finished. The same order is mirrored in
`ff-aggregate.py`, `ff-widget.sh`'s jq rank, `ff-dashboard.html`'s sort rank,
and `ff-monitor.html`'s sort rank — keep all five in step.

Visual language: faded amber (`opacity:.35`), never animated, never the amber
stall chip — "was stalled, long dead". The frozen-amber-pip rule from
ADR-008/ff-monitor still holds for `stalled`; abandoned is one step quieter.

`--exit-stalled` also fires (exit 14) on an abandonment demotion: for
`live_signal:false` lanes it is the *first* silence verdict a watchdog can
ever get, and for covered lanes the watchdog fired hours earlier at the stall.

## Alternatives considered

- **Demote in `ff-aggregate.py`'s roll-up.** Rejected: the aggregate's own
  contract says lane state has one owner; a roll-up-level demotion would leave
  lane pips animating inside run detail and `ff-widget`/`ff-monitor` (which
  read ff-status directly) still calling the lanes running.
- **CSS-only fix (stop animating old runs).** Rejected: cosmetic; `live_runs`,
  totals, the "live now" nav section, the ⚠/▶ tab badge, and the graduated
  re-read burn would all still count abandoned runs as live.
- **Reuse `failed`.** Rejected: `failed` means a journalled non-zero `rc` — a
  real observed outcome. Overloading it destroys the failure roll-ups the
  dashboard reports and hides the "this fleet leaks abandoned runs" signal.
- **Have ff-sweep demote or clean these runs.** Rejected: ff-sweep is manual
  housekeeping that reclaims *disk* under a landed/archived safety predicate
  (ADR-020); classification must not wait for an operator to run a teardown
  tool, and a run can be abandoned yet deliberately kept on disk.
- **Exempt `live_signal:false` lanes (strict ADR-008 reading).** Rejected:
  those lanes are the worst offenders (they can never stall), and at the 6-hour
  horizon the total-filesystem-silence evidence is decisive without a stream.
- **A shorter default (1–2 h).** Rejected: long healthy lanes exist, and an
  uncovered lane's clock only ticks on artifact/stderr writes, which can
  legitimately be sparse. 6 h errs toward keeping runs "live" too long rather
  than condemning a slow lane; `FLEETFLOW_ABANDON_SECONDS` tunes it.

## Consequences

### Positive
- Old runs stop reading as live: `live_runs`, the "live now" section, tab-title
  badges, and the pulse/halo/sweep animations now describe only real activity.
- The aggregator's graduated re-read timer stops burning on dead runs — an
  abandoned run costs one scandir per aggregate, like any finished run.
- `live_signal:false` lanes finally have an honest terminal state.

### Negative
- A lane that legitimately works for longer than the threshold *without
  writing anything at all to disk* would be demoted while alive; the verdict
  self-heals on its next write (state derives fresh per read), and the
  threshold is env-tunable.
- One more state every consumer must render; the five STATE_RANK copies are a
  hand-sync burden (mitigated by tests pinning each).

### Non-goals
- Does not reap, archive, or otherwise touch the run on disk — ff-sweep
  (ADR-020/024) remains the only reclaim path, and its verdict tables are
  unchanged.
- Does not alter ADR-008's stall semantics or threshold; `stalled` still means
  "wedged right now, substantiated by a live stream".
- Does not journal anything: `abandoned` is derived at read time, so a
  respawn's fresh `started` record revives the lane exactly as before.

## See also

- [ADR-008](ADR-008-stall-detection-trusts-activity-not-state.md) — the stall
  detector this extends (and whose false-positive guard this respects at the
  minute scale)
- [ADR-020](ADR-020-sweep-reclaims-only-archived-and-landed.md) — why reclaim
  stays a separate, manual concern
- [ADR-021](ADR-021-chips-are-lanes-not-a-second-worker-class.md) — the
  started-without-result asymmetry that makes `running` sticky by design
- `scripts/ff-status.sh` — the demotion block; `scripts/ff-aggregate.py` —
  STATE_RANK + roll-up
