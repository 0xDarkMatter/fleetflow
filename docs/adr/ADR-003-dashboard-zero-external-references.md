---
status: accepted
date: 2026-08-01
supersedes: []
superseded-by: []
touches:
  - "assets/ff-dashboard.html"
  - "assets/ff-monitor.html"
---

# ADR-003: Dashboard Pages Carry Zero External References

## Decision (one sentence)

`ff-dashboard.html` (and the monitor it shares doctrine with) contains no
external reference of any kind — no CDN script, no webfont, no remote image,
no build step — so the page works offline, from `file://`, and in a network-less
preview pane; a test enforces it.

## Context

The dashboard's consumption surfaces are hostile to network dependencies: it
is opened in Claude Code's Browser/preview panes (which may have no network
route), from `file://` during development, and on a machine whose proxy trusts
only its own CA. A single CDN `<script>` or webfont link degrades any of those
from "works" to "blank page or fallback font", and the failure is
environment-dependent — invisible in the environment where the author tested.
The page is also served live from this repo by the `fleetflow` Process Compose
service, so whatever lands in the file is in production on the next request.

The invariant is machine-enforced (`tests/run.sh`, "dashboard: still zero
external dependencies") because prose alone rots: an agent adding a chart
library via CDN is a one-line diff that looks harmless. One nuance is encoded
with the test: the single CDN-looking string in the file is a **provenance
comment** naming where four inline SVG paths were copied from — prose, not a
fetch — so the test asserts absence of fetching references, not absence of the
substring in comments.

## Alternatives considered

- **CDN-loaded libraries (chart lib, webfont, icon set).** Rejected: breaks
  `file://` and offline panes, adds a third-party availability and
  supply-chain dependency to a page that renders local operational data.
- **A build step bundling dependencies.** Rejected: the repo doubles as a
  live-served skill; a build artifact splits "the file you edit" from "the
  file that serves", exactly the drift a one-file page avoids.
- **Vendoring minified libraries inline.** Not banned by this record, but the
  page so far deliberately hand-rolls its charts/sparklines instead — an
  inlined 200 kB library is auditable by nobody.

## Consequences

### Positive
- The page renders identically online, offline, from `file://`, and in
  preview panes; no network wait, ever.
- No third-party script executes in a page that displays repo paths and run
  data.

### Negative
- Every visual (column charts, sparklines, icons) is hand-built inline; the
  file is large and grows with each feature.

### Non-goals
- Does not forbid *comments* that mention URLs (provenance notes are fine).
- Does not constrain `ff-serve.py`'s server-side behaviour — only what the
  delivered HTML references.

## See also

- `tests/run.sh` — "dashboard: still zero external dependencies" assertion
- AGENTS.md Landmines — "`ff-dashboard.html` has ZERO external references"
- SKILL.md § "The machine-wide dashboard" — "Zero external dependencies, still"
