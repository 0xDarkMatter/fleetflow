# fleetflow

Heterogeneous cross-provider agent fleets from one Claude Code session —
**GLM (z.ai) · Codex (OpenAI) · Grok (xAI) · Pi (15+ providers) · Anthropic
Sonnet/Haiku/Opus** — porting the native Workflow tool's patterns (adversarial
verify, judge panels, journal resume) to OS-process workers, where every worker
gets its own env block and therefore its own brain.

The playbook is [SKILL.md](SKILL.md). This repo is simultaneously a Claude Code
**skill** (mount it at `~/.claude/skills/fleetflow`) and the home of the
**machine-wide dashboard** service.

## Components

| Piece | What it does |
|---|---|
| [SKILL.md](SKILL.md) | Operational doctrine: decision gate, model routing, run lifecycle, safety (escape guard, stall detector, sandbox rules) |
| `scripts/ff-doctor` → `ff-clean` | The run lifecycle: preflight → spawn → collect/gate → status → resume → clean. Bash, semantic exit codes, `--help` with examples |
| [scripts/ff-serve.py](scripts/ff-serve.py) | Machine-wide dashboard server — discovers every run across configured roots, one process, request-driven non-blocking rebuilds |
| [assets/ff-monitor.html](assets/ff-monitor.html) | Single-run live monitor: tethered summary header, active-first sort, S/M/L card sizes, stall-aware pips |
| [assets/ff-dashboard.html](assets/ff-dashboard.html) | Machine-wide dashboard UI (all runs, live + archived) |
| [references/](references/) | Per-brain worker contracts, native Workflow internals extraction, model-routing doctrine |

## Install as a skill

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\fleetflow" -Target "X:\Forge\fleetflow"
```

## Run the dashboard

Serve `scripts/ff-serve.py` under a process supervisor with a readiness probe on
`/api/health` (this machine: Process Compose service `fleetflow`, port 8161,
`https://fleetflow.lab`). Roots to scan live in `~/.fleetflow/roots.txt`.

## Test

```bash
bash tests/run.sh
```

162 assertions over the scripts, monitor, dashboard wiring, and import/resume
semantics.

## License

MIT
