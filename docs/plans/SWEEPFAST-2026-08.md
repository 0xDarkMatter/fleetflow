# Run plan: `sweepfast` — implement SWEEP-PERF P1–P4

**Status:** active (2026-08-14) · The measurements and phase designs live in
[docs/reports/SWEEP-PERF-2026-08.md](../reports/SWEEP-PERF-2026-08.md) §5; the
safety rule lives in [ADR-020](../adr/ADR-020-sweep-reclaims-only-archived-and-landed.md);
the cache-bytes-never-verdicts decision lands as ADR-024 (docs lane). Cite,
never restate. File ownership is exclusive. FINAL REPLY ends with `TESTS:` /
`FILES_CHANGED:` lines.

## §1 Shared surface contract (build + tests lanes both bind to this)

- New flags on `ff-sweep.sh`: `--no-size` (skip `du`; bytes column prints `-`,
  "on disk" roll-up omitted) · `--rediscover` (ignore the discovery cache) ·
  `--discover-ttl N` (seconds; env `FF_SWEEP_DISCOVER_TTL`, default 900).
- Size cache: `~/.fleetflow/cache/sweep-sizes.json` (under `$FLEETFLOW_HOME`
  when set), entries keyed on resolved lowercased run-dir path, value
  `{fp, by, bytes, at}` — `fp` = non-recursive `(child count, newest child
  mtime)`, `by` = producer stamp (`FF_VERSION` + `ff-sweep.sh` mtime:size).
- Discovery reuse reads `~/.fleetflow/cache/aggregate-cache.json`
  `._discovery` only when source matches and age < TTL; any parse failure
  falls through to the `find` walk (which gains `-prune` after `.fleetflow`).
- `age_s`: shallow (`-maxdepth 1`) by default, emitted as `age_s_approx`;
  the exact recursive walk runs ONLY under `--older-than` (it gates
  eligibility and must not be approximated).
- `git status --porcelain=v2 --branch` parsing: tracked = lines starting
  `1 `/`2 `/`u `; untracked = `? `; `#` lines are headers, never counted;
  `branch.oid (initial)` (unborn HEAD) ⇒ lane treated as UNMERGED (kept).
- The classification is NEVER cached. Verdicts are computed live from git on
  every invocation (ADR-024; report §6).

## §2 Lane table

| id | model | owns (exclusive) | builds |
|---|---|---|---|
| sweep | codex (gpt-5.6-sol) | `scripts/ff-sweep.sh` | P1–P4 per report §5 + §1 above. DO NOT COMMIT (ADR-006) |
| tests | glm | `tests/run.sh` | assertions for every §1 behaviour, hermetic (`FLEETFLOW_HOME` to temp; real store guard untouched) |
| docs | glm | `docs/adr/ADR-024-*.md`, report Status line, `SKILL.md` ff-sweep row | ADR-024 (cache bytes, never verdicts); graduate report status; add new flags to the SKILL row |

Verify: two cross-provider refuters on the integrated tree — refute-code (glm
vs the codex build; §1 + ADR-020 adversarial), refute-tests (codex vs the glm
tests). Orchestrator benchmarks machine-wide before/after and lands via
fleet-ops.
