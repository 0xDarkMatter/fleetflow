# Changelog

All notable changes to fleetflow are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow semver.
Decision rationale lives in [docs/adr/](docs/adr/) — entries here say WHAT
shipped, the ADRs own WHY.

## [Unreleased]

### Added
- `lane-capacity` in `ff-doctor --offline` (ADR-041): how many CONCURRENT
  lanes the machine's **commit** headroom supports right now —
  `floor((commit_free − FLEETFLOW_MEMORY_RESERVE_MB) /
  FLEETFLOW_LANE_MEMORY_MB)`, clamped to `[1, FLEETFLOW_MAX_CONCURRENT]`
  (defaults 16 GB, 1.5 GB, 16). Commit, not free RAM: this box wedged at
  0.2 GB commit free with 28 GB of RAM idle, and a RAM reading calls that
  healthy. One helper in `_env.sh` (`ff_commit_headroom` →
  `ff_lane_capacity`) covers Windows, Linux and macOS and exits 3 —
  "not applicable" — anywhere else. Advisory in every branch: it sizes the
  orchestrator's wave, it never gates a spawn. SKILL.md's fan-out doctrine
  gains memory as its third constraint beside cores and endpoint quota, and
  says to re-read between waves (process count drifted 614 → 792 over one
  build) and to check `host-watchers` in the same breath, since an unguarded
  dev server grows *with* lane count.
- A fast iteration lane for `tests/run.sh`, without a second gate. `bash
  tests/run.sh` with no flags is unchanged — same sections, same order, same
  assertions — and stays the only thing that lands. New: `--only <regex>`
  runs sections matching the regex plus everything they depend on, `--skip
  <regex>` runs the complement, `--quick` is a curated preset (131s and 249
  assertions against ~11min and 594), `--list` prints the section slugs and
  `--check-deps` verifies the dependency table. Every subset run tags its
  count `(quick lane - not a landing gate)`. Measured lanes on the author's
  box: dashboard 5s, waves 39s, ff-plan 51s, spawn+collect 71s, status 121s.
- Sections in `tests/run.sh` now carry a stable slug (`if __sec <slug>; then`)
  and a generated prerequisite map. Sections share fixtures built earlier in
  the file, so a subset is only sound if it also runs what built what it reads;
  `tests/section-deps.py` derives that map from the file (writes/reads of shell
  vars, functions and run dirs) and `--check` fails when the embedded copy is
  stale. Subset runs re-verify it first and refuse to run against a stale
  table, so a rotten map can never turn `--only` into a false green.
- `FLEETFLOW_TEST_TIMING=1` prints per-section wall time (ms) to stderr in any
  mode. Absolute times swing with machine load (two full runs the same
  afternoon: 452s and 658s), but the shape is stable — `sweep-perf` and
  `doctor-live-probe-scoping` are ~35% of the run on their own.
- `FLEETFLOW_LANES_ROOT` (ADR-040, opt-in): place lane worktrees **outside**
  the host repo at `<root>/<repo-slug>/<run>/wt-<id>`, where no dev server
  serving the repo can crawl them — the structural fix for ADR-038's 87.9 GB
  Vite incident. Run artifacts stay in `<repo>/.fleetflow/<run>/`. One
  creation resolver in `_env.sh` (`ff_lane_dir`, used by ff-spawn and
  ff-chip) replaces 27 hand-built paths across 10 scripts; the `started`
  journal record carries the lane's absolute path when a root is in use, and
  every reader (ff-status, ff-clean, ff-sweep, ff-collect, ff-chip close)
  resolves journal-first with the in-repo path as its only fallback — never
  from the environment, so a lane is never probed or reclaimed at a guessed
  location. ff-sweep/ff-clean's boundary widens by exactly the lane dirs a
  journal names (an unjournalled outside dir is never touched); emptied
  `<root>/<slug>/<run>` dirs are `rmdir`-pruned. Codex grants (ADR-034) and
  chip transcript attribution (ADR-021) are unchanged and tested against an
  outside lane. `ff-doctor --offline` gains a `lanes-root` row stating the
  mode. Unset, nothing changes: the suite pins in-repo `ff-status` output
  byte-identical with the variable unset vs set and the in-repo journal
  gaining no field.
- `FLEETFLOW_STATUS_WORKERS` (default `nproc`, capped at 8): the number of
  worker subshells `ff-status` reads lanes with; `1` is the serial path.
  Registered in `ff-doctor --env` and `docs/REFERENCE.md`.
