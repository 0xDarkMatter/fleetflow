---
status: accepted
date: 2026-08-20
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-plan.sh"
  - "scripts/ff-spawn.sh"
  - "assets/plan.tmpl.md"
  - "assets/packet.tmpl.md"
---

# ADR-026: `ff-plan` Authors The Manifest Up Front; `ff-spawn` Consumes It

## Decision (one sentence)

The run manifest (`.fleetflow/<run>/manifest.json` — packets, phases, deps,
routing) is authored up front by `ff-plan draft`/`expand` as the plan's
machine-readable half, and `ff-spawn` consumes rather than creates its packet
entries — leaving the journal, content-hash cache keys, and resume semantics
(ADR-012) byte-for-byte unchanged.

## Context

Before ff-plan, the manifest accreted as a side effect of each `ff-spawn`
call: the orchestrator's plan lived in a hand-written `docs/plans/` doc and
the manifest only caught up as lanes launched. That worked at RUNCARD scale
(3 lanes) but leaves nothing machine-checkable *before* tokens are spent —
disjointness, dependency edges, and routing existed only as prose. Every
prior-art system surveyed for the ff-plan design (Axiom's parcel queue, the
native Workflow tool's `meta.phases`) declares the plan structure before
execution; fleetflow was the outlier.

Packets gain YAML frontmatter (owns/modifies/registries/deps/role/class —
see [FFPLAN-2026-08](../plans/FFPLAN-2026-08.md) §5). The spawn cache key
hashes the **whole packet file, frontmatter included**: a re-authored legacy
packet misses cache once and re-runs, which is the correct behaviour — its
contract changed. Stripping frontmatter before hashing was rejected as a
purity leak (two byte-different packets sharing a key violates ADR-012's
"same bytes, same key" property).

## Alternatives considered

- **Keep accretion, add a post-hoc validator.** Rejected: validation after
  spawn is a bill, not a gate — the misrouted lane already ran.
- **A separate plan file format beside the manifest.** Rejected: two
  machine-readable descriptions of the same run drift (the documentary-drift
  failure the docs contract exists to prevent); the manifest already has the
  shape.
- **Hash packet body only, exempting frontmatter.** Rejected (open question
  1): breaks ADR-012's byte purity for a one-time cache miss that is cheap
  and honest.

## Consequences

### Positive
- The plan is checkable before any token is spent; `ff-plan lint` and
  `ff-status --dry`-style previews get a complete substrate.
- `ff-run resume` semantics are unchanged — replay still walks the manifest.

### Negative
- Manifest schema becomes a public contract of two writers (ff-plan authors,
  ff-spawn upserts run-state); the field split must stay documented at the
  construction site.
- Legacy runs without an authored manifest keep working (spawn still upserts)
  — two provenances of manifest exist until old runs age out.

## See also

- [ADR-012](ADR-012-packet-cache-key-purity.md) — the purity property this
  deliberately preserves
- [FFPLAN-2026-08](../plans/FFPLAN-2026-08.md) — the design plan (§3.1, §5)
