---
name: fleetflow
description: "Heterogeneous cross-provider fleet - GLM (z.ai), Codex (OpenAI), Grok (xAI), Anthropic Sonnet/Opus/Haiku - from one session, porting the native Workflow tool's patterns (adversarial verify, judge panels, journal resume) to OS-process workers. Triggers: fleetflow, heterogeneous/mixed-model fleet, codex worker, grok worker, cross-provider fan-out, cross-model verify."
when_to_use: "Use when a fan-out wants DIFFERENT models per work class - e.g. 'fan this backlog out to GLM and Codex workers', 'mixed fleet with cross-model adversarial verify', 'Codex second opinion on each lane'."
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep Task"
metadata:
  author: claude-mods
  depends-on: "fleet-worker, fleet-ops"
  related-skills: "loop-ops, iterate, claude-code-ops"
---

# fleetflow

> Facts verified as of 2026-08-14 (Claude Code Workflow tool, codex-cli 0.144, fleet-worker GLM-5.3/z.ai).

## On invocation — open the dashboard

**When this skill is invoked, put the live dashboard on screen first, before
anything else.** Two steps, both cheap:

1. Confirm the service answers:
   `curl -s --max-time 5 http://127.0.0.1:8161/api/health`
   Use the **loopback** address here, not the `.lab` URL: `curl` has no reason to
   trust the local proxy's CA and fails with exit 7 / status 000 against HTTPS,
   which reads exactly like a dead service and is not one.
2. If it answers, open it in the Browser pane (`preview_start`) at
   **`https://fleetflow.lab/?repo=<git toplevel of cwd>`**. The pane wants the
   **`.lab` URL**, not loopback — browsers do trust the CA, and it is the address
   the user knows.

   The `?repo=` deep-link is what makes this useful rather than decorative: a
   bare URL opens the machine-wide overview, so you would land on 50-odd runs
   across 22 repos and have to go find the one you are working in. With it the
   page selects that repo's most relevant run — **in-flight first, then newest**.
   Slash direction and case do not matter (`git rev-parse` says
   `X:/Forma/forma/slack`, the aggregator says `X:\Forma\forma\slack`; both
   match). Add `&run=<name>` to pin a specific run.

   The pane is narrow (~400-500px), and the page handles that: below 900px the
   repo tree becomes a drawer behind the "runs" button in the top bar, closed by
   default, so the lane grid is what you actually see. Do not fight it with a
   wider layout.

3. In chat-capable sessions (not headless runs), emit the inline snapshot card at
   phase boundaries (spawn, phase change, all-done) via `bash scripts/ff-widget.sh
   --run <name> [--repo P]` piped into the chat widget surface. It is a moment-
   in-time render by design (chat sandbox cannot poll), re-emitted rather than
   self-updating. Sand-box isolation rationale: [ADR-003](docs/adr/ADR-003-dashboard-zero-external-references.md) / [ADR-004](docs/adr/ADR-004-live-probes-click-gated-never-timed.md).

Skip dashboard and widget silently when there is no Browser pane (headless `claude -p`,
CI, a non-desktop host) — the skill's value does not depend on it. Do not narrate
the steps; just have the dashboard there and the card in chat when available.

If the health check fails, say so and offer the one-liner rather than opening a
pane onto nothing:

```powershell
& "X:\00_Orchestration\compose-portless\bin\process-compose.exe" process start fleetflow
```

Claude Code's native **Workflow tool** is a superb orchestration harness with one
structural limit: every agent it spawns runs **in-process**, so they all share one
provider (`ANTHROPIC_BASE_URL` is process-global — only the model *alias slot*
varies per agent). fleetflow ports the Workflow tool's patterns to **OS-process
workers**, where each worker gets its own env block — and therefore its own model:

| Worker model | Process | Harness |
|---|---|---|
| **GLM-5.3 / GLM-4.5-Air** | `claude -p` → z.ai endpoint | Claude Code tools, cheap model (via `fleet-worker`) |
| **Codex** (GPT-class) | `codex exec` | OpenAI's own agent harness — a genuinely different toolchain *and* model |
| **Grok** (xAI grok-4.5) | `grok -p` | xAI's own agentic CLI — a different provider, model, *and* toolchain (like Codex); `GROK_DEPLOYMENT_KEY` auth |
| **Pi** (wildcard: gemini/deepseek/zai/groq/…) | `pi -p` | earendil-works Pi — one harness fronting 15+ providers; `FLEETFLOW_PI_PROVIDER`/`_MODEL` pick the model, provider API-key env auth ([contract §4](references/worker-contracts.md)) |
| **Sonnet / Haiku** | `claude -p --model sonnet\|haiku` | Claude Code tools, host auth |
| **Opus** | `claude -p --model opus` | reserve for verify/judge lanes |

The **orchestrator is this session** — run it on **Fable if the account has it,
Opus otherwise** (`ff-doctor --live` probes and reports which). Judgment stays in
the orchestrator; the scripts own the deterministic mechanics (spawn, journal,
gate). That split *is* the Workflow tool's design, relocated: its JS script is
deterministic control flow around model judgment — here the orchestrator session
plays the script's role and the journal keeps it resumable.

## Decision gate — is fleetflow the right tool?

| Situation | Use |
|---|---|
| Fan-out where all agents can share the session's provider | **native Workflow tool** (cheaper, integrated progress UI, schema-forced outputs) |
| One-off cheap delegation, single worker | **fleet-worker** directly |
| Worker models should differ by work class, or you want cross-provider dissent in verification | **fleetflow** |
| Landing the resulting branches | **fleet-ops** (always) |

Rule of thumb from fleet-worker's locus rule, extended: shell out to process
workers only for a **large, independent, file-mutating, cost-dominant** fan-out
you can gate before landing — *or* when the point is **model diversity** (a
Codex refuter catches what three same-model skeptics miss).

## Model routing (work class × model)

