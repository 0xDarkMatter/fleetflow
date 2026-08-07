---
status: accepted
date: 2026-08-05
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-status.sh"
  - "scripts/ff-spawn.sh"
  - "scripts/ff-aggregate.py"
  - "assets/ff-dashboard.html"
  - "assets/ff-monitor.html"
---

# ADR-017: The `brain`→`model` Rename Keeps Legacy Records Readable via a Load-Bearing Fallback Order

## Decision (one sentence)

Post-rename artifacts write `model` (spawnable alias) + `model_id` (resolved
launch id), legacy artifacts are read with `brain` winning the alias fallback
on journals (`.brain // .model`) and `model` winning on manifests/archives
(`.model // .brain`), external formats' regexes keying on `"model"` are
deliberately NOT renamed, and `--brain` survives as a deprecated flag alias.

## Context

The user-facing vocabulary was renamed from `brain` to `model` on 2026-08-05
(the term "brain" was retired across the wire contract, UI, and docs; see the
`model-not-brain` memory and commit 29487ec). The hazard is entirely in the
archive: pre-rename journal `started` records carry BOTH fields — `brain`
held the spawnable *alias* (`glm`, `codex`, …) and `model` held the resolved
*launch id* (`GLM-5.2`, …). Post-rename records reuse the `model` name for
the alias and add `model_id` for the launch id. The same key therefore means
different things on either side of the rename, and the fallback direction is
what disambiguates: on a journal record, `brain` present ⇒ legacy ⇒ `brain`
is the alias (`.brain // .model`); reversing that order reads a launch id as
an alias. Manifests and archives fall back the other way
(`.model // .brain`). `ff-aggregate` normalises legacy history at the read
boundary, and a legacy-journal test pins the round trip in both directions.

One deliberate non-rename: the external formats `ff-status` scans — claude
session transcripts and codex event streams — still key on `"model"` in
*their* schemas. Those regexes were left untouched because they parse other
tools' output, not fleetflow's; "completing" the rename there would break the
parsers against data fleetflow does not control.

## Alternatives considered

- **Migrate historical records in place.** Rejected: journals and
  `history.jsonl` are append-only records of what happened; rewriting them
  destroys provenance and risks partial-migration states worse than a
  read-time fallback.
- **Keep writing both fields forever.** Rejected: perpetuates the ambiguous
  vocabulary the rename exists to end; the write side is clean
  (`model` + `model_id`), only the read side carries compatibility.
- **A version field per record instead of key-presence detection.** More
  ceremony for the same information — `brain`'s presence already identifies a
  legacy record unambiguously.

## Consequences

### Positive
- All history remains readable without migration; every reader resolves the
  alias and launch id correctly on both sides of the rename.
- The wire contract going forward is unambiguous: `model` = alias,
  `model_id` = resolved id.

### Negative
- Every current and future reader must carry the fallback and get its
  *direction* right per artifact type — a subtle rule guarded by the
  legacy-journal test and the AGENTS.md landmine.

### Non-goals
- Does not rename keys in external formats fleetflow merely parses.
- Does not backfill `model_id` for runs that never recorded a launch model
  (codex/grok predating the journalled launch model show the alias only).

## See also

- AGENTS.md Landmines — "The `brain`→`model` rename left a load-bearing
  fallback order"
- SKILL.md — "Naming (renamed from `brain`, 2026-08-05)"
- `tests/run.sh` — the legacy-journal round-trip test
