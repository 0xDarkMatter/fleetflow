---
status: accepted
date: 2026-07-06
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-spawn.sh"
  - "scripts/ff-run.sh"
---

# ADR-012: Packet Cache Keys Are Content-Pure; Packets Live at `packets/<id>.task.md`

## Decision (one sentence)

Each spawn is keyed by `sha256(model + prompt + opts)` — so packets carry no
timestamps or randomness, `opts` (including `--effort`) is part of the key —
and packets are authored at `.fleetflow/<run>/packets/<id>.task.md`, never at
`.fleetflow/<run>/<id>.prompt.txt`, which ff-spawn owns and refuses as input
(exit 2).

## Context

Resume is fleetflow's port of the native Workflow tool's journal mechanism: a
re-run of `ff-spawn` with an unchanged packet returns the cached result
instantly (exit 3 + path); change the prompt and only that lane re-runs. That
only works if the key is a pure function of the work. Two corollaries follow:

- **No timestamps or random values in packet prompts** — the same reason the
  native tool bans `Date.now()`/`Math.random()` in workflow scripts: any
  volatile content changes the key on every authoring pass and the cache
  never hits, silently converting "resume" into "re-run everything".
- **`opts` is in the hash, including `--effort`** — changing only the effort
  lever is a *different run* (a cache miss), by design: an answer produced at
  low effort is not the cached equivalent of the same prompt at high effort.

The packet-path rule closes a data-loss trap: `ff-spawn` writes its own
*effective* prompt (guard preamble + your packet) to
`.fleetflow/<run>/<id>.prompt.txt`. Pointing `--prompt-file` at that same path
used to destroy the packet — ff-spawn truncated the file it was about to read
— and then launched a task-less worker that still passed every gate (a worker
with only the guard preamble happily reports success). ff-spawn now refuses
that path with exit 2, but the convention (`packets/<id>.task.md`, or any path
outside the run dir) is what keeps authors clear of it in the first place.

## Alternatives considered

- **Key by run/lane id instead of content.** Rejected: ids don't change when
  the work changes, so an edited packet would wrongly cache-hit — the
  inverse failure of the volatile-content problem.
- **Exclude `opts` from the key.** Rejected: effort/turn/schema options change
  what the worker produces; treating them as cache-equivalent serves wrong
  results.
- **Detect-and-warn on self-referential `--prompt-file` instead of refusing.**
  Rejected: the failure it prevents (a destroyed packet plus a
  gate-passing empty worker) is silent and expensive; a hard exit 2 is the
  correct severity.

## Consequences

### Positive
- `ff-run resume` replays a whole manifest with unchanged packets cache-hitting
  and only edited lanes running live; `trace_id` (first 8 hex of the key) gives
  free work-identity correlation.
- The destroy-your-own-packet foot-gun is mechanically closed.

### Negative
- Authors must keep volatile content out of prompts by discipline — the key
  cannot distinguish a meaningful edit from an accidental timestamp.
- Any change to guard-preamble injection or opts serialisation invalidates
  existing caches (accepted: correctness over cache longevity).

### Non-goals
- Does not apply to imported native-Workflow runs — their `v2:` keys are
  terminal facts, not replayable (see SKILL.md, ff-import caveat).

## See also

- SKILL.md — "Resume" and step 3 of "The run lifecycle" (the packet-path
  convention)
- `scripts/ff-spawn.sh` — key computation and the exit-2 refusal;
  `scripts/ff-run.sh` — manifest replay
- `references/native-workflow-insights.md` — the native mechanism this ports
