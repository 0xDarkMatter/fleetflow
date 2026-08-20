<!-- SEEDED SKELETON (2026-08-20): the templates lane of run `ffplan` owns
     this file — see docs/plans/FFPLAN-2026-08.md §7 and ADR-026/027. -->
# Run plan: `{{RUN}}` — {{TITLE}}

**Status:** draft ({{DATE}}) · **Disposable** — decisions live in the cited
ADRs; this doc carries only the run's shared contracts and lane table. Cite,
never restate. File ownership is exclusive. FINAL REPLY per packet
`final_reply` shape.

```
GOAL: {{GOAL}}
SPEC: {{SPEC_PATH}}
PHASES: {{PHASES}}
PACKETS: {{N}}
CRITICAL-PATH: {{IDS}}
EST: {{WALL_CLOCK}} assuming {{K}}-parallel
DETECTED-CONFLICTS: {{0_OR_LIST}}
BOUNDS: {{DECLARED_BOUNDS_OR_NONE}}
```

## §1 Shared contracts

<!-- frozen, verbatim; every packet cites §§ by number -->

## §2 Lane table

| id | role | class | model | owns (exclusive) | builds | gate |
|---|---|---|---|---|---|---|

## §3 Dependency sketch

<!-- ASCII DAG + one line of prose per edge: WHY it exists.
     Barriers must name what they join (ADR-027). -->

## §4 Degradation plan

<!-- "if something slips, drop X first" -->

## §5 Risk register

<!-- app-shape: >=5 risks, likelihood x impact x mitigation -->

## §6 Verify plan

<!-- Adversary seats, Judge seats, providers named (ADR-028) -->

## §7 Chip seats

<!-- human-attended lanes, if any -->