- `tests/run.sh` pins a wall-clock budget on the 200-lane fixture
  (`FLEETFLOW_TEST_STATUS_BUDGET_S`, default 30), asserts lane order equals
  journal first-appearance order, and that a stalled lane still exits 14
  under `--exit-stalled` with more than one worker.
- `host-watchers` in `ff-doctor --offline` and `ff-plan lint` (ADR-038): lane
  worktrees live inside the host repo, so a registered dev server serving it
  crawls every lane — the `mapforge` Vite service reached 87.9 GB of private
  commit on 2026-09-10. One detector in `_env.sh` (`ff_host_watchers`) reads
  the Process Compose services file (`FLEETFLOW_HOST_SERVICES`), finds
  watcher-shaped services whose `working_dir` is the repo, and reports whether
  the watcher config ignores `.fleetflow`. Advisory / warn only; the fix is
  one line in the host repo (`server.watch.ignored: ['**/.fleetflow/**']`).
  Without a services file both read "not applicable". Landmine added to
  AGENTS.md and SKILL.md.
- Fleet-wide rules are carried in the guard preamble (ADR-037). `claude -p`
  lanes inherit `~/.claude/rules/*.md` implicitly; codex/grok/pi lanes see
  only the packet, the preamble and the repo `AGENTS.md` — on godaddy-build
  the commenting doctrine reached GLM lanes (14–16% comment density) and not
  Codex lanes (1–3%) on identical packets. Each rule in
  `FLEETFLOW_FLEET_RULES` (default `agentic-quality`) needs a
  `[fleet-rule: NAME]` block in `assets/guard-preamble.txt`; `ff-doctor
  --offline` gains `fleet-rules` (fail when a declared rule has no block) and
  `rule-inheritance` (the asymmetry, stated); `ff-plan lint` gains a
  `fleet-rules` check that warns when the target repo's `AGENTS.md` carries
  neither the doctrine nor a pointer to it; the Adversary role card gains a
  shape lens with the same thresholds as the GoDaddy comment gate.
- Lane cards report OUTCOME, not only effort. `ff-status` lifts the
  builder-role final-reply contract into the lane record — `verdict`
  (`STATUS:`), `tests`, `files_changed`, `deferred` — from `<id>.last.txt`
  (codex) or `result.json` `.result` (claude-family, bold-markdown accepted),
  inside the jq passes it already runs; plus `stop_reason` and
  `permission_denials` from the envelope. The dashboard draws them as chips
  (`✓ 77/0 tests`, `15 files`, `cut off`, `N denied`; a reviewer's `n/a (…)`
  answer draws a muted chip and `a/a` is read as passed/total), shows the worker's own
  verdict as a tag beside the state (22 of godaddy-build's 123 "done" lanes
  were `partial`, hidden in truncated prose), puts DEFERRED in its tooltip,
  and prints the cache share on the token chip (median lane: 97% cache reads).
- `landed` / `commits_authored` on the status feed. `commits` now counts
  UNMERGED work against the integration ref exactly as ff-clean resolves it
  (ADR-035) instead of a hardcoded `main..HEAD`; `landed` is its zero case made
  explicit; `commits_authored` counts a lane's own commits against a frozen-sha
  base and is null for a branch base. The card says `⎇ landed` where it used to
  say `0 commits` on 122 of 123 lanes.
- `tests/run.sh`: a 200-lane resource-budget fixture (the pre-fix ff-status
  emits 0 bytes on it), contract-parse fixtures for both reply shapes, and a
  landedness fixture with a merged lane, an unmerged lane, and a branch base.
- Model-routing docs name the verified wildcard routes and the seat each one
  earns by RATE rather than novelty: `gemini-3.8-flash` ($0.75/$3.75) as a
  build lane, `meta/muse-spark-1.3` ($1.25/$4.25) for build or dissent. All
  were reached with no code change (pi accepts ids newer than its catalogue).
- GPT-6 Astra IS served to a ChatGPT-plan codex seat as `gpt-6-astra`
  (`FLEETFLOW_CODEX_MODEL=gpt-6-astra`); the pi/openrouter route at $10/$50 is
  a quota fallback, not the primary. The contract records the probe trap that
  made this look unavailable: codex answers an unrecognised name with
  `not supported when using Codex with a ChatGPT account`, so that message
  separates neither gated from nonexistent NOR either from a WRONG ID. Only a
  different error proves acceptance - `gpt-6-astra` reaches the usage-limit
  check where `astra`/`gpt-6`/`-pro`/`-max` do not. Probe the canonical id
  from the provider listing before concluding anything.
