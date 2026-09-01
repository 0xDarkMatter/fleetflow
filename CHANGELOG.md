# Changelog

All notable changes to fleetflow are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow semver.
Decision rationale lives in [docs/adr/](docs/adr/) — entries here say WHAT
shipped, the ADRs own WHY.

## [Unreleased]

### Added
- `ff-doctor --for MODEL[,MODEL...]`: preflight scoped to the models a run
  will spawn - a missing harness for a requested model escalates
  advisory→fail, and `claude` is required only for claude-family/glm/chip
  lanes, so a non-Claude orchestrator can bless a claude-less fleet
  (ADR-033).
- ADR-033: the orchestrator contract is bash plus judgment - any harness may
  hold the seat; host conveniences are optional surfaces. Verified with
  opencode 1.18 and pi 0.83 each driving `ff plan draft → lint` end-to-end on
  Windows, unmodified (claims replayed against the filesystem).
  Includes the measured Windows constraint: sandboxed codex cannot host Git
  Bash, so the codex orchestrator posture there is full access, opposite to
  ADR-007's lane pin.
- SKILL.md: "Orchestrating from another harness" - the off-host rules.

### Fixed
- A relative `--repo` (ff-plan passes `.`) broke every launch branch that
  dereferences `$SENT` inside its `cd "$WORKDIR"` subshell: codex/grok/pi
  lanes died "No such file or directory" before the worker launched (rc=1,
  empty artifact), and glm silently launched with an EMPTY packet because its
  `$(cat "$SENT")` expansion swallowed the failure. ff-spawn now normalises
  REPO to an absolute path right after validating it - fixing every caller at
  once - and canonicalises `$SCHEMA` the same way (codex passes the path,
  grok cats it, both inside the launch subshell). Regression-tested with a
  PATH-stubbed codex driving the real launch branch (`--repo .` +
  `--worktree`), since `--dry-run` never reaches the cd. Observed 2026-09-01,
  run studio-live - the refute lane.
- Codex re-test round 5, all three findings closed: the launcher parity check
  is a machine-readable handshake (`fleet-worker --capabilities` must exit 0
  and declare the exact `claude-bin-override` token; the round-4 textual grep
  was spoofable by a comment) with ONE implementation in `_env.sh` shared by
  doctor and spawn, probed with auth env stripped so a pre-handshake launcher
  stops at its key guard instead of exec'ing claude; a requested codex seat
  whose windows-sandbox tripwire cannot be verified fails closed at 7 instead
  of advisory-and-0; and model dependency refusals moved to a preflight
  BEFORE worktree/journal mutation, so a refused lane leaves no `started`
  record (it used to read `running` until abandonment) - the in-branch guards
  remain as backstops that now journal a terminal rc-5 result via
  `refuse_lane`.
- Codex re-test round 4, all three findings closed plus the grammar
  hardening: `codex-auth` captures once and requires exit 0 plus an anchored
  `^Logged in` (the old case-insensitive substring matched codex's real
  NEGATIVE, "Not logged in", and blessed a logged-out codex); the glm child
  doctor's exit code is no longer masked by the grep pipeline (an ok row
  followed by a nonzero exit read healthy); a launcher predating
  `FLEET_WORKER_CLAUDE_BIN` is refused whenever a claude override is in play -
  structurally by the doctor (`fleet-worker-parity`: fail when glm is
  requested, advisory otherwise) and at launch by ff-spawn (exit 5) - and the
  stale installed copy this found was synced from upstream; `--for` now also
  rejects leading, trailing, and doubled commas.
- Codex re-test round 3, all five findings closed (three were live
  false-green paths, each reproduced before fixing): `--for` now enforces one
  comma-only grammar for validation AND selection (whitespace-separated lists
  validated every name yet selected none - every check advisory, exit 0);
  offline mode honours a declared orchestrator seat whose binary is missing
  (exit 7, same as `--live`, instead of blessing the fleet); doctor/spawn
  claude-binary parity now reaches THROUGH fleet-worker (`ff-spawn` forwards
  `FLEETFLOW_CLAUDE_BIN` as `FLEET_WORKER_CLAUDE_BIN`; the launcher consumes
  it instead of hardcoding `claude`); a requested pi seat fails closed at 7
  when its provider is unset or unmapped (no key to verify, and lane
  isolation means host auth cannot save it); and a requested glm seat fails
  closed at 7 when `fleet-doctor.sh` is absent beside the launcher (the live
  probe cannot run). Unrequested models keep their historic advisory
  demeanour throughout.
- Codex re-test round 2, all four findings closed: an explicit claude-family
  orchestrator seat now joins the model probe union (a declared opus seat
  with a dead claude binary is exit 7, not a false green; seat-also-worker
  probes once), `FLEETFLOW_CLAUDE_BIN` is consumed by ff-spawn's claude
  launches as well as the doctor (no doctor/spawn binary divergence),
  `--orchestrator` refuses option-shaped values and `--for` refuses
  comma-only lists, and ADR-034's body text now carries the by-convention
  qualifier its addendum introduced.
