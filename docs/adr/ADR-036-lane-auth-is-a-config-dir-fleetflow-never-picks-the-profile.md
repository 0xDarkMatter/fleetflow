---
status: accepted
date: 2026-09-05
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-spawn.sh"
  - "scripts/ff-doctor.sh"
---

# ADR-036: A Lane's Claude Auth Is a Config Dir fleetflow Points At; Choosing the Profile Is Never fleetflow's Job

## Decision (one sentence)

`ff-spawn --config-dir DIR` runs a claude-family lane against **any** given
`CLAUDE_CONFIG_DIR` — refused for non-claude models, a missing directory, and
the host store itself, and deliberately **not** part of the cache key — while
the choice of *which* store is healthy stays outside fleetflow: `ff-doctor`
NAMES healthy roost profiles when the host probe fails and never selects one.

## Context

Anthropic lanes inherit the host's claude config by design: unlike GLM lanes
(isolated so the host OAuth token is never sent to z.ai, worker contract §1)
they are *meant* to have host skills and MCP available. The consequence went
unnoticed until it bit: the host store is a **single point of failure for the
whole Anthropic tier**. On 2026-09-04 a 33-lane run lost every sonnet and opus
lane at once, mid-run, to one expired host token —
`Failed to authenticate: OAuth session expired and could not be refreshed` —
with no recovery path inside fleetflow. The same expiry reproduced here the
next day.

Meanwhile the machine already had healthy Max profiles under
`~/.claude-profiles/`, managed by roost, and
[ADR-016](ADR-016-roost-widget-pass-through.md) had already integrated roost
into the **dashboard** — but nothing in the spawn path could use them.

Three shapes were available.

**Depend on roost.** Rejected. It contradicts the README's dependency posture
(nothing vendored; a missing optional tool exits 5 with a named reason), and it
makes a single-maintainer tool load-bearing for the ability to spawn a lane at
all. The failure being solved — one dead token kills the tier — is not
roost-specific, so the fix must not be.

**Reimplement profile health in fleetflow.** Rejected, and this is the more
tempting error. It means parsing OAuth token stores, tracking expiry, reading
quota, and ranking profiles — then drifting from roost every time roost
changes. That is precisely the restatement-drift failure ADR-016 named for UI
and the docs contract names for prose, relocated into code. A second
implementation of somebody else's state is a liability, not a feature.

**Split mechanism from policy.** Accepted. Pointing a process at a config
directory is a one-line mechanism fleetflow already owns twice over —
`FLEET_WORKER_CONFIG_DIR` for GLM, `PI_CODING_AGENT_DIR` for pi. Deciding which
store is healthy is a genuine domain with a tool already solving it. So
fleetflow takes the flag and roost keeps the judgment.

## Consequences

**The flag takes any directory, not a profile name.** `--config-dir
~/.claude-profiles/roamhq` and `--config-dir /some/other/store` are equally
valid. A host with no profile manager still gets the escape hatch, which is the
point: the single-point-of-failure is not conditional on roost being installed.

**Three guards, each closing a way the flag could lie.** Non-claude models are
refused rather than silently ignored (glm and pi isolate through their own
launcher variables; codex and grok have no Claude OAuth to redirect). A missing
directory is refused because `claude` *creates* one and then finds no
credentials in it — a typo'd path degrades into the exact auth failure the flag
exists to route around. The host config is refused because handing a lane the
host store is both a no-op and the thing GLM's isolation rule exists to
prevent.

**It is not in the cache key.** The same packet on the same model is the same
work whichever account paid for it, so a profile switch must not invalidate a
journal entry ([ADR-012](ADR-012-packet-cache-key-purity.md)). It joins
`--phase`, `--round` and `--orchestrator` as manifest and display metadata.

**Transcript archiving follows the redirect.** A `--config-dir` lane writes its
session under *that* store, so the archiver resolves
`$CLAUDE_HOME/projects/…` from one expression shared with the launch. Hardcoding
`~/.claude` there would silently lose the transcript of every profile-routed
lane — the failure is invisible because archiving is best-effort by design.

**The doctor names, never chooses.** When a claude probe fails and `roost` is on
PATH, one advisory row lists healthy profiles least-used first, with the exact
flag to pass. Auto-selecting was rejected: silently moving a fan-out onto a
different account is the kind of surprise ADR-004 and ADR-016 already
click-gate. Absent roost, the row does not appear at all — no nagging about a
tool the host does not run.

**What this does not solve.** A host with no healthy profile anywhere still
needs an interactive re-login, which no flag can perform; the doctor says so
explicitly rather than implying a fallback exists. Provider-exhaustion
fallbacks more broadly (quota-exhausted vs auth-expired vs unreachable, and a
`--fallback` ladder across providers) are a separate decision, deliberately not
settled here.
