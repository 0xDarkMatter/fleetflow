# Run plan: `runcard` — shared run-card renderer (ADR-019)

**Status:** active (2026-08-10) · Decisions live in
[ADR-019](../adr/ADR-019-one-run-card-renderer-two-embedded-copies.md); this doc
carries only the run's shared contracts. Cite, never restate. Every lane reads
ADR-019 first, then its packet, then the §§ named there. File ownership is
exclusive. FINAL REPLY ends with `TESTS:` / `FILES_CHANGED:` lines.

## §1 Module contract (`assets/ff-runcard.js`)

- Plain ES5-compatible script (no modules/imports — it is INLINED into a
  single-file page and a chat fragment). Defines exactly two globals:
  `ffRunCard(runDoc, opts)` → HTML string, and `FF_RUNCARD_CSS` → string of
  scoped CSS (all selectors under `.ffrc`, all colors via `--ffc-*` custom
  properties with fallbacks).
- Renders (top panel parity with the dashboard's runDetail header, in order):
  1. Title row: run name (mono) + state tag (running/stalled/failed/done) +
     wave badge when `runDoc.waves` non-empty + per-model brand chips.
  2. Orchestrator badge (unrecorded → dashed, never guessed — copy the
     existing orchBadge doctrine).
  3. Path line (folder icon + repo path).
  4. "lanes ran <model_id list>" line.
  5. Pip strip: one square per lane, state-colored, title=lane id.
  6. TOKENS PER LANE column chart (DOM divs, no canvas) + "peak <lane> · <n>"
     annotation + provider legend.
  7. Stat row: LANES / ELAPSED / TOKENS / OUTPUT / COST(≈ and * semantics
     preserved) / FAILED (FAILED cell red when >0).
- `opts.surface`: `"dashboard"` maps `--ffc-*` to the dashboard palette
  (exact current colors — extract, don't restyle); `"chat"` maps them to
  claude.ai vars (`var(--surface-1)`, `--text-*`, `--border`, `--radius`,
  `--font-mono`) so light/dark both work. Brand/provider colors stay literal.
  Chat surface: no font below 11px, weights 400/500 only, no gradients or
  shadows, sentence case.
- `runDoc` shape (wire format — document field-by-field AT the top of the
  module): `{run, repo, repo_label, orchestrator, summary:{state, counts{},
  lane_count, elapsed_s, tokens_total, tokens_out, models[], model_ids[]},
  lanes:[{id, model, model_id, state, tokens_total}], waves?:[], cost:{usd,
  partial, estimated}}` — exactly what the dashboard already derives from
  ff-status; the widget feeds the same shape from ff-status directly.
- NO event handlers, NO fetch, NO localStorage, NO Date.now in render output
  (age strings are passed IN via runDoc, precomputed) — the module renders
  state, never behaviour (ADR-019).

## §2 Embedding + parity gate

- Both hosts embed VERBATIM copies delimited by markers:
  `/* ff-runcard:begin */` … `/* ff-runcard:end */` — dashboard inside its
  single `<script>`, widget inside the `<script>` block ff-widget.sh emits.
- Test (tests lane): extract marker-delimited regions from
  `assets/ff-dashboard.html` and from `bash scripts/ff-widget.sh` output on a
  fixture, byte-compare each against `assets/ff-runcard.js` body. Any
  difference = FAIL.

## §3 Lane table (run `runcard`)

| id | model | owns (exclusive) | builds |
|---|---|---|---|
| module | sonnet | `assets/ff-runcard.js`, `assets/ff-dashboard.html` | extract the header cluster (runDetail head, columnChart, brandLegend, brandMark/modelOf visuals, stateTag, stat chips) into the module per §1; rewire the dashboard to call `ffRunCard(…,{surface:"dashboard"})` for the run-detail header; dashboard behaviour (click/drill/export/sort) stays outside the module and byte-visual output stays equivalent (screenshot-diff by eye is fine, structure must match); keep ADR-003 (zero external refs) and every existing dashboard test green |
| widget | sonnet | `scripts/ff-widget.sh` | rewire per ADR-019: emit `<div class="ffrc-host">` + inline `<style>` from `FF_RUNCARD_CSS` + marker-delimited module copy + `ffRunCard(DATA,{surface:"chat"})` call, DATA built from ff-status/manifest as §1 runDoc; BENEATH the card keep the chat-only controls: ADR-018 wave bar, findings strip, refresh/triage/gate sendPrompt buttons, fleetflow.lab anchor (still the sole external ref); keep exit codes, CRLF discipline (jqr), all current widget tests green except those your packet lists as superseded |
| tests | codex | `tests/` | §2 parity gate; update widget assertions that the new structure invalidates (wave-bar segments now beneath card; sendPrompt/no-dialog/sole-https/no-raw-hex all still enforced); dashboard zero-external-ref test still green; DO NOT COMMIT (ADR-006) |

Verify: one cross-provider refuter on the integrated tree (parity, ADR-003,
regression of dashboard behaviour), then land.
