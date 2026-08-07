---
status: accepted
date: 2026-07-27
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-status.sh"
  - "assets/ff-monitor.html"
  - "assets/guard-preamble.txt"
---

# ADR-008: Stall Detection Trusts `last_activity_s`, Never `state: running`

## Decision (one sentence)

A lane counts as stalled when its live stream has been silent past
`FLEETFLOW_STALL_SECONDS` (`last_activity_s`, default 600), never from process
state; `live_signal: false` means "cannot tell", not "healthy"; and grok
worktree lanes are covered solely by the worker-authored `.ff-heartbeat` file.

## Context

Through the whole 2.7-hour Codex hang of 2026-07-27 (ADR-007), `ff-status`
reported both wedged lanes as `running` with `elapsed_s` climbing normally —
a stalled lane is indistinguishable from a working one by process state. The
only tell was that their `<run>/<id>.events.jsonl` mtimes had frozen ~160 s
after spawn. So the detector measures *silence*: the mtime of whatever the
model writes **while it works** — codex's/pi's `--json` event stream, a
claude/glm session transcript, or the worker heartbeat. Past the threshold the
lane flips to `state: "stalled"` (plus `stalled: true`), and the monitor draws
a frozen amber pip captioned with the silence, not the elapsed clock.

Three boundaries are load-bearing:

- **Artifact and `.err` files are not activity.** They are created by the
  shell redirect at launch and untouched until exit, so they cannot
  distinguish work from a wedge — an early build counted them and flagged
  every healthy 10-minute sonnet lane as stalled.
- **`live_signal: false` = cannot tell.** Claude/grok lanes spawned without
  `--worktree` have no attributable stream (a non-worktree lane's cwd is the
  shared main checkout, so neither a heartbeat there nor a shared transcript
  dir can be attributed to a lane). Their `stalled: false` must never be read
  as healthy — the monitor keeps rendering them as running because it cannot
  show a verdict the data doesn't support.
- **Grok worktree lanes are heartbeat-only.** Grok's `--output-format json`
  buffers the whole turn and writes once at exit — by design, because
  adopting `streaming-json` would mean reconstructing the buffered envelope
  `ff-collect` gates on from an event shape this repo has not re-verified.
  Until that is done, grok's only live signal is the guard preamble's
  heartbeat clause: worktree workers append a line to a git-excluded
  `./.ff-heartbeat` after each major step (rookery's `parcel progress`
  pattern filed down to one file), and ff-status counts its mtime as a live
  stream. The heartbeat deliberately never touches the envelope.

## Alternatives considered

- **Trust process liveness / `state: running`.** Rejected on direct evidence:
  the 2.7 h hang was `running` throughout.
- **Count artifact/`.err` mtimes as activity.** Tried and reverted — false
  positives on every healthy long lane (see above).
- **Switch grok to `--output-format streaming-json` for live events.**
  Deferred, not rejected: it is one flag, but it changes the result envelope
  the collect gate parses; adopting it requires re-verifying that envelope
  first. Recorded in SKILL.md as deliberately out of scope until then.
- **Report `stalled: false` for uncovered lanes.** Kept, but only alongside
  `live_signal` — collapsing "cannot tell" into "healthy" is the lie the
  tri-state exists to prevent.

## Consequences

### Positive
- Wedged lanes surface within the threshold instead of after hours;
  `ff-status --exit-stalled` (exit 14) lets a watchdog branch without parsing.
- Coverage is honest: every lane says whether it *can* be judged.

### Negative
- Non-worktree claude/grok lanes remain genuinely uncovered — one more reason
  the doctrine says spawn mutating workers with `--worktree`.
- A model that legitimately thinks silently longer than the threshold shows a
  false stall (tunable via `FLEETFLOW_STALL_SECONDS`).

### Non-goals
- Does not decide what to *do* about a stall (reaping is `ff-clean --reap`;
  killing is the orchestrator's call).
- Does not promise grok live introspection in the monitor.

## See also

- SKILL.md § Safety — the stall-detector and `live_signal` entries
- `scripts/ff-status.sh` — the detector; `assets/ff-monitor.html` — the
  frozen amber pip rendering
- ADR-007 — the incident that forced this design
