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
| Full behavioural suite (192 assertions) | `bash tests/run.sh` |
| Provider preflight | `bash scripts/ff-doctor.sh --offline` (or `--live`) |
| Dashboard server (supervised only — see landmines) | `python scripts/ff-serve.py --port 8161` |

## Structure

| Path | What lives there |
|---|---|
| `SKILL.md` | The skill: doctrine, lifecycle, routing, safety. Single source of truth. |
| `scripts/` | `ff-doctor` / `ff-spawn` / `ff-collect` / `ff-status` / `ff-run` / `ff-clean` / `ff-import` (bash, Skill Resource Protocol) + `ff-serve.py` (dashboard server) |
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
