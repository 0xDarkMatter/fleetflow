# Agent Instructions — fleetflow

Heterogeneous cross-provider agent fleets (GLM / Codex / Grok / Pi / Anthropic)
orchestrated from one agent session - typically Claude Code, but the seat is
harness-agnostic (ADR-033) - plus the machine-wide run dashboard.
Extracted from [claude-mods](https://github.com/0xDarkMatter/claude-mods)
`skills/fleetflow` on 2026-08-01 with full history (subtree split).

**The repo root IS the skill.** [SKILL.md](SKILL.md) is the entry point and the
operational playbook — read it first; this file only carries repo mechanics.

## Run / test

| Task | Command |
|---|---|
| Full behavioural suite (549 assertions) | `bash tests/run.sh` |
| Provider preflight | `bash scripts/ff-doctor.sh --offline` (or `--live`) |
| Dashboard server (supervised only — see landmines) | `python scripts/ff-serve.py --port 8161` |

## Structure

| Path | What lives there |
|---|---|
| `SKILL.md` | The skill: doctrine, lifecycle, routing, safety. Single source of truth. |
| `scripts/` | `ff` (dispatcher: forwards to the scripts, plus native `env`/`open`/`logs`/`watch`) + `ff-plan` / `ff-doctor` / `ff-spawn` / `ff-collect` / `ff-status` / `ff-run` / `ff-clean` / `ff-sweep` / `ff-chip` / `ff-archive` / `ff-findings` / `ff-widget` / `ff-import` (bash, Skill Resource Protocol) + `ff-aggregate.py` / `ff-serve.py` (dashboard) |
| `assets/` | `ff-monitor.html` (single-run live monitor), `ff-dashboard.html` (machine-wide dashboard), `guard-preamble.txt` (worker guard), `plan.tmpl.md` + `packet.tmpl.md` (ff-plan templates), `roles/` (twelve role cards, ADR-031), `wave-packets/` (finder templates) |
| `docs/ARCHITECTURE.md` | how the shipped system works — components, data stores, invariant map. Living; drift is a bug |
| `references/` | worker contracts (per-model launch/collect/auth), native Workflow extraction notes, model routing |
| `docs/adr/` | Architecture Decision Records — the append-only WHY behind every standing rule below. The directory is the index; `adr-lint --strict` runs inside the test gate |
| `completions/` | `ff.bash` — tab-completion for the dispatcher (subcommands, models, run names) |
| `docs/REFERENCE.md` | env-var registry mirror (source of truth: `ff-doctor --env`) + exit-code table |
| `tests/` | `run.sh` — the one gate; run it before landing anything |

## Landmines

Some of these are **conditional on how this checkout is mounted**, not universal:
the skill junction and the supervised dashboard service are this author's setup.
Each such landmine states its precondition - check it holds before obeying it. On
a plain clone with neither, the git rules relax to ordinary practice.

- **If this repo is mounted as a skill (README -> Install), that mount is a
  junction/symlink INTO this checkout** - on the author's box,
  `C:\Users\Mack\.claude\skills\fleetflow`. Where that holds, edits
  here are live in every Claude session's skill copy immediately. Renaming or
  moving root files breaks skill resolution. **Any skills-sync/installer that
  copies INTO the skills dir writes THROUGH the junction into this repo** — the
  2026-08-01 11:48 sync test overwrote uncommitted work here with stale copies
  and git stayed CLEAN (content matched HEAD), so the loss was invisible to
  `git status`. Two incident classes now confirmed: untracked files get
  deleted, tracked files get silently REVERTED. After any sync event, diff
  against the newest authoring transcript, not just git.
- **Never `git add -A` / `git add .` here — stage explicit paths.** Because the
  repo root may be a live skill behind that mount, other sessions can edit these
  same files while you work, and `-A` silently annexes their in-flight changes into
  your commit. `0a83f5d` and `0bca912` (2026-08-01) each carry a slice of an
  unrelated prompt-file aliasing guard (`ff-spawn.sh`, `tests/run.sh`,
  `references/worker-contracts.md`) for exactly this reason. History was left
  as-is — the content is correct and tested, only the attribution is wrong — so
  do not be misled by those two commit messages when reading `git log -p` for
  the aliasing guard's rationale.
- **If you run the dashboard as a supervised service pointed at this checkout**
  (the author does: port 8161, behind `https://fleetflow.lab`), that service runs
  `scripts/ff-serve.py` FROM THIS REPO with this repo as CWD. Editing
  `ff-dashboard.html` changes the live page on the next request; editing
  `ff-serve.py` needs a service restart. The repo dir is therefore
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
- **Do not add a `--landed` flag to `ff-clean` — it was built and deleted —
  and never revert ff-clean to counting from the manifest `base`.** ff-clean
  counts commits unreachable from the INTEGRATION branch (manifest base if it
  names a live branch, else main/master — see
  [docs/adr/ADR-035](docs/adr/ADR-035-landedness-is-ancestry-in-the-integration-branch.md)),
  so a landed lane counts zero whatever the landing style and the existing
  "zero commits + clean" row reclaims it. Base-counting looks equivalent but
  is not: real manifests record a frozen sha, and `rev-list BASE..HEAD` keeps
  counting a merge-landed lane's own commits forever (the 2026-09-01 "kept 3
  commits" bug — a test pins the inequivalence). The disk that accumulated
  was ff-clean never being *run*, not ff-clean refusing.
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
- **Where either precondition above holds, never `git switch` / checkout a
  branch in the repo root.** A skill mount means the checked-out branch IS the
  live skill every session loads, and a supervised dashboard holds this dir as
  CWD. All development happens in worktree lanes; `main` stays parked on `main`.
  On a plain clone with neither, branch normally.
- **`ff-plan lint` never passes findings through argv, and parses each packet
  once — both look like premature optimisation and are neither.** A real run's
  findings JSON is hundreds of KB against a ~32k-char Windows command line, so
  `jq --argjson "$FINDINGS"` dies E2BIG (rc 126) printing NOTHING; serialise by
  reading files (`--rawfile`/stdin) only. And the scope matrix is ONE awk pass
  over a prebuilt index, not per-check re-parsing — the old shape forked per
  owned-path pair (~31k pairs) and took 24m43s where this takes ~8s. **Both are
  invisible at test scale**, which is why the "simpler" `--argjson` survived so
  long; `tests/run.sh` C8 pins them. Fixed 2026-09-05.
- **Windows `jq.exe` emits CRLF — strip `\r` on EVERY `jq -r` capture.**
  A raw `$(jq -r …)` or `< <(jq -r …)` carries a trailing `\r` that silently
  breaks `=` comparisons, `[ -f ]` checks, `case` matches, and `--fp` lookups.
  Four independent victims in one run (2026-08-10, run `waves`): ff-widget,
  ff-run wave, the tests lane's assertions, and the orchestrator itself. Use
  the scripts' `jqr()` helper (`jq -r … | tr -d '\r'`) or append
  `| tr -d '\r'` — there is no safe raw capture on this platform.
