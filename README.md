# fleetflow

**Heterogeneous cross-provider agent fleets from one Claude Code session** —
GLM (z.ai) · Codex (OpenAI) · Grok (xAI) · Pi (15+ providers) · Anthropic
Sonnet/Haiku/Opus — as OS-process workers with adversarial cross-model
verification, journalled resume, and a machine-wide dashboard.

<img alt="fleetflow dashboard, run detail: an 8-lane run across four providers, all green — per-lane tokens, states, and honest cost estimates" src="docs/screenshots/dashboard-run.png">

## Why

**Frontier judgment, commodity execution.** The expensive models are worth
every cent exactly where judgment concentrates — architecture, task
decomposition, verdicts — and wasted almost everywhere else. fleetflow makes
that split structural: a frontier orchestrator (Claude Fable, GPT-5.6 Sol via
Codex) architects the run and authors the task packets, then very capable,
much cheaper models (GLM-5.3, Haiku) execute the grunt work in parallel lanes.
The gate catches what the cheap lanes miss, so you spend frontier tokens on
decisions and commodity tokens on keystrokes — which is what makes a 20-lane
fan-out affordable instead of aspirational.

**Multi-model consensus, adversarial by design.** Three same-model reviewers
share the same blind spots; a reviewer from a different provider does not.
fleetflow builds runs around that: independent implementations judged across
providers, refuters prompted to *attack* rather than confirm, tests written
blind to the implementation and then refuted by yet another model. Findings
loop into fix lanes until the refuters run dry. In practice that means more
features per week — parallel lanes do the building — while more bugs die
before landing, because every claim survives a model that had no stake in
making it.

**And the boring guarantees that make it usable daily:** every lane is a real
OS process in its own git worktree (one writer per tree, escape-guarded);
every spawn is journalled under a content hash so unchanged work replays from
cache and a crashed run resumes; costs are honest — token totals are
model-comparable, estimates are marked `≈`, uncosted lanes are marked `*`, and
nothing is ever presented as an invoice.

## Quickstart

```bash
# 1. preflight — don't spawn a fleet a doctor won't bless
bash scripts/ff-doctor.sh --live

# 2. author a task packet, then spawn a lane per packet (repeat per model)
bash scripts/ff-spawn.sh --run demo --id build --model glm   --prompt-file packets/build.task.md --worktree
bash scripts/ff-spawn.sh --run demo --id refute --model codex --prompt-file packets/refute.task.md --worktree

# 3. gate each lane, then check the whole run
bash scripts/ff-collect.sh --run demo --id build
bash scripts/ff-status.sh  --run demo

# 4. land through your merge gate, then reclaim
bash scripts/ff-clean.sh --run demo
```

