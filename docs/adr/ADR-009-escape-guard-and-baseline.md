---
status: accepted
date: 2026-07-08
supersedes: []
superseded-by: []
touches:
  - "assets/guard-preamble.txt"
  - "scripts/ff-collect.sh"
---

# ADR-009: Worktree Escapes Are Guarded by Relative-Paths-Only Plus `--check-main-clean`, Baselined Before Closeout

## Decision (one sentence)

Every run carries two default escape defenses — the guard preamble's
relative-paths-only clause and a finishing `ff-collect --check-main-clean`
(exit 12 = escape) — and the orchestrator snapshots a clean-`main` baseline
*before* making any closeout edits of its own, so the check compares against
the pre-spawn state.

## Context

A worktree confines a worker only by convention: the filesystem does not stop
a worker from writing absolute paths. On 2026-07-05 a GLM worker did exactly
that — wrote its output into the main checkout while its own lane stayed
clean, so every lane-level check passed while the main tree silently carried
the work. Two mechanical defenses became defaults: the guard preamble forbids
workers from constructing absolute paths (relative-paths-only), and every run
finishes with `ff-collect --check-main-clean`, which inspects the main
checkout and exits 12 when it finds unexplained writes (stop, `git stash push
-u` to salvage, investigate).

The check then produced its own incident: on 2026-07-08 it fired a false
positive because the orchestrator had made its *own* edits to `main` (docs,
PLAN.md, closeout commits) between spawning lanes and running the check —
self-made edits are indistinguishable from an escaped worker's writes when the
comparison point is "whatever main looks like now". Hence the third rule:
snapshot a clean-`main` baseline (`git status --short` / a commit sha)
**before** any orchestrator-authored closeout edit, so the check compares
against the pre-spawn state, not a moving target the orchestrator itself just
moved.

## Alternatives considered

- **Trust worktree isolation.** Rejected on direct evidence — the 2026-07-05
  escape happened *through* a correctly-provisioned worktree.
- **OS-level sandboxing for every worker.** Only Codex ships one; GLM/Grok/
  Anthropic `claude -p` workers have no equivalent enforcement layer, so a
  convention-plus-audit design is what generalises across harnesses.
- **Preamble clause alone (no closing check).** Rejected: the preamble is
  advice to a model and can be ignored; the check is the mechanical layer that
  catches the ignoring.
- **Check against "main is clean right now".** That was the 2026-07-08 bug —
  the baseline rule replaces it.

## Consequences

### Positive
- Escapes are detected at run end with a semantic exit code (12) a script can
  branch on, and salvage (`git stash push -u`) is prescribed before cleanup
  can destroy the evidence.
- The false-positive class from orchestrator self-edits is designed out.

### Negative
- Detection, not prevention: an escaped write exists until the closing check
  runs. The orchestrator must actually remember to run it (doctrine: "always
  finish with `--check-main-clean`") and to baseline first.

### Non-goals
- Does not cover writes outside the repo entirely (cache/tmp litter is
  handled by the cache-redirect design, not this guard).
- Does not decide sandbox posture per harness (ADR-006/ADR-007 for Codex).

## See also

- SKILL.md § Safety — "Escape guard" and "Baseline-before-closeout"
- `assets/guard-preamble.txt` — the relative-paths-only clause
- `scripts/ff-collect.sh` — `--check-main-clean` (exit 12)
