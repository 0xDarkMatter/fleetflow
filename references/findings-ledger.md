# The Findings Ledger (`ff-findings.sh`)

> Contract owned by [ADR-018](../docs/adr/ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md)
> §1 (findings are data, not prose) and its Manifest note. This doc states the
> record grammar, the fp construction, and the lifecycle — it does not restate
> the ADR's reasoning; read that for WHY findings are structural to the
> pipeline rather than a report generator's output.

## Record grammar

One JSON object per line in `.fleetflow/<run>/findings.jsonl`:

| field | who sets it | why |
|---|---|---|
| `id` | ledger, at append | `<wave>-<seq>`, zero-padded per wave (`qa-003`) — stable, human-referenceable, independent of fp collisions across waves |
| `fp` | ledger, at append | identity for dedup — see below |
| `wave` \| `severity` \| `files` \| `claim` \| `evidence` | finder lane | the defect itself; schema at `assets/findings.schema.json` |
| `status` | ledger / triage / fix loop | `open\|fixed\|escalated\|waived` |
| `round` | fix loop, via `--round` | which fix-loop pass produced/last touched this record — metadata, per ADR-018's cache-key consequence, never part of a re-verify packet's identity |
| `lane` | producing lane, via `--lane` | the lane id that found or last touched it, for audit trail |
| `ts` | ledger, at append | epoch — **ledger-only, never in a packet** (ADR-012: a timestamp in a prompt mints a fresh cache key every run) |

## fp construction — at the site it's built

`fp` is the first 12 hex chars of
`sha256(wave + "\n" + sorted(files).join(",") + "\n" + lowercase(collapse_ws(claim)))`.

Constructed exactly once, in `ff-findings.sh append`'s `cmd_append` branch,
because that is the only place a finding's identity should ever be decided —
triage, the fix loop, and re-verify all key off the result rather than
re-deriving it, so a change to the formula only has one call site to update.

- **wave + files** anchor identity to *what broke and where*, not to prose.
- **claim, normalized** — lowercased, runs of whitespace collapsed to one
  space — means a finder that phrases the same defect slightly differently
  across a re-run (different LLM sample, same bug) still dedupes instead of
  minting a duplicate row.
- **evidence is deliberately excluded.** Repro details are expected to be
  re-worded round over round without becoming a "new" finding.
- **12 hex chars**, not the full digest: enough entropy for a per-run ledger
  (thousands of findings, not billions) while staying short enough to type in
  `--fp` and to read in the widget's findings strip.

## Lifecycle

```
            append (new fp)              triage: file-disjoint             fix lane lands a commit
  finder ─────────────────────▶  open  ───group, at/below floor───▶  (still open, round++)
                                   │                                          │
                                   │ triage: above floor or                   ▼
                                   │ always-escalate path                re-verify (different provider)
                                   ▼                                    refutes ──┐  confirms
                              escalated                                  round<2  │     │
                                   ▲                                     (retry)◀─┘     ▼
                                   └───────── refuted twice ─────────────────────    fixed
                                                                                        │
  apply-waivers (fp in docs/waivers.json,                                              │
  status was open) ──────────────────────────────────────────────▶  waived  ◀──────────┘
                                                                    (waive --fp can also
                                                                     set this directly)
```

Anti-oscillation (ADR-018): a fix that re-verify refutes twice is `escalated`,
never retried a third time — see `set-status`/round gating below.

## Waivers file

`docs/waivers.json` — repo-level (findings recur across runs) and committed
(a waiver is a team-visible trade-off, not run-scoped state):

```json
[{"fp": "a1b2c3d4e5f6", "reason": "accepted risk, see #42",
  "waived": "2026-08-10", "expires": null}]
```

`expires` is an ISO date or `null` (never). `apply-waivers` skips and warns
on stderr for any entry whose `expires` has passed — an expired waiver
un-suppresses the finding on the next apply, it does not silently keep
waiving it.

## CLI

```
ff-findings.sh append        --run NAME [--json JSON | stdin] [--round N] [--lane ID]
ff-findings.sh list          --run NAME [--status S] [--severity S] [--wave W] [--min-severity S]
ff-findings.sh count         --run NAME [same filters]           # -> {"open":n,"fixed":n,...}
ff-findings.sh set-status    --run NAME --fp FP --status S
ff-findings.sh waive         --run NAME --fp FP --reason R [--expires DATE]
ff-findings.sh apply-waivers --run NAME
```

All flags, no positionals; `--repo PATH` overrides the git-toplevel default
on every subcommand. Exit 0 even on zero matches/zero results — exit codes
signal errors (`2` usage/bad input, `3` run-or-ledger missing), not empty
result sets.

```
ff-findings.sh count --run wave1 --min-severity high
ff-findings.sh list --run wave1 --status open --wave security | jq '.[].claim'
ff-findings.sh waive --run wave1 --fp a1b2c3d4e5f6 --reason "accepted, tracked in #42"
```
