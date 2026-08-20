<!-- assets/plan.tmpl.md - the frozen v1 run-plan template. `ff-plan draft`
     scaffolds docs/plans/<RUN>.md from this file by substituting the
     {{BRACES}} placeholders; the tests lane checks template parity (section
     set, lane-table columns, machine header). Spec:
     docs/plans/FFPLAN-2026-08.md section 7; ADR-026, ADR-027, ADR-028. -->

# Run plan: `{{RUN}}` - {{TITLE}}

**Status:** draft ({{DATE}}) - **Disposable**: decisions live in the cited
ADRs; this doc carries only the run's shared contracts and lane table.
Cite, never restate. Every lane reads its packet first, then only the
numbered sections named there. File ownership is exclusive. FINAL REPLY
follows each packet's declared `final_reply` shape.

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

## 1. Shared contracts

<!-- good entry: frozen interface text (wire shapes, CLI contracts, schemas) that two or more packets bind to; packets cite the section number, never retype it -->

## 2. Lane table

<!-- good entry: one row per packet; id = packet filename stem and manifest id; owns = repo-relative globs disjoint from every other row; builds cites sections of this doc; gate = auto|review|stop (ADR-018) -->

| id | role | class | model | owns (exclusive) | builds | gate |
|---|---|---|---|---|---|---|

## 3. Dependency sketch

<!-- good entry: an ASCII DAG plus one prose line per edge saying why the edge exists; every barrier names what it joins (ADR-027) -->

## 4. Degradation plan

<!-- good entry: an ordered drop list - "if something slips, drop X first" - chosen before anything slips -->

## 5. Risk register

<!-- good entry: app-shape runs carry at least 5 risks (feature-shape: optional), one line each - likelihood x impact x mitigation -->

## 6. Verify plan

<!-- good entry: every Adversary and Judge seat named with its provider, never the builder's own; refuters attack the decomposition before spawn and the integrated tree after (ADR-028) -->

## 7. Chip seats

<!-- good entry: each human-attended lane and the decision it waits on; "none" is a valid entry; chips are steerable conveniences, never load-bearing -->
