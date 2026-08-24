---
status: accepted
date: 2026-08-24
supersedes: ["ADR-006"]
superseded-by: []
touches:
  - "scripts/ff-spawn.sh"
  - "assets/guard-preamble.txt"
---

# ADR-034: Codex Lanes Self-Commit via Scoped Git Grants

## Decision (one sentence)

Codex worktree lanes self-commit like every other model, enabled by exactly
four sandbox write grants — the lane's own worktree metadata dir, the
append-only object store, the lane branch's ref dir, and its reflog dir
(both per-run, pre-created at spawn) — while `.git/config`
(`core.hooksPath` = code execution), `hooks/`, `refs/heads/main`,
`packed-refs`, and other lanes' metadata stay outside the cage; the commit
clause returns to the shared guard preamble and the per-model prompt split
is gone.

## Context

ADR-006 inverted the commit contract for codex ("edits, orchestrator
commits") because a worktree's git metadata lives in the main repo's `.git`,
outside the codex sandbox, and the only known alternative was `--add-dir`
on the whole git dir — a hole that includes `config`, hooks, and every ref
(its addendum records that exact carve-out shipping anyway and surviving
seven weeks). The maintainer's standing preference, stated 2026-08-24, is
uniform lane behaviour: every model commits its own work.

Those two positions only conflicted while the choice was binary. A commit
needs write access to precisely four places, all of which can be granted
individually — `--add-dir` accepts multiple directories — and none of which
include the dangerous surfaces. The binary choice was a false one.

## Options considered

1. **Keep ADR-006** (orchestrator commits). Rejected: contradicts the
   maintainer's uniformity preference, and the forced-diff-review benefit
   was already redundant — every `ff-run wave` collect site passes
   `--auto-commit`, so orchestrator-side commits happened without review in
   practice.
2. **Restore the full git-dir carve-out.** Rejected: reopens the ADR-006
   addendum's hole (hooksPath, main ref, cross-lane metadata) for no gain
   over option 3.
3. **Scoped grants** (chosen): worktree metadata + objects + own ref dir +
   own reflog dir. Uniform behaviour, minimal surface.

## Consequences

- Verified live 2026-08-24 (dogfooded through `ff-spawn`, no dry-run): a
  codex worktree lane committed to its branch (`git log` ground truth, not
  the lane's claim), and an adversarial probe instructed to append to the
  main `.git/config` was denied — config byte-identical after the run.
- Auto-gc inside a lane may fail to write `.git/gc.log` (root of the git
  dir, ungranted). Harmless: gc runs detached after the commit lands and
  its failure warns rather than blocks; lanes rarely cross the loose-object
  threshold.
- The object store is writable by lanes. Acceptable: objects are
  content-addressed and immutable; unreachable ones are GC'd. No ref
  outside `refs/heads/fleetflow/<run>/` can be moved by a lane.
- Non-worktree codex lanes run in the primary checkout, where `.git` sits
  inside the workspace-write root — they could always commit; behaviour is
  now uniform rather than accidental.
- `ff-collect --auto-commit` remains the safety net for lanes that die
  before committing; it still fires only on a passing gate.
- The per-model prompt split (and its cache-key invalidation) reverts: one
  commit clause in the guard preamble for all models. Guard-enabled packet
  keys from the split's brief life invalidate once more.
