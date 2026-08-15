# fleetflow

Heterogeneous cross-provider agent fleets from one Claude Code session —
**GLM (z.ai) · Codex (OpenAI) · Grok (xAI) · Pi (15+ providers) · Anthropic
Sonnet/Haiku/Opus** — porting the native Workflow tool's patterns (adversarial
verify, judge panels, journal resume) to OS-process workers, where every worker
gets its own env block and therefore its own model.

Claude Code's built-in orchestration spawns every agent in-process, so they all
share one provider: `ANTHROPIC_BASE_URL` is process-global, and only the model
alias varies per agent. fleetflow moves the worker boundary to the OS process.
Each lane is a real process in its own git worktree with its own environment —
which means a Codex refuter can attack a GLM build, an Opus judge can score
both, and the whole run stays journalled, resumable, and test-gated before
anything lands. The orchestrator is your interactive session; the scripts own
the deterministic mechanics (spawn, journal, collect, gate, clean).

It exists because model diversity is a quality tool, not just a cost tool: a
cross-provider refuter catches what three same-model skeptics miss, and cheap
mechanical lanes (GLM, Haiku) make wide fan-outs affordable while premium
models keep the judgment seats. If your fan-out is happy on one provider, use
the native Workflow tool — the [SKILL.md](SKILL.md) decision gate says so in
its first row. This repo is simultaneously a Claude Code **skill** (mount it
at `~/.claude/skills/fleetflow`) and the home of a **machine-wide dashboard**
that watches every run, live and archived, across every repo on the box.

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

## Install as a skill

Clone, then junction (or symlink) the clone into your skills directory:

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\fleetflow" -Target "<path-to-your-clone>"
```

```bash
ln -s "<path-to-your-clone>" ~/.claude/skills/fleetflow
```

## Run the dashboard

Serve `scripts/ff-serve.py` under a process supervisor with a readiness probe
on `/api/health`. Roots to scan live in `~/.fleetflow/roots.txt` (seed once
with `ff-aggregate.py --init-roots <paths>`).

## Test

```bash
bash tests/run.sh
```

389 assertions over the scripts, monitor, dashboard wiring, and import/resume
semantics. The suite is hermetic: it exports its own `FLEETFLOW_HOME`, and a
guard asserts the real `~/.fleetflow/history.jsonl` is byte-unchanged.

## License

[MIT](LICENSE)