- `ff-spawn --config-dir DIR`: run a claude-family lane against another
  `CLAUDE_CONFIG_DIR` instead of the host's. Anthropic lanes inherit the host
  store by design, which makes one expired host token fatal to every
  claude-family lane in a fan-out simultaneously, mid-run (observed 2026-09-04,
  a 33-lane run). The flag takes ANY directory - a roost profile under
  `~/.claude-profiles/<name>` or any other store - and is refused for
  non-claude models, a missing dir, and the host config itself. Not part of the
  cache key: the same packet on the same model is the same work whichever
  account paid. Transcript archiving follows the redirect.
- `ff-doctor` emits a `claude-auth-fallback` advisory when a claude probe fails
  and `roost` is installed, naming healthy profiles least-used first plus the
  exact `--config-dir` to pass. It NAMES, never selects - auto-switching the
  account a fan-out bills to is the surprise ADR-004/ADR-016 click-gate
  elsewhere - and is silent when roost is absent (ADR-036).
- ADR-036: a lane's claude auth is a config dir fleetflow points at; choosing
  the profile is never fleetflow's job. Rejects both a roost dependency and a
  reimplementation of profile health inside fleetflow (the restatement-drift
  failure ADR-016 named for UI, relocated into code).

### Changed
- `ff-status` reads lanes in parallel (ADR-039). The per-lane loop body is
  now `lane_record`, run inside worker subshells over round-robin chunks of
  the journal rows; each lane writes its own record file and stall marker,
  and `emit` reduces the markers and concatenates the records by journal
  index. Same JSON, same order, same exit codes. Measured 2026-09-10: the
  200-lane fixture 69s -> 11.8s, the 140-lane godaddy-build 56s -> 12.8s.
- A run's `elapsed_s` is its wall-clock span (first lane start → most recent
  activity), no longer `max(lane elapsed)`. The two coincide only for a single
  simultaneous wave; godaddy-build ran 123 lanes in waves across a night and
  the card paired a 17h52m-old `started` with a 1h53m elapsed. Measured
  against run-directory mtime spans: godaddy 18h16m on disk → 18h18m,
  newbook-v1 34h06m → 32h55m (the old value was 121h34m — a lane that died
  without a result envelope accrues elapsed forever, which is also why the
  span is NOT floored at max-lane). The dashboard's time-window filter ends a
  run at `started + elapsed_s`, so long runs stop falling out of "last N hours"
  while still live.
- Lane cards: `done` is a solid green tag (running stays pale green); the
  artifact basename line is gone (it was `<lane id>.<ext>` on 122/122 lanes —
  one bit, twenty-two characters); `agent_message: STATUS: x SUMMARY:` is
  stripped from the activity line (~40 of ~85 visible characters); the red
  stderr line is now an amber `recovered` / red `error` chip drawn only when it
  changes the verdict, with the tail in its tooltip — it had been red on 68 of
  117 done lanes, and only 10 of 73 tails were error-shaped (one was a line of
  TypeScript). The card face shows the reply's full `SUMMARY:` block (clamped to
  two lines) rather than the activity tail cut at 70 characters, with the whole
  summary and DEFERRED in its tooltip; the elapsed chip's tooltip carries the
  lane's absolute start → end. Review lanes (`verify` phase) no longer wear the
  amber "no worktree lane" warning — they are spawned without a worktree by
  design, and 24 of godaddy-build's 30 no-worktree lanes were reviewers.
- `ff-plan lint`'s `adr-constraints` check now calls adr-ops's
  `adr-touching.py` ONCE per packet, passing every owned path, and reads the
  per-path verdict from the tool's new `queries[]` envelope (adr-ops batched
  positionals on 2026-09-05). Measured on the live `tess-v1` plan (41 packets,
  33 carrying `owns:`, 251 owned paths): 251 Python spawns collapse to 33, and
  the ADR phase drops 42.0s -> 6.4s with identical verdicts (73 governed).
  That phase was NOT the lint's bottleneck - the O(n^2) scope matrix was, and
  the lint then died assembling its final envelope (`jq --argjson` on a large
  findings list -> E2BIG, rc 126). Both are fixed by the re-engineering
  entry below, landed the same day. Findings still name only the governed paths. If the installed
  adr-touching predates batching (exits 2 on a second positional) the packet
  falls back to one call per path and the check reason says so, so a stale
  skill install can never disarm the gate again (ADR-030). `tests/run.sh` C3b
  stubs the batched contract and C3c pins the spawn count for both paths:
  2 batched, 4 via the legacy fallback.

