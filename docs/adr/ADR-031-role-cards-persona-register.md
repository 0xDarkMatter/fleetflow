---
status: accepted
date: 2026-08-20
supersedes: []
superseded-by: []
touches:
  - "assets/roles/"
  - "scripts/ff-plan.sh"
  - "assets/packet.tmpl.md"
---

# ADR-031: Behavioural Role Cards In A Trade-Guild Persona Register

## Decision (one sentence)

Lane behaviour contracts live as twelve versioned role cards at
`assets/roles/<persona>.role.md` — Architect, Oracle, Scout, Surveyor,
Scholar, Builder, Inspector, Adversary, Judge, Critic, Composer, Warden —
named as one-word trade-guild personas (Forma's register, with Inspector and
Warden adopting Forma's meanings verbatim), each carrying mandate, stance
rules, capability bounds, default FINAL REPLY shape, and anti-patterns;
packets declare `role:` in frontmatter, `ff-plan draft` prepends the card to
the packet body, and the lint enforces role ↔ class coherence.

## Context

fleetflow had role *vocabulary* (refuter, judge, orchestrator throughout
README/SKILL prose) but no role *definitions* — every run re-improvised the
Adversary's attack stance from memory, and the structural rules that make
the quality patterns work (default-refute on uncertainty, judges score
stated criteria only, finders dedup against *seen*) lived as folklore.
Axiom demonstrated the form (lane files: mandate, owns/never-touches, hard
rules); the native Workflow tool demonstrated the content split — persistent
contracts (agent-type definitions) versus ephemeral stances (prompt patterns
paired with structural rules). A role card merges the two, the same move the
wave-packet templates already made for post-build finders (those templates
are finder role cards that predate the naming and stay as-is).

Persona naming: a seat is named for what it *is*, not its stance adjective,
and where a meaning coincides with a Forma role the same word is used so
generator packets read natively in fleet plans. "Researcher" is deliberately
not a card: the native Research archetype decomposes it into Surveyor →
Scholar → Composer → Critic, and `ff-plan draft --shape research` expands it
as that pipeline.

## Alternatives considered

- **Keep stance prose in SKILL.md only.** Rejected: unversioned doctrine
  re-typed per run drifts per run; the wave templates already proved cards
  beat prose for finders.
- **Stance-adjective names (Refuter, Synthesizer, Skeptic).** Rejected after
  review: the guild register is more legible in lane tables and aligns the
  two ecosystems; Adversary and Composer were chosen over Skeptic and
  Synthesist specifically.
- **Native agent-type files (`.claude/agents/`) instead of cards.** Rejected:
  agent types bind to the Claude harness; half the fleet is Codex/Grok/Pi,
  and a card is harness-neutral text prepended to any packet.
- **A "Researcher" card.** Rejected: a pipeline wearing a name tag; one
  vague mandate would replace four sharp ones.

## Consequences

### Positive
- Stance doctrine ships versioned and testable; packets self-describe their
  seat; role ↔ class incoherence (an Adversary on a `mechanical` class, a
  down-routed Judge or Composer) is lint-visible.

### Negative
- Thirteen files to keep in step with SKILL.md's routing table (cards +
  packet template); card edits change packet bytes and therefore cache keys
  for re-drafted packets — accepted per ADR-026.

## See also

- [ADR-018](ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md) — wave-packet templates, the finder precedent
- [ADR-029](ADR-029-generator-backed-packets-registry-owns-expansions.md) — why Forma's register matters here
- [FFPLAN-2026-08](../plans/FFPLAN-2026-08.md) §5b
