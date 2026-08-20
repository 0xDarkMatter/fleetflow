<!-- assets/packet.tmpl.md - the frozen v1 packet template. `ff-plan draft`
     stamps one packet per lane-table row (substituting the {{BRACES}}
     placeholders and prepending the role card at the marker below); the
     tests lane checks frontmatter grammar and section parity. Spec:
     docs/plans/FFPLAN-2026-08.md sections 5 and 5b; ADR-026, ADR-031.

     Frontmatter grammar - a restricted YAML subset, documented here at
     the construction site (ff-plan lint accepts nothing else):

       key: value      flat scalar (bare string, number, null, or [])
       key:            flat list - one "  - item" line per value beneath

     Nothing may nest: no key or map under a value, no list under a list
     item, no anchors, no block scalars, no flow collections beyond the
     empty-list []. Quote any string containing ": " (see final_reply).

     Purity (ADR-026 on ADR-012): the spawn cache key hashes the packet
     WHOLE FILE, frontmatter included - so no timestamps, no randomness,
     no volatile content anywhere in a packet. One accidental date and
     resume silently becomes re-run. -->
---
id: {{ID}}                    # matches the packet filename stem
role: {{ROLE}}                # Architect|Oracle|Scout|Surveyor|Scholar|Builder|Inspector|Adversary|Judge|Critic|Composer|Warden (ADR-031)
class: {{CLASS}}              # mechanical|scout|build|verify|judge|generator|interactive
model: {{MODEL}}              # spawn alias; judge seats omit to inherit, never pin down
locus: process                # process|in-proc (fleet-worker locus rule)
owns: []                      # exclusive write; overlap with another packet's owns/modifies = finding
modifies: []                  # shared edit; overlap = finding (weaker severity)
reads: []                     # informational
registries: []                # shared registries touched (pyproject, tests/run.sh, pricing tables) - single writer enforced
depends_on: []                # packet ids; edges, not waves
generator: null               # e.g. forma - marks a generator-stamped packet
gate: auto                    # auto|review|stop (ADR-018 vocabulary)
final_reply:                  # declared shape, validated at collect
  - "TESTS: <passed>/<failed>"
  - "FILES_CHANGED: <n>"
---

<!-- role card prepended here by ff-plan draft -->

## Context

<!-- good entry: what this packet builds and why, in a few lines a cold worker can act on; nothing said outside this file is assumed -->

## Scope (exclusive)

<!-- good entry: every path this packet may write, repo-relative, each with a one-line justification; a path not listed is not touchable -->

## Read first (in order)

<!-- good entry: an ordered list of files with line ranges - governing ADRs, the plan doc sections named by number, prior packets' outputs -->

## Constraints from standing decisions

<!-- good entry: the Decision (BLUF) sentence of every governing ADR pasted verbatim; a governing ADR absent here is a lint finding -->

## Contracts (frozen, verbatim)

<!-- good entry: the frozen contract text copied byte-identical from the plan doc's numbered contracts, led by the section number it cites -->

## Steps

<!-- good entry: imperative and numbered, one verifiable action per step; machine-attended serial steps marked interactive -->

## Tests

<!-- good entry: the tee'd command and its exit-code capture; hermetic; a file-mutating packet with no test command is a lint finding -->

## Done criteria

<!-- good entry: checkable states, not activities; the last is the FINAL REPLY in the declared final_reply shape -->

## If you get stuck

<!-- good entry: report BLOCKER with evidence and stop - no scope improvisation, no silent waiting; the orchestrator re-plans, the packet never does -->
