---
status: accepted
date: 2026-08-24
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-doctor.sh"
  - "SKILL.md"
  - "README.md"
---

# ADR-033: The Orchestrator Contract Is Bash Plus Judgment, Not Claude Code

## Decision (one sentence)

The orchestrator seat requires only the ability to execute the `ff-*` scripts
and exercise frontier-grade judgment over their output — any agent harness
(Codex, Pi, a human at a terminal) may hold it, so `ff-doctor` gates on the
models a run actually spawns (`--for MODEL,...`) rather than assuming a
Claude-orchestrated fleet, and Claude-Code-specific conveniences (skill
loading, the chat widget, the Browser-pane ritual, `ff chip`, `--acp`
steering) are defined as optional surfaces that degrade silently, never as
requirements.

## Context

fleetflow's thesis is provider diversity: one model per OS process, chosen
per lane. The worker tier honours that. The orchestrator seat did not — not
mechanically (every interface the seat uses is a bash CLI with semantic exit
codes and data on stdout; the journal, manifest, worktrees, and dashboard are
all filesystem) but by packaging and one preflight line:

- `ff-doctor` hard-failed when the `claude` binary was absent, vetoing a
  codex+grok+pi fleet on a machine with no Claude Code installed, even though
  nothing in such a run would ever invoke `claude`.
- The README tagline bound the tool to "one Claude Code session", and
  SKILL.md's rituals (Browser pane, chat widget) read as requirements rather
  than conveniences of one particular host.

The README already half-claimed the opposite ("a frontier orchestrator —
Claude Fable, or GPT-5.6 Sol via Codex — architects the run"). This ADR makes
the claim real and states its bounds.

## Options considered

1. **Status quo** — Claude Code is the orchestrator; other harnesses
   unsupported. Rejected: the coupling was accidental (one doctor line, one
   tagline), and it contradicts the tool's own thesis at the seat where
   judgment concentrates.
2. **Port fleetflow's doctrine into each harness's native packaging** (a
   Codex AGENTS.md profile, a Pi system prompt, kept in lockstep with
   SKILL.md). Rejected: three copies of the doctrine is documentary drift by
   construction — the exact failure mode the docs contract exists to prevent.
   SKILL.md stays the single source; other harnesses are pointed at it.
3. **Scope the contract** (chosen) — define the seat as bash + judgment,
   scope preflight to requested models, and mark host-specific surfaces
   optional. The doctrine stays in one file; the mechanics stay
   harness-blind.

## Consequences

- `ff-doctor --for MODEL[,MODEL...]`: a missing harness for a *requested*
  model escalates advisory→fail; `claude` is required only when the request
  includes a claude-family model, `glm` (fleet-worker rides `claude -p`), or
  `chip` — or when no `--for` is given, which preserves the historic
  Claude-orchestrated default unchanged.
- Judgment quality remains the operator's responsibility. The decision gate's
  routing doctrine (frontier models in judgment seats) applies to whatever
  model drives the harness: Codex with a frontier model behind it qualifies;
  Pi qualifies exactly when its wildcard provider does.
- A non-Claude orchestrator must be *given* the doctrine: it reads SKILL.md
  as a document (AGENTS.md already directs this) rather than receiving it via
  skill loading. The widget, Browser-pane ritual, `ff chip`, and `--acp`
  steering are unavailable off-host and must never grow load-bearing duties.
- Codex-as-orchestrator needs a permissive sandbox — the opposite posture
  from Codex *lanes*, which stay pinned per ADR-007. Same binary, two
  postures, chosen by seat. On Windows this is not advisory: measured
  2026-08-24, `codex exec --sandbox workspace-write` cannot host Git Bash at
  all (msys bash dies at init with `CreateFileMapping … Win32 error 5` — the
  sandbox denies the cygwin shared-memory section), so every `ff-*` script is
  unreachable from a sandboxed Windows codex. The orchestrator posture there
  is full access or nothing.
- Verification status, 2026-08-24: **two non-Claude harnesses drove `ff plan
  draft → lint` end-to-end on Windows, unmodified** — opencode 1.18 and pi
  0.83 (gpt-5.4-mini via openai-codex). Both executed the commands in order
  and reported lint's exit code, armed-check count, and packet paths
  accurately; both claims were replayed against the filesystem rather than
  taken on trust. The seat is proven harness-portable for the planning gate,
  and pi's success is the stronger signal: it is the minimalist harness with
  no sandbox of its own, which is precisely the shape the orchestrator seat
  wants. Still open: a permissive-posture codex run (needs an
  operator-launched session — an auto-mode Claude session correctly may not
  spawn a bypass-sandbox child), the WSL-bash-under-codex-sandbox probe, and
  a full spawn-to-clean run from any non-Claude seat.