The full playbook — model routing, packet discipline, safety rules, the
decision gate for when *not* to use fleetflow — is [SKILL.md](SKILL.md). This
repo is simultaneously a Claude Code **skill** (mount it at
`~/.claude/skills/fleetflow`) and the home of the dashboard service.

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\fleetflow" -Target "<path-to-your-clone>"
```

```bash
ln -s "<path-to-your-clone>" ~/.claude/skills/fleetflow
```

## How it works

One orchestrator, many processes. Your interactive session plans file-disjoint
task packets and keeps the judgment; the scripts own the deterministic
mechanics. Workers never talk to each other (hub-and-spoke, by design); a
lane's FINAL REPLY comes back through the collect gate, and the orchestrator
decides what happens next.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/architecture-dark.svg">
  <img alt="hub-and-spoke architecture: orchestrator spawns four cross-provider worker lanes in git worktrees; one collect gate returns results; journal enables resume; a dashboard observes" src="docs/diagrams/architecture-light.svg">
</picture>

A run is a pipeline with verification built in, not bolted on. `ff-doctor`
refuses to bless a fleet a provider can't serve; the collect gate applies
per-model success semantics plus an escape guard on the primary checkout; and
teardown archives before it removes — a run's history outlives its directory.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/lifecycle-dark.svg">
  <img alt="run lifecycle: doctor preflight, spawn, collect gate, cross-provider verify with a fix loop, test-gated landing, archive-then-remove cleanup" src="docs/diagrams/lifecycle-light.svg">
</picture>

In-run telemetry and mid-run steering ride
[raven](https://github.com/0xDarkMatter/raven), a zero-infra SQLite message
bus: workers post opt-in heartbeats onto the run's telemetry channel, and
`raven acp` hosts steerable claude lanes that accept course corrections and
graceful wind-downs mid-flight (ADR-022/ADR-023).

**Why not Claude Code's built-in orchestration?** Use it — when one provider
suffices. Its agents run in-process, so they all share `ANTHROPIC_BASE_URL`;
only the model alias varies. fleetflow exists for the runs where model
*diversity* is the point: a cross-provider refuter catches what three
same-model skeptics miss, cheap mechanical lanes (GLM, Haiku) make wide
fan-outs affordable, and premium models keep the judgment seats. The
[SKILL.md](SKILL.md) decision gate puts the native tool first for a reason.

## The dashboard

Every run on the machine — live and archived, across every repo — behind one
always-on page. Serve `scripts/ff-serve.py` under a process supervisor with a
readiness probe on `/api/health`; roots live in `~/.fleetflow/roots.txt`
(seed once with `ff-aggregate.py --init-roots <paths>`).

<img alt="fleetflow machine-wide dashboard: every run on the box, live and archived, with token, cost, and failure roll-ups" src="docs/screenshots/dashboard-fleet.png">

## Components

| Piece | What it does |
|---|---|
| [SKILL.md](SKILL.md) | Operational doctrine: decision gate, model routing, run lifecycle, safety (escape guard, stall detector, sandbox rules) |
| `scripts/ff-doctor` → `ff-clean` | The run lifecycle: preflight → spawn → collect/gate → status → resume → clean. Bash, semantic exit codes, `--help` with examples |
| [scripts/ff-sweep.sh](scripts/ff-sweep.sh) | Machine-wide housekeeping: verdicts on every leftover run dir (`reclaimable` / `holds-work` / `active`), reclaim only what is provably safe — verdicts computed live, never cached (ADR-020/024) |
| [scripts/ff-chip.sh](scripts/ff-chip.sh) | Adopts a manually spawned Claude Code chip as an ordinary lane — worktree, journal, telemetry, teardown (ADR-021) |
| [scripts/ff-serve.py](scripts/ff-serve.py) | Machine-wide dashboard server — discovers every run across configured roots, one process, request-driven non-blocking rebuilds |
| [assets/ff-monitor.html](assets/ff-monitor.html) | Single-run live monitor: tethered summary header, active-first sort, S/M/L card sizes, stall-aware pips |
| [assets/ff-dashboard.html](assets/ff-dashboard.html) | Machine-wide dashboard UI (all runs, live + archived) |
| [references/](references/) | Per-model worker contracts, native Workflow internals extraction, model-routing doctrine |
| [docs/adr/](docs/adr/) | Architecture Decision Records — the append-only WHY behind the standing rules (one process, escape guard, stall detection, pricing, …); lint-gated by the test suite |

## Recent Updates

### v0.1.0 — 2026-08-14 · first public release

- 🚀 **Extracted to a standalone repo** from the claude-mods skills tree with
  full history (subtree split). Everything below landed here since.
- 🧹 **`ff-sweep` machine-wide housekeeping** — verdicts for every leftover
  run dir, safe-only reclaim, and a 16× faster machine-wide sweep (measured
  717s → 44–84s; the classification is computed live, never cached —
  [ADR-024](docs/adr/ADR-024-sweep-caches-bytes-never-verdicts.md)).
- 🧩 **Chips are lanes** — manually spawned Claude Code chips get a real lane
  (worktree, journal, live telemetry, teardown) via `ff-chip open|close`
  ([ADR-021](docs/adr/ADR-021-chips-are-lanes-not-a-second-worker-class.md)).
- 📡 **Opt-in raven-bus telemetry + steerable ACP lanes** — one uniform live
  feed across providers, and claude lanes that accept mid-run steering and
  graceful wind-down ([ADR-022](docs/adr/ADR-022-raven-bus-optin-telemetry.md),
  [ADR-023](docs/adr/ADR-023-acp-lanes-packet-trusted-verdict-from-telemetry.md)).
- 🧠 **GLM default is GLM-5.3** (verified live against z.ai the day of
  rollout), with the 5.3 reasoning levels (`low|high|max`) documented in the
  worker contract.
- 📋 **Post-build wave pipeline + findings ledger** — posture-selected finder
  waves, mechanical triage, fix loops, cross-provider re-verify
  ([ADR-018](docs/adr/ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md)).
- 📊 **One run-card renderer** shared byte-identically by the dashboard and
  the chat widget ([ADR-019](docs/adr/ADR-019-one-run-card-renderer-two-embedded-copies.md)).

## Test

```bash
bash tests/run.sh
```

389 assertions over the scripts, monitor, dashboard wiring, and import/resume
semantics. The suite is hermetic: it exports its own `FLEETFLOW_HOME`, and a
guard asserts the real `~/.fleetflow/history.jsonl` is byte-unchanged.

## License

[MIT](LICENSE)
