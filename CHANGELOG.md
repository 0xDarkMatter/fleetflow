# Changelog

All notable changes to fleetflow are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow semver.
Decision rationale lives in [docs/adr/](docs/adr/) — entries here say WHAT
shipped, the ADRs own WHY.

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
