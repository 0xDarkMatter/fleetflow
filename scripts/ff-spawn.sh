#!/usr/bin/env bash
# ff-spawn.sh - spawn one fleetflow worker lane (GLM / Codex / Anthropic model).
#
# Creates the run dir + optional worktree lane, injects the guard preamble,
# journals a hash-keyed started/result pair (native-Workflow-style replay
# cache), launches the model-appropriate process, and writes its artifacts.
# stdout: the artifact path (data). stderr: progress chatter.
#
# Exit codes: 0 ok | 2 usage | 3 cache hit (cached artifact path on stdout)
#             5 missing dependency | 10 worker failed
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"

usage() {
  cat <<'EOF'
Usage: ff-spawn.sh --run NAME --id ID --model MODEL --prompt-file FILE
                   [--worktree] [--base BRANCH] [--repo PATH] [--max-turns N]
                   [--effort low|medium|high|max] [--schema FILE] [--no-guard]
                   [--force] [--dry-run] [--round N] [--acp]

  --run NAME       run name (groups lanes; [a-z0-9-]+)
  --id ID          lane id within the run ([a-z0-9-]+)
  --model MODEL    glm | codex | grok | pi | sonnet | opus | haiku | fable
  --prompt-file F  packet file (guard preamble is prepended unless --no-guard)
  --phase NAME     progress-group label (default: build) - display only
  --round N        fix-loop round - metadata only (integer >=0, default: 0).
                   NOT part of the cache key (see ADR-018's "Consequence for
                   ADR-012" - a round counter in the key would re-run
                   verification an unchanged tree does not need; the
                   sanctioned re-verify invalidator is BASE_SHA in the packet
                   body, not a round number in the key).
  --orchestrator M which model is DRIVING this fleet (e.g. fable, opus). Nothing
                   in the environment exposes it - a Claude Code session gives its
                   children CLAUDE_EFFORT and a session id but NOT its model - so
                   it must be passed, or set once via $FLEETFLOW_ORCHESTRATOR, or
                   left to whatever `ff-doctor --live` last probed. Display only.
  --worktree       give the worker its own worktree lane (branch fleetflow/RUN/ID)
  --base BRANCH    worktree base (default: main, falls back to HEAD)
  --repo PATH      repo root (default: git toplevel of cwd)
  --max-turns N    worker turn cap (default: 100)
  --effort LEVEL   reasoning effort lever: low|medium|high|max (default: unset =
                   inherit the model's own default). GLM -> FLEET_WORKER_EFFORT;
                   claude models -> --settings effortLevel; codex -> model_reasoning_effort.
                   Effort IS part of the cache key (different effort = different run).
  --schema FILE    JSON Schema for the final answer (codex: native
                   --output-schema; other models: appended to the prompt)
  --no-guard       skip the guard preamble injection
  --force          ignore a journal cache hit and re-run
  --dry-run        do not launch a worker; write a stub result (for tests/planning)
  --acp            run the lane under the raven-bus ACP harness (`raven acp`
                   driving zed's claude-code-acp adapter) instead of one-shot
                   `claude -p`. Claude models only. The lane becomes steerable
                   mid-run: it watches run/RUN/lane/ID + run/RUN/control and
                   posts replies to run/RUN/telemetry. It runs until reaped
                   (the adapter never exits by itself) - the artifact verdict
                   comes from telemetry, not the process exit code. --effort
                   is not supported under --acp (no per-session settings
                   channel over ACP yet); --max-turns is ignored.

ENV (pi model)
  FLEETFLOW_PI_BIN                 pi launcher (default: pi on PATH; point at a
                                   local install's pi.cmd, e.g. X:/Agents/Pi/pi.cmd)
  FLEETFLOW_PI_PROVIDER            provider passed to `pi --provider` (pi's
                                   wildcard slot: google=Gemini, openrouter, deepseek, zai, groq, ...)
  FLEETFLOW_PI_MODEL               model passed to `pi --model`
                                   NOTE: lanes get an ISOLATED PI_CODING_AGENT_DIR,
                                   so ~/.pi/agent/auth.json does NOT apply - the
                                   provider's API key env var is the only auth.

ENV
  FLEETFLOW_ORCHESTRATOR           default for --orchestrator (set once per session)

ENV (--acp lanes)
  FLEETFLOW_ACP_AGENT_JS           path to claude-code-acp's dist/index.js
                                   (default: resolved via `npm root -g`)
  FLEETFLOW_PERMISSION_MODE        session mode sent via session/set_mode
                                   (default: acceptEdits - file-edit tools
                                   auto-allowed, Bash gated by the allowlist;
                                   set bypassPermissions to opt up to the
                                   claude -p lanes' posture, dontAsk to lock
                                   edits down too)

ENV (codex model)
  FLEETFLOW_CODEX_MODEL            model passed to `codex exec -m`
  FLEETFLOW_CODEX_WINDOWS_SANDBOX  windows.sandbox override, Windows hosts only
                                   (default: unelevated - `elevated` needs a UAC
                                   approval no headless lane can give). Set empty
                                   to pass nothing and defer to ~/.codex/config.toml.

EXAMPLES
  ff-spawn.sh --run audit --id ts-refresh --model glm --worktree \
              --prompt-file packets/ts.txt
  ff-spawn.sh --run audit --id dissent-1 --model codex --effort high \
              --prompt-file packets/refute.txt --schema verdict.schema.json
  ff-spawn.sh --run audit --id judge --model opus --effort max --prompt-file packets/judge.txt
EOF
}

err() { echo "ff-spawn: $*" >&2; }

# Canonical absolute path. `realpath` is not on every host bash (and MSYS's
# emits a mixed-style path), so cd+pwd is the portable equivalent - and because
# BOTH sides of a comparison go through this one helper, the two land in the
# same path flavour (MSYS `/x/...` vs git's `X:/...`) and compare correctly.
# Falls back to the literal path when the directory does not exist.
abspath() {
  local p="$1" d
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || { printf '%s' "$p"; return; }
  printf '%s/%s' "$d" "$(basename "$p")"
}

# main() wrapper - parse-before-execute guard (incident 2026-08-01, run
# atdw-sync, lane verify-cli-2). bash parses script files INCREMENTALLY during
# execution: when this file was rewritten mid-run (a concurrent session edit +
# a repo->global skills sync), the resuming parser read shifted bytes and a
# 5-minute lane died with a phantom "line 457: syntax error" AFTER its worker
# succeeded - in a 341-line file, with `bash -n` passing. Wrapping the whole
# procedural body in main() forces bash to parse the entire file up front, so
# a mid-run file replacement can no longer kill a running lane.
# Body is deliberately NOT re-indented (keeps the diff/blame readable).
# DO NOT unwrap this as a "simplification".
main() {

RUN="" ID="" MODEL="" PROMPT_FILE="" WORKTREE=0 BASE="main" REPO=""
MAX_TURNS=100 SCHEMA="" GUARD=1 FORCE=0 DRYRUN=0 PHASE="build" EFFORT=""
ORCHESTRATOR="" ROUND=0 ACP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --phase) PHASE="${2:-}"; shift 2 ;;
    --round) ROUND="${2:-}"; shift 2 ;;
    --orchestrator) ORCHESTRATOR="${2:-}"; shift 2 ;;
    --id) ID="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    # deprecated alias from the brain->model rename; kept so pre-rename
    # orchestrator prompts keep working
    --brain) MODEL="${2:-}"; err "NOTE: --brain is deprecated, use --model"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --worktree) WORKTREE=1; shift ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --max-turns) MAX_TURNS="${2:-}"; shift 2 ;;
    --effort) EFFORT="${2:-}"; shift 2 ;;
    --schema) SCHEMA="${2:-}"; shift 2 ;;
    --acp) ACP=1; shift ;;
    --no-guard) GUARD=0; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

