---
status: proposed
date: 2026-08-10
supersedes: []
superseded-by: []
touches:
  - "assets/ff-runcard.js"
  - "assets/ff-dashboard.html"
  - "scripts/ff-widget.sh"
---

# ADR-019: One Run-Card Renderer, Two Embedded Copies, Mechanically Pinned

## Decision (one sentence)

The run header (title/badges/model chips, path, lanes-ran line, pip strip,
tokens-per-lane chart + legend, stat row) is rendered by ONE canonical module —
`assets/ff-runcard.js`, `ffRunCard(runDoc, {surface:"dashboard"|"chat"})` →
HTML string, themed via namespaced `--ffc-*` variables — which the dashboard
and the chat widget each EMBED as a byte-identical copy, with a test failing
the build on any divergence from the canonical asset.

## Context

The inline chat card (ADR-018's widget) and the dashboard's run header drifted
apart within one day of the widget shipping — different grids, different stat
rows, no shared chart. The repo already carries the cautionary precedent: the
dashboard's card language is "shared" with the summon picker *by convention*,
policed only by a "change one, change both" note. Convention did not survive
one feature cycle; a mechanical gate will.

Why embedded copies rather than a runtime include: the dashboard must stay one
self-contained file that works offline and from `file://` (ADR-003), and the
chat sandbox blocks all non-CDN fetches — NEITHER surface may load the module
at runtime. Byte-equality testing of embedded copies is the same register
discipline as `HARNESS`/`PRICING` (ADR-014/015), but mechanical instead of
hand-maintained.

Surface differences stay OUTSIDE the module: the chat widget renders its
wave bar, findings strip, and sendPrompt controls beneath the card; the
dashboard binds its click/drill handlers around it. The module renders state,
never behaviour.

## Alternatives considered

- **Visual parity by hand in ff-widget.sh** (bash emits lookalike HTML).
  Rejected: recreates the summon drift problem this ADR exists to end.
- **Serve the module from ff-serve.** Rejected: violates ADR-003 for the
  dashboard (external ref) and is unreachable from the chat sandbox (CSP).
- **Widget iframes the dashboard.** Rejected: sandbox blocks the origin, and
  the card would stop working when the service is down — the widget is
  deliberately a dead snapshot that outlives every service.

## Consequences

- Positive: header parity is a build invariant; a card improvement lands in
  both surfaces in one commit; the widget's bash shrinks to data-gathering.
- Negative: the chat card now renders post-stream (scripts execute after
  streaming) — a blink of empty container before paint; accepted for a
  snapshot card. Two embedded copies inflate both artifacts by the module's
  size (~a few KB); accepted.
- The runDoc data contract (what ffRunCard consumes) becomes a wire format —
  documented at the construction site in ff-runcard.js and covered by the
  equality test's fixture render.

## See also

- ADR-003 (dashboard zero external references), ADR-014/015 (register
  discipline), ADR-018 (the widget this upgrades)
- SKILL.md "Card language is shared with summon" — the convention this
  replaces with a gate for the widget/dashboard pair
