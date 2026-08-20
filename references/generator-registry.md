<!-- SEEDED SKELETON (2026-08-20): expansions land here per ADR-029 — the
     registry doc owns them; ff-plan.sh stays generator-agnostic. The Forma
     expansion tables arrive with rollout Phase 3 (after the Forma repo's
     cleanup pass), NOT in run `ffplan`. Hand-maintained like HARNESS/PRICING:
     a generator contract change updates this file in the same commit. -->
# Generator registry

Work for which a factory exists is planned as generator-backed packets:
invoke the generator, customise, accept via the generator's own gates
(ADR-029). `ff-plan expand --generator NAME` instantiates the tables below.

| Generator | Shape it stamps | Status |
|---|---|---|
| `forma` | CLI+MCP tool (scout → architect → verifier/inspector → mcp-design → HUMAN GATE → mcp-build → warden) | pending Phase 3 — blocked on the Forma repo cleanup pass |