case "$MODEL" in glm|codex|grok|pi|sonnet|opus|haiku|fable) ;; *) err "invalid --model '$MODEL'"; exit 2 ;; esac
case "$EFFORT" in ""|low|medium|high|max) ;; *) err "invalid --effort '$EFFORT' (low|medium|high|max)"; exit 2 ;; esac
case "$ROUND" in ''|*[!0-9]*) err "invalid --round '$ROUND' (integer >=0)"; exit 2 ;; esac
if [ "$ACP" = 1 ]; then
  # claude-code-acp wraps the Claude Agent SDK - only claude models can sit
  # behind it. Other providers get ACP lanes when they grow ACP adapters.
  case "$MODEL" in sonnet|opus|haiku|fable) ;;
    *) err "--acp requires a claude model (sonnet|opus|haiku|fable)"; exit 2 ;;
  esac
  # No per-session settings channel over ACP (claude -p lanes pass --settings
  # effortLevel; the adapter exposes no equivalent). Refuse loudly rather than
  # silently run at default effort - effort is part of the cache key, so an
  # ignored flag would ALSO poison the key with a lie.
  [ -z "$EFFORT" ] || { err "--acp does not support --effort (no settings channel over ACP)"; exit 2; }
fi

# --- Windows/Codex elevation trap (incident 2026-07-27, run bkv2p2) ------------
# codex-cli's `elevated` Windows sandbox mode provisions its AppContainer through
# a setup helper launched via ShellExecuteExW - i.e. a UAC prompt. In a HEADLESS
# fleet there is no approver, so Windows cancels the launch (error 1223 =
# ERROR_CANCELLED, surfaced as `orchestrator_helper_launch_canceled`) and the
# lane HANGS instead of failing fast: two lanes sat at state=running for 2.7h
# with dead event streams. The provisioning cache (~/.codex/.sandbox*) is why
# earlier lanes in the same session survive - any invalidation, or a race between
# concurrently-provisioning lanes, re-triggers the elevation request.
# Fleet lanes therefore pin `unelevated` PER INVOCATION. Deliberately NOT a write
# to the user's ~/.codex/config.toml: interactive Codex keeps whatever mode they
# chose. Escape hatches: FLEETFLOW_CODEX_WINDOWS_SANDBOX=elevated to opt back in,
# or ="" (empty) to pass nothing and defer to the global config.
# DO NOT remove this flag as "redundant" - it is the whole fix.
CODEX_WINSANDBOX=""
if [ "$MODEL" = "codex" ]; then
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) CODEX_WINSANDBOX="${FLEETFLOW_CODEX_WINDOWS_SANDBOX-unelevated}" ;;
  esac
  # the binary accepts exactly these two values for windows.sandbox
  case "$CODEX_WINSANDBOX" in
    ""|elevated|unelevated) ;;
    *) err "invalid FLEETFLOW_CODEX_WINDOWS_SANDBOX '$CODEX_WINSANDBOX' (elevated|unelevated)"; exit 2 ;;
  esac
fi
echo "$RUN" | grep -qE '^[a-z0-9-]+$' || { err "invalid --run"; exit 2; }
echo "$ID"  | grep -qE '^[a-z0-9-]+$' || { err "invalid --id"; exit 2; }
[ -f "$PROMPT_FILE" ] || { err "prompt file not found: $PROMPT_FILE"; exit 2; }
[ -z "$SCHEMA" ] || [ -f "$SCHEMA" ] || { err "schema file not found: $SCHEMA"; exit 2; }
command -v jq >/dev/null || { err "jq required"; exit 5; }
command -v git >/dev/null || { err "git required"; exit 5; }

[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }
# Absolute from here on. RUNDIR/SENT/WORKDIR all derive from REPO, and every
# launch branch dereferences $SENT inside its `cd "$WORKDIR"` subshell - with a
# relative --repo (ff-plan passes `.`) the redirect resolved against the LANE
# dir after the cd: codex/grok/pi lanes died "No such file or directory" before
# the worker launched (rc=1, empty artifact), and glm silently launched with an
# EMPTY packet because its `$(cat "$SENT")` expansion swallowed the failure
# (incident 2026-09-01, run studio-live - the refute lane).
# pwd -W (Git Bash builtin) keeps the drive-letter flavour git itself emits
# (`X:/...`): archive_transcript's project-dir slug is derived from $WORKDIR,
# and a `/x/...` POSIX-flavour path would encode a slug claude never writes.
# Non-MSYS hosts don't have -W and fall back to plain pwd.
REPO="$(cd "$REPO" && { pwd -W 2>/dev/null || pwd -P; })" || { err "cannot resolve --repo to an absolute path"; exit 2; }
# same cd hazard, other input: codex --output-schema takes the $SCHEMA path and
# grok cats it, both inside the launch subshell - canonicalise while the
# caller's cwd still resolves it ([ -f ] above proved the file exists).
[ -z "$SCHEMA" ] || SCHEMA="$(abspath "$SCHEMA")"

