---
status: accepted
date: 2026-09-10
supersedes: []
superseded-by: []
touches:
  - "scripts/_env.sh"
  - "scripts/ff-spawn.sh"
  - "scripts/ff-chip.sh"
  - "scripts/ff-status.sh"
  - "scripts/ff-clean.sh"
  - "scripts/ff-sweep.sh"
  - "scripts/ff-collect.sh"
  - "scripts/ff-doctor.sh"
---

# ADR-040: Lane Worktrees May Live Outside the Host Repo; One Resolver Places Them, and Readers Trust the Journal, Never the Environment

## Decision (one sentence)

`FLEETFLOW_LANES_ROOT`, when set, places every new lane worktree at
`<root>/<repo-slug>/<run>/wt-<id>` — outside the host repo, beyond any dev
server's watch scope — through **one creation resolver** in `_env.sh`
(`ff_lane_dir`) used only by `ff-spawn` and `ff-chip`; the lane's absolute
path is then written into its `started` journal record, and **every reader**
(`ff-status`, `ff-clean`, `ff-sweep`, `ff-collect`, `ff-chip close`)
resolves a lane journal-first with the in-repo path as its only fallback
(`ff_lane_path`), never from the environment; unset, nothing changes —
paths, journals and `ff-status` output are byte-identical to before.

## Context

[ADR-038](ADR-038-lanes-are-inside-the-host-watch-scope.md) recorded the
incident: the `mapforge` Vite service crawled every lane under
`.fleetflow/<run>/wt-*` and reached **87.9 GB of private commit** with 0.2 GB
free machine-wide. It chose to *name* the hazard (doctor row, lint check)
and left "where lanes live" as a non-goal, because moving them touched three
standing decisions:

- [ADR-021](ADR-021-chips-are-lanes-not-a-second-worker-class.md): a
  claude-family lane's transcript is found by encoding the lane's cwd into
  `~/.claude/projects/<encoded>/`, and `ff-status` built that cwd as
  `$RUNDIR/wt-$id`.
- [ADR-020](ADR-020-sweep-reclaims-only-archived-and-landed.md): "ff-sweep
  owns `<repo>/.fleetflow/` and NOTHING else" — a boundary defined by a
  directory, so a lane outside that directory was by definition not
  sweepable.
- [ADR-034](ADR-034-codex-lanes-self-commit-via-scoped-git-grants.md): the
  codex sandbox is scoped to the worktree and commits only through four
  `--add-dir` grants into the main repo's `.git`.

Measured on 2026-09-10 before this change: **27 sites across 10 scripts**
built the lane path by hand (`ff-status` 8, `ff-clean` 5, `ff-chip` 4,
`ff-sweep` 2, `ff-spawn` 2, `ff-import` 2, one each in `_env.sh`,
`ff-archive`, `ff-collect`, `ff-plan`). That duplication, not any one
dependency, is what made the placement untouchable: a mode that moved lanes
had to move all 27 or silently leave a reader probing the wrong place.

The three dependencies turned out to be one question — *how does a reader
learn where a lane is?* — and the answer that resolves all three is the same:
**the journal says**. A lane is created exactly once, by a script that knows
the path it chose; every later reader can be handed that path instead of
rebuilding it. Once readers stop reconstructing the path, the transcript
encoding follows the real cwd (ADR-021 holds), the sweep boundary can be
stated as "the run dir plus what the journal names" (ADR-020 widens by one
clause), and codex needs nothing new (see below).