### Fixed
- Dashboard roll-ups counted a run that is archived AND still on disk twice
  (lanes, tokens, runtime, cost, and a duplicate bar in the project token
  chart): the fleetflow project card read 44 lanes for 36 real ones. The
  on-disk record wins; the history row is its index. The header's `archived`
  count (`totals.history_runs`) applies the same rule on the aggregator side.
- A failed claude-family lane with an empty `.err` now says why: `err_tail`
  falls back to the envelope (`error_max_turns after 121 turn(s) - stop_reason
  tool_use`, `api_error_status`, the result text). `claude -p` reports failures
  there, not on stderr — 27 of this box's 68 failed lanes had no reason on the
  card.
- `ff-status` silently dropped a running lane's journalled `model_id` (and
  would have dropped the new proc pid): its per-lane journal rows were
  tab-separated, tab is IFS whitespace, and `read` collapses a run of tabs —
  so every empty column (rc, artifact and model_id are all empty on a running
  lane) shifted the later fields left. Rows are now 0x1f-separated.
- A lane whose spawner is dead no longer reads `running` for six hours:
  ff-status probes the `proc` record's pid for in-flight lanes and demotes to
  `abandoned` at once, naming the pid (ADR-025 addendum). The probe errs only
  toward alive.
- `ff-status` emitted NOTHING — and exited 0 — for any run past ~37 lanes,
  so the machine-wide dashboard rendered its three largest runs
  (godaddy-build at 123 lanes, newbook-v1, tess-v1) as empty "could not read
  this run" cards while every small run looked fine. The lane accumulator
  folded every record into a growing `$L + [...]` array passed BACK through
  jq's argv once per lane — quadratic in argv bytes — until Windows refused
  with "Argument list too long"; `$(...)` then collapsed the accumulator to
  "", every remaining lane failed `--argjson`, and the final assembly died.
  Records now append to an NDJSON temp file slurped on stdin, so argv carries
  one lane's fields whatever the count; a failed emit propagates a non-zero
  exit instead of the script's unconditional `exit 0`.
- `ff-aggregate` / `ff-serve` reported a failing tool's LAST stderr line,
  which for a usage dump is boilerplate: the dashboard showed "or see the jq
  manpage, or online docs at https://jqlang.org" while the cause — "Argument
  list too long" — was line one. `error_line()` now drops boilerplate and
  prefers the first error-shaped line.
- `ff-plan lint`'s `adr-constraints` check silently reported `disarmed` on
  every packet: it passed all of a packet's `owns:` paths to adr-ops's
  `adr-touching.py` in one call, but that script takes exactly one positional
  query and exits 2 on more, which ff-plan read as "tool unavailable". No
  governing ADR BLUF was ever verified. The check now calls `adr-touching`
  once per owned path and pins `--dir` to the target repo's `docs/adr`, so the
  verdict comes from the planned repo rather than ff-plan's cwd. Findings name
  only the paths that are actually governed. Per ADR-030, `disarmed` again
  means the tool is genuinely absent, never a wrong invocation; a stub
  adr-touching that exits 2 on a second positional now pins this in
  `tests/run.sh`. Observed 2026-09-04.
- `ff-run wave`'s triage had the same disarm one script over: its
  ADR-governed-path escalation called `adr-touching.py --repo`, a flag the
  script has never had (argparse exits 2), with stderr discarded and
  `|| true`, so the verdict was always "ungoverned" and a finding on a
  governed path was auto-queued for fix instead of escalated. The check now
  makes ONE batched call per finding (`--json --dir <repo>/docs/adr` plus
  every file; adr-touching accepts many positionals since 2026-09-05 and
  reports a per-query `rc` in its `queries[]` envelope), keeps stderr in
  `triage.err`, names the governed paths on stderr, and fails CLOSED: any
  exit other than 0/10 is an unanswered query and escalates with the rc
  rather than passing. A pre-batching adr-touching therefore escalates
  multi-file findings visibly (rc=2) until the skill is synced, never
  silently. A strict stub (unknown flag exits 2, `--dir` must exist, batched
  positionals, `queries[]` envelope) pins both halves in `tests/run.sh`:
  governed escalates, ungoverned stays queued. Observed 2026-09-05.