RUNDIR="$REPO/.fleetflow/$RUN"
mkdir -p "$RUNDIR"
# keep the scratch tree out of git without touching the repo's .gitignore
EXCL="$(git -C "$REPO" rev-parse --absolute-git-dir)/info/exclude"
mkdir -p "$(dirname "$EXCL")"
grep -qs '^\.fleetflow/$' "$EXCL" 2>/dev/null || echo ".fleetflow/" >> "$EXCL"
# .ff-heartbeat is the worker-authored liveness file (see the heartbeat clause
# below). Excluded so it never dirties a lane (ff-clean's zero-commit+clean
# reclaim, git worktree remove) and never trips --check-main-clean.
grep -qs '^\.ff-heartbeat$' "$EXCL" 2>/dev/null || echo ".ff-heartbeat" >> "$EXCL"

# escape-guard baseline: snapshot the main checkout's status once per run
BASELINE="$RUNDIR/main-baseline.txt"
[ -f "$BASELINE" ] || git -C "$REPO" status --porcelain > "$BASELINE" 2>/dev/null

# --- build the effective prompt ---------------------------------------------
# ALIASING HAZARD (incident 2026-08-01, run bkv4 - three lanes lost in one wave).
# $SENT is an OUTPUT: truncated here, then rebuilt from the guard preamble plus
# $PROMPT_FILE. If the caller points --prompt-file at this same path, it is also
# the INPUT, and `: > "$SENT"` destroys the author's packet before the `cat`
# below can read it. Everything downstream then reports success: the worker
# launches with a guard preamble and NO TASK, replies "I don't see a task
# description in this session yet", exits 0, and ff-collect's gate passes.
# Nothing anywhere holds a backup of the packet.
# This is a LIKELY mistake, not an exotic one - `<rundir>/<id>.prompt.txt` is
# exactly the filename a person authoring packets into the run dir would choose.
# Two defences, both deliberate; DO NOT "simplify" either away:
#   1. refuse the aliased path outright, canonically compared, before any write;
#   2. read the packet into memory BEFORE the truncate, so ordering alone can
#      never destroy input if a future refactor reintroduces an aliasing path.
SENT="$RUNDIR/$ID.prompt.txt"
if [ "$(abspath "$PROMPT_FILE")" = "$(abspath "$SENT")" ]; then
  err "prompt file $PROMPT_FILE is the path ff-spawn writes its effective prompt to;"
  err "author packets elsewhere (e.g. $RUNDIR/packets/$ID.task.md)"
  exit 2
fi
# defence in depth (see above). The `printf x` / `%x` bracket preserves the
# packet's exact trailing newlines, which command substitution would strip -
# byte fidelity here keeps the journal's content-hash cache key stable.
PACKET="$(cat "$PROMPT_FILE"; printf x)"; PACKET="${PACKET%x}"
: > "$SENT"
if [ "$GUARD" = 1 ]; then
  PRE="$(dirname "${BASH_SOURCE[0]}")/../assets/guard-preamble.txt"
  [ -f "$PRE" ] && cat "$PRE" >> "$SENT"
  # Heartbeat clause (worktree lanes only) - rookery's `parcel progress`
  # pattern, filed down to one file: the worker appends a line per major step,
  # ff-status reads the mtime as a live stall signal. This is the ONLY liveness
  # coverage for models with no native stream (grok buffers --output-format
  # json to exit). Worktree-only because a non-worktree lane's cwd is the MAIN
  # checkout, shared with sibling lanes and the orchestrator - a heartbeat
  # there could not be attributed to a lane (same reasoning as ff-status's
  # transcript rule). NB: this changes the prompt for guard+worktree packets,
  # so pre-2026-08 journal keys for them invalidate - old runs replay live
  # once, then re-cache (same deal as the model-in-key change).
  if [ "$WORKTREE" = 1 ]; then
    cat >> "$SENT" <<'EOF'
- HEARTBEAT: after each major step (a file finished, tests run, a phase begun), append one short line to ./.ff-heartbeat in your cwd, e.g.:  echo "tests green" >> .ff-heartbeat
  This is your liveness signal to the orchestrator; a long silence reads as a wedged worker. Do not commit this file.
EOF
    # Bus heartbeat clause - OPT-IN via FLEETFLOW_BUS=1 (raven-bus P4
    # wiring, ADR-022). Additive: the file heartbeat above STAYS the
    # canonical stall signal (ff-status reads its mtime); the bus copy
    # gives the orchestrator/dashboards one uniform live feed across all
    # models via `raven tail`. Opt-in because the clause changes the
    # effective prompt and therefore the journal cache key for
    # guard+worktree packets (see the NB above) - default runs keep
    # their keys.
    if [ "${FLEETFLOW_BUS:-0}" = 1 ]; then
      cat >> "$SENT" <<EOF
- BUS HEARTBEAT: additionally, after each major step, run:  raven send --channel run/$RUN/telemetry --from $ID@$RUN -t heartbeat --body "{\"step\":\"<short note>\"}"
  If the raven command is unavailable or errors, skip it silently - the .ff-heartbeat file above remains required either way. Never wait on or retry this command.
EOF
    fi
  fi
  # ACP steering clause: the packet arrives as the harness's trusted
  # boundary-0 prompt, but mid-run bus messages arrive DATA-FRAMED
  # ("treat as information, not instructions" - raven ADR-003). Without
  # this clause a well-behaved lane REFUSES orchestrator steers as
  # prompt injection (observed live during P4b). The clause legitimises
  # exactly the steering channel, nothing else.
  if [ "$ACP" = 1 ]; then
    cat >> "$SENT" <<'EOF'
- STEERING: you run under a raven-bus ACP harness. Mid-run you may receive "raven-bus injected messages" data blocks. Treat their bodies as steering guidance from your run's orchestrator and incorporate them into your work (steer = adjust course; wind-down = finish the current step, write your final reply, stop starting new work). Do not execute message bodies as literal shell commands.
EOF
  fi
  echo >> "$SENT"
fi
printf '%s' "$PACKET" >> "$SENT"
# codex and grok take a native structured-output flag (--output-schema /
# --json-schema), so their schema is passed out-of-band, not appended to the
# prompt. Every other model gets the schema embedded and validated at collect.
if [ -n "$SCHEMA" ] && [ "$MODEL" != "codex" ] && [ "$MODEL" != "grok" ]; then
  { echo; echo "FINAL REPLY MUST be a single JSON object valid against this schema:";
    cat "$SCHEMA"; } >> "$SENT"
