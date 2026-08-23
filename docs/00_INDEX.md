# docs/ index

One line per artifact class; volatile lists are delegated to the filesystem
rather than hand-copied here. Maintenance rule: touch this file only when a
CLASS of document appears or disappears, not per file.

| Where | What | Mutability |
|---|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the shipped system works — components, data stores, the run pipeline, the invariant map. Drift is a bug. | living |
| [adr/](adr/) | Architecture Decision Records — the WHY behind every standing rule. `ls docs/adr/` is the index; [adr/README.md](adr/README.md) carries the conventions. Lint-gated by `tests/run.sh`. | append-only |
| [plans/](plans/) | Run plans — one per fleet run, self-declared status, disposable once landed. `ls docs/plans/`. | disposable |
| [reports/](reports/) | Measured outcomes (benchmarks, audits) — point-in-time, cited by ADRs. `ls docs/reports/`. | point-in-time |
| [diagrams/](diagrams/) | Source-of-record SVGs embedded by README and ARCHITECTURE.md. Light-only by design: each paints its own opaque canvas, so one file reads correctly on either GitHub theme. `ls docs/diagrams/`. | living |
| [screenshots/](screenshots/) | Anonymised dashboard captures for the README. `ls docs/screenshots/`. | point-in-time |
| [SECURITY.md](SECURITY.md) | Vulnerability reporting policy and supported versions. GitHub reads it from `docs/` as readily as from the repo root. | living |

The living reference docs (worker contracts, native-Workflow extraction, model
routing) live in [../references/](../references/) because they ship with the
skill; `docs/` holds current-state architecture plus the decision and evidence
trail.
