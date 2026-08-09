---
status: accepted
date: 2026-08-10
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-run.sh"
  - "scripts/ff-spawn.sh"
  - "scripts/ff-findings.sh"
  - "scripts/ff-widget.sh"
  - "assets/wave-catalogue.json"
  - "SKILL.md"
---

# ADR-018: Post-Build Waves — Posture Selects Depth, Gate Selects Attendance

## Decision (one sentence)

Post-build work (QA, security, polish, docs, a11y, supply-chain, perf) runs as a
**fixed pipeline** — `build → verify → finders → triage → fix → re-verify →
docs-sync → land` — sequenced by `ff-run wave` rather than by the orchestrator,
where a `--posture` (`baseline|tested|hardened|complete`) selects *which finder
waves run*, an orthogonal attendance policy selects *who is watching*, and every
finder emits **findings as ledger records** (`findings.jsonl`) that triage,
fix, re-verify, gates, and the dashboards all consume — remediation is
structural to the pipeline, not a property of the deepest tier.

## Context

Every fleetflow run of consequence has been followed by the same manual passes —
a QA sweep, a security read, a polish round — performed by hand after the fleet
reported done. Those passes are fan-out-shaped work being done serially by the
orchestrator, which is precisely the workload the tool exists to parallelise.

The design forces, in the order they shaped the split:

**Depth and attendance are orthogonal axes, and an early draft conflated them.**
A four-preset ladder of `prototype → reviewed → polished → unattended` names the
first and third by output depth and the second and fourth by human involvement.
The conflation shows up immediately as an inexpressible combination: "run the
deepest passes overnight with nobody watching" and "run the shallowest pass but
stop at every wave" are both reasonable and neither fits the ladder. Splitting
the axes yields fewer names and strictly more expressive power. It also removed
a false claim: the shallowest tier is *not* a prototype, because verify-by-
default already puts adversarial refuters on every build.

**Attendance is a macro; per-wave gates are the single source of truth.**
`--attend none|land|each` only *sets the default* `gate` on each wave
(`auto|review|stop`); an explicit `--gate <wave>=<policy>` overrides the macro
for that wave. There is no separate attendance state to disagree with the
gates — resolving "which wins?" by construction rather than by precedence
rules.

**Findings are data, not prose.** The whole pipeline pivots on findings —
triage dedups them, fix packets consume them, re-verify checks them, gates
count them — so they are a first-class artifact: `.fleetflow/<run>/findings.jsonl`,
one record per finding — `{id, fp, wave, severity, files[], claim, evidence,
status: open|fixed|escalated|waived, round, lane}` — emitted by finder lanes
through the existing `--schema` mechanism and appended via `ff-findings`.
Everything downstream becomes deterministic: triage is a fingerprint pass plus
judgment, a gate is a count query, the barrier state lives on disk so a crashed
run resumes at the barrier, and the dashboards render findings without a new
data path.

**Remediation is the spine, not the summit.** Finder waves emit findings; a
pipeline that files them without closing them is a report generator, and the
manual triage it produces is the cost this feature was meant to remove. Placing
the fix-loop only at the deepest posture reintroduces exactly that failure one
tier down. It therefore sits in the fixed pipeline, bounded by `--fix-rounds`
(0 degrades any posture to report-only) and by a severity floor that auto-fixes
at or below and escalates above. **Anti-oscillation:** a finding whose fix is
refuted by re-verify **twice is escalated, never retried** — without this, an
unattended run burns its budget "fixing" the same finding differently forever.

**Waivers make re-runs convergent.** Run the pipeline twice on the same repo
and every accepted trade-off is re-found, re-triaged, re-escalated — the second
run costs as much attention as the first. A **repo-level** waiver file
(`docs/waivers.json`, committed — repo-level because findings recur across
runs, committed because waivers are team-visible decisions) matches findings by
fingerprint and moves them to `waived` at triage. Waived findings appear in the
run summary as waived, never silently — the no-silent-caps rule applied to
suppression.

**Docs parity is a finder, and it belongs at the floor.** SKILL.md already holds
that "docs are a wave class, not exhaust" and that every behaviour-changing run
ships doc lanes in the same run. Scheduling docs at the deepest tier would have
contradicted shipped doctrine and preserved the neglect the doctrine was written
against. It splits along the same find/fix seam as everything else: a parity
refuter (cheap, reads doc against implementation, prompted to refute the doc)
runs at every posture; the sync lane runs when behaviour changed.

**Wave→model routing is catalogue data, not per-run judgment.** The wave
catalogue (`assets/wave-catalogue.json`) carries a routing column per wave:
finders on cheap models, security cross-provider (Codex + Opus — genuinely
different toolchains attacking the same code), fix on Sonnet, and **re-verify
always a different provider than the lane that produced the fix** — the
adversarial-verify doctrine applied to remediation, encoded as a default the
data enforces rather than a thing the orchestrator remembers.