- `ff-plan lint` was unusable on Windows at real-run scale (41 packets / 251
  owned paths): 24m43s wall, then nothing printed and a wrong exit code. Two
  causes. The scope-conflict matrix re-parsed every packet per check and
  tested every owned-path pair through subshell-forking helpers (~31k pairs,
  several forks each), and the final envelope handed the findings JSON to jq
  as an argument, which dies past the 32k-char Windows command line with
  `Argument list too long`. The lint is re-engineered rather than patched:
  one awk pass indexes every packet, the checks read that index from memory,
  the whole O(n^2) matrix is a single awk program over it, and findings and
  checks accumulate in TSV ledger files that one jq call turns into the
  envelope by reading files, never argv. Same findings in the same order
  (verified against the previous implementation on a tess-v1 subset); the
  41-packet run now lints in about 1.3s with 9 external processes, where
  the old code spent 1,613 on an 8-packet subset alone. Two new
  pins in `tests/run.sh`: a 20-packet / 200-owned-path fixture must stay
  inside a 40-external-process budget (counted through PATH shims) and a
  30s wall ceiling, and an 8-packet fixture producing 280 overlaps (~83k
  chars of JSON) must still exit 10 with every finding present.

## [0.4.0] — 2026-09-04

### Added
- `ff-doctor --for MODEL[,MODEL...]`: preflight scoped to the models a run
  will spawn - a missing harness for a requested model escalates
  advisory→fail, and `claude` is required only for claude-family/glm/chip
  lanes, so a non-Claude orchestrator can bless a claude-less fleet
  (ADR-033).
- ADR-033: the orchestrator contract is bash plus judgment - any harness may
  hold the seat; host conveniences are optional surfaces. Verified with
  opencode 1.18 and pi 0.83 each driving `ff plan draft → lint` end-to-end on
  Windows, unmodified (claims replayed against the filesystem).
  Includes the measured Windows constraint: sandboxed codex cannot host Git
  Bash, so the codex orchestrator posture there is full access, opposite to
  ADR-007's lane pin.
- SKILL.md: "Orchestrating from another harness" - the off-host rules.

### Fixed
- codex-cli 0.153 refused every codex lane at spawn (rc=2, `the argument
  '--approve-for-me' cannot be used with '--sandbox'`): the flag now implies
  the workspace-write sandbox, so ff-spawn passes `--approve-for-me` alone
  (0.144 accepted the pair). Guard comment at the launch line; contract,
  SKILL.md safety text, and the dashboard HARNESS matrix updated together.
  Lanes that cached the rc=2 result re-spawn with `--force`. Observed
  2026-09-04, TessituraMCP run.
- Pi's Gemini seat was documented as `FLEETFLOW_PI_PROVIDER=gemini`, which
  ff-doctor's key map does not know (fails closed, exit 7). The provider is
  pi's own name, `google`; SKILL.md, README, the worker contract, and the
  ff-spawn comments now say so. Verified live: full `gemini-3.6-flash` and
  `gemini-3.8-flash` lanes through pi (the latter is newer than pi's
  catalogue - pi accepts an uncatalogued id with a warning). OpenRouter
  lanes verified the same way (`meta/muse-spark-1.3` at `--effort max`),
  including the account-level attestation gate some models carry.
- A relative `--repo` (ff-plan passes `.`) broke every launch branch that
  dereferences `$SENT` inside its `cd "$WORKDIR"` subshell: codex/grok/pi
  lanes died "No such file or directory" before the worker launched (rc=1,
  empty artifact), and glm silently launched with an EMPTY packet because its
  `$(cat "$SENT")` expansion swallowed the failure. ff-spawn now normalises
  REPO to an absolute path right after validating it - fixing every caller at
  once - and canonicalises `$SCHEMA` the same way (codex passes the path,
  grok cats it, both inside the launch subshell). Regression-tested with a
  PATH-stubbed codex driving the real launch branch (`--repo .` +
  `--worktree`), since `--dry-run` never reaches the cd. Observed 2026-09-01,
  run studio-live - the refute lane.
