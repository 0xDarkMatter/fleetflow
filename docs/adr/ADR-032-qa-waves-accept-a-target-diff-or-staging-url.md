---
status: accepted
date: 2026-08-21
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-run.sh"
  - "assets/wave-packets/qa.tmpl.md"
  - "assets/wave-packets/visual-qa.tmpl.md"
  - "assets/wave-packets/perf.tmpl.md"
---

# ADR-032: QA Waves Accept `--target diff|staging=<url>`

## Decision (one sentence)

`ff-run wave` takes a `--target` (default `diff`, meaning inspect the
change — today's behaviour), where `staging=<url>` aims the finder waves at
a **running** instance with full interaction permitted (forms, state
mutation, whole flows — staging is disposable) but never deploying,
restarting, or reconfiguring the target service; deploy stays
maintainer-gated per ADR-018's no-posture-deploys non-goal, and visual
lanes route claude-family so they can carry MCP servers (e.g. Figma) in
their config dir.

## Context

The finder waves (ADR-018) audit a *tree*: they read the diff, run the
repo's own commands, and infer runtime behaviour from code. That is the
right default — cheap, hermetic, no environment needed — but it caps what
QA-shaped waves can honestly claim. A functional finder inferring "this
form would lose edits" from the code is a weaker finding than one that
drove the form and watched the edits vanish; a visual finder reasoning
from CSS is weaker than one that screenshotted the rendered page. When a
disposable staging deployment of the product already exists, pointing the
same waves at it converts inference into observation for exactly the three
waves whose findings are behavioural: `qa`, `visual-qa`, and `perf`.

The one decision here is that **a wave takes a target**. `--target` is a
run-level input threaded into finder packets as `%%TARGET%%` — like
`%%BASE_SHA%%` it is a pure function of what is being audited, never a
timestamp, so it stays ADR-012 cache-key clean. It is recorded in the
manifest and summary JSON beside `posture`, so dashboards and resumed runs
can see what a run was aimed at, and a resume without an explicit
`--target` keeps the recorded value (manifest is truth, same as
`fix_rounds`).

Two guard rails carry over unchanged. Staging permits full interaction
because staging is disposable — but interaction is not administration:
lanes never deploy, restart, or reconfigure the target service, the same
boundary ADR-018 draws with its no-posture-deploys non-goal. And
visual-qa's routing stays claude-family (sonnet today): a claude lane can
carry MCP servers (e.g. Figma) in its own config dir, which is what lets
the visual lane judge against a real comp rather than only heuristics.

## Alternatives considered

- **The elaborate live-target design** — declared-environments config, a
  `prod` read-only tier, a fetch/judge vendoring split so non-claude
  models could judge screenshots, component-hash fingerprints for visual
  diffing, and dedicated baseline-management tooling. Rejected as
  over-engineered for v1: every piece is speculative machinery ahead of a
  single live-target run's evidence. Each is named as a non-goal below so
  its absence is a decision, not an oversight.
- **A boolean `--live` flag.** Rejected: the URL has to travel anyway, and
  a bare boolean invites a second flag for the address — one value that is
  either `diff` or `staging=<url>` keeps flag surface minimal and makes
  the target self-describing in the manifest.
- **Per-wave targets** (qa at staging, visual-qa at diff). Rejected: no
  evidence of need, and a split target makes "what was this run aimed at"
  a per-lane question the summary can't answer in one field.

## Consequences

### Positive

- QA-family findings against a staging URL are observations, not
  inferences — strictly stronger evidence for the same lane cost.
- The target is recorded beside `posture` in manifest/summary JSON, so
  dashboards and resumes see what a run was aimed at.
- The default is byte-compatible: no flag means `diff`, which is exactly
  today's behaviour.

### Negative

- A stale staging deployment silently audits the wrong build — the target
  URL says *where*, nothing verifies *what revision* is running there.
  Accepted for v1; a revision handshake waits for it to bite.
- The never-deploy/restart/reconfigure rule is prompt-enforced in the
  packet, not mechanically sandboxed — consistent with the wave packets'
  existing read-only contract, and the same trust level.

### Non-goals (each waits for evidence of need)

- **No prod tier.** Staging is the only live target; nothing here points a
  fleet at production.
- **No declared-environments config.** The URL is a flag value, not a
  registry.
- **No fetch/judge vendoring split.** Visual lanes route claude-family
  and do their own looking.
- **No component-hash fingerprints.** Visual comparison stays
  screenshot-vs-baseline prose findings.
- **No baseline tooling.** `tests/visual/` stays the target repo's
  hand-managed property (ADR-018 non-goals).

## See also

- [ADR-018](ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md) —
  the wave pipeline this aims; its no-posture-deploys non-goal is the
  boundary staging interaction stops at
- [ADR-012](ADR-012-packet-cache-key-purity.md) — why `%%TARGET%%` is
  legal in a packet (run-level input, content-pure)
- [ADR-017](ADR-017-model-rename-alias-fallback-order.md) — the
  sibling-key manifest pattern `target` follows