**Cost is part of the posture choice.** The run summary reports **per-wave
token and cost roll-ups** (aggregated from what `ff-status` already measures,
keyed by the lane's wave label) so choosing between `tested` and `complete` is
a priced decision, not a vibe.

**The barrier lives in `ff-run`, not the orchestrator.** `ff-run resume` is
today a flat sequential replay with no phase boundary, while triage genuinely
requires one — deduplicating findings across QA, security and a11y needs all of
them at once, which is the native tool's stated test for when a barrier is
correct. The alternative — the orchestrator holding wave sequencing in-session,
as it already does for spawn throttling — fails two ways here: a fix-loop that
cannot resume after a crash cannot run unattended, which is the feature; and
scripted sequencing is reachable by `tests/run.sh` while in-session prose is
enforceable only by hope. Pacing spawns and sequencing waves are different jobs
and only the latter needs to be replayable. Mechanical triage (fingerprint
dedup, severity ranking, union-find grouping of findings into file-disjoint fix
packets) is deterministic and belongs to the script; *judgment* triage — is
this finding real, is this fix right — stays with lanes and the orchestrator,
per the hub-and-spoke contract (ADR-005).

## Alternatives considered

- **Three boolean flags (`--qa --security --polish`).** Rejected: the moment two
  are set, the sequencer, the barrier, and the fix-loop are all required anyway,
  so the flags buy nothing and foreclose the wave catalogue becoming data.
- **Keep the four mixed-axis presets.** Rejected: cannot express depth-with-no-
  attendance or shallow-with-full-attendance, and mislabels the floor tier as a
  prototype when adversarial verify already runs there.
- **Fix-loop only at the deepest posture.** Rejected: makes every shallower
  posture a report generator and pushes triage back onto the human.
- **Docs at the deepest posture.** Rejected: contradicts the shipped
  "docs are a wave class, not exhaust" doctrine in SKILL.md.
- **Findings as prose in FINAL REPLY only.** Rejected: every consumer (triage,
  gates, fix packets, re-verify, dashboards, resume) would re-parse prose, and
  barrier state would live in the orchestrator's context — unresumable.
- **Run-level waivers.** Rejected: findings recur across runs; a waiver that
  dies with the run dir re-surfaces every accepted trade-off forever.
- **Orchestrator-held wave sequencing** (consistent with existing manual spawn
  throttling). Rejected: not resumable and not testable — see Context.
- **Perf in the default catalogue.** Rejected as a default, kept as `+perf`: it
  shares the browser harness with QA so its marginal cost is low, but it is
  rarely the binding concern on a freshly built feature.
- **Retry-until-fixed in the fix-loop.** Rejected for the twice-refuted rule:
  unbounded retry of an uncloseable finding is the unattended-budget failure
  mode.

## Consequences

### Positive
- The manual post-run passes become declarative: one flag selects depth, the
  gate policy selects attendance, and the catalogue is data rather than control
  flow.
- Findings are closed rather than filed at every posture that produces them,
  and re-runs converge (waivers) instead of re-litigating.
- Phase boundaries become resumable checkpoints — a crashed fix-loop restarts at
  the barrier instead of re-running the finders.
- The wave catalogue is extensible (routing included) without touching the
  sequencer.
- Posture choice is priced: per-wave cost roll-ups make depth a budget decision.

### Negative
- The severity floor becomes load-bearing: it is the control that makes
  unattended postures safe, so a miscalibrated floor auto-applies changes that
  should have escalated. Auth, crypto, permissions, schema and wire-format
  changes, dependency additions, public API breaks, and anything covered by a
  governing ADR escalate regardless of floor.
- Deeper postures multiply lane count; cost scales with depth and must be
  visible in the run summary (the no-silent-caps rule applies to skipped waves
  and waived findings alike).
- `docs/waivers.json` is one more hand-curated file that can rot; expired or
  wrong waivers suppress real findings, so waivers carry a reason and are
  themselves findings-summary line items.

### Non-goals
- **No posture deploys.** The pipeline terminates at land; deploying remains
  maintainer-gated from an interactive session.
- Does not change spawn-time throttling, which stays with the orchestrator.
- Visual baselines are the target repo's property (`tests/visual/`, committed —
  regression needs history), not `.fleetflow/`'s: run dirs are disposable by
  doctrine (ADR-011).

## Consequence for ADR-012 (cache-key purity)

Re-verify is a cache-key hazard and must be handled explicitly. A re-verify lane
replays a finder packet whose prompt is byte-identical to the pre-fix run, so it
cache-hits and returns the **stale pre-fix verdict** — the fix-loop then reads a
green result it did not earn and terminates. `phase` cannot rescue this: it is
display metadata and deliberately outside the key.

The resolution is to include the lane's **base commit SHA** in re-verify
packets. It is a pure function of the work under test, so it satisfies ADR-012's
content-purity requirement, and it invalidates exactly when the tree changes and
not otherwise — a fix round that changed nothing cache-hits its re-verify,
which is correct and free. A round counter in the key was rejected for exactly
that reason: it re-runs verification the tree does not need. `round` therefore
joins `phase` as **manifest/journal metadata outside the key** — display and
audit, never identity.

## Manifest note

The existing `phases` array (strings, insertion-ordered, unique) is **frozen as
is** — `ff-status`, `ff-aggregate`, and the dashboard all read it, and lanes'
`phase` labels flow through it. Wave state lands in a **new sibling `waves`
key** (ordered objects: `{name, kind: build|finder|barrier|fix|docs, gate,
status, round}` plus run-level `posture`, `fix_rounds`, `severity_floor`), so
legacy readers see exactly the shape they always did and a legacy manifest is
valid by omission — the ADR-017 lesson applied prospectively instead of
retroactively.

## See also

- ADR-012 — packet cache-key purity; the base-SHA rule above is its corollary
- ADR-005 — hub-and-spoke topology; triage is the barrier where lane outputs
  are composed, and judgment stays out of the script
- ADR-011 — archive-before-remove; why baselines and waivers live outside run
  dirs
- ADR-017 — the freeze-and-sibling pattern the Manifest note applies
- SKILL.md — "Default posture: verify by default, scale to the ask"; "The docs
  contract"; "Patterns ported from the native Workflow tool" (adversarial
  verify, loop-until-dry, no silent caps)
- `references/native-workflow-insights.md` §3 — pipeline-by-default and the test
  for when a barrier is correct