- Codex re-test round 5, all three findings closed: the launcher parity check
  is a machine-readable handshake (`fleet-worker --capabilities` must exit 0
  and declare the exact `claude-bin-override` token; the round-4 textual grep
  was spoofable by a comment) with ONE implementation in `_env.sh` shared by
  doctor and spawn, probed with auth env stripped so a pre-handshake launcher
  stops at its key guard instead of exec'ing claude; a requested codex seat
  whose windows-sandbox tripwire cannot be verified fails closed at 7 instead
  of advisory-and-0; and model dependency refusals moved to a preflight
  BEFORE worktree/journal mutation, so a refused lane leaves no `started`
  record (it used to read `running` until abandonment) - the in-branch guards
  remain as backstops that now journal a terminal rc-5 result via
  `refuse_lane`.
- Codex re-test round 4, all three findings closed plus the grammar
  hardening: `codex-auth` captures once and requires exit 0 plus an anchored
  `^Logged in` (the old case-insensitive substring matched codex's real
  NEGATIVE, "Not logged in", and blessed a logged-out codex); the glm child
  doctor's exit code is no longer masked by the grep pipeline (an ok row
  followed by a nonzero exit read healthy); a launcher predating
  `FLEET_WORKER_CLAUDE_BIN` is refused whenever a claude override is in play -
  structurally by the doctor (`fleet-worker-parity`: fail when glm is
  requested, advisory otherwise) and at launch by ff-spawn (exit 5) - and the
  stale installed copy this found was synced from upstream; `--for` now also
  rejects leading, trailing, and doubled commas.
- Codex re-test round 3, all five findings closed (three were live
  false-green paths, each reproduced before fixing): `--for` now enforces one
  comma-only grammar for validation AND selection (whitespace-separated lists
  validated every name yet selected none - every check advisory, exit 0);
  offline mode honours a declared orchestrator seat whose binary is missing
  (exit 7, same as `--live`, instead of blessing the fleet); doctor/spawn
  claude-binary parity now reaches THROUGH fleet-worker (`ff-spawn` forwards
  `FLEETFLOW_CLAUDE_BIN` as `FLEET_WORKER_CLAUDE_BIN`; the launcher consumes
  it instead of hardcoding `claude`); a requested pi seat fails closed at 7
  when its provider is unset or unmapped (no key to verify, and lane
  isolation means host auth cannot save it); and a requested glm seat fails
  closed at 7 when `fleet-doctor.sh` is absent beside the launcher (the live
  probe cannot run). Unrequested models keep their historic advisory
  demeanour throughout.
- Codex re-test round 2, all four findings closed: an explicit claude-family
  orchestrator seat now joins the model probe union (a declared opus seat
  with a dead claude binary is exit 7, not a false green; seat-also-worker
  probes once), `FLEETFLOW_CLAUDE_BIN` is consumed by ff-spawn's claude
  launches as well as the doctor (no doctor/spawn binary divergence),
  `--orchestrator` refuses option-shaped values and `--for` refuses
  comma-only lists, and ADR-034's body text now carries the by-convention
  qualifier its addendum introduced.
- Scoped-grant derivation asked git for the lane's metadata dir instead of
  reconstructing it from the basename: git deduplicates worktree names
  (`wt-build`, `wt-build1`), so a colliding lane id across runs was granted
  ANOTHER lane's metadata dir - a cross-lane grant. Found by codex re-review;
  regression pins two same-id lanes resolving distinctly. ADR-034 addendum
  records this plus the now-explicit objects-dir exposure and the per-lane
  git-database endgame (ADR-035 candidate).
- `ff-doctor` argument handling failed loud instead of green: an unknown
  `--for` value used to mean "nothing wanted" - every check advisory, exit 0
  on a typo; now exit 2 naming the value. Missing `--for`/`--orchestrator`
  values are usage errors. Live probes cover workers UNION the declared
  orchestrator seat (a grok seat pulls in grok-auth with no grok lane), and
  each requested claude-family model gets its own availability probe
  (`FLEETFLOW_CLAUDE_BIN` stubs all of it hermetically - the suite exercises
  the full --live surface tokenlessly).
- **`ff-clean` destroyed committed lanes whenever the manifest base was a
  SHA** - which is what ff-spawn records. Base validation only accepted
  branch names, silently fell back to the literal string `HEAD` (a
  self-compare inside each lane worktree: zero commits, always), and the
  keep-committed-lanes protection was inert for every real run while
  removal-side tests stayed green. Found live when a 2-commit codex lane was
  destroyed during the ADR-034 lifecycle test. Three layers fixed: the base
  read strips the Windows jq CRLF, validation accepts any commit-ish and
  falls back to the main repo's HEAD *sha*, and a failed commit-count now
  KEEPS the lane instead of defaulting to zero. Regression fixture is the
  destroying run itself.