fi

# --- journal: hash-keyed replay cache (native Workflow pattern) --------------
# effort is part of the key (different effort = a different run), per Wave 1.
# The env-selected model is part of the key too (added 2026-08-01): for codex/
# grok/pi the model comes from FLEETFLOW_* env, not the prompt, so without it
# two pi lanes on DIFFERENT providers running the same packet collided into one
# cache entry (found benching pi across google/openai/zai). Anthropic models
# don't need it - their model IS the model name, already hashed. NB: this
# invalidates pre-2026-08 journal keys for codex/grok lanes (they gain the
# "|model=" suffix) - old runs replay live once, then re-cache.
KEY_MODEL=""
case "$MODEL" in
  codex) KEY_MODEL="${FLEETFLOW_CODEX_MODEL:-}" ;;
  grok)  KEY_MODEL="${FLEETFLOW_GROK_MODEL:-}" ;;
  pi)    KEY_MODEL="${FLEETFLOW_PI_PROVIDER:-}/${FLEETFLOW_PI_MODEL:-}" ;;
esac
OPTS="turns=$MAX_TURNS|wt=$WORKTREE|schema=$( [ -n "$SCHEMA" ] && basename "$SCHEMA" )|effort=$EFFORT|model=$KEY_MODEL"
# acp joins the key CONDITIONALLY: an ACP lane is a different execution mode
# (harness vs one-shot), so same packet+model must not collide - but appending
# "|acp=0" to every key would invalidate every cached run on the machine for a
# mode they don't use (the exact blast the heartbeat clause's opt-in avoids).
[ "$ACP" = 1 ] && OPTS="$OPTS|acp=1"
KEY="v2:$( { printf '%s\n' "$MODEL"; cat "$SENT"; printf '%s' "$OPTS"; } | ff_sha256 | cut -d' ' -f1)"
JOURNAL="$RUNDIR/journal.jsonl"

# --- run manifest (orchestrator-side packet metadata; ff-run replays it) ----
# Created on first spawn; each spawn upserts its packet by id (idempotent).
MANIFEST="$RUNDIR/manifest.json"
# one canonicalizer for the whole script (also the aliasing check's comparator)
prompt_abs() { abspath "$PROMPT_FILE"; }
WT_JSON="false"; [ "$WORKTREE" = 1 ] && WT_JSON="true"
ACP_JSON="false"; [ "$ACP" = 1 ] && ACP_JSON="true"
MENTRY="$(jq -nc --arg id "$ID" --arg b "$MODEL" --arg p "$PHASE" --arg pf "$(prompt_abs)" \
  --argjson wt "$WT_JSON" --argjson mt "$MAX_TURNS" --arg e "$EFFORT" --arg s "${SCHEMA:-}" --arg k "$KEY" \
  --argjson round "$ROUND" --argjson acp "$ACP_JSON" \
  '{id:$id,model:$b,phase:$p,prompt_file:$pf,worktree:$wt,max_turns:$mt,effort:$e,schema:$s,key:$k,round:$round,acp:$acp}')"
if [ ! -s "$MANIFEST" ]; then
  jq -nc --arg run "$RUN" --arg base "$BASE" --arg by "ff-spawn/$FF_VERSION" \
    --argjson entry "$MENTRY" --arg phase "$PHASE" --arg o "$ORCHESTRATOR" \
    '{run:$run,base:$base,created_by:$by,
      orchestrator:(if $o=="" then null else $o end),
      phases:[$phase],packets:[$entry]}' > "$MANIFEST"
else
  jq --argjson entry "$MENTRY" --arg id "$ID" --arg phase "$PHASE" --arg o "$ORCHESTRATOR" \
    '.packets = ((.packets // []) | map(select(.id != $id))) + [$entry]
     | .phases = (((.phases // []) + [$phase]) | unique)
     | .orchestrator = (.orchestrator // (if $o=="" then null else $o end))' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
fi

if [ "$FORCE" = 0 ] && [ -f "$JOURNAL" ]; then
  CACHED="$(jq -r --arg k "$KEY" 'select(.type=="result" and .key==$k and .rc==0) | .artifact' "$JOURNAL" 2>/dev/null | tail -1)"
  if [ -n "$CACHED" ] && [ -f "$CACHED" ]; then
    err "cache hit for $ID (unchanged packet) - use --force to re-run"
    echo "$CACHED"
    exit 3
  fi
fi

# --- model preflight (refuse BEFORE any lane state exists) --------------------
# Dependency refusals used to live inside the launch branches, AFTER the
# worktree was created and `started` was journalled - so a stale/missing
# launcher exited 5 and left the lane reading `running` until abandonment
# demoted it (codex review round 5). Every synchronous "cannot launch" check
# that needs no launch-time context runs here, before journal/worktree
# mutation. The in-branch guards remain as backstops and journal a terminal
# result via refuse_lane. Dry-run skips: it launches nothing, and the suite's
# dry-run fixtures must stay hermetic.
if [ "$DRYRUN" != 1 ]; then
  case "$MODEL" in
    glm)
      _PFW="${FLEETFLOW_FLEET_WORKER:-$HOME/.claude/skills/fleet-worker/scripts/fleet-worker}"
      [ -f "$_PFW" ] || { err "fleet-worker launcher not found ($_PFW)"; exit 5; }
      if [ "${FLEETFLOW_CLAUDE_BIN:-claude}" != "claude" ] && ! ff_fw_has_claude_bin_override "$_PFW"; then
        err "fleet-worker at $_PFW lacks the claude-bin-override capability - the claude override would be silently ignored; re-run install"; exit 5
      fi
      ;;
    codex) command -v codex >/dev/null || { err "codex CLI not found"; exit 5; } ;;
    grok)
      _PGK="${FLEETFLOW_GROK_BIN:-grok}"
      command -v "$_PGK" >/dev/null || { err "grok CLI not found ($_PGK)"; exit 5; } ;;
    pi)
      _PPI="${FLEETFLOW_PI_BIN:-pi}"
      command -v "$_PPI" >/dev/null || [ -f "$_PPI" ] || { err "pi CLI not found ($_PPI - set FLEETFLOW_PI_BIN)"; exit 5; } ;;
    sonnet|haiku|opus|fable)
      _PCB="${FLEETFLOW_CLAUDE_BIN:-claude}"
      command -v "$_PCB" >/dev/null || { err "claude CLI not found ($_PCB)"; exit 5; }
      if [ "$ACP" = 1 ]; then
        command -v raven >/dev/null || { err "raven CLI not found (--acp needs raven-bus)"; exit 5; }
        command -v node  >/dev/null || { err "node not found (claude-code-acp runs on node)"; exit 5; }
      fi
      ;;
  esac
