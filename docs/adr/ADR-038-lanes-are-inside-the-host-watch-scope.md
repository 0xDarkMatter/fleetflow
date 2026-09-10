---
status: accepted
date: 2026-09-10
supersedes: []
superseded-by: []
touches:
  - "scripts/_env.sh"
  - "scripts/ff-doctor.sh"
  - "scripts/ff-plan.sh"
---

# ADR-038: Lane Worktrees Are Inside the Host Repo's Watch Scope; fleetflow Says So Before a Spawn, and Never Edits the Host's Config

## Decision (one sentence)

Because lane worktrees live under `.fleetflow/<run>/wt-<id>` **inside** the
host repo, fleetflow treats a registered dev server serving that repo as a
hazard it must **name before a spawn** — a `host-watchers` row in
`ff-doctor --offline` and a `host-watchers` check in `ff-plan lint`, both
`warn`/`advisory`, both from one detector in `_env.sh` — while the fix itself
(`**/.fleetflow/**` in the watcher's ignore list) stays in the host repo, where
it belongs.

## Context

During the mapforge fleet build (2026-09-10) the machine went sluggish with
28 GB of RAM free and **0.2 GB of commit free** against a 136 GB limit. One
process held it: the registered `mapforge` Process Compose service — a Vite
dev server with `working_dir: X:/Roam/mapforge` — at **87.9 GB of private
commit**, 19k handles, 0% CPU. Its log showed Vite doing full reloads and
"changed tsconfig detected, clearing cache" for every file under
`.fleetflow/mapforge-qa/wt-*/` and `.fleetflow/mapforge-p3/wt-*/`. Every
lane worktree is a full checkout with its own `node_modules`; the watcher
crawled each new one and never released the module graph. Restarting the
service freed 88 GB instantly. A one-line change in the victim's
`vite.config` (`server.watch.ignored: ['**/.fleetflow/**']`) prevents it.

Lanes are in-repo on purpose. [ADR-021](ADR-021-chips-are-lanes-not-a-second-worker-class.md)
attributes a chip's transcript by its cwd, `ff-spawn` keeps the scratch tree
out of git through `.git/info/exclude`, and [ADR-020](ADR-020-sweep-reclaims-only-archived-and-landed.md)'s
sweep boundary is the `.fleetflow` dir it finds. Moving lanes out is a
separate decision (see Non-goals). What this ADR fixes is that **fleetflow
and long-running host-repo processes did not know about each other** — the
same root as the 2026-09-04 orphaned-test-runner teardown problem, seen from
the spawn side.

## Decision

1. **One detector.** `ff_host_watchers REPO` in `scripts/_env.sh` parses the
   Process Compose services file (`FLEETFLOW_HOST_SERVICES`, default this
   author's stack path) for services whose `working_dir` is the repo and
   whose command looks like a watcher (vite, webpack, next, nuxt, astro,
   remix, parcel, turbo, nodemon, `tsx watch`, `--watch`, `--reload`), and
   reports whether the repo's watcher config mentions `.fleetflow`
   (`yes` / `no` / `unknown` when no recognised config file exists). Absent
   services file → exit 3, **not applicable** — never "clean".
2. **`ff-doctor --offline` row `host-watchers`.** Machine-wide: every
   registered `working_dir` that has a `.fleetflow` directory on disk, and
   whether its watcher ignores it. `advisory` when any does not; `ok`
   otherwise; `ok` "not applicable" without a services file.
3. **`ff-plan lint` check `host-watchers`.** Per repo: a `warn` finding for
   each registered watcher serving the plan's repo without an ignore
   (`no`) or without a config the detector could verify (`unknown`). Disarmed
   without a services file.
4. **Landmine, front and centre.** The hazard is written in this repo's
   `AGENTS.md` and in `SKILL.md`'s safety section, with the one-line fix.

## Alternatives rejected

- **Refuse to spawn unless `--force`.** A hard stop on a property of the
  *host* repo gets `--force`d into muscle memory within a week, and then
  protects nothing. `warn` on every lint is seen every time and costs
  nothing.
- **fleetflow edits the host repo's watcher config.** It is not fleetflow's
  file; a bundler-specific patch applied by a tool that does not build the
  project is a new class of surprise. Say it, do not do it.
- **A marker file in `.fleetflow/` plus a journal note at spawn.** A second
  copy of the same fact, read by nobody at the moment it matters. The lint
  warning already fires at plan time and the doctor row at preflight.
- **Detect from `ports.yaml` instead.** The port registry records what is
  allocated; `process-compose.yaml` records what is *running*, with the
  `working_dir` and the command. Detection needs the latter.

## Consequences

### Positive
- The next served repo to receive lanes is told, at lint and at preflight,
  before the first worktree is created.
- One detector, two surfaces, one definition of "watcher".
- Portable by construction: without the services file both checks read
  "not applicable" rather than silently passing.

### Negative
- The watcher regex is a heuristic; an unrecognised dev server (a bespoke
  script) is invisible to it. The landmine text covers what the regex does
  not.
- `unknown` (no recognised config) warns even when the bundler ignores
  `.fleetflow` some other way. Acceptable: a warning is the cheap direction.

### Non-goals
- **Where lanes live.** A `--lanes-outside` mode that places worktrees as
  siblings of the repo (the `new-lane.sh --sibling` pattern) would remove the
  hazard structurally, but it touches ADR-021's chip cwd attribution, the
  `info/exclude` mechanism and ADR-020's sweep boundary. That is its own
  decision record, to be written after those dependencies are enumerated.
- The teardown side (reaping test runners a lane left behind) — the
  2026-09-04 session — stays separate work; this ADR names the shared root.

## See also

- [ADR-020](ADR-020-sweep-reclaims-only-archived-and-landed.md) — the sweep
  boundary that assumes in-repo lanes
- [ADR-021](ADR-021-chips-are-lanes-not-a-second-worker-class.md) — cwd
  attribution that assumes in-repo lanes
- `~/.claude/rules/dev-servers.md` — why every dev server on this machine is
  a registered Process Compose service (which is what makes detection possible)
- `X:/00_Orchestration/compose-portless/logs/mapforge.log` — the incident's
  primary evidence
- `tests/run.sh` — `doctor: host-watchers`, `ff-plan: lint host-watchers`