- Codex lanes now self-commit like every other model - through four SCOPED
  sandbox grants (lane worktree metadata, object store, own ref dir, own
  reflog dir), not the whole-git-dir carve-out that a pre-ADR-006 commit
  (2026-07-05) had left granting write access to `.git/config`/hooksPath,
  `refs/heads/main`, and other lanes' metadata. ADR-034 supersedes ADR-006
  (whose addendum records the seven-week drift); verified live with a real
  codex lane committing and an adversarial `.git/config` write probe being
  denied. Uniform commit clause restored to the guard preamble; tests pin the
  exact grant list and that the whole git dir is never granted.
- `--live` probes now honour `--for`: unrequested providers are neither
  called nor allowed to affect the exit status, reporting "not requested"
  advisory rows instead. Previously a claude-less fleet could exit 7 on
  providers it never asked for.
- `--orchestrator NAME` (or `FLEETFLOW_ORCHESTRATOR`) declares the seat and
  skips the Claude auto-probe - the one live check that still assumed a
  Claude orchestrator after ADR-033. Explicit seats validate cheaply (human
  is an assertion; harness seats need their binary), persist to
  `$FLEETFLOW_HOME/orchestrator`, and work in `--offline` too.

## [0.3.0] — 2026-08-24

Written from the point of view of someone who has just cloned the repo: a
Requirements/Install/Quickstart path verified by running it verbatim in a
fresh clone, portability fixes for the two dependencies that failed silently
off the author's machine, the `ff` dispatcher with terminal QOL, and a
drift-gated tunables registry.

### Added
- `ff` dispatcher (`scripts/ff`): one entry point over the scripts - `ff plan
  lint`, `ff doctor --offline` - plus native conveniences with no script of
  their own: `ff env` (the tunables registry, columnised), `ff open` (dashboard
  for this repo), `ff logs RUN ID` (tail a lane's artifacts without knowing the
  run-dir layout), `ff watch RUN` (terminal live view that exits when every
  lane is final). Bash tab-completion in `completions/ff.bash` (subcommands,
  models, run names read live from `.fleetflow/`).
- `ff-doctor --env`: every `FLEETFLOW_*` tunable as name/current/default/purpose
  TSV. The registry is gate-checked both ways: every script-referenced variable
  must be registered, and every registered variable must appear in
  `docs/REFERENCE.md` (which also carries the semantic exit-code table).
- End-of-run summary: when a collect passes and every started packet has a
  result, ff-collect reports lane counts on stderr - counts only, totals stay
  ff-status's job.
- README glossary: the sixteen load-bearing terms, one line each.
- `--target diff|staging=<url>` on `ff-run wave` aims the finder waves: `diff`
  (default) inspects the change, `staging=<url>` drives a running deployment.
  Lanes may interact fully but never deploy, restart, or reconfigure it (ADR-032).
- `FLEETFLOW_DASHBOARD_URL` overrides the dashboard origin used by the chat
  widget anchor and the SKILL.md pane ritual. Defaults to `http://127.0.0.1:8161`,
  ff-serve's own default, so a fresh install links somewhere real.
- README **Requirements** and **Install** sections: the hard tool set, the
  per-model optional set, and what each missing tool actually costs you.
- `docs/diagrams/stores-light.svg` — the run-state stores and the teardown
  boundary, embedded in ARCHITECTURE.md.

### Changed
- Portable `ff_sha256` / `ff_python` helpers in `scripts/_env.sh`, used by every
  call site. `sha256sum` now falls back to `shasum`/`openssl`, and the Python
  probe EXECUTES its candidates so a Windows App Execution Alias stub is not
  mistaken for an interpreter.
- README Quickstart starts at `ff-plan draft` (matching ADR-026) and uses real
  packet paths, so it runs verbatim from a fresh clone.
- `ARCHITECTURE.md` and `SECURITY.md` moved into `docs/`; ARCHITECTURE.md now
  embeds five diagrams. Diagram set is light-only and free of webfont imports.
- AGENTS.md landmines that depend on the author's skill junction or supervised
  dashboard now state that precondition instead of asserting it universally.