fi

# --- worktree lane ------------------------------------------------------------
WORKDIR="$REPO"
if [ "$WORKTREE" = 1 ]; then
  WORKDIR="$RUNDIR/wt-$ID"
  if [ ! -d "$WORKDIR" ]; then
    git -C "$REPO" show-ref --verify --quiet "refs/heads/$BASE" || BASE="HEAD"
    git -C "$REPO" worktree add -q -b "fleetflow/$RUN/$ID" "$WORKDIR" "$BASE" \
      || { err "worktree add failed"; exit 10; }
  fi
fi

# phase is display metadata only - deliberately NOT part of the cache key.
# round: NOT in key - same deal, and the reason is spelled out in ADR-018's
# "Consequence for ADR-012": a round counter in the key would re-run
# verification an unchanged tree does not need. The sanctioned re-verify
# invalidator is BASE_SHA in the packet body (a pure function of the work
# under test), not a round number here. round joins phase as manifest/journal
# metadata only - display and audit, never identity.
#
# The exact model is journalled because for codex and grok it is otherwise
# UNRECOVERABLE after the fact: their event streams carry no model field, so the
# id exists only in this process's environment and dies with it. Claude-model
# workers self-report theirs in result.json's modelUsage, but recording it here
# too means every lane can answer "what actually ran" the same way. Also display
# metadata, also deliberately out of the cache key.
# WHICH MODEL RAN THE ORCHESTRATOR. Nothing in the environment exposes it - a
# Claude Code session publishes CLAUDE_EFFORT and a session id to its children but
# NOT its model - so fleetflow has to be told, in this order:
#   --orchestrator M  >  $FLEETFLOW_ORCHESTRATOR  >  what ff-doctor last probed
# and null if nobody said. Recorded because "who decided" is the one thing a run's
# cost table cannot reconstruct afterwards: the lanes are all in the journal, the
# judgment that placed them is not.
: "${ORCHESTRATOR:=}"
[ -n "$ORCHESTRATOR" ] || ORCHESTRATOR="${FLEETFLOW_ORCHESTRATOR:-}"
[ -n "$ORCHESTRATOR" ] || ORCHESTRATOR="$(cat "${FLEETFLOW_HOME:-$HOME/.fleetflow}/orchestrator" 2>/dev/null | tr -d '\r\n')"

SPAWN_MODEL=""
case "$MODEL" in
  codex) SPAWN_MODEL="${FLEETFLOW_CODEX_MODEL:-}" ;;
  grok)  SPAWN_MODEL="${FLEETFLOW_GROK_MODEL:-}" ;;
  pi)    SPAWN_MODEL="${FLEETFLOW_PI_PROVIDER:+$FLEETFLOW_PI_PROVIDER/}${FLEETFLOW_PI_MODEL:-}" ;;
  fable) SPAWN_MODEL="claude-fable-5" ;;
  *)     SPAWN_MODEL="$MODEL" ;;
esac
jq -nc --arg k "$KEY" --arg id "$ID" --arg b "$MODEL" --arg p "$PHASE" --arg v "$FF_VERSION" \
  --arg m "$SPAWN_MODEL" --arg o "$ORCHESTRATOR" --argjson round "$ROUND" \
  '{type:"started",key:$k,id:$id,model:$b,phase:$p,v:$v,round:$round,
    model_id:(if $m=="" then null else $m end),
    orchestrator:(if $o=="" then null else $o end)}' >> "$JOURNAL"

# --- reap anchor (2026-07-27: TaskStop left 5 orphaned codex.exe alive) --------
# Killing the wrapper does NOT kill the worker: `codex exec` spawns codex.exe and
# codex-code-mode-host.exe as descendants, and they survive. Journal THIS
# process's ids so ff-clean --reap can identify that subtree afterwards - $$ is
# ff-spawn, the worker is always below it.
#
# Both ids are recorded because they live in different namespaces: the PID bash
# reports is a Cygwin id, useless to taskkill/Stop-Process, which need the
# Windows PID. `ps -W` is the only place the two appear side by side. Windows
# does not reparent orphans, so a dead ff-spawn's WINPID still identifies its
# subtree - which is exactly the post-kill case reaping has to handle. `at`
# guards against PID reuse: a process older than the spawn cannot be ours.
REAP_WINPID=""
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) REAP_WINPID="$(ps -W 2>/dev/null | awk -v p=$$ '$1==p {print $4; exit}')" ;;
esac
jq -nc --arg id "$ID" --arg b "$MODEL" --argjson pid "$$" --arg w "${REAP_WINPID:-}" \
  --argjson at "$(date +%s)" \
  '{type:"proc",id:$id,model:$b,pid:$pid,
    winpid:(if $w=="" then null else ($w|tonumber) end),at:$at}' >> "$JOURNAL"

# --- launch -------------------------------------------------------------------
ART="$RUNDIR/$ID.result.json"
ERRF="$RUNDIR/$ID.err"
RC=0

# cache/tmp redirect: worker/pytest/uv litter lands OUTSIDE repo + lanes
# (a codex sandbox once left AppContainer-ACL'd pytest dirs inside a lane that
# resisted unelevated deletion and blocked a repo move).
CACHE_DIR="${FLEETFLOW_CACHE_ROOT:-$HOME/.fleet-worker/cache}/$RUN-$ID"
mkdir -p "$CACHE_DIR"
CFGD="${FLEET_WORKER_CONFIG_DIR:-$HOME/.fleet-worker/cfg-ff-$ID}"
# precompute the claude --settings effortLevel JSON so ${EFFORT:+...} stays simple
EFF_JSON=""
[ -n "$EFFORT" ] && EFF_JSON="$(jq -nc --arg e "$EFFORT" '{"effortLevel":$e}' 2>/dev/null)"

