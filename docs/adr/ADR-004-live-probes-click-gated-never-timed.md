---
status: accepted
date: 2026-08-01
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-serve.py"
  - "assets/ff-dashboard.html"
---

# ADR-004: Live Doctor Probes Are Click-Gated, Never on a Timer

## Decision (one sentence)

Any dashboard action that spends money or mutates external state — the
`/api/doctor.json?live=1` provider probe foremost — runs only on an explicit
user click, never on a poll path, timer, or page-load hook, and a test asserts
no `setInterval` drives it.

## Context

`ff-doctor --live` is not a read: it runs a one-turn `claude -p` against every
Anthropic model (including Fable) plus real auth probes at every other
provider. Each invocation is billable model usage and takes minutes. The
dashboard polls its aggregate every few seconds; if the live doctor sat on
that poll path — or on any timer — the dashboard would quietly bill a
provider round-trip on every tick, forever, on an idle machine. That is a bug
with an invoice attached, and it would be invisible until the invoice.

So the boundary is drawn by *effect*, not by endpoint: offline/read probes
(`--offline`: binaries + `bash -n`) may run automatically when the Fleet view
opens; anything that spends or mutates is click-gated. The server side
reinforces the gate with a 15-minute cache on live results, and the probe runs
in a background thread so the click never blocks the page. The same principle
was later extended to the roost auth-refresh button (2026-08-05), which
mutates the OAuth token store and is likewise click-gated with no timer (see
ADR-016).

## Alternatives considered

- **Live probe on the poll path / a refresh timer.** Rejected: recurring
  spend proportional to how long a tab stays open, unrelated to any human
  decision.
- **Probe on page load.** Rejected for the same reason in smaller form —
  opening the dashboard to *look* should never cost a model call.
- **Rate-limiting alone (server cache, no click gate).** Insufficient: it
  bounds the spend but still detaches it from intent; the cache is kept as a
  second layer, not the gate.

## Consequences

### Positive
- Zero standing cost: a dashboard left open all day spends nothing.
- Spend maps one-to-one to a human decision ("probe now").
- The gate is test-enforced (`tests/run.sh` asserts no `setInterval` drives
  the live probe, and separately that roost refresh has no timer).

### Negative
- Capacity data is only as fresh as the last click — accepted, and the UI
  compensates by always stamping the probe's age rather than implying
  liveness.

### Non-goals
- Does not gate `--offline` probes or read-only polling (aggregate, status,
  roost status), which are free and may stay tick-driven.

## See also

- `tests/run.sh` — no-`setInterval` assertions for doctor live and roost refresh
- AGENTS.md Landmines — "`/api/doctor.json?live=1` spends real model calls"
- ADR-016 — roost auth refresh, the same gate applied to a mutation
