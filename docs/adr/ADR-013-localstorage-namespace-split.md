---
status: accepted
date: 2026-08-01
supersedes: []
superseded-by: []
touches:
  - "assets/ff-dashboard.html"
  - "assets/ff-monitor.html"
---

# ADR-013: Dashboard and Monitor Use Split `localStorage` Namespaces (`ffd.*` / `ff.*`)

## Decision (one sentence)

The machine-wide dashboard prefixes every `localStorage` key with `ffd.` and
the single-run monitor with `ff.`, because the two pages can be served from
one origin and share one storage bucket while meaning different things by the
same key.

## Context

Browsers scope `localStorage` by *origin*, not by page. The monitor is copied
into a run dir and served by whatever static server is handy; the dashboard is
served by `ff-serve.py` — and nothing prevents both being reached through the
same origin (the same local host/port, or the `.lab` proxy). When that
happens they share one storage bucket, and both pages persist UI state under
naturally-colliding names: `ff.sort` means "lane sort within a phase group"
to the monitor and would mean "run/repo sort" to the dashboard. A collision
doesn't error — each page just silently reads the other's preference,
producing impossible-to-reproduce UI state that follows the user between
pages.

The split is load-bearing, not cosmetic: every dashboard key (`ffd.pricing`,
`ffd.collapse` state, etc.) lives under `ffd.`, every monitor key under
`ff.`, and new keys must follow the prefix of their page.

## Alternatives considered

- **Share the keys (one namespace).** Rejected: the pages' same-named
  concepts are genuinely different (`sort` orders different things); sharing
  guarantees cross-contamination whenever origins coincide.
- **Guarantee distinct origins instead.** Rejected: serving arrangements are
  the operator's choice (static server, ff-serve, proxy) — the pages cannot
  control how they are mounted, so the fix must live in the keys.
- **`sessionStorage`.** Rejected: these are deliberate persistent preferences
  (sort, card size, pricing basis) meant to survive the tab.

## Consequences

### Positive
- The two pages are safe under any serving arrangement, including one origin.
- A key's prefix identifies its owning page at a glance.

### Negative
- The discipline is conventional — nothing mechanical stops a new
  dashboard key landing under `ff.`; review must catch it.

### Non-goals
- Does not version the stored shapes or decide migration when a key's format
  changes.

## See also

- AGENTS.md Landmines — "Dashboard `localStorage` keys are `ffd.*`, the
  monitor's are `ff.*`"
- `assets/ff-dashboard.html` / `assets/ff-monitor.html` — the two key
  families in situ
