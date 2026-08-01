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
| Full behavioural suite (162 assertions) | `bash tests/run.sh` |
| Provider preflight | `bash scripts/ff-doctor.sh --offline` (or `--live`) |
| Dashboard server (supervised only — see landmines) | `python scripts/ff-serve.py --port 8161` |

## Structure

| Path | What lives there |
|---|---|
| `SKILL.md` | The skill: doctrine, lifecycle, routing, safety. Single source of truth. |
| `scripts/` | `ff-doctor` / `ff-spawn` / `ff-collect` / `ff-status` / `ff-run` / `ff-clean` / `ff-import` (bash, Skill Resource Protocol) + `ff-serve.py` (dashboard server) |
| `assets/` | `ff-monitor.html` (single-run live monitor), `ff-dashboard.html` (machine-wide dashboard), `guard-preamble.txt` (worker guard) |
| `references/` | worker contracts (per-brain launch/collect/auth), native Workflow extraction notes, model routing |
| `tests/` | `run.sh` — the one gate; run it before landing anything |

## Landmines

- **`C:\Users\Mack\.claude\skills\fleetflow` is a JUNCTION to this repo.** Edits
  here are live in every Claude session's skill copy immediately. Renaming or
  moving root files breaks skill resolution.
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
- **Grok lanes have no live stream** (buffered `--output-format json` by design;
  see SKILL.md) — do not "fix" the monitor to show grok activity without
  re-verifying the streaming envelope against `ff-collect`'s gate.
- **`ff-serve.py` is deliberately ONE process** (server + request-driven
  rebuilds). Do not split out a watcher — the predecessor's detached watcher
  dying silently is the exact failure this design removes (contract block in
  the file).
