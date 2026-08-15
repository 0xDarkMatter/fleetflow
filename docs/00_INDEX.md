# docs/ index

One line per artifact class; volatile lists are delegated to the filesystem
rather than hand-copied here. Maintenance rule: touch this file only when a
CLASS of document appears or disappears, not per file.

| Where | What | Mutability |
|---|---|---|
| [adr/](adr/) | Architecture Decision Records — the WHY behind every standing rule. `ls docs/adr/` is the index; [adr/README.md](adr/README.md) carries the conventions. Lint-gated by `tests/run.sh`. | append-only |
| [plans/](plans/) | Run plans — one per fleet run, self-declared status, disposable once landed. `ls docs/plans/`. | disposable |
| [reports/](reports/) | Measured outcomes (benchmarks, audits) — point-in-time, cited by ADRs. `ls docs/reports/`. | point-in-time |

The living reference docs (worker contracts, native-Workflow extraction, model
routing) live in [../references/](../references/) because they ship with the
skill; `docs/` holds the decision and evidence trail.