# archive the session transcript next to the artifact (best-effort, never fatal)
archive_transcript() {
  local dest="$RUNDIR/$ID.transcript.jsonl" src="" sid enc
  case "$MODEL" in
    glm)
      src="$(ls -t "$CFGD"/projects/*/*.jsonl 2>/dev/null | head -1)"
      ;;
    pi)
      # pi persists sessions under <PI_CODING_AGENT_DIR>/sessions/<path-slug>/<uuid>.jsonl;
      # the lane's dir is isolated, so the newest session there is unambiguously ours
      src="$(ls -t "$CFGD"/sessions/*/*.jsonl 2>/dev/null | head -1)"
      ;;
    sonnet|opus|haiku|fable)
      # ACP lanes have no session_id in the envelope (it's distilled from bus
      # telemetry); the newest transcript under the lane's project dir is
      # unambiguously ours because the WORKDIR is lane-specific (worktree) or
      # the run just finished (best-effort either way).
      if [ "$ACP" = 1 ]; then
        enc="$(printf '%s' "$WORKDIR" | sed 's#[:\\/.]#-#g')"
        src="$(ls -t "$HOME/.claude/projects/$enc"/*.jsonl 2>/dev/null | head -1)"
      else
        sid="$(jq -r '.session_id // empty' "$ART" 2>/dev/null)"
        if [ -n "$sid" ]; then
          # workdir encoding: per-char [:\\/.] -> "-" (verified empirically:
          # C:\Users\Mack -> C--Users-Mack under ~/.claude/projects)
          enc="$(printf '%s' "$WORKDIR" | sed 's#[:\\/.]#-#g')"
          src="$HOME/.claude/projects/$enc/$sid.jsonl"
          [ -f "$src" ] || src="$(ls "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)"
        fi
      fi
      ;;
  esac
  if [ -n "$src" ] && [ -f "$src" ]; then
    cp -f "$src" "$dest" 2>/dev/null && err "archived transcript -> $dest" \
      || err "transcript copy failed ($src), skipped"
  else
    err "transcript source not found (${src:-no session_id}), skipped (non-fatal)"
  fi
}

# In-branch dependency guards fire AFTER `started` is journalled, so a bare
# exit would leave the lane reading `running` forever. Journal a terminal
# result (rc 5, the missing-launcher code) so ff-status reads failed instead
# (codex review round 5). The preflight above catches these before any state
# exists; this is the backstop for launch-time-only conditions.
refuse_lane() { # MSG
  err "$1"
  jq -nc --arg k "$KEY" --arg id "$ID" --arg b "$MODEL" \
    '{type:"result",key:$k,id:$id,model:$b,rc:5,artifact:null}' >> "$JOURNAL" 2>/dev/null || true
  exit 5
}

if [ "$DRYRUN" = 1 ]; then
  # the stub must match the model's real envelope so collect can gate it:
  # grok emits {text,stopReason,...} (no is_error); every other model here
  # collects via the claude-style {is_error,result} envelope.
  case "$MODEL" in
    grok) jq -nc '{text:"DRYRUN",stopReason:"EndTurn"}' > "$ART" ;;
    *)    jq -nc '{is_error:false,result:"DRYRUN"}' > "$ART" ;;
  esac