The operator keeps **one directory per project** on `X:\`. The obvious
alternative layout — a sibling directory per lane next to the repo, the
`new-lane.sh --sibling` pattern — would have scattered 123 sibling
directories beside a single busy repo (godaddy-build's lane count) and was
rejected for that reason alone.

## Decision

1. **Layout.** `<root>/<repo-slug>/<run>/wt-<id>`. `repo-slug` is
   `<basename>-<8 hex of sha256(canonical path)>`: readable, and
   collision-free across repos that share a basename (`X:/a/api`, `X:/b/api`)
   or differ only in characters the claude-projects encoding would fold
   (`X:/a.b` vs `X:/a-b`). Canonical = absolute, forward slashes, no
   trailing slash, lowercased (NTFS is case-insensitive and Git Bash spells
   the same directory three ways). **Run artifacts never move**: the journal,
   prompts, results, events, `.err`, manifest and packets stay in
   `<repo>/.fleetflow/<run>/`, which is what leaves discovery (`ff-sweep`,
   `ff-aggregate`) and the `info/exclude` mechanism untouched.
2. **One creation resolver.** `ff_lane_dir REPO RUN ID` in `_env.sh` is the
   only function that consults `FLEETFLOW_LANES_ROOT`. Unset, it returns the
   in-repo path verbatim. Only `ff-spawn` and `ff-chip open` call it. The
   companion `ff_run_dir` replaces the hand-built run dir everywhere.
3. **The journal carries the path.** When a lanes root is in use, the
   `started` record gains `worktree: <absolute path>` (`ff-spawn` and
   `ff-chip open` alike). When it is not, the record is unchanged — an
   in-repo run's journal is byte-identical to one written before this ADR.
4. **Readers trust the journal, never the environment.** `ff_lane_path`
   returns the last `started` record's `worktree` for the lane, else the
   in-repo path. It does not read `FLEETFLOW_LANES_ROOT`, on purpose: a
   reader that did would attribute transcripts, count commits, or **run
   `git worktree remove`** at a location guessed from *today's* environment
   rather than the one the lane was created in. `ff-status` folds the field
   into its single journal pass (one more row column); `ff-clean`,
   `ff-collect --auto-commit` and `ff-chip close` resolve per lane;
   `ff-sweep` classifies the in-repo `wt-*` walk **plus** the journalled
   paths, and its survivor check uses the same list.
5. **ADR-020's boundary, widened by exactly one clause.** `ff-sweep` and
   `ff-clean` own `<repo>/.fleetflow/` *plus the lane directories the run's
   journal names*, and nothing else. An outside directory the journal does
   not name — a stray `wt-*` under the root, a lane from a run whose journal
   is gone — is invisible to both: never classified, never reclaimed. After
   teardown `ff-clean` prunes the now-empty `<root>/<slug>/<run>/` and
   `<root>/<slug>/` with `rmdir`, never `rm -rf`, so only fleetflow-shaped
   emptiness is removed.
6. **ADR-021 holds because the encoding follows the resolved path.**
   `ff-status` encodes `ff_lane_path`'s answer, so a chip or claude-family
   lane placed outside the repo is attributed by the cwd claude actually ran
   in. The path is canonicalised to the drive-letter form (`pwd -W`) the same
   way `ff-spawn` canonicalises `REPO`, because that is the spelling claude
   encodes its project directory from.
7. **ADR-034 needs nothing.** An in-repo lane's cwd is
   `<repo>/.fleetflow/<run>/wt-<id>` and the main repo's `.git` is *already*
   outside it — that is why the four scoped grants exist at all. Moving the
   lane elsewhere changes none of the four paths: the worktree metadata dir
   is asked of git (`rev-parse --git-dir`, absolute), and objects / refs /
   logs live under the main git dir regardless. The sandbox reads through the
   worktree's `.git` file to `<repo>/.git/worktrees/<name>` as before. Pinned
   by a stub-codex test that asserts the grants an outside lane receives.
8. **`ff-doctor --offline` states the mode** (`lanes-root` row: in-repo, or
   the root and whether it exists), and `FLEETFLOW_LANES_ROOT` joins the env
   registry and `docs/REFERENCE.md`.

## Alternatives rejected

- **Sibling directories beside the repo** (`<repo>-<run>-<id>`, the
  `new-lane.sh --sibling` form). Removes the hazard just as well, but the
  operator's `X:\` layout is one directory per project and a 123-lane run
  would put 123 siblings next to one of them. A root the operator chooses
  keeps every lane of every repo under one tree.
- **Outside by default.** Rejected for this change: in-repo placement is what
  every existing run, test fixture and reader was built against, and a
  default flip is a separate decision to take once the mode has run in anger.
  The variable is opt-in and unset means "as before", proven byte-for-byte
  by the suite.
- **Readers consult `FLEETFLOW_LANES_ROOT` too** (symmetric resolver). The
  simplest shape, and the dangerous one: it makes teardown correct only while
  the environment at clean time equals the environment at spawn time. The
  journal is the record of what happened; the environment is a guess.
- **Encode the slug with the claude-projects rule** (`[:\/.]` → `-`). Not
  collision-free (`X:/a.b` ≡ `X:/a-b`), and this slug decides which
  directory two repos' lanes share. A hash suffix costs eight characters.
- **Move the run artifacts out too.** Would break discovery (`find` for
  `.fleetflow/`), the dashboard's aggregate cache, the sweep's `rundir`
  identity and `ff-collect --check-main-clean`'s baseline lookup, for no
  gain — a Vite watcher crawling a few JSON files is not the incident.
- **A per-lane private git database** (ADR-034's addendum candidate). Solves
  a different problem (the objects-dir exposure) at the cost of a lane-shape
  rework across every reader; orthogonal to placement.
- **A `--lanes-outside` flag per spawn.** Per-lane placement means a run can
  hold both shapes, which is exactly the state readers must cope with anyway
  (a legacy run under a new environment) — but making it a deliberate
  per-call choice invites it. One environment variable, per session, is the
  shape the operator asked for.

## Consequences

### Positive
- A served repo can host a fleet with zero watcher configuration: the lanes
  are simply not under it. ADR-038's `host-watchers` warning stays for the
  in-repo default and stops applying the moment a root is set.
- Twenty-seven hand-built paths became two functions; the next placement
  change is a one-line edit.
- Readers are environment-independent: a run cleaned from a different shell,
  a different session, or after the variable was unset still resolves every
  lane to where it actually is.
- In-repo behaviour is unchanged and provably so — the suite compares
  `ff-status` output on one fixture with the variable unset and set, and the
  in-repo journal gains no field.

### Negative
- An outside lane's disk usage is not under the run dir, so `ff-sweep`'s
  `bytes` column (cosmetic, ADR-024) undercounts runs placed outside. The
  reclaim decision is unaffected; sizing outside lanes is follow-up work.
- Two directory trees per run instead of one: a run whose journal is lost
  (never observed, but possible) leaves an outside lane dir that nothing
  will ever reclaim automatically. It is at a predictable path under the root
  and holds a registered git worktree, so `git worktree list` still names it.
- Relocating the root between runs is not migration: existing lanes stay
  where their journals say. That is the property, not a bug.

### Non-goals
- Does not change the default placement.
- Does not migrate existing lanes, and does not touch `.claude/worktrees/`.
- Does not size outside lanes in the sweep.

## See also

- [ADR-038](ADR-038-lanes-are-inside-the-host-watch-scope.md) — the incident,
  and the non-goal this ADR discharges
- [ADR-020](ADR-020-sweep-reclaims-only-archived-and-landed.md) — the sweep
  boundary, widened here by one clause
- [ADR-021](ADR-021-chips-are-lanes-not-a-second-worker-class.md) — cwd
  attribution, preserved by encoding the resolved path
- [ADR-034](ADR-034-codex-lanes-self-commit-via-scoped-git-grants.md) — the
  codex grants, unchanged by placement
- [ADR-035](ADR-035-landedness-is-ancestry-in-the-integration-branch.md) —
  landedness is measured in the main repo, wherever the lane sits
- `scripts/_env.sh` — `ff_lane_dir` / `ff_lane_path` / `ff_repo_slug`, with
  the creator/reader split spelled out at the definition
- `tests/run.sh` — "lanes root (ADR-040)"