Extends [fleet-worker's routing convention](https://github.com/0xDarkMatter/claude-mods/blob/main/skills/fleet-worker/references/model-routing.md)
with the Codex/Grok columns and the orchestrator rule:

| Work class | Model | Why |
|---|---|---|
| **mechanical** (batch edits, verifier clones, backfills) | GLM-5.3, Haiku | proven cheap; gate catches misses |
| **scout** (survey, inventory, locate) | Sonnet, GLM-5.3 | breadth over depth |
| **build** (scoped features, refactors) | Sonnet, GLM-5.3, Codex, Grok | Codex/Grok = independent harnesses; GLM-5.3 = open-weights coding SOTA at commodity rates; good second implementations for judge panels |
| **verify / judge** | Opus + one cross-provider dissenter (Codex, Grok, GLM, or Pi) | *never under-power a judge*; diversity beats redundancy |
| **wildcard** (build or verify on a provider none of the fixed models cover) | Pi (`FLEETFLOW_PI_PROVIDER=gemini\|deepseek\|…`) | one integration, 15+ providers; builds as readily as it refutes; no sandbox and no turn cap — worktree + stall detector are the bounds |
| **synthesize / land decisions** | orchestrator (Fable > Opus) | needs the conversation's context |

Two guardrails carried over verbatim from the native tool's doctrine: reach for
the **effort lever before the model lever**, and a cheap rubber-stamp verifier is
worse than none.

**The same routing applies INSIDE native Workflow scripts — and it defaults
wrong.** A 7-day session audit (2026-06-28..07-05) found 75% of 10.1M subagent
output tokens ran on Fable/Opus, including 729 StructuredOutput extract/verdict
calls, because `agent()` inherits the session model unless overridden and nobody
sets overrides. Doctrine: **the stage that decides stays premium (omit the
override — inherit); the stages that collect go cheap** —
`{ model: 'haiku', effort: 'low' }` for extraction/classification/log scans,
`{ model: 'sonnet' }` for finder/reviewer sweeps. When unsure, inherit: a wrong
cheap answer that survives verification costs more than it saves. Mechanism,
routing table, and before/after snippets:
[references/native-model-routing.md](references/native-model-routing.md).

## The run lifecycle

```
ff-plan (draft → lint → refute) → ff-doctor → ff-spawn (×N, background) → ff-collect (gate) → fleet-ops land → clean up
```

1. **Plan packets that are file-disjoint.** No two lanes may touch the same file
   — this is what makes landing conflict-free and is the #1 planning duty.
   Pipeline-by-default thinking applies: add a barrier (wait for all lanes)
   only when a later stage genuinely needs *all* prior results
   (dedup, early-exit, cross-lane comparison). See
   [references/native-workflow-insights.md](references/native-workflow-insights.md) §3.
   The #2 planning duty is **decision-consistent packets** — see
   [The docs contract](#the-docs-contract--plans-cite-adrs-own-reference-states):
   in a repo with `docs/adr/`, check what governs the paths a packet touches
   *before* authoring it, and paste governing BLUFs into the packet.
2. **Plan the run:** `scripts/ff-plan.sh draft --run NAME --spec FILE`
   scaffolds the plan doc, one packet stub per lane, and the manifest —
   `ff-spawn` consumes packet entries rather than creating them
   ([ADR-026](docs/adr/ADR-026-ff-plan-authors-the-manifest-spawn-consumes-it.md)). Packets declare `role:` and draft
   prepends the persona card (Architect … Warden) carrying that lane's
   behaviour contract
   ([ADR-031](docs/adr/ADR-031-role-cards-persona-register.md)). `lint` is the
   gate before spawn — scope conflicts, dependency edges, ADR-BLUF presence,
   routing sanity — exit 10 on findings, every check reporting `armed` or
   `disarmed`, and it also runs as a section of `ff-doctor --offline`
   ([ADR-030](docs/adr/ADR-030-plan-lint-gates-the-spawn-and-reports-armed-status.md)). `refute` then spawns one
   cross-provider Adversary lane to attack the decomposition before any
   build lane spawns
   ([ADR-028](docs/adr/ADR-028-the-plan-is-refuted-before-the-fleet-spawns.md)); the decomposition itself stays
   pipeline-first — lanes flow to their own downstream, and a barrier is
   legal only when the plan names its join
   ([ADR-027](docs/adr/ADR-027-pipeline-first-decomposition-barriers-name-their-join.md)). Exit codes follow the sibling
   family: `0` ok, `2` usage, `3` missing, `10` findings.

   ```bash
   bash scripts/ff-plan.sh draft  --run demo --spec spec/demo.md
   bash scripts/ff-plan.sh lint   --run demo   # exit 10 = findings; fix before doctor
   bash scripts/ff-plan.sh refute --run demo   # cross-provider Adversary attacks the plan
   ```

   Planning checklist — what `draft` expects and `lint` enforces:

   - file-disjoint `owns:` — no two packets own the same path;
   - `depends_on:` are edges between packets, not wave numbers;
   - every barrier names its join (integrated-tree refute, cross-lane dedup, land);
   - governing ADR BLUFs pasted into each packet per `adr-touching`;
   - lint green before doctor — findings (exit 10) block the run.

3. **Preflight:** `scripts/ff-doctor.sh --live` — probes every provider (GLM
   endpoint, `codex login status`, Anthropic model availability incl. Fable) and
   reports the orchestrator tier. Don't spawn a fleet a doctor won't bless.
4. **Spawn:** `scripts/ff-spawn.sh --run <name> --id <id> --model <model>
   --prompt-file <f> --worktree` from the orchestrator's Bash tool with
   `run_in_background: true`, one call per lane. ff-spawn creates the worktree
   lane (`fleetflow/<run>/<id>` at `.fleetflow/<run>/wt-<id>`, repo top — never
   under `.claude/`), injects the guard preamble
   ([assets/guard-preamble.txt](assets/guard-preamble.txt)), journals a
   `started` record, runs the worker to completion, journals the `result`.
   **Author packets at `.fleetflow/<run>/packets/<id>.task.md`** (any path
   outside the run dir works too) — **never `.fleetflow/<run>/<id>.prompt.txt`**,
   which ff-spawn owns and refuses as input (exit 2): pointing `--prompt-file`
   there once destroyed the packet and launched a task-less worker that still
   passed every gate. See
   [docs/adr/ADR-012](docs/adr/ADR-012-packet-cache-key-purity.md).
5. **Collect + gate:** `scripts/ff-collect.sh --run <run> --id <id>` — flags,
   not positionals (a positional invocation is rejected with exit 2) — per-model success
   semantics (Claude JSON `is_error`; Codex exit + last-message), then the
   orchestrator reviews the three-dot diff (`git diff main...fleetflow/<run>/<id>`)
   and runs the lane's tests. **Always finish with
   `ff-collect.sh --check-main-clean`** — the escape guard (see Safety).
6. **Land** through fleet-ops (sequential, test-gated). Delete lanes and
   `.fleetflow/<run>/` after landing.

**A manually spawned chip is a lane too — open it before you click it.**
A chip can now start in its own fresh worktree (the click-time option that fixed
[claude-code#64605](https://github.com/anthropics/claude-code/issues/64605)), so
it need not dirty the primary checkout any more. But an isolated chip is still
*invisible*: its tree is `.claude/worktrees/<slug>`, which fleetflow deliberately
never manages, so the work stays outside status, cost roll-ups, teardown and the
sweep. Give it a fleetflow lane instead:

```bash
bash scripts/ff-chip.sh open --run <run> --id <id> --task "<the brief>"   # prints the seed prompt
# …paste that into spawn_task, let it work, then:
bash scripts/ff-chip.sh close --run <run> --id <id> --note "<one line>"
```

`open` builds the lane (worktree + branch + guard preamble), journals `started`,
and seeds `.ff-heartbeat` so the lane reads *running* rather than instantly
stalled; `close` records the **measured** outcome (commits, dirty, HEAD), never
a self-report. **Start the chip with its cwd set to that lane and without the
fresh-worktree option** — the lane already is the isolation, and because
`ff-status` resolves a transcript by encoding the session's cwd, a
double-isolated chip goes dark on the dashboard even though its work is fine. Between the two, the chip is a normal lane on every surface — and
because `ff-status`'s live introspection keys on the worktree path rather than
the model, it gets tokens, tools and stall detection for free. `chip` is not
spawnable (fleetflow cannot click a chip), so `ff-run resume` reports chip
packets as skipped. Rationale:
[ADR-021](docs/adr/ADR-021-chips-are-lanes-not-a-second-worker-class.md).

**Inter-worker communication is hub-and-spoke, by design.** Workers never talk
to each other — no shared memory, no message bus, no sideband files (lanes are
isolated worktrees). The only channel is the native tool's: a worker's FINAL
REPLY returns through `ff-collect` to the orchestrator, which embeds it in a
later packet (the `prevResult`-into-next-prompt handoff; see
[insights §3/§7](references/native-workflow-insights.md)). A judge packet is
just the collected builder outputs pasted in. If a stage needs *all* sibling
results, that is a barrier — collect everything first, then compose. (True
peer-to-peer between long-lived workers is out of scope; that's what a message
bus is for.) One sanctioned sideband exists — **opt-in raven-bus telemetry**
(`FLEETFLOW_BUS=1`): worker heartbeats onto `run/<run>/telemetry`, tailed with
`raven tail`. Telemetry is not peer coordination; workers gain no bus-READ
instructions, and the `.ff-heartbeat` file stays the canonical stall signal.
See [docs/adr/ADR-022](docs/adr/ADR-022-raven-bus-optin-telemetry.md).

The exception, opt-in per lane: **`ff-spawn --acp`** runs a *claude* lane
under the raven-bus ACP harness (`raven acp` driving zed's `claude-code-acp`),
making it **steerable mid-run** — it watches `run/<run>/lane/<id>` +
`run/<run>/control`, posts replies to `run/<run>/telemetry`, and its task
packet goes in as the harness's trusted boundary-0 prompt (bus messages stay
data-framed). An ACP lane is a persistent process: it ends by being reaped,
and its verdict is distilled from telemetry into the normal claude-style
envelope, so collect/status are unchanged. Permission mode defaults to
`acceptEdits` — edit tools auto-allowed, Bash gated by the allowlist
(`FLEETFLOW_PERMISSION_MODE` opts up/down); `--effort` is refused.
See [docs/adr/ADR-023](docs/adr/ADR-023-acp-lanes-packet-trusted-verdict-from-telemetry.md).

**Why not Claude Desktop's `ccd_session_mgmt` messaging here** (asked and settled
2026-08-03): it addresses Desktop sessions, and a fleetflow worker is an OS
process with no address in that system — hub-and-spoke is the only topology
this process model permits, and where cross-worker signalling IS wanted the
tool is a real CLI bus that works for any harness — in-run telemetry is now
raven-bus (ADR-022 supersedes ADR-005's pigeon pointer for this case); pigeon
remains the cross-project mailbox. Full settlement:
[docs/adr/ADR-005](docs/adr/ADR-005-hub-and-spoke-worker-topology.md). The
Desktop-only channel is documented in
[fleet-ops SKILL.md](https://github.com/0xDarkMatter/claude-mods/blob/main/skills/fleet-ops/SKILL.md),
which also owns the MAIN-coordinator role that fleetflow runs land through.

**Clean-room / benchmark runs get their own target repo.** Lanes are worktrees
*of some repo* — don't graft a build experiment onto an unrelated repo's object
store. Seed a standalone repo (e.g. under `X:\Benching`), and **vendor any
external spec INTO it** (`spec/…`) so packets reference it by *relative* path —
the guard preamble forbids workers building absolute paths, and Codex's
sandbox is confined to the lane, so out-of-repo specs are unreadable anyway.

**Resume.** The journal (`.fleetflow/<run>/journal.jsonl`) uses the native
tool's mechanism: each spawn is keyed by a content hash of
`(model, prompt, opts)` — and `opts` includes `--effort`, so changing only the
effort lever is a cache miss (a different run). Re-running `ff-spawn` with an
unchanged packet returns the cached result instantly (exit 3 + path); change
the prompt and only that lane re-runs. Keep timestamps and random values OUT
of packet prompts, or the key changes and the cache never hits. See
[docs/adr/ADR-012](docs/adr/ADR-012-packet-cache-key-purity.md).

**Manifest & resume.** Each spawn also upserts a packet into
`.fleetflow/<run>/manifest.json` (`{run, base, created_by, phases[], packets[]}`,
one entry per id — idempotent — carrying `{id, model, phase, prompt_file,
worktree, max_turns, effort, schema, key}`). It is the orchestrator-side plan,
distinct from the per-spawn journal: it records *what was intended* so a whole
run can be replayed. `ff-run.sh resume --run NAME` snapshots the manifest's
packets once, then replays each through `ff-spawn` in manifest order — unchanged
packets cache-hit (`"cached"`), changed or new ones run live; per-lane summary
to stderr, a JSON result list on stdout, exit 0 if all ok/cached, 10 if any
lane failed. `ff-run status --run NAME` is an alias for `ff-status`. Snapshots
matter: ff-spawn re-orders the live manifest on each upsert (remove-then-append),
so the replay reads from a frozen copy. When you're done,
`ff-clean.sh --run NAME [--force]` reclaims zero-commit lanes (worktree + branch
deleted), keeps committed ones, and removes the run's cache dirs.

**Cache & tmp redirect.** Workers' `UV_CACHE_DIR`, `TMPDIR`, `TMP`, and `TEMP`
are pointed at `${FLEETFLOW_CACHE_ROOT:-$HOME/.fleet-worker/cache}/<run>-<id>/`
(created before launch), so pytest/uv litter and codex's AppContainer-ACL'd
sandbox dirs land OUTSIDE the repo and lanes — never inside a worktree that
`git worktree remove` later needs to delete. Set `FLEETFLOW_CACHE_ROOT` once for
the whole run and pass the same value to `ff-clean` so it can find and remove
those dirs.

## The docs contract — plans cite, ADRs own, reference states

Fleetflow runs generate code *and documents* at fan-out speed, and the observed
failure mode (ga4-port, ATDW-MCP, settled 2026-08-07) is documentary drift: a
run's plan doc restates a decision that lives elsewhere — a spec, a landmine,
another repo's ADR — the restatement drifts, and the plan becomes the wrong
record. ATDW-MCP hand-rolled an entire supersession lifecycle inside one plan
doc (`D1-SYNC-EVALUATION.md`) and had to write *"the repo has no `docs/adr/`
convention"* into its own preamble. The contract below prevents both.

**The one-line rule: plans are mutable and cite; ADRs are append-only and own;
reference docs are living state. A plan edit may never be the only record of a
decision changing.** Separation is time-vs-state: an ADR records an *event*
("we chose X over Y, dated, here's why"); a reference doc records the *current
state* ("how it works now"); a plan records *intent for one run* and is
disposable. Facts belong in reference docs; only choices belong in ADRs.

Fleetflow eats its own cooking: this repo's standing decisions live in
[docs/adr/](docs/adr/) (backfilled 2026-08-07, lint-gated by `tests/run.sh`),
and the prose in this file cites them rather than owning the archaeology.

The doc kit a fleetflow-built repo carries (Diátaxis for the canonical side,
[adr-ops](https://github.com/0xDarkMatter/claude-mods/blob/main/skills/adr-ops/SKILL.md) for the decision side, arc42-shaped architecture
doc; ATDW-MCP's `00_INDEX.md` filing criterion is the reference implementation):

| Layer | Holds | Mutability |
|---|---|---|
| `AGENTS.md` + Landmines | entry doc; one-line warnings linking to ADRs | living, lean |
| `docs/reference/`, `api/` | specs of record, parity tables, measured facts | living — drift is a bug |
| `docs/ARCHITECTURE.md` | how the shipped system works | living |
| `docs/adr/` | decisions: BLUF, alternatives, consequences | append-only |
| `docs/plans/` | run plans, wave tables, handoffs — self-declared status | disposable |
| `docs/reports/` | measured outcomes, audits | point-in-time |

**Greenfield (clean-room runs):** seeding the target repo includes
`adr-init` and the kit skeleton above. The plan's load-bearing decisions land
as ADR-001..N *before* packets are authored; the plan cites them, never
restates. By wave 2, `adr-touching` works because wave 1 populated `touches:`.

**Brownfield:** before authoring packets, run adr-ops's `adr-touching.py`
against the paths each packet owns. Exit 10 → paste the governing ADR's BLUF
into the packet under a `CONSTRAINTS FROM STANDING DECISIONS` heading. Workers
cannot read what they are not given — non-Claude lanes have no ambient
knowledge of the target repo's decision log, and a Codex sandbox may not reach
`docs/adr/` unless the packet points at it.

**Mid-run replanning stays fast.** Resequencing waves, reassigning lanes,
checking off work, deferring scope — all free, no ceremony: none of it is ADR
material (reversible without re-litigating a trade-off). The discipline bites
only when a plan edit *contradicts a cited decision* — and that is the drift
being caught, not bureaucracy. Then either supersede first
(`adr-new --supersedes ADR-OLD --apply-supersede`, minutes, done while waves
run) or don't make the edit. Design claims resting on unmeasured evidence stay
in the plan as labelled hypotheses — they become ADRs only after a spike
confirms them (`status: proposed` if a direction must be recorded early).

**Land time — docs are a wave class, not exhaust.** Every run that changes
behaviour ships doc lanes in the same run: reference-doc updates for what the
build waves changed (cheap models; a GLM lane wrote ga4-port's PARITY.md), and
new future-constraining choices made mid-run land as `proposed` ADRs in the
target repo — never as plan prose only. The verify wave gets **doc-parity
refuters**: a cross-provider lane reads a canonical doc and the implementation
and is prompted to *refute the doc*; every falsifiable claim is a finding.
Prefer **derived docs** over authored prose wherever possible (coverage
inventories, capability tables, exit-code maps — the ga4 `capabilities()`
pattern that turns drift into a build failure); refuters police what can't be
derived. At closeout, a decision doc whose conclusions were acted on
*graduates*: current-state content moves to `docs/reference/`, the choice
record stays behind (ATDW's `mirror-query-spec.md` path).

**Sprawl guard.** ADRs record *architecturally significant* decisions —
expensive to reverse, cross-cutting: boundaries, invariants, wire formats,
storage shapes, always/never rules. Module-level choices are guard comments;
test-enforced invariants are landmines. A large project produces dozens of
ADRs, not hundreds — most verdicts are facts (→ reference) or evidence (→ the
evaluation doc, kept byte-intact; the ADR is a short card that *cites* it).
Never convert a rich evaluation doc into ADRs — extract each constraining
verdict into a short ADR that points back at the doc's section.

## Patterns ported from the native Workflow tool

Full extraction with evidence in
[references/native-workflow-insights.md](references/native-workflow-insights.md).
The ones to actually use:

- **Adversarial verify:** for each finding/lane output, spawn 2–3 refuters
  prompted to *refute*, majority kills. Make one refuter a different provider.
- **Judge panel:** N independent build attempts (e.g. Sonnet vs Codex), judged
  by Opus lanes, synthesize from the winner.
- **Loop-until-dry:** for unknown-size discovery, keep spawning finder lanes
  until 2 consecutive rounds add nothing new. Dedup against everything *seen*,
  not everything *confirmed*.
- **Completeness critic:** one final lane asking "what's missing?" — its answer
  is the next round's packet list.
- **No silent caps:** if you bound coverage (top-N, sampling), say so in the
  run summary. Silent truncation reads as "covered everything".
- **Workers return data, not prose:** every packet ends with "FINAL REPLY:
  <exact shape>". For machine-parseable results use `--schema` (Codex
  `--output-schema` is native; Claude workers get the schema embedded in the
  prompt and validated at collect time).
- **Verdict metadata in the FINAL REPLY (rookery's structured-verdict rule):**
  packets whose lanes run tests or mutate files include `TESTS: <passed>/<failed>`
  and `FILES_CHANGED: <n>` lines in the reply shape (any subset; omit what the
  lane cannot know). Tokens and cost are measured by ff-status - never
  self-reported - but test results and file counts exist only inside the lane,
  and a gate that can read "TESTS: 12/0" catches a green-sounding failure the
  prose would hide.

## Default posture: verify by default, scale to the ask

The native tool's fan-outs look "automatic" because its doctrine makes them the
default the script-author follows, not an option — and real runs routinely hit
30–50 agents on large tasks. fleetflow adopts the same posture:

- **Every run gets a verify phase unless you state why not.** Minimum: one
  refuter per build lane (cross-provider) + a judge for anything with more
  than one candidate. A run that skips verification is the exception and says
  so in its summary.
- **Scale the fan-out to the ask, not to caution.** Mechanical batch → one
  lane per file-disjoint packet, however many that is. Discovery/audit →
  loop-until-dry rounds, not a fixed small N. Verification typically adds
  0.5–1.5× the build-lane count on top. 20–50 lanes on a big task is the
  pattern working, not a smell — the native tool budgets 1000 agent calls per
  run for exactly this reason.
- **Throttle in waves, don't shrink the plan.** The native engine queues past
  `min(16, cores−2)` concurrent; fleetflow's orchestrator does the same
  manually — spawn in waves of ≤4–6 per provider (endpoint quota binds first),
  collect as lanes finish, keep the total plan intact. **Codex on Windows is
  the exception: ≤2–3 concurrent.** Its binding constraint isn't endpoint quota
  but the machine-global sandbox-provisioning helper — lanes provisioning at
  once race each other into the elevation trap (see Safety). Bound each lane
  (`--max-turns`), never the ambition.
- **No silent caps** (native rule, verbatim): if you sample, top-N, or skip,
  say so in the run summary.

## Post-build waves

Post-build work (QA, security, a11y, supply-chain, perf, docs, polish) runs as a
fixed pipeline — `build → verify → finders → triage → fix → re-verify → docs-sync
→ land` — sequenced by `ff-run wave` rather than by the orchestrator, where
`--posture` selects *which finder waves run* and an orthogonal attendance policy
selects *who is watching*. Every finder emits **findings as ledger records**
(`.fleetflow/<run>/findings.jsonl`, one JSON record per finding) that triage, fix,
re-verify, gates, and dashboards all consume — remediation is structural to the
pipeline, not a property of the deepest tier ([ADR-018](docs/adr/ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md)).

| Posture | Finder waves |
|---|---|
| `baseline` | docs-parity |
| `tested` | +qa, visual-qa, regression |
| `hardened` | +security, supply-chain, a11y |
| `complete` | +polish |

`perf` joins any posture as an opt-in (`--wave +perf`) — never by default; it
shares the browser harness with qa so its marginal cost is low, but it is
rarely the binding concern on a freshly built feature (ADR-018).

**Attendance is a macro; gates are the single source of truth** ([ADR-018](docs/adr/ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md)):
`--attend none|land|each` only *sets the default* gate on each wave; an explicit
`--gate <wave>=<policy>` overrides per-wave. The manifest's gates are the only record.

**Severity floor and always-escalate**
([ADR-018](docs/adr/ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md)):
findings at or below `--severity-floor S=medium` auto-fix; above the floor *or* touching
`auth`, `crypto`, `permissions`, `schema`, `deps`, `public-api`, or ADR-covered paths
escalate to a human gate. **Anti-oscillation:** a finding refuted twice by re-verify
escalates, never retried ([ADR-018](docs/adr/ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md)).

```
ff-run.sh wave --run NAME --posture baseline|tested|hardened|complete \
               [--attend none|land|each] [--gate WAVE=auto|review|stop]... \
               [--fix-rounds N=2] [--severity-floor S=medium] [--repo PATH] \
               [--dry-run|--continue]
```

Run names are `[a-z0-9-]+` — no dots (`v0.2` is rejected; `v0-2` is fine).

**Example 1** — tested posture, fully attended:
```bash
ff-run.sh wave --run v0-2 --posture tested --attend each
```

**Example 2** — hardened, gated only at landing (preview the plan first):
```bash
ff-run.sh wave --run v0-2 --posture hardened --attend land --dry-run
```

Per-wave cost roll-ups aggregate from `ff-status`, visible in the run summary
(`--dry-run` previews the plan only — no lanes have run, so it has no costs). **No posture deploys:** the pipeline terminates at land; deploying remains maintainer-gated from an interactive session ([ADR-018](docs/adr/ADR-018-post-build-waves-posture-selects-depth-gate-selects-attendance.md)).

## Safety — the cage, not the model

- **Isolation:** every mutating worker gets its own worktree lane *and* (GLM)
  its own `CLAUDE_CONFIG_DIR`. Codex workers run `--full-auto` (sandboxed,
  workspace-write) confined to their lane via `-C`. Grok workers run
  `--always-approve` (autonomous tools), confined by the lane worktree — no
  config-dir isolation needed (no Claude OAuth to collide with; auth is the
  `GROK_DEPLOYMENT_KEY` env var, read from env, never written to disk).
- **Codex lanes cannot `git commit` (learned 2026-07-08):** a worktree's git
  metadata lives outside the lane the sandbox confines Codex to. Convention:
  Codex packets say "DO NOT COMMIT — leave changes in the working tree", the
  worker reports `FILES_CHANGED`, and the **orchestrator reviews the diff and
  commits** (GLM/Anthropic workers are unaffected and may self-commit). See
  [docs/adr/ADR-006](docs/adr/ADR-006-codex-lanes-never-self-commit.md).
- **Codex on Windows must never depend on an elevation prompt (learned
  2026-07-27):** the `elevated` sandbox mode raises a UAC dialog nobody can
  approve headless, and the lane **hangs instead of failing fast**. `ff-spawn`
  pins `-c windows.sandbox="unelevated"` **per invocation** on Windows hosts
  (`FLEETFLOW_CODEX_WINDOWS_SANDBOX` overrides; empty defers to global config)
  — deliberately never an edit to the user's `~/.codex/config.toml`. And
  **`ff-doctor --live` guards the guard**: codex accepts unknown `-c` keys
  silently, so the doctor feeds `windows.sandbox` a deliberately invalid value
  and requires rejection, proving the key is still live. Full incident and
  rationale: [docs/adr/ADR-007](docs/adr/ADR-007-codex-windows-sandbox-unelevated-pin.md).
- **A stalled lane is indistinguishable from a working one — trust
  `last_activity_s`, not `state: running`** (through the whole 2.7h hang both
  lanes read `running` with `elapsed_s` climbing normally). `ff-status`
  measures live-stream silence per lane and flips it to `state: "stalled"`
  past `FLEETFLOW_STALL_SECONDS` (default 600); the monitor draws those lanes
  as a *frozen* amber pip captioned with the silence. Before assuming a long
  wave is progressing:
  `ff-status.sh --run <name> | jq '.lanes[]|select(.stalled)|{id,last_activity_s}'`.
- **Know what the stall detector covers — `live_signal` tells you.** A stall
  is provable only where the model writes *while it works*: codex's/pi's
  `--json` event stream, a claude/glm session transcript, or the worker
  heartbeat (`./.ff-heartbeat`, appended by worktree lanes per the guard
  preamble — grok worktree lanes' only live signal, since grok's
  `--output-format json` buffers to exit). Lanes spawned without `--worktree`
  report `live_signal: false`, and their `stalled: false` means *cannot
  tell*, never *healthy* — one more reason to spawn mutating workers with
  `--worktree`. Boundaries, false-positive history, and the grok deferral:
  [docs/adr/ADR-008](docs/adr/ADR-008-stall-detection-trusts-activity-not-state.md).
- **Silence for hours is a verdict of its own — `abandoned`.** A `running` or
  `stalled` lane whose `last_activity_s` passes `FLEETFLOW_ABANDON_SECONDS`
  (default 21600 = 6h) demotes to the FINAL state `abandoned` — even where
  `live_signal` is false, because at that horizon total filesystem silence
  plus no result envelope is decisive without a stream. Abandoned lanes are
  not in flight: the dashboard stops animating them, `live_runs` stops
  counting them, and the aggregator stops re-polling them. Rationale and the
  STATE_RANK slot:
  [docs/adr/ADR-025](docs/adr/ADR-025-abandonment-demotes-silent-inflight-lanes.md).
- **Killing a lane leaves orphans — reap them.** `TaskStop` (or killing the
  background Bash task) kills the *wrapper*, not the worker's children; the
  2026-07-27 cleanup left five live `codex.exe` / `codex-code-mode-host.exe`
  processes. `ff-spawn` now journals a `proc` reap anchor (its own PID **and**
  WINPID) per lane, so `ff-clean` can find that subtree afterwards — report
  first, kill second:

  ```bash
  bash scripts/ff-clean.sh --run <name> --reap
  ```

  Add `--force` to terminate. It matches by **ancestry** (walking up to a
  journalled anchor), never by image name, so a Codex *you* started is never
  collateral. The blunt fallback, if the run predates the anchors:

  ```powershell
  Get-Process codex,codex-code-mode-host -ErrorAction SilentlyContinue | Stop-Process -Force
  ```

  — but that kills every Codex on the box. Either way, `taskkill /PID` on the
  PIDs `ps -W` prints does **not** work: those are Cygwin PIDs, and Windows
  needs the WINPID from the same table's fourth column.
- **Escape guard (learned 2026-07-05):** a worker CAN escape its worktree by
  writing absolute paths. Two mechanical defenses, both defaults: the guard
  preamble's *relative-paths-only* clause, and `ff-collect.sh
  --check-main-clean` after every run (exit 12 = escape detected; stop,
  `git stash push -u` to salvage, investigate).
- **Baseline-before-closeout (learned 2026-07-08):** orchestrator self-edits
  to `main` look identical to an escaped worker's writes, so snapshot a
  clean-`main` baseline (`git status --short` / a commit sha) **before** any
  orchestrator-authored closeout edit — the check must compare against the
  pre-spawn state, not a target the orchestrator just moved. Both incidents:
  [docs/adr/ADR-009](docs/adr/ADR-009-escape-guard-and-baseline.md).
- **Permission posture:** workers run non-interactive
  (`bypassPermissions` default; `FLEETFLOW_PERMISSION_MODE=dontAsk` + allowlist
  when the orchestrator session is in auto mode — a `bypassPermissions` child
  is hard-denied there as *Create Unsafe Agents*). Same doctrine as
  fleet-worker; see its Permission posture section.
- **Bounds:** `--max-turns` per worker (default 100), concurrency ≤ 4–6 per
  provider (endpoint quota is the binding constraint) but ≤ 2–3 for Codex on
  Windows (the sandbox helper is machine-global, not per-lane), wall-clock
  patience via the orchestrator's background-task notifications — never
  poll-sleep. Patience is not indefinite: a wave that has been quiet gets a
  stall check, not more waiting.
- **Terms:** a subscription-authed orchestrator must stay interactive;
  API-key-authed sessions may be automated. Codex usage bills to the ChatGPT
  plan. Verify your own plans' terms (fleet-worker "Know your terms" applies).

## Scripts

| Script | Purpose |
|---|---|
| [scripts/ff-plan.sh](scripts/ff-plan.sh) | `draft --run NAME --spec FILE [--shape SHAPE]` scaffolds the plan doc + packet stubs + the manifest `ff-spawn` consumes; `expand --generator NAME --vars FILE` stamps generator-backed packets; `lint --run NAME [--json]` gates the spawn — scope-conflict matrix, dependency/DAG checks, ADR-BLUF presence, routing — exit 10 on findings, each check reporting `armed`/`disarmed`, also a section of `ff-doctor --offline`; `refute --run NAME [--model M]` spawns one cross-provider Adversary against the decomposition; `estimate --run NAME` prices lanes and wall-clock ([ADR-026](docs/adr/ADR-026-ff-plan-authors-the-manifest-spawn-consumes-it.md), [ADR-027](docs/adr/ADR-027-pipeline-first-decomposition-barriers-name-their-join.md), [ADR-028](docs/adr/ADR-028-the-plan-is-refuted-before-the-fleet-spawns.md), [ADR-030](docs/adr/ADR-030-plan-lint-gates-the-spawn-and-reports-armed-status.md)) |
| [scripts/ff-doctor.sh](scripts/ff-doctor.sh) | `--offline` structural preflight (+ which `windows.sandbox` mode codex lanes will get); `--live` probes GLM endpoint, Codex auth, Grok key, Anthropic models, the `windows.sandbox` key tripwire, and reports orchestrator tier (fable/opus) |
| [scripts/ff-spawn.sh](scripts/ff-spawn.sh) | uniform spawner: worktree lane + guard preamble (+ heartbeat clause for worktree lanes) + journal + per-model launch (GLM via fleet-worker, Codex via `codex exec`, Grok via `grok -p`, Pi via `pi -p` stdin + event-stream distillation, Anthropic via `claude -p`); pins `windows.sandbox=unelevated` for Codex on Windows |
| [scripts/ff-collect.sh](scripts/ff-collect.sh) | per-model result gate; strips ```json fences before `--schema` validation; `--repair` respawns a `<id>-repair` lane on validation failure; `--auto-commit` commits a dirty lane tree after a PASS so landing has a HEAD (opt-in, never changes the verdict); `--check-main-clean` escape guard |
| [scripts/ff-status.sh](scripts/ff-status.sh) | run status as JSON (lane state `running`/`stalled`/`abandoned`/`done`/`failed`, elapsed, `last_activity_s` + `stalled` + `live_signal` stall detector, hours-scale abandonment demotion, commits, tools, tokens, activity, manifest summary); `--watch N --out status.json` feeds the live monitor; `--exit-stalled` exits 14 so a watchdog can branch without parsing |
| [scripts/ff-run.sh](scripts/ff-run.sh) | `wave --run NAME --posture P [--attend none\|land\|each] [--gate WAVE=POLICY]... [--fix-rounds N] [--severity-floor S]` sequences post-build waves (QA, security, a11y, supply-chain, perf, docs, polish) — findings ledger, triage, fix-loop, re-verify, docs-sync. `resume --run NAME` replays every manifest packet through ff-spawn in order (unchanged = cached, changed/new = live); `status --run NAME` aliases ff-status |
| [scripts/ff-findings.sh](scripts/ff-findings.sh) | findings ledger CLI: `append [--json '...']` dedupes by fingerprint, `list`/`count [--status S] [--severity S] [--min-severity S] [--wave W]`, `set-status --fp F --status S`, `waive --fp F --reason R [--expires DATE]`, `apply-waivers` (marks open findings whose fp appears in `docs/waivers.json` as waived); append accepts `--round`/`--lane` metadata; all take `--run NAME [--repo P]` |
| [scripts/ff-widget.sh](scripts/ff-widget.sh) | HTML fragment for chat sandbox: wave bar, metric cells (lanes/tokens/cost/findings/elapsed), lane grid (capped at `--max-lanes N=10`), findings strip (severity chips when >0), buttons (refresh, triage failed, review gate when gated); stateless, CSS variables only, sole external reference is the fleetflow.lab anchor |
| [scripts/ff-clean.sh](scripts/ff-clean.sh) | `--run NAME [--force]` reclaims zero-commit lanes (worktree remove + branch -D), keeps lanes with unmerged commits, removes the run's cache dirs; reports locked ACL-litter dirs. Note a **landed** lane already counts as zero-commit (`rev-list BASE..HEAD` is 0 once merged), so landing then cleaning reclaims it with no extra flag ([ADR-020](docs/adr/ADR-020-sweep-reclaims-only-archived-and-landed.md)). **Archives the run to history first** (`--no-archive` opts out). `--reap [--force]` finds worker processes the wrapper left alive, matched by ancestry to the run's journalled anchors |
| [scripts/ff-archive.sh](scripts/ff-archive.sh) | `--run NAME` appends a compact run summary to `~/.fleetflow/history.jsonl` so the run outlives its own directory; `--dry-run` prints without appending |
| [scripts/ff-chip.sh](scripts/ff-chip.sh) | adopts a manually spawned `spawn_task` chip as an ordinary lane: `open --run NAME --id ID --task "…"` creates the worktree lane, journals `started`, and prints the seed prompt to paste into the chip; `close --run NAME --id ID [--rc N] [--note …]` records the measured outcome (commits, dirt, HEAD) so collect/status/clean/archive/sweep treat it like any lane; `list --run NAME`. `chip` is not spawnable — `ff-run resume` skips it. See [ADR-021](docs/adr/ADR-021-chips-are-lanes-not-a-second-worker-class.md) |
| [scripts/ff-sweep.sh](scripts/ff-sweep.sh) | machine-wide housekeeping: `--list` (default) reports every run dir still on disk across the configured roots with a verdict (`reclaimable` / `landed-untracked` / `holds-work` / `active`), lane landed-counts, and bytes; `--no-size` skips `du` (prints `-`, omits the on-disk roll-up), `--rediscover` / `--discover-ttl N` govern reuse of the dashboard's discovery cache; `--reclaim` removes only the provably safe ones (archiving first if needed), `--include-untracked` extends that to runs pinned open by untracked leftovers after listing their paths. Verdicts are computed live from git on every invocation and are never cached. Never touches `.claude/worktrees/`. See [ADR-020](docs/adr/ADR-020-sweep-reclaims-only-archived-and-landed.md), [ADR-024](docs/adr/ADR-024-sweep-caches-bytes-never-verdicts.md) |
| [scripts/ff-aggregate.py](scripts/ff-aggregate.py) | discovers every run under the configured roots and emits ONE aggregate JSON (all repos, all runs, roll-ups, history); `--init-roots PATH...` writes the roots file |
| [scripts/ff-serve.py](scripts/ff-serve.py) | serves the machine-wide dashboard + builds its aggregate on request; the process behind `https://fleetflow.lab` |
| [scripts/ff-import.sh](scripts/ff-import.sh) | `--wf DIR --run NAME` imports a native Claude Code Workflow run dir (`wf_*/`) — completed agents become lanes (prompt + result envelope + journal + manifest), started-only agents are flagged incomplete; native keys are terminal, not replayable |
| [scripts/ff-serve.py](scripts/ff-serve.py) | machine-wide dashboard server: discovers every fleetflow run (live + historical, across repos) by scanning the roots in `~/.fleetflow/roots.txt` for `.fleetflow/<run>/journal.jsonl`, serves [assets/ff-dashboard.html](assets/ff-dashboard.html) at `/` plus `/api/aggregate.json` / `/api/refresh` / `/api/doctor.json` / `/api/health`; per-run state comes from `ff-status.sh` and capacity from `ff-doctor.sh` (neither reimplemented). `/api/doctor.json` is `--offline` by default and runs inline; `?live=1` probes every provider in a background thread (minutes, and it spends real model calls). One process by design — request-driven, non-blocking rebuilds, no detachable watcher to die silently. Run it as a supervised service (e.g. Process Compose + a probe on `/api/health`) |

**Live monitor** ([assets/ff-monitor.html](assets/ff-monitor.html)): a
zero-dependency page reproducing the native /workflows progress surface — run
header with square per-lane pips, a mono/technical agent grid, elapsed/tools/
commits/tokens, and expandable per-agent detail (activity, last commit, error
tail, artifact). The run header is **tethered** (sticky) so the summary stays
in view while the agent grid scrolls beneath it, and it carries two segmented
controls (persisted in localStorage): **sort** — `active` (default: running,
then stalled, then failed, then done, so in-flight lanes float to the top),
`name`, `tokens` — applied within each phase group while the header pip strip
keeps arrival order; and **card size** — `S` (dense grid, stat columns hidden),
`M` (default), `L` (one full-width card per row). Wire-up: copy it into the run dir as `index.html`, run
`ff-status --watch 3 --out <rundir>/status.json`, serve the run dir with any
static server, open in a browser/preview panel. It polls `status.json` every
2.5s. Live claude-model lanes are introspected via their session transcript (GLM:
the isolated config dir; Anthropic models: `~/.claude/projects/<encoded-workdir>/`,
worktree lanes only); codex lanes via their `--json` event stream. **Grok lanes
have no live stream**: `ff-spawn` launches grok with `--output-format json`, which
buffers the whole turn and writes once at exit, so a grok lane shows no tools and
no activity until it finishes. Grok *does* offer `--output-format streaming-json`
(NDJSON `thought`/`text`/`end`), but it is one flag — adopting it for live
progress means reconstructing the buffered envelope `ff-collect` gates on, from an
event shape this repo has not re-verified. Until that is done and verified, grok
is deliberately outside live introspection and stall coverage. Those streams
double as the stall signal: a lane
whose stream has been silent past the threshold renders as a **frozen amber pip**
captioned with the silence (`2h39m silent`) instead of a pulsing blue one, and
never counts toward a phase's finished fraction. Lanes with no live stream
(`live_signal: false`) keep rendering as running — the monitor cannot show a
verdict the data doesn't support.

**Machine-wide dashboard** ([scripts/ff-serve.py](scripts/ff-serve.py) +
[assets/ff-dashboard.html](assets/ff-dashboard.html)): where the live monitor
watches ONE run dir, the dashboard aggregates EVERY run on the machine —
live and archived, across repos — behind a single always-on service. Same
layout doctrine as the monitor: pinned summary, cards beneath.

**Two surfaces, like the native tool.** The served monitor is the *live*
grid (the Background-tasks panel analogue). In-chat, the orchestrator emits a
compact *snapshot* card at phase boundaries (spawn, phase change, all-done) —
chat-widget sandboxes cannot poll localhost, so the inline card is a
moment-in-time render by design, re-emitted rather than self-updating.

## The machine-wide dashboard

`ff-monitor.html` shows **one run in one repo** and needs a watcher and a static
server wired up per run. That is the right tool while you are driving a single
fleet, and it is unchanged. But it cannot answer "what is running on this box",
and a run vanished entirely once `ff-clean` deleted its directory.

**[https://fleetflow.lab](https://fleetflow.lab)** ([ff-dashboard.html](assets/ff-dashboard.html),
served by [ff-serve.py](scripts/ff-serve.py)) is the permanent surface: every run
in every repo, grouped by repo, live section and history section, with token and
cost totals per run. It is registered with the Process Compose stack (port 8161,
`shared/services/fleetflow.md`) and needs no per-run setup at all.

- **Discovery is configurable, never hardcoded.** Roots resolve from `--root` →
  `$FLEETFLOW_ROOTS` → `~/.fleetflow/roots.txt` → the current git repo. Seed the
  file once with `ff-aggregate.py --init-roots <PATH>...`.
- **One implementation of lane state.** `ff-aggregate.py` shells out to
  `ff-status.sh` per run rather than reimplementing it — the stall detector's
  `live_signal:false` = *cannot tell* distinction is exactly the kind of subtlety
  a second copy would quietly lose.
- **History survives cleanup.** `ff-clean` calls `ff-archive` **before**
  removing anything, appending a compact record to `~/.fleetflow/history.jsonl`
  (outside every repo) — an index, not a backup; `--no-archive` opts out. See
  [docs/adr/ADR-011](docs/adr/ADR-011-archive-before-remove.md).
- **Rebuilds are request-driven and non-blocking.** No standing watcher process
  to die silently — the failure that made the predecessor dashboards
  untrustworthy. An unreachable server shows red with the snapshot's age; stale
  numbers are never rendered as live. See
  [docs/adr/ADR-002](docs/adr/ADR-002-ff-serve-is-one-process.md).
- **The Fleet view answers "what can this box run"** — pinned at the top of the
  sidebar, and the only view about capability rather than history. It holds
  three registers deliberately kept apart — **spec** (hand-maintained doctrine
  per model, changed in the same commit as a contract change), **observed**
  (measured across runs + archived history), and **capacity** (an `ff-doctor`
  probe, always shown with its age) — because merging registers with different
  truth values is how a dashboard starts lying
  ([docs/adr/ADR-014](docs/adr/ADR-014-fleet-view-three-registers.md)).
  `--offline` (binaries + `bash -n`) runs automatically when the view opens;
  **`--live` is click-gated and never on a timer** — it spends real model calls
  ([docs/adr/ADR-004](docs/adr/ADR-004-live-probes-click-gated-never-timed.md)).
  Live probes run in the server's background and the page polls until they
  settle.
- **ROOST accounts (conditional).** On machines with the `roost` CLI installed
  (claude-lb, the Claude Code OAuth profile health/load-balancer), the sidebar
  gains a "roost · accounts" entry. The pane embeds **roost's own `roost
  widget` fragment verbatim** — never re-design a surface roost already ships;
  a test enforces the pass-through — with a trimmed `roost status --json` as
  the fallback. The click-gated **refresh auth** button
  (`/api/roost/refresh`) mutates the token store, so it is never on a poll or
  timer. Absent binary → `{"available": false}` and the section never renders.
  See [docs/adr/ADR-016](docs/adr/ADR-016-roost-widget-pass-through.md).
- **Zero external dependencies, still.** No CDN, no webfont, no remote image, no
  build step — the page is one file that works offline, from `file://`, and in a
  preview pane with no network. A test asserts it (`dashboard: still zero
  external dependencies`); the only URL in the file is a provenance comment.
  See [docs/adr/ADR-003](docs/adr/ADR-003-dashboard-zero-external-references.md).
- **The pane is not repainted when nothing changed.** `paint()` compares the
  generated HTML against what is on screen and no-ops on a match, which is most
  ticks on a mostly-idle fleet. Before it, the 3s poll rebuilt the DOM
  unconditionally and took the page scroll offset and any keyboard focus with it
  — tabbing through the run list was impossible because focus died within three
  seconds. When it does paint, scroll and focus are restored.
- **Per-lane telemetry the single-run view never had:** `density` (20 buckets) +
  `density_basis`, `model` (the resolved id, e.g. `GLM-5.3`, not the `glm` alias),
  `worktree` / `branch`. **`density_basis` is load-bearing:** it is `"time"` for
  claude-family lanes, whose transcripts carry per-record ISO timestamps, and
  `"sequence"` for codex, whose `--json` stream carries **none** — those buckets
  are item ordinals, and the dashboard labels them "by step" rather than passing
  a sequence chart off as a timeline.
- **`worktree_state` is tri-state, and the middle value matters most:** `present`
  (lane still on disk), `reclaimed` (it HAD one; ff-clean removed it after landing
  — the normal end of a healthy lane), `none` (spawned without `--worktree`, so the
  stall detector cannot attribute a transcript and reports "cannot tell"). Reading
  a reclaimed lane as `none` inverts the diagnosis.
- **`trace_id`** is the first 8 hex of the journal's existing
  `sha256(model+prompt+opts)` cache key — free correlation for metrics and traces.
  It answers *"was this the same work?"*, not *"which lane"*; artifact filenames
  stay `<id>.<ext>` deliberately (see `references/`-adjacent note in ff-status).
- **`orchestrator`** — which model drove the fleet. **Nothing in a Claude Code
  session's environment exposes its own model** (children get `CLAUDE_EFFORT` and a
  session id, not the model), so it must be supplied:
  `ff-spawn --orchestrator M` > `$FLEETFLOW_ORCHESTRATOR` > whatever
  `ff-doctor --live` last probed (it persists to `~/.fleetflow/orchestrator`).
  Set `FLEETFLOW_ORCHESTRATOR` once per session. Runs predating this read
  `unrecorded` — deliberately not backfilled with a guess.
- **Exact model ids.** Claude-family workers self-report theirs in
  `result.json`'s `modelUsage`. Codex and grok report none anywhere, so
  `ff-spawn` now journals the launch model — for those models that record is the
  *only* one that will ever exist, and runs predating it show the model alias.
- **Cold build is minutes, steady state is milliseconds.** The run cache
  (`~/.fleetflow/cache/`) survives restarts; an unchanged finished run is never
  re-read, and abandoned `stalled` runs are re-read on a graduated interval
  instead of every tick. Measured on 53 runs: **15 ms** when nothing changed,
  ~4 s when one live run needed re-reading, **29 s** for a cold scan of every run
  (was ~6 min before ff-status's per-lane passes were collapsed). The cache key
  includes ff-status's own mtime, so editing the reader invalidates exactly the
  entries it affects instead of serving the old shape forever.
- **Three drill levels, all hash-addressable.** The default view is **FLEET**
  (everything on the machine, live + archived, with lanes/token-breakdown/cost/
  failure-rate/runtime roll-ups); clicking a repo name in the sidebar drills to
  **PROJECT** (`#repo:<label>` — that repo's on-disk runs plus archived history,
  same stat row); a run card or row drills to **WAVE** (the lane grid).
  Breadcrumbs walk back up; the wordmark is home. The sidebar is accordion
  strata — pinned capability rows (fleet, roost when installed), *live now*,
  *projects*, *history* — sharing one collapse-persistence contract. Small
  comforts: the tab title carries `(N▶ M⚠)` so a background tab still alerts on
  stalls, `/` focuses the filter, Esc closes the costs modal, and every run
  detail has an "export json" button (client-side blob, nothing leaves the box).
- **A time-window lens scopes every view.** The top-bar window select (This/Last
  week · month · quarter, custom range, All time — weeks start Monday, quarters
  calendar) filters which runs and history records feed *every* view and
  roll-up: nav, charts, token/cost totals, failure rates, the fleet view's
  observed stats. A record is in the window when its activity interval overlaps
  it, so live runs always show in any "this …" window. Persisted under
  `ffd.window` (ADR-013); plan-blend pools deliberately stay window-independent
  so a month's blended costs still sum to the fee.
- **Card language is shared with the [summon](https://github.com/0xDarkMatter/claude-mods/tree/main/skills/summon) session picker** — same
  header, title/summary, bar strip, chip row, path footer. Change one, change both.
  The right pane leads with a **column chart** (tokens per lane, or per run on the
  overview), which is what makes the cross-model cost story visible at a glance.

**Compare runs with `tokens_total`, not `tokens`.** The legacy `tokens` field
is model-INCONSISTENT (codex reports a grand total, claude models output only)
and is frozen because `ff-monitor.html` renders it; `ff-status` also emits
`tokens_in` / `tokens_cached` / `tokens_out` / `tokens_total`, which mean the
same thing for every model, plus `cost_usd` where the worker prices its own
turn. **Cost is partial by construction** — codex/grok report none, GLM's
figure is a wrong-rate estimate — so the dashboard carries its own
hand-maintained `PRICING` registry (rates verified against published pricing,
date stamped in the file) and a per-model **pricing basis** picked in the ⚙
costs modal: `api` (token counts × published rates), `plan` (subscription
tier shown as a **blended** monthly-fee share — sums to exactly the fee,
never a flat $0), or `report` (trust the CLI's figure). Every figure says
what it is: plain `$x` is self-reported, `≈$x` contains estimates, `*` means
uncosted lanes remain, and nothing is ever presented as an invoice. The basis
persists under `ffd.pricing`; archived lanes without an input/cache split
fall back to reported-or-nothing. Full rationale:
[docs/adr/ADR-010](docs/adr/ADR-010-tokens-frozen-tokens-total-comparable.md)
and [docs/adr/ADR-015](docs/adr/ADR-015-pricing-basis-and-blended-plans.md). A
snapshot card follows the monitor's layout doctrine: the run summary (name,
totals, per-lane strip) sits in a header pinned via `position: sticky` at the
card's top, with agent/lane cards listed vertically beneath it ordered
active-first — so when the card is tall enough to scroll in a side panel, the
summary never scrolls out of view.

**Naming (renamed from `brain`, 2026-08-05):** the spawnable alias is the
**model** (`--model glm|codex|grok|pi|sonnet|opus|haiku|fable`; wire fields
`model` in journal/manifest/status lanes, `models` in roll-ups and archives)
and the exact resolved id is **`model_id`** (e.g. `GLM-5.3`). In a legacy
record `brain` must win the alias fallback (`.brain // .model` on journals,
`.model // .brain` on manifests/archives); `--brain` survives as a deprecated
flag alias, and tests pin both directions. See
[docs/adr/ADR-017](docs/adr/ADR-017-model-rename-alias-fallback-order.md).

All follow the Skill Resource Protocol: stdout is data, chatter on stderr,
semantic exit codes (`0` ok, `2` usage, `3` cached/missing, `7` unreachable,
`10` worker failed, `12` escape detected, `14` lane stalled), `--help` with
EXAMPLES.

## Importing a native Workflow run

`ff-import --wf <wf_*/> --run <name>` reads a native Claude Code Workflow run
directory — its `journal.jsonl` (`started`/`result` records with `v2:` hash
keys and `agentId`) plus per-agent `agent-<id>.jsonl` transcripts — and lands
each completed agent as a fleetflow lane: the agent's first user-role message
(string content or content-array-with-text-blocks, both handled) becomes
`<id>.prompt.txt`, its native `result` object becomes `<id>.result.json`
(`{is_error:false, result:<native-result>|tojson}`), and a `native`-model
packet is appended to the manifest (`imported_from: <DIR>`) for provenance.
Agents with a `started` but no `result` get a prompt file only and are
reported `incomplete` on stdout's TSV — respawn candidates.

**Caveat — imported results are terminal facts, not a replayable cache.** The
native `v2:` keys are content hashes of the *native* `(prompt, opts)` call, not
fleetflow's `sha256(model+prompt+opts)`, and `native` is not a spawnable model
— so `ff-run resume` **skips** native packets rather than replaying them (it
reports each `imported` and exits 0). The native script's control flow
(pipeline/barrier/loop) is not recovered either. To continue from an imported
result, spawn a fresh lane with a real model and paste the imported result into
its packet (the hub-and-spoke handoff). Use import for salvage, provenance, and
visual continuity in the monitor — not to resume native work in place.

## References

- [references/native-workflow-insights.md](references/native-workflow-insights.md)
  — the extraction: journal format on disk, resume semantics, control-flow
  doctrine, quality patterns, caps and budget spine, with evidence.
- [references/worker-contracts.md](references/worker-contracts.md) — per-model
  launch/collect/auth contracts (GLM env knobs, full `codex exec` flag map, the
  Grok `grok -p` headless/schema/auth contract, Anthropic alias notes) and the
  Fable/Opus orchestrator probe.
- [references/native-model-routing.md](references/native-model-routing.md) —
  per-stage `opts.model`/`opts.effort` routing for native Workflow scripts: the
  cost evidence, the collect-cheap/decide-premium table, caveats (aliases, fork
  inheritance, effort = reasoning depth).

## See Also

- [fleet-worker](https://github.com/0xDarkMatter/claude-mods/tree/main/skills/fleet-worker) — the single-worker spawn layer fleetflow builds on (GLM auth isolation, model routing, terms).
- [fleet-ops](https://github.com/0xDarkMatter/claude-mods/tree/main/skills/fleet-ops) — the landing layer; every fleetflow run ends there.
- [loop-ops](https://github.com/0xDarkMatter/claude-mods/tree/main/skills/loop-ops) — schedule a recurring fleetflow run as an L1/L2 loop.
- [adr-ops](https://github.com/0xDarkMatter/claude-mods/tree/main/skills/adr-ops) — the decision layer of the docs contract: `adr-init` at
  greenfield seeding, `adr-touching` before packet authoring, `adr-new
  --supersedes` for mid-run reversals, `adr-lint` in the target repo's gate.
