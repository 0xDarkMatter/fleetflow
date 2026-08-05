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
- **Grok lanes have no live stream** (buffered `--output-format json` by design;
  see SKILL.md) — do not "fix" the monitor to show grok activity without
  re-verifying the streaming envelope against `ff-collect`'s gate. Stall
  coverage for grok WORKTREE lanes comes from the worker-authored
  `.ff-heartbeat` file instead (guard clause in ff-spawn; mtime read by
  ff-status) — it deliberately never touches the envelope.
- **`ff-clean` archives before it removes** (`ff-archive.sh` →
  `~/.fleetflow/history.jsonl`, `--no-archive` opts out) — teardown is the last
  moment the run's data exists, so do not reorder the archive step below the
  removal loop.
- **`ff-serve.py` is deliberately ONE process** (server + request-driven
  rebuilds). Do not split out a watcher — the predecessor's detached watcher
  dying silently is the exact failure this design removes (contract block in
  the file).
- **`ff-dashboard.html` has ZERO external references and must keep them.** No
  CDN, webfont, remote image, or build step: it is one file that has to work
  offline, from `file://`, and in a preview pane with no network. A test
  enforces it. (The one CDN string in the file is a provenance comment naming
  where four inline SVG paths were copied from — prose, not a fetch.)
- **`/api/doctor.json?live=1` spends real model calls** (a one-turn `claude -p`
  per Anthropic model, plus provider auth probes). It is click-gated in the UI
  and cached for 15 min server-side. Never put it on the poll path or a timer —
  a test asserts there is no `setInterval` driving it.
- **The dashboard's Fleet view carries a hand-maintained capability matrix**
  (`const HARNESS`). It encodes contracts that live in prose — sandbox posture,
  whether a model may self-commit, concurrency ceilings — and that no run
  artifact reports. When a model's contract changes in SKILL.md, change it there
  in the SAME commit; a test asserts every spawnable model appears in it.
- **The dashboard's `const PRICING` registry is hand-maintained** (like
  `HARNESS`): per-model $/MTok rates verified against provider pricing pages,
  with the verification date stamped in the file. When a provider ships new
  rates or fleetflow gains a model, update the registry (and the `PLANS` tier
  table — plan lanes show a BLENDED share of the monthly fee, never $0)
  in the same commit — a stale rate silently mis-prices every ≈ estimate.
  Tests assert every spawnable model has an entry, GLM is priced at z.ai
  rates, estimates carry the `≈` marker, and no native `alert`/`confirm`/
  `prompt` dialog exists anywhere in the page.
- **The `brain`→`model` rename (2026-08-05) left a load-bearing fallback
  order.** Legacy journal `started` records carry BOTH `brain` (alias) and
  `model` (launch id), so alias readers must prefer `brain` when present
  (`.brain // .model`); reversing that reads a launch id as an alias.
  Post-rename records write `model` (alias) + `model_id` (launch id). The
  external formats ff-status scans (claude session transcripts, codex event
  streams) still key on `"model"` — their regexes were deliberately NOT
  renamed. A legacy-journal test pins the round trip.
- **Dashboard `localStorage` keys are `ffd.*`, the monitor's are `ff.*`.** They
  are served from one origin and `ff.sort` means different things to each; the
  split is load-bearing, not cosmetic.
