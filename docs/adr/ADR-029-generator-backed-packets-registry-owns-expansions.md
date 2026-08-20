---
status: accepted
date: 2026-08-20
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-plan.sh"
  - "references/generator-registry.md"
---

# ADR-029: Generator-Backed Packets — The Registry Doc Owns Expansions, The Script Stays Generic

## Decision (one sentence)

Work for which a factory exists (first entry: Forma's CLI+MCP stamping
pipeline) is planned as generator-backed packets — invoke the generator,
customise, and accept via the generator's own gates — expanded by `ff-plan
expand` from expansion tables that live in `references/generator-registry.md`,
keeping `ff-plan.sh` itself generator-agnostic.

## Context

A complex application decomposes into judgment work and pattern-
instantiation work, and the second class is where fleets win or lose on
cost: a bespoke build packet for "another CLI tool" re-derives what a
factory already guarantees. A generator-backed packet is a different packet
class — mostly template, machine-checkable acceptance (the generator's own
verifier), near-zero integration risk — and therefore routes cheap.

Forma proves the shape: its pipeline skills carry variable-slotted headless
prompts (12 Architect slots), a contention table that pre-solves lane
disjointness (one lane per tool dir, Warden as the registry mutex), stage
gates (verifier verdict, inspector run, §30 MCP checklist), and a telemetry
channel (`forma log`) collect can reconcile against. Three frictions are
resolved in the expansion once, not per run: fleetflow's gated sandbox model
overrides Forma's `bypassPermissions` spawn advice; the real ecosystem root
is injected rather than the prompts' hardcoded paths; and per-packet trailer
policy honours target-repo rules.

Keeping expansions in the registry *doc* (open question 5) rather than in
script code means adding a generator is a documented table + prompt
templates — reviewable prose, no bash surgery — and the script's job is
mechanical instantiation.

## Alternatives considered

- **Bespoke packets for everything.** Rejected: re-derives factory
  guarantees at premium-model prices and hand-written acceptance criteria.
- **Per-generator subcommands in ff-plan.sh.** Rejected: N generators would
  each grow script surface; the registry-doc split keeps one code path.
- **A generator plugin directory of shell hooks.** Rejected for now:
  arbitrary code execution at plan time widens the trust surface; revisit if
  a generator genuinely needs computation beyond template instantiation.

## Consequences

### Positive
- Stampable work routes to cheap models with the factory's gate as the done
  criterion; future factories (scaffold-class skills) slot in as table rows.

### Negative
- The registry doc is hand-maintained (like `HARNESS`/`PRICING`): a
  generator contract change must update it in the same commit, and the lint
  can only check what the tables declare.

## See also

- [ADR-014](ADR-014-fleet-view-three-registers.md) / [ADR-015](ADR-015-pricing-basis-and-blended-plans.md) — the hand-maintained-register precedent
- [FFPLAN-2026-08](../plans/FFPLAN-2026-08.md) §8 — the Forma expansion in full
