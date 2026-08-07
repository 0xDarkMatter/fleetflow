---
status: accepted
date: 2026-08-03
supersedes: []
superseded-by: []
touches:
  - "SKILL.md"
  - "scripts/ff-spawn.sh"
  - "scripts/ff-collect.sh"
---

# ADR-005: Inter-Worker Communication Is Hub-and-Spoke

## Decision (one sentence)

Fleetflow workers never talk to each other — the only channel is a worker's
FINAL REPLY returning through `ff-collect` to the orchestrator, which embeds
it in a later packet; where genuine cross-worker signalling is wanted, the
tool is `pigeon`, not Claude Desktop's `ccd_session_mgmt`.

## Context

The question "should workers message each other via `ccd_session_mgmt`?" was
asked and settled 2026-08-03. The Desktop messaging tools address *Desktop
sessions* — wrapper JSONs under `claude-code-sessions/`. A fleetflow worker is
an OS process (`claude -p`, `codex exec`, a GLM/Grok endpoint call): it
registers no wrapper, and the non-Anthropic models are not Claude at all, so
`send_message` has no address for them. The tools are also absent from the
terminal CLI binary entirely, so a headless worker could not call them even if
it had an address. Hub-and-spoke is therefore not a stylistic preference here
— it is the only topology this process model permits.

It also matches the ported design: the native Workflow tool's
`prevResult`-into-next-prompt handoff is exactly this shape. Lanes are
isolated worktrees with no shared memory, no message bus, no sideband files; a
judge packet is just the collected builder outputs pasted in. If a stage needs
*all* sibling results, that is a barrier — collect everything first, then
compose.

## Alternatives considered

- **`ccd_session_mgmt` `send_message` between workers.** Rejected on
  mechanism: no address for OS-process workers, tools absent from the CLI
  binary, non-Claude harnesses can never gain them.
- **Sideband files in a shared location.** Rejected: breaks lane isolation
  (the escape guard exists precisely to keep lanes from writing outside their
  worktree), and unaudited peer channels make results non-reproducible from
  the journal.
- **A real message bus (`pigeon`).** Not rejected — scoped out: pigeon is a
  real CLI that works for any harness and is the designated answer when
  long-lived peers genuinely need to signal each other. Peer-to-peer between
  fleetflow *lanes* stays out of scope.

## Consequences

### Positive
- Every inter-worker data flow passes through the orchestrator and the
  journal — auditable, resumable, and gate-able.
- Works identically for every harness (Claude, Codex, Grok, Pi); no
  per-provider messaging shims.

### Negative
- Fan-in requires a barrier: a stage needing sibling results waits for the
  orchestrator to collect them, adding wall-clock over hypothetical direct
  peer messaging.

### Non-goals
- Does not constrain orchestrator-to-*Desktop-session* coordination
  (fleet-ops' MAIN-coordinator role, documented in fleet-ops SKILL.md).
- Does not ban pigeon for non-lane, long-lived worker processes.

## See also

- SKILL.md § "The run lifecycle" — hub-and-spoke paragraph and the
  ccd_session_mgmt settlement
- `references/native-workflow-insights.md` §3/§7 — the handoff pattern ported
- fleet-ops SKILL.md — the Desktop-only channel and MAIN-coordinator role
