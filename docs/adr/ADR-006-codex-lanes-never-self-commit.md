---
status: accepted
date: 2026-07-08
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-spawn.sh"
  - "scripts/ff-collect.sh"
  - "assets/guard-preamble.txt"
---

# ADR-006: Codex Lanes Never Self-Commit; the Orchestrator Reviews and Commits

## Decision (one sentence)

Codex packets say "DO NOT COMMIT — leave changes in the working tree", the
worker reports `FILES_CHANGED`, and the orchestrator reviews the diff and
commits — because a Codex lane physically cannot commit in a worktree.

## Context

Learned 2026-07-08 on codex-cli 0.142: a git worktree's metadata
(`HEAD.lock`, `index.lock`) lives under the MAIN repo's `.git/worktrees/`,
which is *outside* the lane directory the Codex sandbox (`--full-auto`,
workspace-write, confined via `-C`) allows writes to. A Codex `git commit`
therefore dies with a lock-permission error — after the work itself succeeded.
The failure is deceptive: the lane's edits are fine, only the commit step
explodes, so a packet that assumes self-commit produces a "failed" lane
holding good work.

Rather than fight the sandbox (widening it would surrender the isolation that
justifies running Codex `--full-auto` at all), the contract was inverted:
Codex lanes deliver a dirty working tree plus a `FILES_CHANGED` count in the
FINAL REPLY, and committing becomes an orchestrator act. This tightened the
gate as a side effect — nothing a Codex lane produces can land without an
orchestrator diff review, because the orchestrator is the one holding the
commit. GLM/Anthropic `claude -p` workers are unaffected (no sandbox between
them and the worktree metadata) and may self-commit. `ff-collect
--auto-commit` later added an opt-in convenience: commit a dirty lane tree
after a PASS so landing has a HEAD — orchestrator-side, never changing the
verdict.

## Alternatives considered

- **Widen the Codex sandbox to cover `.git/worktrees/`.** Rejected: the
  sandbox boundary is the safety property; granting write access to the main
  repo's `.git` hands a worker the keys to every lane and the main checkout.
- **Non-worktree Codex lanes (full clones).** Rejected: clones cost per-lane
  disk and lose the shared object store that makes landing and recovery cheap
  (committed lane work survives worktree deletion precisely because objects
  are shared).
- **Wrapper-side commit inside `ff-spawn` after worker exit.** Folded into
  `ff-collect --auto-commit` instead, and gated *after* the PASS verdict —
  committing before the gate would bless unreviewed work with a HEAD.

## Consequences

### Positive
- Every Codex-produced diff gets an orchestrator review before it can land.
- Lanes stop failing on a step that isn't their job; the deceptive
  lock-permission error is designed out.

### Negative
- The orchestrator carries commit work per Codex lane, and an uncommitted lane
  tree is fragile until collected (uncommitted work does not survive worktree
  deletion).

### Non-goals
- Does not restrict GLM/Anthropic workers, which may self-commit.
- Does not decide the Windows sandbox *mode* — that is ADR-007.

## See also

- SKILL.md § Safety — "Codex lanes cannot `git commit`"
- `assets/guard-preamble.txt` — the worker-facing contract text
- `scripts/ff-collect.sh` — `--auto-commit` (post-PASS, opt-in)
