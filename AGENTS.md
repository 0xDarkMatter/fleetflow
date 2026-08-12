# Agent Instructions — fleetflow

Heterogeneous cross-provider agent fleets (GLM / Codex / Grok / Pi / Anthropic)
orchestrated from one Claude Code session, plus the machine-wide run dashboard.
Extracted from [claude-mods](https://github.com/0xDarkMatter/claude-mods)
`skills/fleetflow` on 2026-08-01 with full history (subtree split).

**The repo root IS the skill.** [SKILL.md](SKILL.md) is the entry point and the
operational playbook — read it first; this file only carries repo mechanics.

## Run / test

| Task | Command |
|---|---|
| Full behavioural suite (313 assertions) | `bash tests/run.sh` |
| Provider preflight | `bash scripts/ff-doctor.sh --offline` (or `--live`) |
| Dashboard server (supervised only — see landmines) | `python scripts/ff-serve.py --port 8161` |

## Structure

| Path | What lives there |
|---|---|
| `SKILL.md` | The skill: doctrine, lifecycle, routing, safety. Single source of truth. |
| `scripts/` | `ff-doctor` / `ff-spawn` / `ff-collect` / `ff-status` / `ff-run` / `ff-clean` / `ff-sweep` / `ff-chip` / `ff-archive` / `ff-findings` / `ff-widget` / `ff-import` (bash, Skill Resource Protocol) + `ff-aggregate.py` / `ff-serve.py` (dashboard) |
| `assets/` | `ff-monitor.html` (single-run live monitor), `ff-dashboard.html` (machine-wide dashboard), `guard-preamble.txt` (worker guard) |
| `references/` | worker contracts (per-model launch/collect/auth), native Workflow extraction notes, model routing |
| `docs/adr/` | Architecture Decision Records — the append-only WHY behind every standing rule below. The directory is the index; `adr-lint --strict` runs inside the test gate |
| `tests/` | `run.sh` — the one gate; run it before landing anything |

## Landmines

- **`C:\Users\Mack\.claude\skills\fleetflow` is a JUNCTION to this repo.** Edits
  here are live in every Claude session's skill copy immediately. Renaming or
  moving root files breaks skill resolution. **Any skills-sync/installer that
  copies INTO the skills dir writes THROUGH the junction into this repo** — the
  2026-08-01 11:48 sync test overwrote uncommitted work here with stale copies
  and git stayed CLEAN (content matched HEAD), so the loss was invisible to
  `git status`. Two incident classes now confirmed: untracked files get
  deleted, tracked files get silently REVERTED. After any sync event, diff
  against the newest authoring transcript, not just git.
- **The `fleetflow` Process Compose service (https://fleetflow.lab, port 8161)
  runs `scripts/ff-serve.py` FROM THIS REPO** with this repo as CWD. Editing
  `ff-dashboard.html` changes the live page on the next request; editing
  `ff-serve.py` needs `process restart fleetflow`. The repo dir is therefore
  CWD-locked while the service runs — nothing may delete/rename the repo root.
- **Scripts follow the Skill Resource Protocol**: stdout is data, chatter on
  stderr, semantic exit codes (`0` ok, `2` usage, `3` cached/missing, `7`
  unreachable, `10` worker failed, `12` escape detected, `14` lane stalled).
  Tests grep for specific markers (e.g. the torn-write guard comment, `.sq.stalled`,
  `STATE_RANK`) — keep those strings when refactoring.
- **Grok lanes have no live stream** (buffered `--output-format json` by
  design) — do not "fix" the monitor to show grok activity without
  re-verifying the streaming envelope against `ff-collect`'s gate; grok
  WORKTREE lanes are stall-covered by the `.ff-heartbeat` file instead.
  See [docs/adr/ADR-008](docs/adr/ADR-008-stall-detection-trusts-activity-not-state.md).
- **Never double-isolate a chip.** The chip UI can start a session in its own
  fresh worktree (fixed since [claude-code#64605](https://github.com/anthropics/claude-code/issues/64605),
  which used to force the primary checkout). When `ff-chip open` has already made
  the lane, take the plain option with `cwd` set to that lane: `ff-status`
  resolves a lane's transcript by encoding the **session's cwd**, so a chip in
  `.claude/worktrees/<slug>` writes its transcript and `.ff-heartbeat` where
  fleetflow never looks — the lane goes dark and reads stalled while the chip
  works normally. The seed prompt asks the chip to report a cwd mismatch;
  that detects it, nothing prevents it. Two things in `ff-chip` look like litter and are not: the
  `.ff-heartbeat` seed (without it a fresh lane reads `stalled` on the first
  poll — no transcript means `last_activity_s` falls back to a garbage epoch),
  and the `started`-without-`result` asymmetry (that is what makes the lane read
  running, which is what switches on live transcript introspection).
  See [docs/adr/ADR-021](docs/adr/ADR-021-chips-are-lanes-not-a-second-worker-class.md).
- **`ff-sweep` owns `.fleetflow/` and NOTHING else — never point it at
  `.claude/worktrees/`.** Those are Claude Code session state, not fleetflow's
  to reap, and one that looks abandoned may be a live session (see
  `~/.claude/rules/worktree-boundaries.md`). The discovery walk deliberately
  descends *through* `.claude/worktrees/` — runs hosted inside a session's
  worktree are real runs — but only ever acts on the `.fleetflow` dir it finds
  there. Equally load-bearing: the tracked-vs-untracked check lives in
  **ff-sweep**, NOT in `ff-clean --force` — `--force` is meant to discard a
  failed lane's dirty tree and must keep doing so; ff-sweep passes it only for
  runs it has proven carry zero tracked modifications.
  See [docs/adr/ADR-020](docs/adr/ADR-020-sweep-reclaims-only-archived-and-landed.md).
- **Do not add a `--landed` flag to `ff-clean` — it was built and deleted.**
  `git rev-list --count $BASE..HEAD` is already 0 once a lane is merged (the
  same question as `merge-base --is-ancestor`), so the existing "zero commits +
  clean" row reclaims landed lanes today. A test pins that equivalence. The
  disk that accumulated was ff-clean never being *run*, not ff-clean refusing.
- **`tests/run.sh` exports its own `FLEETFLOW_HOME` — never remove that line.**
  `ff-clean` archives before it removes (ADR-011), so every ff-clean exercise
  appends a throwaway `rc` run to the machine-level history the dashboard
  renders. Unisolated, the suite polluted the real store on every invocation,
  multiplied by lane count whenever a fleetflow run ran the suite inside its
  own workers: 81 of 120 unique runs on this box were test fixtures by
  2026-08-12. A guard assertion at the end of the suite pins the real store
  byte-unchanged.
- **`ff-archive`'s `repo_label` must keep the `.claude/worktrees/` collapse.**
  Runs are now routinely driven from inside Claude Code worktree sessions, and
  a bare `basename` labels those with the session slug alone — orphaning the
  run from its repo's dashboard group the moment it is archived, which is the
  live-vs-archived divergence the roll-up comment in that file forbids.
- **`ff-clean` archives before it removes** — teardown is the last moment the
  run's data exists; never reorder the archive step below the removal loop.
  See [docs/adr/ADR-011](docs/adr/ADR-011-archive-before-remove.md).
- **`ff-serve.py` is deliberately ONE process** (request-driven rebuilds). Do
  not split out a watcher — the predecessor's watcher died silently (contract
  block in the file). See [docs/adr/ADR-002](docs/adr/ADR-002-ff-serve-is-one-process.md).
- **`ff-dashboard.html` has ZERO external references and must keep them** — it
  must work offline, from `file://`, and in a network-less preview pane; a
  test enforces it (the one CDN string is a provenance comment, not a fetch).
  See [docs/adr/ADR-003](docs/adr/ADR-003-dashboard-zero-external-references.md).
- **`/api/doctor.json?live=1` spends real model calls.** Click-gated, cached
  15 min server-side; never on the poll path or a timer (a test asserts no
  `setInterval` drives it). See [docs/adr/ADR-004](docs/adr/ADR-004-live-probes-click-gated-never-timed.md).
- **The dashboard's Fleet view carries a hand-maintained capability matrix**
  (`const HARNESS`) — it encodes contracts no run artifact reports; when a
  model's contract changes in SKILL.md, change it in the SAME commit (a test
  asserts every spawnable model appears).
  See [docs/adr/ADR-014](docs/adr/ADR-014-fleet-view-three-registers.md).
- **The dashboard's `const PRICING` registry is hand-maintained** (like
  `HARNESS`) — a stale rate silently mis-prices every ≈ estimate, so rate or
  model changes update it (and the `PLANS` tier table — blended share of the
  monthly fee, never $0) in the same commit; tests pin the entries, z.ai
  rates for GLM, the `≈` marker, and the no-native-dialog rule.
  See [docs/adr/ADR-015](docs/adr/ADR-015-pricing-basis-and-blended-plans.md).