- Scoped-grant derivation asked git for the lane's metadata dir instead of
  reconstructing it from the basename: git deduplicates worktree names
  (`wt-build`, `wt-build1`), so a colliding lane id across runs was granted
  ANOTHER lane's metadata dir - a cross-lane grant. Found by codex re-review;
  regression pins two same-id lanes resolving distinctly. ADR-034 addendum
  records this plus the now-explicit objects-dir exposure and the per-lane
  git-database endgame (ADR-035 candidate).
- `ff-doctor` argument handling failed loud instead of green: an unknown
  `--for` value used to mean "nothing wanted" - every check advisory, exit 0
  on a typo; now exit 2 naming the value. Missing `--for`/`--orchestrator`
  values are usage errors. Live probes cover workers UNION the declared
  orchestrator seat (a grok seat pulls in grok-auth with no grok lane), and
  each requested claude-family model gets its own availability probe
  (`FLEETFLOW_CLAUDE_BIN` stubs all of it hermetically - the suite exercises
  the full --live surface tokenlessly).
- **`ff-clean` destroyed committed lanes whenever the manifest base was a
  SHA** - which is what ff-spawn records. Base validation only accepted
  branch names, silently fell back to the literal string `HEAD` (a
  self-compare inside each lane worktree: zero commits, always), and the
  keep-committed-lanes protection was inert for every real run while
  removal-side tests stayed green. Found live when a 2-commit codex lane was
  destroyed during the ADR-034 lifecycle test. Three layers fixed: the base
  read strips the Windows jq CRLF, validation accepts any commit-ish and
  falls back to the main repo's HEAD *sha*, and a failed commit-count now
  KEEPS the lane instead of defaulting to zero. Regression fixture is the
  destroying run itself.
- Codex lanes now self-commit like every other model - through four SCOPED
  sandbox grants (lane worktree metadata, object store, own ref dir, own
  reflog dir), not the whole-git-dir carve-out that a pre-ADR-006 commit
  (2026-07-05) had left granting write access to `.git/config`/hooksPath,
  `refs/heads/main`, and other lanes' metadata. ADR-034 supersedes ADR-006
  (whose addendum records the seven-week drift); verified live with a real
  codex lane committing and an adversarial `.git/config` write probe being
  denied. Uniform commit clause restored to the guard preamble; tests pin the
  exact grant list and that the whole git dir is never granted.
- `--live` probes now honour `--for`: unrequested providers are neither
  called nor allowed to affect the exit status, reporting "not requested"
  advisory rows instead. Previously a claude-less fleet could exit 7 on
  providers it never asked for.
- `--orchestrator NAME` (or `FLEETFLOW_ORCHESTRATOR`) declares the seat and
  skips the Claude auto-probe - the one live check that still assumed a
  Claude orchestrator after ADR-033. Explicit seats validate cheaply (human
  is an assertion; harness seats need their binary), persist to
  `$FLEETFLOW_HOME/orchestrator`, and work in `--offline` too.

## [0.3.0] — 2026-08-24

Written from the point of view of someone who has just cloned the repo: a
Requirements/Install/Quickstart path verified by running it verbatim in a
fresh clone, portability fixes for the two dependencies that failed silently
off the author's machine, the `ff` dispatcher with terminal QOL, and a
drift-gated tunables registry.

### Added
- `ff` dispatcher (`scripts/ff`): one entry point over the scripts - `ff plan
  lint`, `ff doctor --offline` - plus native conveniences with no script of
  their own: `ff env` (the tunables registry, columnised), `ff open` (dashboard
  for this repo), `ff logs RUN ID` (tail a lane's artifacts without knowing the
  run-dir layout), `ff watch RUN` (terminal live view that exits when every
  lane is final). Bash tab-completion in `completions/ff.bash` (subcommands,
  models, run names read live from `.fleetflow/`).
- `ff-doctor --env`: every `FLEETFLOW_*` tunable as name/current/default/purpose
  TSV. The registry is gate-checked both ways: every script-referenced variable
  must be registered, and every registered variable must appear in
  `docs/REFERENCE.md` (which also carries the semantic exit-code table).
- End-of-run summary: when a collect passes and every started packet has a
  result, ff-collect reports lane counts on stderr - counts only, totals stay
  ff-status's job.
- README glossary: the sixteen load-bearing terms, one line each.
- `--target diff|staging=<url>` on `ff-run wave` aims the finder waves: `diff`
  (default) inspects the change, `staging=<url>` drives a running deployment.
  Lanes may interact fully but never deploy, restart, or reconfigure it (ADR-032).
- `FLEETFLOW_DASHBOARD_URL` overrides the dashboard origin used by the chat
  widget anchor and the SKILL.md pane ritual. Defaults to `http://127.0.0.1:8161`,
  ff-serve's own default, so a fresh install links somewhere real.
- README **Requirements** and **Install** sections: the hard tool set, the
  per-model optional set, and what each missing tool actually costs you.
- `docs/diagrams/stores-light.svg` — the run-state stores and the teardown
  boundary, embedded in ARCHITECTURE.md.

