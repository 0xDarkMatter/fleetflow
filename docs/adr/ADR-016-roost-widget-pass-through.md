---
status: accepted
date: 2026-08-05
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-serve.py"
  - "assets/ff-dashboard.html"
---

# ADR-016: The Roost Pane Embeds Roost's Own Widget Verbatim; Auth Refresh Is Click-Gated

## Decision (one sentence)

The dashboard's roost accounts pane passes through **roost's own
`roost widget` fragment verbatim** (never re-rendering a surface roost
already ships; a test enforces the pass-through), the whole section is
conditional on the `roost` binary existing, and the auth-refresh endpoint —
which mutates the OAuth token store — is click-gated and never on a poll or
timer.

## Context

Roost (claude-lb, the Claude Code OAuth profile health/load-balancer) already
ships an embeddable status surface: `roost widget` emits a script-free,
`.rw`-scoped CSS fragment built for exactly this use. Re-designing that
surface inside the dashboard would create a second rendering of roost's state
that drifts every time roost changes — the same restatement-drift failure the
docs contract names for prose, applied to UI. So the pane embeds the fragment
verbatim, with `/api/roost.json` also carrying a trimmed `roost status
--json` as the fallback for a roost build without the widget subcommand.

Integration is strictly conditional: the server probes `shutil.which("roost")`
once (background thread, cached 60 s — roost caches its own probes ~5 min);
an absent binary yields `{"available": false}` and the section never renders.
Page fetches are tick/click driven, never on a timer of their own.

The refresh button is the sharp edge: `/api/roost/refresh` runs
`roost refresh --soon 30m --json` — it *renews OAuth tokens*, mutating the
token store, then forces a status re-probe. Under ADR-004's principle
(anything that spends or mutates is click-gated), it runs only on click, in a
background thread, and tests assert both the click-gated endpoint's shape and
the absence of any timer driving it.

## Alternatives considered

- **Re-render roost state with dashboard-native UI.** Rejected: a hand-built
  copy of a surface roost ships is guaranteed drift; the widget is
  purpose-built for embedding (script-free, scoped CSS).
- **Unconditional integration (assume roost).** Rejected: fleetflow runs on
  machines without roost; a hard dependency would break the dashboard there
  for a strictly optional feature.
- **Auto-refresh expiring tokens from the dashboard.** Rejected: a token-store
  mutation on a timer is exactly the class ADR-004 bans — and auth renewal
  belongs to a deliberate operator action, not a page being left open.

## Consequences

### Positive
- Roost UI changes flow through automatically; the dashboard cannot drift
  from roost's own presentation.
- Machines without roost see no broken section; token mutations map
  one-to-one to operator clicks.

### Negative
- The pane's look is bounded by what roost ships; dashboard-side styling
  control is deliberately given up.
- A second probe-caching layer (server 60 s over roost's ~5 min) means
  freshness reasoning spans two caches.

### Non-goals
- Does not manage roost configuration or profiles — the pane is read-plus-
  one-action (refresh) only.
- Does not generalise a plugin system for other CLIs; this is a single
  conditional integration.

## See also

- SKILL.md § "The machine-wide dashboard" — "ROOST accounts (conditional)"
- `tests/run.sh` — widget pass-through and no-timer-refresh assertions
- ADR-004 — the click-gate principle this extends to a mutation
