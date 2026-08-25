# Reference — tunables and exit codes

Quick-reference for operating fleetflow. The glossary lives in the
[README](../README.md#glossary); doctrine lives in [SKILL.md](../SKILL.md).

## Environment variables

Every `FLEETFLOW_*` tunable. **The registry inside `ff-doctor --env` is the
source of truth** — run `ff env` for live values on your box. Two mechanical
gates keep this page honest: the test suite asserts every variable any script
reads appears in the registry, and that every registry row appears in this
table. Add a variable, its registry row, and its row here in one commit.

| Variable | Default | Tunes |
|---|---|---|
| `FLEETFLOW_HOME` | `$HOME/.fleetflow` | machine-level store root: history.jsonl, dashboard cache (ff-archive/clean/sweep/serve) |
| `FLEETFLOW_ROOTS` | `(unset)` | path-separator-joined roots for machine-wide discovery; overrides ~/.fleetflow/roots.txt (ff-serve, ff-aggregate, ff-sweep) |
| `FLEETFLOW_STALL_SECONDS` | `600` | live-stream silence before a running lane reads stalled (ff-status, ADR-008) |
| `FLEETFLOW_ABANDON_SECONDS` | `21600` | silence before a running/stalled lane is demoted to final abandoned (ff-status, ADR-025) |
| `FLEETFLOW_CACHE_ROOT` | `$HOME/.fleet-worker/cache` | per-lane tmp + uv cache root, redirected OUT of worktrees (ff-spawn, ff-clean) |
| `FLEETFLOW_CFG_BASE` | `$HOME/.fleet-worker` | fleet-worker config-dir base ff-status scans for glm lane transcripts |
| `FLEETFLOW_DASHBOARD_URL` | `http://127.0.0.1:8161` | dashboard origin for the widget anchor and the SKILL.md pane ritual |
| `FLEETFLOW_BUS` | `0` | =1 opts lanes into raven bus heartbeats (ff-spawn, ADR-022) |
| `FLEETFLOW_ORCHESTRATOR` | `(unset)` | declared orchestrator seat: consumed by ff-doctor (skips the claude auto-probe, ADR-033) and recorded in the journal; falls back to $FLEETFLOW_HOME/orchestrator |
| `FLEETFLOW_PERMISSION_MODE` | `acceptEdits (acp) / bypassPermissions (headless)` | permission mode for claude-family lanes; default differs by lane kind |
| `FLEETFLOW_FLEET_WORKER` | `$HOME/.claude/skills/fleet-worker/scripts/fleet-worker` | glm launcher path (ff-spawn hard-requires it for --model glm) |
| `FLEETFLOW_CODEX_MODEL` | `(harness default)` | codex -m override for codex lanes |
| `FLEETFLOW_CODEX_WINDOWS_SANDBOX` | `unelevated` | Windows codex sandbox pin (ADR-007); set EMPTY to disarm the override (set-vs-unset is meaningful) |
| `FLEETFLOW_CLAUDE_BIN` | `claude` | claude binary used by ff-doctor (checks + model probes) AND ff-spawn claude-family launches - one override, no doctor/spawn divergence |
| `FLEETFLOW_GROK_BIN` | `grok` | grok binary or launcher path |
| `FLEETFLOW_GROK_MODEL` | `(harness default)` | grok -m override for grok lanes |
| `FLEETFLOW_PI_BIN` | `pi` | pi binary or launcher path |
| `FLEETFLOW_PI_PROVIDER` | `(pi config default)` | pi --provider override; recorded in the lane alias |
| `FLEETFLOW_PI_MODEL` | `(provider default)` | pi --model override |
| `FLEETFLOW_ACP_AGENT_JS` | `(auto-resolved)` | path to the claude-code-acp agent JS for --acp lanes |
| `FLEETFLOW_WAVE_ROOT` | `(repo root)` | asset root for the wave pipeline (ff-run wave) |
| `FLEETFLOW_WAVE_CATALOGUE` | `$WAVE_ROOT/assets/wave-catalogue.json` | wave catalogue override |
| `FLEETFLOW_WAVE_SCHEMA` | `$WAVE_ROOT/assets/findings.schema.json` | findings schema override |
| `FLEETFLOW_FINDINGS_BIN` | `scripts/ff-findings.sh` | findings CLI override (ff-run, ff-widget) |
| `FLEETFLOW_REPAIR_DRYRUN` | `(unset)` | non-empty = ff-collect --repair respawns with --dry-run (test the loop without spending) |
| `FLEETFLOW_PATH_PREPEND` | `(unset)` | colon-separated dirs _env.sh prepends to PATH before tool discovery |

`FLEET_WORKER_EFFORT` and `FLEET_WORKER_CONFIG_DIR` also appear in `ff-spawn` —
they belong to [fleet-worker](https://github.com/0xDarkMatter/claude-mods/tree/main/skills/fleet-worker)'s
contract, not this registry.

## Exit codes

The scripts share one semantic exit-code language (Skill Resource Protocol).
When a command fails, the code tells you which document to reach for:

| Code | Meaning | What to do next |
|---|---|---|
| `0` | ok | carry on |
| `2` | usage error, refused overwrite, or missing precondition | re-run with `--help`; for `ff-plan draft`, add `--force` to overwrite |
| `3` | cached / missing — artifact absent, cache hit, or unimplemented path | a cache hit on `ff-spawn` is success (journal replay, ADR-012); a missing artifact means the lane never ran — `ff logs RUN ID` |
| `5` | launcher or binary missing for the requested model | `ff doctor --offline` names the tool and the env var that points at it |
| `7` | provider unreachable (live probes only) | check auth/keys for the named provider; `ff doctor --live` re-probes |
| `10` | worker failed, gate failed, or lint findings | `ff logs RUN ID` for a lane; `ff plan lint --run X` prints FINDING lines; a refuted plan loops back to draft (ADR-028) |
| `12` | escape detected — a worker wrote outside its lane | inspect `git status` in the main checkout before anything lands (ADR-009) |
| `14` | lane stalled (only with `--exit-stalled`) | `ff logs RUN ID`; stall doctrine is ADR-008, thresholds are `FLEETFLOW_STALL_SECONDS` / `FLEETFLOW_ABANDON_SECONDS` |

Per-script nuances live in each script's `--help`.