- `adr-ops` declared in `depends-on` — `ff-plan lint` and the test gate call it.
- SKILL.md carries the dispatcher: a `scripts/ff` row leads the scripts table
  (with the sugar-never-a-layer rule stated), the doctor row documents `--env`,
  the collect row documents the end-of-run summary, and the frontmatter roster
  gains Pi.

### Fixed
- Journal cache keys could silently collapse to `v2:` on hosts without
  coreutils, making every lane after the first a false cache hit (ADR-012).
- The chat widget hardcoded a private `.lab` host as the run card's primary
  link, and the test suite pinned that hostname; both now follow the configured
  dashboard origin.
- `ff-doctor` advisories name the exit code and the remedy, so a missing
  per-model harness is no longer a bare "unavailable".

## [0.2.0] — 2026-08-20

Runs are now planned, linted, and refuted before they spawn; the build of
this release itself ran as a codex+glm fleet with tested-posture QA
(findings: 8 fixed, 1 waived, 0 open).

### Added
- `ff-plan` — `draft` (plan doc + packets + manifest authored up front,
  ADR-026), `lint` (scope/dep/constraint/routing/barrier/bounds checks with
  armed-or-disarmed reporting, gates the spawn, ADR-030), `refute`
  (cross-provider Adversary attacks the plan pre-spawn, ADR-028), `estimate`
  (honest pricing), `expand` (generator registry, ADR-029; Forma registered,
  arming pending).
- Packet YAML frontmatter: `owns`/`modifies`/`registries`/`depends_on`/
  `role`/`class` — file-disjointness and single-writer registries become
  machine-checkable.
- Twelve role cards (`assets/roles/`, ADR-031): Architect, Oracle, Scout,
  Surveyor, Scholar, Builder, Inspector, Adversary, Judge, Critic, Composer,
  Warden — prepended into packets by `ff-plan draft`.
- Frozen plan-doc and packet templates (`assets/plan.tmpl.md`,
  `assets/packet.tmpl.md`).
- `abandoned` lane state (ADR-025): hours-scale silence demotes an in-flight
  lane to a final state; dashboards stop animating and re-polling dead runs.
- Dashboard time-window lens: this/last week · month · quarter, custom, all
  time — scopes every view and roll-up (`ffd.window`).
- `docs/ARCHITECTURE.md` — living current-state map of components, data stores,
  and the invariant gate.
- Role-cards diagram (`docs/diagrams/role-cards-light.svg`).

### Changed
- Suite grown to 442 hermetic assertions (ff-plan contract tests written
  blind to the implementation; stubbed refute/estimate/expand coverage).
- SKILL.md/README document the extended lifecycle:
  `ff-plan → doctor → spawn → collect → wave → land`.

## [0.1.0] — 2026-08-14

Extracted from the claude-mods skills tree with full history (subtree
split, 2026-08-01); everything below landed in this repo since extraction.

### Added
- The run lifecycle scripts: `ff-doctor`, `ff-spawn`, `ff-collect`,
  `ff-status`, `ff-run` (resume + post-build waves), `ff-findings`,
  `ff-widget`, `ff-archive`, `ff-clean`, `ff-import` — bash, Skill Resource
  Protocol, semantic exit codes.
- Post-build wave pipeline with findings ledger, posture-selected finder
  waves, mechanical triage, fix loops and cross-provider re-verify (ADR-018).
- Shared run-card renderer embedded byte-identically in the dashboard and the
  chat widget, parity-gated by the test suite (ADR-019).
- `ff-sweep`: machine-wide housekeeping with live-computed verdicts and
  safe-only reclaim (ADR-020), plus the P1–P4 performance work — measured
  16× on a machine-wide sweep (see docs/reports/SWEEP-PERF-2026-08.md) with
  a bytes-only cache (ADR-024).
- `ff-chip`: manually spawned Claude Code chips adopted as first-class lanes
  (ADR-021).
- Opt-in raven-bus worker telemetry (ADR-022) and steerable ACP claude lanes
  with packet-as-trusted-boundary and telemetry-distilled verdicts (ADR-023).
- Machine-wide dashboard (`ff-serve.py` + `ff-dashboard.html`) with Fleet
  view (spec/observed/capacity registers, ADR-014), honest cost estimation
  (ADR-010/015), and single-run live monitor (`ff-monitor.html`).
- 389-assertion hermetic behavioural test suite; ADR lint runs inside it.

### Changed
- Default GLM worker model is GLM-5.3; reasoning
  levels `low|high|max` documented in the worker contract.