- **The `brain`→`model` rename (2026-08-05) left a load-bearing fallback
  order** — on legacy journal records `brain` must win the alias fallback
  (`.brain // .model`); reversing it reads a launch id as an alias, and the
  external formats ff-status scans were deliberately NOT renamed. A
  legacy-journal test pins the round trip.
  See [docs/adr/ADR-017](docs/adr/ADR-017-model-rename-alias-fallback-order.md).
- **Dashboard `localStorage` keys are `ffd.*`, the monitor's are `ff.*`** —
  the pages can share one origin and `ff.sort` means different things to
  each; the split is load-bearing, not cosmetic.
  See [docs/adr/ADR-013](docs/adr/ADR-013-localstorage-namespace-split.md).
- **Never `git switch` / checkout a branch in the repo root.** The junction
  `C:\Users\Mack\.claude\skills\fleetflow` → this repo means the checked-out
  branch IS the live skill every session loads, and the `fleetflow` Process
  Compose service holds this dir as CWD. All development happens in worktree
  lanes; `main` stays parked on `main`. See [Landmines](AGENTS.md#landmines)
  incident notes (junctions, service CWD-lock).
- **Windows `jq.exe` emits CRLF — strip `\r` on EVERY `jq -r` capture.**
  A raw `$(jq -r …)` or `< <(jq -r …)` carries a trailing `\r` that silently
  breaks `=` comparisons, `[ -f ]` checks, `case` matches, and `--fp` lookups.
  Four independent victims in one run (2026-08-10, run `waves`): ff-widget,
  ff-run wave, the tests lane's assertions, and the orchestrator itself. Use
  the scripts' `jqr()` helper (`jq -r … | tr -d '\r'`) or append
  `| tr -d '\r'` — there is no safe raw capture on this platform.
