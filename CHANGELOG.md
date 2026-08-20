# Changelog

All notable changes to fleetflow are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow semver.
Decision rationale lives in [docs/adr/](docs/adr/) — entries here say WHAT
shipped, the ADRs own WHY.

## [0.2.0] — 2026-08-20

The planning stage. Runs are now planned, linted, and refuted before they
spawn; the build of this release itself ran as a codex+glm fleet with
tested-posture QA (findings: 8 fixed, 1 waived, 0 open).

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
- `ARCHITECTURE.md` — living current-state map of components, data stores,
  and the invariant gate.
- Role-cards diagram (`docs/diagrams/role-cards-{light,dark}.svg`).

### Changed
- Suite grown to 442 hermetic assertions (ff-plan contract tests written
  blind to the implementation; stubbed refute/estimate/expand coverage).
- SKILL.md/README document the extended lifecycle:
  `ff-plan → doctor → spawn → collect → wave → land`.

## [0.1.0] — 2026-08-14

First public release. Extracted from the claude-mods skills tree with full
history (subtree split, 2026-08-01); everything below landed in this repo
since extraction.

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
- Default GLM worker model is GLM-5.3 (verified live 2026-08-14); reasoning
  levels `low|high|max` documented in the worker contract.