else
  case "$MODEL" in
    glm)
      FW="${FLEETFLOW_FLEET_WORKER:-$HOME/.claude/skills/fleet-worker/scripts/fleet-worker}"
      [ -f "$FW" ] || refuse_lane "fleet-worker launcher not found ($FW)"
      # Refuse a stale launcher when an override is in play: one without the
      # claude-bin-override capability ignores the forwarded var and execs
      # literal `claude`, so the binary the doctor validated is not the one
      # that runs (codex review rounds 4-5). Handshake, not grep - the check
      # lives in _env.sh, shared with ff-doctor's parity row.
      if [ "${FLEETFLOW_CLAUDE_BIN:-claude}" != "claude" ] && ! ff_fw_has_claude_bin_override "$FW"; then
        refuse_lane "fleet-worker at $FW lacks the claude-bin-override capability - the claude override would be silently ignored; re-run install"
      fi
      # env(1) carries the assignments: a ${VAR:+NAME=val} expansion is NOT an
      # assignment prefix (bash parses prefixes before expansion), so without
      # env the expanded NAME=val word execs as a command -> rc 127.
      # FLEET_WORKER_CLAUDE_BIN carries FLEETFLOW_CLAUDE_BIN through to the
      # launcher: fleet-worker execs the claude binary itself, and a hardcoded
      # `claude` there let a doctor validated against the override pass while
      # the spawn failed exit 5 (codex review round 3 - doctor/spawn parity).
      ( cd "$WORKDIR" && \
        env FLEET_WORKER_CONFIG_DIR="$CFGD" \
        FLEET_WORKER_CLAUDE_BIN="${FLEETFLOW_CLAUDE_BIN:-claude}" \
        UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
        ${EFFORT:+FLEET_WORKER_EFFORT="$EFFORT"} \
        bash "$FW" --output-format json --max-turns "$MAX_TURNS" "$(cat "$SENT")" \
      ) > "$ART" 2> "$ERRF" || RC=$?
      ;;
    codex)
      command -v codex >/dev/null || refuse_lane "codex CLI not found"
      ART="$RUNDIR/$ID.last.txt"
      # Scoped git carve-out (ADR-034, supersedes ADR-006's no-commit contract):
      # a worktree's git metadata lives in the MAIN repo's .git, outside the
      # sandbox, so `git commit` needs exactly four write grants - the lane's
      # own worktree metadata (index/HEAD/locks), the append-only object store,
      # the lane branch's ref dir, and its reflog dir. NOTHING ELSE: .git/config
      # (core.hooksPath = code execution), hooks/, refs/heads/main, and other
      # lanes' metadata stay OUTSIDE the cage - granting the whole git dir is
      # the hole ADR-006 documented. Ref+log dirs are per-run (branches are
      # fleetflow/RUN/ID) and pre-created because git will not mkdir through
      # a sandbox boundary it cannot write above.
      CODEX_GIT_GRANTS=()
      if [ "$WORKTREE" = 1 ]; then
        MAINGIT="$(git -C "$REPO" rev-parse --absolute-git-dir)"
        # The metadata dir is ASKED OF GIT, never reconstructed from the lane's
        # basename: git deduplicates worktree names (wt-build, wt-build1, ...),
        # so basename() points a colliding lane at ANOTHER lane's metadata -
        # a cross-lane grant, the exact class these scoped grants exist to
        # prevent (found by codex review, 2026-08-25).
        WTGIT="$(git -C "$WORKDIR" rev-parse --git-dir)"
        REFDIR="$MAINGIT/refs/heads/fleetflow/$RUN"
        LOGDIR="$MAINGIT/logs/refs/heads/fleetflow/$RUN"
        mkdir -p "$REFDIR" "$LOGDIR"
        CODEX_GIT_GRANTS=( --add-dir "$WTGIT" --add-dir "$MAINGIT/objects" --add-dir "$REFDIR" --add-dir "$LOGDIR" )
      fi
      # codex-cli 0.153+: --approve-for-me already implies the workspace-write
      # sandbox and REJECTS an explicit -s ("the argument '--approve-for-me'
      # cannot be used with '--sandbox'", verified 2026-09-04). 0.144 accepted
      # both; passing only --approve-for-me works on both lines.
      ( cd "$WORKDIR" && \
        UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
        codex exec --approve-for-me --ephemeral --color never --json \
          ${CODEX_GIT_GRANTS[@]+"${CODEX_GIT_GRANTS[@]}"} \
          ${CODEX_WINSANDBOX:+-c windows.sandbox="$CODEX_WINSANDBOX"} \
          ${FLEETFLOW_CODEX_MODEL:+-m "$FLEETFLOW_CODEX_MODEL"} \
          ${EFFORT:+-c "model_reasoning_effort=$EFFORT"} \
          ${SCHEMA:+--output-schema "$SCHEMA"} \
          -o "$ART" - < "$SENT" \
      ) > "$RUNDIR/$ID.events.jsonl" 2> "$ERRF" || RC=$?
      ;;
    grok)
      # xAI's Grok Build CLI - a NON-Anthropic worker (own binary + protocol,
      # NOT a claude -p wrapper). Auth is the GROK_DEPLOYMENT_KEY env var, read
      # from the inherited environment - never written to disk or args.
      GROK="${FLEETFLOW_GROK_BIN:-grok}"
      command -v "$GROK" >/dev/null || refuse_lane "grok CLI not found ($GROK)"
      # --always-approve = codex --approve-for-me analog: autonomous tool use, headless.
      # --json-schema takes the schema STRING (not a path) and implies json output,
      # surfacing an already-parsed .structuredOutput field (see ff-collect).
      ( cd "$WORKDIR" && \
        UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
        "$GROK" --prompt-file "$SENT" --output-format json --always-approve \
          --max-turns "$MAX_TURNS" \
          ${FLEETFLOW_GROK_MODEL:+-m "$FLEETFLOW_GROK_MODEL"} \
          ${EFFORT:+--reasoning-effort "$EFFORT"} \
          ${SCHEMA:+--json-schema "$(cat "$SCHEMA")"} \
      ) > "$ART" 2> "$ERRF" || RC=$?
      ;;
    pi)
      # earendil-works Pi (@earendil-works/pi-coding-agent) - one harness
      # fronting 15+ providers, which makes this model the fleet's WILDCARD
      # slot: google (Gemini)/openrouter/deepseek/zai/groq/... are env changes,
      # not new model code. Provider names are pi's own (Gemini = `google`);
      # ff-doctor's pi-auth key map keys on the same names.
      # Posture is GLM-class: NO sandbox, so the cage is the worktree lane +
      # guard preamble; and pi has NO --max-turns equivalent, so bounds are the
      # stall detector + orchestrator wall-clock patience. Headless pi never
      # shows a trust prompt (docs/security.md) - no UAC-style hang risk.
      PI="${FLEETFLOW_PI_BIN:-pi}"
      # -f fallback: bash executes a .cmd shim fine, but its `command -v`/-x
      # tests reject one (no exec bit on NTFS), so a path-shaped FLEETFLOW_PI_BIN
      # is checked for existence instead.
      command -v "$PI" >/dev/null || [ -f "$PI" ] || refuse_lane "pi CLI not found ($PI - set FLEETFLOW_PI_BIN)"
      # fleetflow effort -> pi --thinking (pi also has off/minimal below, xhigh above)
      PI_THINK=""
      case "$EFFORT" in low|medium|high) PI_THINK="$EFFORT" ;; max) PI_THINK="xhigh" ;; esac
      # - prompt via STDIN, never argv: $PI is usually a .cmd shim and cmd.exe
      #   caps the command line at ~8K chars; a guard-preamble packet exceeds it.
      # - --no-extensions/--no-skills: discovery loads behavior OUTSIDE the
      #   cache key's hash - same packet must mean same run.
      # - PI_CODING_AGENT_DIR: per-lane config/session isolation (the analog of
      #   GLM's CLAUDE_CONFIG_DIR). Consequence: ~/.pi/agent/auth.json does NOT
      #   apply - the provider's API key env var is the lane's only auth.
      ( cd "$WORKDIR" && \
        env PI_CODING_AGENT_DIR="$CFGD" \
        UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
        "$PI" -p --mode json --no-extensions --no-skills \
          ${FLEETFLOW_PI_PROVIDER:+--provider "$FLEETFLOW_PI_PROVIDER"} \
          ${FLEETFLOW_PI_MODEL:+--model "$FLEETFLOW_PI_MODEL"} \
          ${PI_THINK:+--thinking "$PI_THINK"} \
        < "$SENT" \
      ) > "$RUNDIR/$ID.events.jsonl" 2> "$ERRF" || RC=$?
      # Distill the event stream into a claude-style envelope so ff-collect's
      # default gate and ff-status's finished-lane reader work UNCHANGED ("one
      # implementation of lane state"). The stream stays on disk as the live
      # stall signal, exactly like codex's. Field mapping (docs/session-format.md):
      # pi usage {input,output,cacheRead,cacheWrite,cost.total} -> claude usage
      # names; stopReason error/aborted (or no assistant reply at all) -> is_error.
      jq -s '
        ([.[] | select(.type=="agent_end")] | last) as $end
        | (($end.messages // []) | map(select(.role=="assistant"))) as $as
        | ($as | last) as $fin
        | ($as | map(.usage // {})) as $us
        | (($fin.content // []) | map(select(.type=="text") | .text) | join("\n")) as $text
        | {is_error: (($fin == null) or ($fin.stopReason == "error") or ($fin.stopReason == "aborted")),
           result: (if $fin == null then "no assistant reply (see events/.err)"
                    else ($fin.errorMessage // $text) end),
           usage: {input_tokens: ($us | map(.input // 0) | add // 0),
                   output_tokens: ($us | map(.output // 0) | add // 0),
                   cache_read_input_tokens: ($us | map(.cacheRead // 0) | add // 0),
                   cache_creation_input_tokens: ($us | map(.cacheWrite // 0) | add // 0)},
           num_turns: ($as | length),
           total_cost_usd: (($us | map(.cost.total // 0) | add // 0) as $c
                            | if $c > 0 then $c else null end),
           modelUsage: (if ($fin.model // "") != ""
                        then {(($fin.provider // "pi") + "/" + $fin.model):
                              {outputTokens: ($us | map(.output // 0) | add // 0)}}
                        else {} end)}
      ' "$RUNDIR/$ID.events.jsonl" > "$ART" 2>> "$ERRF" || { [ "$RC" = 0 ] && RC=10; }
      # an error-flagged envelope must fail the spawn even on a clean exit,
      # or the journal would cache it as a replayable success
      [ "$RC" = 0 ] && [ "$(jq -r '.is_error' "$ART" 2>/dev/null)" = "true" ] && RC=10
      ;;
    sonnet|opus|haiku|fable)
      # CLAUDE_MODEL is the string handed to `claude -p --model` (or, for ACP
      # lanes, ANTHROPIC_MODEL) — the alias in $MODEL must survive untouched
      # for the result journal record below.
      CLAUDE_MODEL="$MODEL"; [ "$MODEL" = "fable" ] && CLAUDE_MODEL="claude-fable-5"
      if [ "$ACP" = 1 ]; then
        command -v raven >/dev/null || refuse_lane "raven CLI not found (--acp needs raven-bus)"
        command -v node  >/dev/null || refuse_lane "node not found (claude-code-acp runs on node)"
        # node + dist/index.js, never the npm bin shim: the harness spawns
        # argv directly (no shell), and Windows' claude-code-acp.cmd shim is
        # not exec-able that way (WinError 2 - found by the P4b smoke).
        ACP_AGENT_JS="${FLEETFLOW_ACP_AGENT_JS:-}"
        if [ -z "$ACP_AGENT_JS" ]; then
          ACP_AGENT_JS="$(npm root -g 2>/dev/null | tr -d '\r')/@zed-industries/claude-code-acp/dist/index.js"
        fi
        [ -f "$ACP_AGENT_JS" ] || refuse_lane "claude-code-acp not found ($ACP_AGENT_JS) - npm i -g @zed-industries/claude-code-acp@0.16.2 or set FLEETFLOW_ACP_AGENT_JS"
        # env -u CLAUDECODE/-u CLAUDE_CODE_ENTRYPOINT: the Claude Agent SDK
        # refuses to nest inside a Claude Code session; a fleet spawned FROM
        # one inherits those vars and every ACP lane dies at session/new.
        # ANTHROPIC_MODEL: the adapter passes no model to the SDK - the env
        # var is the only per-lane model channel.
        # --mode: the harness refuses session/request_permission, so the lane
        # must sit in a non-prompting permission mode or it cannot use tools.
        # Default acceptEdits: the adapter auto-allows file-edit tools; Bash
        # stays gated by the user's allowlist (dontAsk denied Write outright -
        # e2e finding: interactive allowlists never contain Write/Edit rules,
        # so a dontAsk lane cannot build anything). FLEETFLOW_PERMISSION_MODE
        # opts up (bypassPermissions) or down (dontAsk).
        # The packet goes in VERBATIM as --initial-prompt-file (trusted
        # boundary 0); bus messages stay data-framed (raven ADR-003).
        ( cd "$WORKDIR" && \
          env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
            ANTHROPIC_MODEL="$CLAUDE_MODEL" \
            UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
            raven acp --as "$ID@$RUN" \
              --channel "run/$RUN/lane/$ID" --channel "run/$RUN/control" \
              --reply-to "run/$RUN/telemetry" \
              --mode "${FLEETFLOW_PERMISSION_MODE:-acceptEdits}" \
              --initial-prompt-file "$SENT" --cwd "$WORKDIR" \
              -- node "$ACP_AGENT_JS" \
        ) > "$RUNDIR/$ID.acp.log" 2> "$ERRF" || true
        # An ACP lane ends by being REAPED (the adapter never exits on its
        # own), so the harness exit code is lifecycle, not verdict. The
        # verdict is the telemetry: the lane's last acp-reply ending
        # end_turn = success. Distill the claude-style envelope from the bus
        # so ff-collect's gate and ff-status's finished-lane reader work
        # UNCHANGED (one implementation of lane state).
        raven tail --channel "run/$RUN/telemetry" --no-follow --json 2>/dev/null | \
        jq -s --arg sender "$ID@$RUN" '
          [.[] | select(.sender==$sender and .type=="acp-reply")] as $r
          | ($r | last) as $fin
          | {is_error: (($fin == null) or ($fin.body.stop_reason != "end_turn")),
             result: (if $fin == null then "no acp-reply on telemetry (see .acp.log / .err)"
                      else $fin.body.text end),
             num_turns: ($r | length),
             acp: true,
             acp_last_boundary: (if $fin == null then null else $fin.body.boundary end)}
        ' > "$ART" 2>> "$ERRF"
        if [ "$(jq -r '.is_error' "$ART" 2>/dev/null)" = "false" ]; then RC=0; else RC=10; fi
      else
        # Same override the doctor validates (FLEETFLOW_CLAUDE_BIN) - a doctor
        # blessing one binary while spawn executes another is a false green.
        CLAUDEBIN="${FLEETFLOW_CLAUDE_BIN:-claude}"
        command -v "$CLAUDEBIN" >/dev/null || refuse_lane "claude CLI not found ($CLAUDEBIN)"
        ( cd "$WORKDIR" && \
          UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
          "$CLAUDEBIN" -p --model "$CLAUDE_MODEL" --output-format json --max-turns "$MAX_TURNS" \
            --permission-mode "${FLEETFLOW_PERMISSION_MODE:-bypassPermissions}" \
            ${EFFORT:+--settings "$EFF_JSON"} \
          < "$SENT" \
        ) > "$ART" 2> "$ERRF" || RC=$?
      fi
      ;;
  esac
  archive_transcript
fi

jq -nc --arg k "$KEY" --arg id "$ID" --arg b "$MODEL" --arg a "$ART" --argjson rc "$RC" \
  '{type:"result",key:$k,id:$id,model:$b,rc:$rc,artifact:$a}' >> "$JOURNAL"

echo "$ART"
if [ "$RC" -ne 0 ]; then err "worker exited rc=$RC (see $ERRF)"; exit 10; fi
exit 0

}

main "$@"