### Changed
- Portable `ff_sha256` / `ff_python` helpers in `scripts/_env.sh`, used by every
  call site. `sha256sum` now falls back to `shasum`/`openssl`, and the Python
  probe EXECUTES its candidates so a Windows App Execution Alias stub is not
  mistaken for an interpreter.
- README Quickstart starts at `ff-plan draft` (matching ADR-026) and uses real
  packet paths, so it runs verbatim from a fresh clone.
- `ARCHITECTURE.md` and `SECURITY.md` moved into `docs/`; ARCHITECTURE.md now
  embeds five diagrams. Diagram set is light-only and free of webfont imports.
- AGENTS.md landmines that depend on the author's skill junction or supervised
  dashboard now state that precondition instead of asserting it universally.
- `adr-ops` declared in `depends-on` — `ff-plan lint` and the test gate call it.
- SKILL.md carries the dispatcher: a `scripts/ff` row leads the scripts table
  (with the sugar-never-a-layer rule stated), the doctor row documents `--env`,
  the collect row documents the end-of-run summary, and the frontmatter roster
  gains Pi.

### Fixed
- Journal cache keys could silently collapse to `v2:` on hosts without
  coreutils, making every lane after the first a false cache hit (ADR-012).
- The chat widget hardcoded a private `.lab` host as the run card's primary
  link, and the test suite pinned that hostname; both now follow the configured
  dashboard origin.
- `ff-doctor` advisories name the exit code and the remedy, so a missing
  per-model harness is no longer a bare "unavailable".

## [0.2.0] — 2026-08-20

Runs are now planned, linted, and refuted before they spawn; the build of
this release itself ran as a codex+glm fleet with tested-posture QA
(findings: 8 fixed, 1 waived, 0 open).

### Added
- `ff-plan` — `draft` (plan doc + packets + manifest authored up front,
  ADR-026), `lint` (scope/dep/constraint/routing/barrier/bounds checks with
  armed-or-disarmed reporting, gates the spawn, ADR-030), `refute`
  (cross-provider Adversary attacks the plan pre-spawn, ADR-028), `estimate`
  (honest pricing), `expand` (generator registry, ADR-029; Forma registered,
  arming pending).
- Packet YAML frontmatter: `owns`/`modifies`/`registries`/`depends_on`/
  `role`/`class` — file-disjointness and single-writer registries become
  machine-checkable.
- Twelve role cards (`assets/roles/`, ADR-031): Architect, Oracle, Scout,
  Surveyor, Scholar, Builder, Inspector, Adversary, Judge, Critic, Composer,
  Warden — prepended into packets by `ff-plan draft`.
- Frozen plan-doc and packet templates (`assets/plan.tmpl.md`,
  `assets/packet.tmpl.md`).
- `abandoned` lane state (ADR-025): hours-scale silence demotes an in-flight
  lane to a final state; dashboards stop animating and re-polling dead runs.
- Dashboard time-window lens: this/last week · month · quarter, custom, all
  time — scopes every view and roll-up (`ffd.window`).
- `docs/ARCHITECTURE.md` — living current-state map of components, data stores,
  and the invariant gate.
- Role-cards diagram (`docs/diagrams/role-cards-light.svg`).

### Changed
- Suite grown to 442 hermetic assertions (ff-plan contract tests written
  blind to the implementation; stubbed refute/estimate/expand coverage).
- SKILL.md/README document the extended lifecycle:
  `ff-plan → doctor → spawn → collect → wave → land`.

## [0.1.0] — 2026-08-14

Extracted from the claude-mods skills tree with full history (subtree
split, 2026-08-01); everything below landed in this repo since extraction.

### Added
- The run lifecycle scripts: `ff-doctor`, `ff-spawn`, `ff-collect`,
  `ff-status`, `ff-run` (resume + post-build waves), `ff-findings`,
  `ff-widget`, `ff-archive`, `ff-clean`, `ff-import` — bash, Skill Resource
  Protocol, semantic exit codes.
- Post-build wave pipeline with findings ledger, posture-selected finder
  waves, mechanical triage, fix loops and cross-provider re-verify (ADR-018).
- Shared run-card renderer embedded byte-identically in the dashboard and the
  chat widget, parity-gated by the test suite (ADR-019).
- `ff-sweep`: machine-wide housekeeping with live-computed verdicts and
  safe-only reclaim (ADR-020), plus the P1–P4 performance work — measured
  16× on a machine-wide sweep (see docs/reports/SWEEP-PERF-2026-08.md) with
  a bytes-only cache (ADR-024).
- `ff-chip`: manually spawned Claude Code chips adopted as first-class lanes
  (ADR-021).
- Opt-in raven-bus worker telemetry (ADR-022) and steerable ACP claude lanes
  with packet-as-trusted-boundary and telemetry-distilled verdicts (ADR-023).
- Machine-wide dashboard (`ff-serve.py` + `ff-dashboard.html`) with Fleet
  view (spec/observed/capacity registers, ADR-014), honest cost estimation
  (ADR-010/015), and single-run live monitor (`ff-monitor.html`).
- 389-assertion hermetic behavioural test suite; ADR lint runs inside it.

### Changed
- Default GLM worker model is GLM-5.3; reasoning
  levels `low|high|max` documented in the worker contract.
