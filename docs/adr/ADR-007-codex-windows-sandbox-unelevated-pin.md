---
status: accepted
date: 2026-07-27
supersedes: []
superseded-by: []
touches:
  - "scripts/ff-spawn.sh"
  - "scripts/ff-doctor.sh"
---

# ADR-007: Codex on Windows Pins `windows.sandbox=unelevated` Per Invocation, With a Doctor Tripwire

## Decision (one sentence)

On Windows hosts `ff-spawn` passes `-c windows.sandbox="unelevated"` on every
Codex invocation (never by editing the user's `~/.codex/config.toml`), and
`ff-doctor --live` verifies the key is still honoured by feeding codex a
deliberately *invalid* value and requiring rejection.

## Context

Learned 2026-07-27 (codex-cli 0.144.1, run `bkv2p2`): codex-cli's `elevated`
Windows sandbox mode provisions its AppContainer through a setup helper
launched with `ShellExecuteExW` — a UAC dialog. Headless, nobody can approve
it, so Windows cancels the launch (error `1223` = `ERROR_CANCELLED`, surfaced
as `orchestrator_helper_launch_canceled`) and the lane **hangs instead of
failing fast** — two lanes burned 2.7 hours. The failure is intermittent by
construction: provisioning caches under `~/.codex/.sandbox*`, so ten lanes can
succeed and the eleventh wedges when the cache invalidates or two lanes
provision at once (which is also why Codex-on-Windows concurrency is capped at
2–3: the helper is machine-global, and simultaneous provisioning races lanes
into the elevation trap).

Two design points follow. **Per-invocation, not global:** the pin is a `-c`
flag on each spawn so interactive Codex keeps whatever sandbox mode the user
chose; fleetflow never edits user config. `FLEETFLOW_CODEX_WINDOWS_SANDBOX`
overrides it; empty passes nothing and defers to the global config.
**Guard the guard:** `codex -c` accepts unknown dotted keys *silently*, so if
codex ever renames or drops `windows.sandbox` the pin degrades to an inert
no-op and lanes hang again with no signal. The doctor therefore feeds the key
a deliberately invalid value and requires codex to reject it — rejection
proves the key is still live. The tripwire rides on `codex debug prompt-input`
(config load only, ~1.2 s, no network, no model call) rather than
`codex sandbox`, because sandbox provisioning is machine-global and is the
very thing being guarded against; a preflight must never trigger it.

## Alternatives considered

- **Edit `~/.codex/config.toml` to `unelevated` globally.** Rejected: mutates
  the user's interactive-Codex posture as a side effect of running a fleet.
- **Detect the hang and retry.** Rejected: the hang presents as a healthy
  `running` lane (see ADR-008); detection is after-the-fact and the retry
  re-enters the same trap.
- **Trust the pin without a tripwire.** Rejected: `-c`'s silent acceptance of
  unknown keys means a codex rename converts the fix into a no-op invisibly —
  the exact class of silent regression a preflight exists to catch.
- **Tripwire via `codex sandbox`.** Rejected: it provisions the machine-global
  sandbox, i.e. the preflight would itself risk triggering the elevation trap.

## Consequences

### Positive
- Headless Codex lanes on Windows cannot reach the UAC dialog; the 2.7 h
  hang class is closed while the key exists.
- The doctor turns "codex silently dropped our key" from an invisible
  regression into a failing preflight.

### Negative
- One more provider-version coupling: a codex rename of the key needs a
  matching fleetflow change (the tripwire makes this loud, not painless).
- Windows Codex concurrency stays capped at 2–3 lanes.

### Non-goals
- Does not decide non-Windows Codex sandbox posture (`--full-auto`,
  workspace-write — unchanged).
- Does not cover the commit restriction — that is ADR-006.

## See also

- SKILL.md § Safety — "Codex on Windows must never depend on an elevation prompt"
- `scripts/ff-spawn.sh` — the per-invocation pin
- `scripts/ff-doctor.sh` — the invalid-value tripwire
- ADR-008 — why the hang was invisible to status
