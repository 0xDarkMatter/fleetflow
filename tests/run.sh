#!/usr/bin/env bash
# Offline behavioural suite for the fleetflow skill scripts.
# Self-contained: builds a throwaway git repo, exercises spawn/collect/doctor
# via --dry-run (no network, no workers). Exits nonzero on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts"
# heal the runner's own PATH too, or the jq guard below self-skips on hosts
# with a stale env snapshot (the exact failure _env.sh exists to fix)
[ -f "$S/_env.sh" ] && . "$S/_env.sh"
PASS=0; FAILN=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAILN=$((FAILN+1)); echo "  FAIL  $1"; }
check() { # desc, expected-rc, cmd...
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  [ "$got" = "$want" ] && ok "$desc (exit $want)" || bad "$desc: wanted $want got $got"
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable on this platform"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# THE SUITE MUST NEVER TOUCH THE REAL MACHINE-LEVEL STORE. ff-clean archives
# before it removes (ADR-011), so every ff-clean exercise below appends a
# throwaway `rc` run to $FLEETFLOW_HOME/history.jsonl. Left unset that is
# ~/.fleetflow/history.jsonl - the file the machine-wide dashboard renders as
# its history section. Measured 2026-08-12 before this line existed: 81 of 120
# unique runs on the box were test fixtures, and it grew every suite run,
# multiplied by lane count whenever a fleetflow run ran the suite inside its
# own workers. The guard assertion at the end of the file keeps it that way.
export FLEETFLOW_HOME="$TMP/ffhome"
REAL_STORE="${HOME:-}/.fleetflow/history.jsonl"
real_store_size() { [ -f "$REAL_STORE" ] && wc -c < "$REAL_STORE" | tr -d ' \r' || echo 0; }
REAL_STORE_BEFORE="$(real_store_size)"

REPO="$TMP/repo"
mkdir -p "$REPO" && git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
PKT="$TMP/packet.txt"; echo "Do the thing. FINAL REPLY: one line." > "$PKT"

# --- syntax + help ------------------------------------------------------------
for s in ff-spawn.sh ff-collect.sh ff-doctor.sh ff-status.sh ff-run.sh ff-clean.sh ff-import.sh; do
  bash -n "$S/$s" 2>/dev/null && ok "syntax $s" || bad "syntax $s"
  bash "$S/$s" --help 2>/dev/null | grep -q "EXAMPLES" && ok "$s --help has EXAMPLES" || bad "$s --help lacks EXAMPLES"
  check "$s --help exits 0" 0 bash "$S/$s" --help
done

# --- usage validation -----------------------------------------------------------
check "spawn: no args" 2 bash "$S/ff-spawn.sh"
check "spawn: bad model" 2 bash "$S/ff-spawn.sh" --run r1 --id a --model gpt9 --prompt-file "$PKT" --repo "$REPO"
check "spawn: bad run name" 2 bash "$S/ff-spawn.sh" --run "R 1" --id a --model glm --prompt-file "$PKT" --repo "$REPO"
check "spawn: missing prompt file" 2 bash "$S/ff-spawn.sh" --run r1 --id a --model glm --prompt-file "$TMP/nope" --repo "$REPO"
check "collect: no args" 2 bash "$S/ff-collect.sh" --repo "$REPO"
check "doctor: bad flag" 2 bash "$S/ff-doctor.sh" --frobnicate

# --- codex windows.sandbox override (2026-07-27 elevation-hang guard) ------------
# the flag itself can't be exercised offline (no codex binary), so gate the two
# things that CAN rot: the value validation, and the wiring into `codex exec`.
FLEETFLOW_CODEX_WINDOWS_SANDBOX=bogus \
  check "spawn: rejects bad windows-sandbox value" 2 \
  bash "$S/ff-spawn.sh" --run r0 --id ws --model codex --prompt-file "$PKT" --repo "$REPO" --dry-run
FLEETFLOW_CODEX_WINDOWS_SANDBOX=bogus \
  check "spawn: windows-sandbox value ignored for non-codex models" 0 \
  bash "$S/ff-spawn.sh" --run r0 --id ws --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run
grep -q 'windows\.sandbox="\$CODEX_WINSANDBOX"' "$S/ff-spawn.sh" \
  && ok "spawn: windows.sandbox override wired into codex exec" \
  || bad "spawn: windows.sandbox override missing from codex exec"
grep -q 'FLEETFLOW_CODEX_WINDOWS_SANDBOX-unelevated' "$S/ff-spawn.sh" \
  && ok "spawn: windows.sandbox defaults to unelevated" \
  || bad "spawn: windows.sandbox default is not unelevated"

# --- dry-run lifecycle -----------------------------------------------------------
check "spawn: dry-run ok" 0 bash "$S/ff-spawn.sh" --run r1 --id a --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run
[ -f "$REPO/.fleetflow/r1/a.result.json" ] && ok "artifact written" || bad "artifact missing"
[ -f "$REPO/.fleetflow/r1/journal.jsonl" ] && ok "journal exists" || bad "journal missing"
N_STARTED="$(jq -r 'select(.type=="started")|.key' "$REPO/.fleetflow/r1/journal.jsonl" | wc -l)"
N_RESULT="$(jq -r 'select(.type=="result")|.key' "$REPO/.fleetflow/r1/journal.jsonl" | wc -l)"
[ "$N_STARTED" -ge 1 ] && [ "$N_RESULT" -ge 1 ] && ok "journal has started+result" || bad "journal records missing"
grep -q '^v2:' <(jq -r '.key' "$REPO/.fleetflow/r1/journal.jsonl") && ok "keys carry v2: prefix" || bad "key prefix wrong"
grep -qs '^\.fleetflow/$' "$REPO/.git/info/exclude" && ok ".fleetflow gitignored via info/exclude" || bad "info/exclude not updated"
[ -f "$REPO/.fleetflow/r1/main-baseline.txt" ] && ok "escape baseline snapshotted" || bad "baseline missing"
grep -q "relative to cwd" "$REPO/.fleetflow/r1/a.prompt.txt" && ok "guard preamble injected" || bad "guard preamble absent"

# --- prompt-file aliasing guard (incident 2026-08-01, run bkv4) -----------------
# --prompt-file pointing at <rundir>/<id>.prompt.txt - the path ff-spawn writes
# its own effective prompt to - used to truncate the author's packet before
# reading it, launching a worker with a guard preamble and NO TASK while every
# gate downstream still reported success. The packet has no backup anywhere, so
# "left INTACT" is the assertion that actually matters here.
AL_RD="$REPO/.fleetflow/ralias"; mkdir -p "$AL_RD"
ALP="$AL_RD/al.prompt.txt"
echo "PRECIOUS PACKET. FINAL REPLY: one line." > "$ALP"
check "spawn: --prompt-file aliasing the effective-prompt path -> 2" 2 \
  bash "$S/ff-spawn.sh" --run ralias --id al --model sonnet --prompt-file "$ALP" --repo "$REPO" --dry-run
grep -q "PRECIOUS PACKET" "$ALP" \
  && ok "spawn: aliased packet left INTACT (not truncated)" || bad "spawn: aliased packet was DESTROYED"
# a different SPELLING of the same file must be caught too - the check is a
# canonical-path compare, not a string compare
ALRC=0
( cd "$AL_RD" && bash "$S/ff-spawn.sh" --run ralias --id al --model sonnet \
    --prompt-file "./al.prompt.txt" --repo "$REPO" --dry-run ) >/dev/null 2>&1 || ALRC=$?
[ "$ALRC" = "2" ] && ok "spawn: relative spelling of the aliased path also rejected" \
  || bad "spawn: relative aliased path slipped through (rc=$ALRC)"
grep -q "PRECIOUS PACKET" "$ALP" \
  && ok "spawn: packet intact after the relative-path attempt" || bad "spawn: relative attempt destroyed the packet"
# the documented convention (<rundir>/packets/<id>.task.md) still spawns, and its
# body reaches the effective prompt byte-for-byte (trailing newline included -
# the packet is part of the journal's content-hash cache key)
mkdir -p "$AL_RD/packets"; printf 'real task. FINAL REPLY: x\n' > "$AL_RD/packets/al.task.md"
check "spawn: packets/<id>.task.md convention still works" 0 \
  bash "$S/ff-spawn.sh" --run ralias --id al --model sonnet --prompt-file "$AL_RD/packets/al.task.md" --repo "$REPO" --dry-run
grep -q "real task" "$ALP" && ok "spawn: non-colliding packet body reaches the effective prompt" \
  || bad "spawn: packet body missing from effective prompt"
tail -c 26 "$ALP" | cmp -s - "$AL_RD/packets/al.task.md" \
  && ok "spawn: packet appended byte-for-byte" || bad "spawn: packet bytes altered on append"

# resume: identical packet -> cache hit (exit 3); --force -> re-run (exit 0)
check "spawn: cache hit on identical packet" 3 bash "$S/ff-spawn.sh" --run r1 --id a --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run
check "spawn: --force re-runs" 0 bash "$S/ff-spawn.sh" --run r1 --id a --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run --force
echo "changed" >> "$PKT"
check "spawn: changed packet re-runs" 0 bash "$S/ff-spawn.sh" --run r1 --id a --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run

# worktree lane creation
check "spawn: worktree lane" 0 bash "$S/ff-spawn.sh" --run r1 --id lane --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run --worktree
git -C "$REPO" show-ref --verify --quiet refs/heads/fleetflow/r1/lane && ok "lane branch created" || bad "lane branch missing"
[ -d "$REPO/.fleetflow/r1/wt-lane" ] && ok "lane worktree created" || bad "lane worktree missing"

# --- worker heartbeat (stall signal for models with no native stream) ------------
grep -q 'HEARTBEAT' "$REPO/.fleetflow/r1/lane.prompt.txt" \
  && ok "spawn: worktree lane prompt carries HEARTBEAT clause" || bad "spawn: heartbeat clause missing (worktree lane)"
grep -q 'HEARTBEAT' "$REPO/.fleetflow/r1/a.prompt.txt" \
  && bad "spawn: non-worktree lane must NOT get the heartbeat clause" || ok "spawn: non-worktree lane has no heartbeat clause"
echo "step 1: tests" > "$REPO/.fleetflow/r1/wt-lane/.ff-heartbeat"
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="lane")|.live_signal==true' >/dev/null \
  && ok "status: heartbeat file counts as a live signal" || bad "status: heartbeat not counted as live signal"
git -C "$REPO/.fleetflow/r1/wt-lane" status --porcelain 2>/dev/null | grep -q 'ff-heartbeat' \
  && bad "heartbeat file dirties the lane (must be git-excluded)" || ok "heartbeat file is git-excluded (never dirties the lane)"

# --- collect gating ---------------------------------------------------------------
check "collect: dry-run result passes" 0 bash "$S/ff-collect.sh" --run r1 --id a --repo "$REPO"
OUT="$(bash "$S/ff-collect.sh" --run r1 --id a --repo "$REPO" 2>/dev/null)"
[ "$OUT" = "DRYRUN" ] && ok "collect prints final text" || bad "collect text wrong: '$OUT'"
jq -nc '{is_error:true,result:"boom"}' > "$REPO/.fleetflow/r1/bad.result.json"
jq -nc '{type:"result",key:"v2:x",id:"bad",model:"sonnet",rc:0,artifact:"x"}' >> "$REPO/.fleetflow/r1/journal.jsonl"
check "collect: is_error=true fails gate" 10 bash "$S/ff-collect.sh" --run r1 --id bad --repo "$REPO"
check "collect: missing artifact" 3 bash "$S/ff-collect.sh" --run r1 --id ghost --repo "$REPO"
# --- auto-commit on gate pass (opt-in; rookery's auto-commit-on-PASS) ------------
echo "worker output" > "$REPO/.fleetflow/r1/wt-lane/out.txt"
check "collect: --auto-commit still passes gate" 0 bash "$S/ff-collect.sh" --run r1 --id lane --repo "$REPO" --auto-commit
[ -z "$(git -C "$REPO/.fleetflow/r1/wt-lane" status --porcelain 2>/dev/null)" ] \
  && ok "collect: --auto-commit left a clean lane tree" || bad "collect: lane still dirty after --auto-commit"
git -C "$REPO/.fleetflow/r1/wt-lane" log -1 --format=%s 2>/dev/null | grep -q 'auto-commit gated worker output' \
  && ok "collect: auto-commit message shape" || bad "collect: auto-commit message wrong"
# a FAILED gate must never commit (the verdict rule)
# NB: distinct packet - the journal cache keys on (model,prompt,opts), not id,
# so reusing $PKT+--worktree here would cache-hit the "lane" spawn and skip
# worktree creation entirely.
ACP="$TMP/acfail-packet.txt"; echo "acfail task. FINAL REPLY: x" > "$ACP"
bash "$S/ff-spawn.sh" --run r1 --id acfail --model sonnet --prompt-file "$ACP" --repo "$REPO" --dry-run --worktree >/dev/null 2>&1
jq -nc '{is_error:true,result:"boom"}' > "$REPO/.fleetflow/r1/acfail.result.json"
echo "doomed" > "$REPO/.fleetflow/r1/wt-acfail/doomed.txt"
check "collect: --auto-commit failed gate still exits 10" 10 bash "$S/ff-collect.sh" --run r1 --id acfail --repo "$REPO" --auto-commit
git -C "$REPO/.fleetflow/r1/wt-acfail" status --porcelain 2>/dev/null | grep -q 'doomed' \
  && ok "collect: failed gate leaves the dirty tree uncommitted" || bad "collect: failed gate committed (must never)"

# codex-style artifact: last.txt path with schema validation
printf '{"verdict":"ok"}' > "$REPO/.fleetflow/r1/cx.last.txt"
check "collect: codex last-message passes" 0 bash "$S/ff-collect.sh" --run r1 --id cx --repo "$REPO"
check "collect: codex schema-valid JSON" 0 bash "$S/ff-collect.sh" --run r1 --id cx --repo "$REPO" --schema
printf 'not json' > "$REPO/.fleetflow/r1/cx.last.txt"
check "collect: codex schema-invalid fails" 10 bash "$S/ff-collect.sh" --run r1 --id cx --repo "$REPO" --schema

# --- grok model (non-Anthropic worker: grok -p envelope, no is_error) ----------
GKP="$TMP/grok-packet.txt"; echo "grok task. FINAL REPLY: one line." > "$GKP"
# --- ff-spawn --acp (P4b: lanes under the raven-bus ACP harness) -------------
check "spawn: --acp rejects non-claude model" 2 \
  bash "$S/ff-spawn.sh" --run racp --id a1 --model glm --prompt-file "$PKT" --repo "$REPO" --dry-run --acp
check "spawn: --acp rejects --effort" 2 \
  bash "$S/ff-spawn.sh" --run racp --id a1 --model sonnet --effort high --prompt-file "$PKT" --repo "$REPO" --dry-run --acp
check "spawn: --acp dry-run ok" 0 \
  bash "$S/ff-spawn.sh" --run racp --id a1 --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run --acp --worktree
# the clause check must precede the non-acp respawn below: every spawn
# REWRITES <id>.prompt.txt, so the respawn wipes the clause from disk
grep -q 'STEERING:' "$REPO/.fleetflow/racp/a1.prompt.txt" \
  && ok "spawn: --acp lane keeps the steering clause in the effective prompt" \
  || bad "spawn: acp steering clause missing"
# acp is its own cache key: the same packet without --acp must MISS (run live),
# and a repeat with --acp must HIT - and vice versa
check "spawn: --acp repeat is a cache hit" 3 \
  bash "$S/ff-spawn.sh" --run racp --id a1 --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run --acp --worktree
check "spawn: same packet without --acp misses the acp cache" 0 \
  bash "$S/ff-spawn.sh" --run racp --id a1 --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run --worktree
jq -e '.packets[]|select(.id=="a1")|.acp==false' "$REPO/.fleetflow/racp/manifest.json" >/dev/null \
  && ok "manifest upsert records acp=false after the non-acp respawn" || bad "manifest acp flag wrong"
# non-acp claude lanes must never gain the acp key suffix or the clause
bash "$S/ff-spawn.sh" --run racp --id plain --model sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run >/dev/null 2>&1
grep -q 'STEERING:' "$REPO/.fleetflow/racp/plain.prompt.txt" \
  && bad "spawn: steering clause leaked into a non-acp lane" \
  || ok "spawn: steering clause stays acp-only"
jq -r '.packets[]|select(.id=="plain")|.key' "$REPO/.fleetflow/racp/manifest.json" | grep -q . \
  && ok "spawn: non-acp lane still journals a key" || bad "spawn: non-acp key missing"

check "spawn: grok model accepted (dry-run)" 0 bash "$S/ff-spawn.sh" --run rg --id g --model grok --prompt-file "$GKP" --repo "$REPO" --dry-run
jq -e '.text=="DRYRUN" and .stopReason=="EndTurn" and (has("is_error")|not)' "$REPO/.fleetflow/rg/g.result.json" >/dev/null \
  && ok "spawn: grok dry-run stub is a grok envelope (text+stopReason, no is_error)" || bad "spawn: grok stub shape wrong"
jq -e '.packets[]|select(.id=="g")|.model=="grok"' "$REPO/.fleetflow/rg/manifest.json" >/dev/null \
  && ok "manifest records model=grok" || bad "manifest grok model wrong"
check "collect: grok envelope passes gate" 0 bash "$S/ff-collect.sh" --run rg --id g --repo "$REPO"
GOUT="$(bash "$S/ff-collect.sh" --run rg --id g --repo "$REPO" 2>/dev/null)"
[ "$GOUT" = "DRYRUN" ] && ok "collect: grok prints .text" || bad "collect: grok text wrong: '$GOUT'"
# grok --schema lane prefers the already-parsed .structuredOutput
jq -nc '{text:"ignored prose",stopReason:"EndTurn",structuredOutput:{verdict:"ok"}}' > "$REPO/.fleetflow/rg/gs.result.json"
jq -nc '{type:"result",key:"v2:gs",id:"gs",model:"grok",rc:0,artifact:"x"}' >> "$REPO/.fleetflow/rg/journal.jsonl"
GSOUT="$(bash "$S/ff-collect.sh" --run rg --id gs --repo "$REPO" --schema 2>/dev/null)"; GSRC=$?
{ [ "$GSRC" = "0" ] && printf '%s' "$GSOUT" | jq -e '.verdict=="ok"' >/dev/null; } \
  && ok "collect: grok --schema returns structuredOutput" || bad "collect: grok structuredOutput wrong (rc=$GSRC out=$GSOUT)"
# grok schema fallback: no structuredOutput, .text carries fenced JSON
jq -nc '{text:"```json\n{\"verdict\":\"fb\"}\n```",stopReason:"EndTurn"}' > "$REPO/.fleetflow/rg/gf.result.json"
jq -nc '{type:"result",key:"v2:gf",id:"gf",model:"grok",rc:0,artifact:"x"}' >> "$REPO/.fleetflow/rg/journal.jsonl"
GFOUT="$(bash "$S/ff-collect.sh" --run rg --id gf --repo "$REPO" --schema 2>/dev/null)"; GFRC=$?
{ [ "$GFRC" = "0" ] && printf '%s' "$GFOUT" | jq -e '.verdict=="fb"' >/dev/null; } \
  && ok "collect: grok --schema falls back to fenced .text" || bad "collect: grok fallback wrong (rc=$GFRC)"
# grok empty-text envelope fails the gate
jq -nc '{text:"",stopReason:"EndTurn"}' > "$REPO/.fleetflow/rg/ge.result.json"
jq -nc '{type:"result",key:"v2:ge",id:"ge",model:"grok",rc:0,artifact:"x"}' >> "$REPO/.fleetflow/rg/journal.jsonl"
check "collect: grok empty text fails gate" 10 bash "$S/ff-collect.sh" --run rg --id ge --repo "$REPO"
# ff-doctor surfaces a bin-grok structural check
bash "$S/ff-doctor.sh" --offline 2>/dev/null | grep -qE "^bin-grok	(ok|advisory)" \
  && ok "doctor: reports bin-grok check" || bad "doctor: bin-grok check missing"

# --- phases --------------------------------------------------------------------------
check "spawn: --phase accepted" 0 bash "$S/ff-spawn.sh" --run r1 --id ver --model opus --phase verify --prompt-file "$PKT" --repo "$REPO" --dry-run
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.lanes[] | select(.id=="ver") | .phase=="verify"' >/dev/null \
  && ok "status: phase propagates" || bad "status: phase missing"
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.lanes[] | select(.id=="a") | .phase=="build"' >/dev/null \
  && ok "status: default phase is build" || bad "status: default phase wrong"

# --- status feed --------------------------------------------------------------------
check "status: no args" 2 bash "$S/ff-status.sh"
check "status: watch without out" 2 bash "$S/ff-status.sh" --run r1 --repo "$REPO" --watch 3
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.lanes | length >= 2' >/dev/null \
  && ok "status: emits lanes JSON" || bad "status: JSON invalid"
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.lanes[] | select(.id=="a") | .state=="done"' >/dev/null \
  && ok "status: dry-run lane state done" || bad "status: lane state wrong"
[ -f "$HERE/../assets/ff-monitor.html" ] && grep -q "status.json" "$HERE/../assets/ff-monitor.html" \
  && ok "monitor asset present + polls status.json" || bad "monitor asset missing"
# torn-write guard: an empty/missing-lanes payload is treated as a fetch miss
grep -q "torn-write guard" "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: empty-lanes torn-write guard present" || bad "monitor: torn-write guard missing"
grep -q "d.lanes.length === 0" "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: guards on empty lanes array" || bad "monitor: empty-lanes guard logic missing"

# --- escape guard ------------------------------------------------------------------
check "escape guard: clean main" 0 bash "$S/ff-collect.sh" --check-main-clean --run r1 --repo "$REPO"
echo rogue > "$REPO/rogue.txt"
check "escape guard: detects new file" 12 bash "$S/ff-collect.sh" --check-main-clean --run r1 --repo "$REPO"
rm "$REPO/rogue.txt"
check "escape guard: clean again" 0 bash "$S/ff-collect.sh" --check-main-clean --run r1 --repo "$REPO"

# --- doctor (offline only; never hits network) ---------------------------------------
bash "$S/ff-doctor.sh" --offline >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] || [ "$RC" = 10 ] && ok "doctor --offline runs (rc=$RC)" || bad "doctor --offline rc=$RC"
bash "$S/ff-doctor.sh" --offline 2>/dev/null | grep -qE "^bin-jq	ok" && ok "doctor TSV output" || bad "doctor TSV output missing"

# --- manifest (feature 1): created on first spawn, append, idempotent -----------
M="$REPO/.fleetflow/r1/manifest.json"
[ -f "$M" ] && ok "manifest created on first spawn" || bad "manifest not created"
jq -e '.run=="r1" and .base=="main" and (.created_by|startswith("ff-spawn/"))' "$M" >/dev/null \
  && ok "manifest header fields" || bad "manifest header wrong"
# lane 'a' was spawned several times (cache-hit, --force, changed) yet stays 1 entry
NA="$(jq '[.packets[]|select(.id=="a")]|length' "$M")"
[ "$NA" = "1" ] && ok "manifest packet idempotent (one entry per id)" || bad "manifest has $NA 'a' entries"
# every packet carries the Wave-1 fields the brief requires
jq -e '.packets[]|select(.id=="a")|has("effort") and has("key") and has("max_turns") and has("worktree")' "$M" >/dev/null \
  && ok "manifest packet has effort+key+max_turns+worktree" || bad "manifest packet fields missing"
# ff-status surfaces the manifest summary
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.manifest.packet_count >= 1' >/dev/null \
  && ok "status: surfaces manifest.packet_count" || bad "status: manifest summary missing"

# --- ff-run.sh (feature 2): whole-run resume + status alias ---------------------
check "ff-run: no subcommand -> 2" 2 bash "$S/ff-run.sh"
check "ff-run: bad subcommand -> 2" 2 bash "$S/ff-run.sh" frobnicate --run r1 --repo "$REPO"
check "ff-run: resume missing run -> 2" 2 bash "$S/ff-run.sh" resume --run nope --repo "$REPO"
check "ff-run: resume no manifest -> 2" 2 bash "$S/ff-run.sh" resume --run r1 --repo "$TMP"
# fresh run, two DISTINCT packets so replay order is unambiguous
PA="$TMP/r2-a.txt"; echo "do A. FINAL REPLY: a" > "$PA"
PB="$TMP/r2-b.txt"; echo "do B. FINAL REPLY: b" > "$PB"
bash "$S/ff-spawn.sh" --run r2 --id a --model sonnet --prompt-file "$PA" --repo "$REPO" --dry-run >/dev/null 2>&1
bash "$S/ff-spawn.sh" --run r2 --id b --model sonnet --prompt-file "$PB" --repo "$REPO" --dry-run >/dev/null 2>&1
# resume re-spawns both -> both cache-hit -> exit 0; ids return in manifest order
RR="$(bash "$S/ff-run.sh" resume --run r2 --repo "$REPO" 2>/dev/null)"; RC=$?
[ "$RC" = "0" ] && ok "ff-run: all-cached resume exits 0" || bad "ff-run: resume rc=$RC"
printf '%s' "$RR" | jq -e 'length==2 and .[0].id=="a" and .[1].id=="b" and all(.[]; .status=="cached")' >/dev/null \
  && ok "ff-run: resume preserves packet order (no reorder drift)" || bad "ff-run: resume order wrong: $RR"
# status subcommand == ff-status (compare stable fields; generated_at differs by design)
SA="$(bash "$S/ff-run.sh" status --run r2 --repo "$REPO" 2>/dev/null | jq -c '{run,lanes:[.lanes[].id]}')"
SB="$(bash "$S/ff-status.sh" --run r2 --repo "$REPO" 2>/dev/null | jq -c '{run,lanes:[.lanes[].id]}')"
[ "$SA" = "$SB" ] && ok "ff-run status aliases ff-status" || bad "ff-run status != ff-status"

# --- schema fence-strip (feature 3) --------------------------------------------
# a result whose text is fenced JSON must still validate (--schema strips fences)
jq -nc '{is_error:false,result:"```json\n{\"verdict\":\"ok\"}\n```"}' > "$REPO/.fleetflow/r1/fence.result.json"
jq -nc '{type:"result",key:"v2:fence",id:"fence",model:"sonnet",rc:0,artifact:"x"}' >> "$REPO/.fleetflow/r1/journal.jsonl"
FOUT="$(bash "$S/ff-collect.sh" --run r1 --id fence --repo "$REPO" --schema 2>/dev/null)"; FRC=$?
[ "$FRC" = "0" ] && ok "collect: fence-strip lets fenced JSON validate" || bad "collect: fence-strip failed rc=$FRC"
printf '%s' "$FOUT" | jq -e '.verdict=="ok"' >/dev/null && ok "collect: fence-strip returns inner JSON" || bad "collect: fence-strip output wrong"

# --- schema --repair seam (feature 3) ------------------------------------------
# bad result + FLEETFLOW_REPAIR_DRYRUN: do_repair saves <id>.invalid.txt and
# respawns a <id>-repair lane. The dry-run lane replies "DRYRUN" (not JSON), so
# the repair gate fails -> exit 10; we assert the SEAM fired, not a happy path.
jq -nc '{is_error:false,result:"this is not json"}' > "$REPO/.fleetflow/r1/rp.result.json"
jq -nc '{type:"result",key:"v2:rp",id:"rp",model:"sonnet",rc:0,artifact:"x"}' >> "$REPO/.fleetflow/r1/journal.jsonl"
FLEETFLOW_REPAIR_DRYRUN=1 bash "$S/ff-collect.sh" --run r1 --id rp --repo "$REPO" --schema --repair >/dev/null 2>&1; RPRC=$?
[ "$RPRC" = "10" ] && ok "collect: --repair exits 10 when corrected output invalid" || bad "collect: --repair rc=$RPRC (want 10)"
[ -f "$REPO/.fleetflow/r1/rp.invalid.txt" ] && ok "collect: --repair saved <id>.invalid.txt" || bad "collect: invalid.txt missing"
NREP="$(jq -r 'select(.type=="result" and .id=="rp-repair")|.id' "$REPO/.fleetflow/r1/journal.jsonl" | wc -l | tr -d ' ')"
[ "$NREP" -ge 1 ] && ok "collect: --repair respawned rp-repair lane" || bad "collect: no repair lane spawned"
grep -q 'corrected JSON' "$REPO/.fleetflow/r1/rp-repair.prompt-src.txt" 2>/dev/null \
  && ok "collect: --repair lane got the corrective prompt" || bad "collect: repair prompt missing"

# --- brain->model rename: compatibility spine -----------------------------------
# The wire contract renamed brain->model (alias) and model->model_id (resolved).
# Two things must hold forever: the deprecated --brain flag still spawns, and
# PRE-rename journals/archives still read back correctly.
check "spawn: deprecated --brain alias still accepted" 0 \
  bash "$S/ff-spawn.sh" --run rcompat --id al --brain sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run
jq -e '.packets[]|select(.id=="al")|.model=="sonnet"' "$REPO/.fleetflow/rcompat/manifest.json" >/dev/null \
  && ok "spawn: --brain alias writes the new model key" || bad "spawn: alias wrote wrong key"
RDL="$REPO/.fleetflow/rlegacy"; mkdir -p "$RDL"; : > "$RDL/z.prompt.txt"
printf '%s\n' \
  '{"type":"started","key":"v2:z","id":"z","brain":"codex","model":"gpt-5.2-codex","phase":"build","v":"1.2.0"}' \
  '{"type":"result","key":"v2:z","id":"z","brain":"codex","rc":0,"artifact":"x"}' > "$RDL/journal.jsonl"
bash "$S/ff-status.sh" --run rlegacy --repo "$REPO" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="z")|.model=="codex" and .model_id=="gpt-5.2-codex" and .state=="done"' >/dev/null \
  && ok "status: pre-rename journal reads back (brain->model, model->model_id)" \
  || bad "status: legacy journal fallback broken"

# --- FF_VERSION in journal (feature 4) -----------------------------------------
grep -q '"v":"1.2.0"' "$REPO/.fleetflow/r1/journal.jsonl" && ok "journal records FF_VERSION 1.2.0" || bad "journal missing FF_VERSION"
# every operational script pins the same version (version-skew spine)
VS=0
for s in ff-spawn.sh ff-collect.sh ff-status.sh ff-doctor.sh ff-run.sh ff-clean.sh \
         ff-import.sh ff-archive.sh ff-sweep.sh ff-chip.sh; do
  grep -q '^FF_VERSION="1.2.0"$' "$S/$s" || VS=1
done
[ "$VS" = "0" ] && ok "all scripts pin FF_VERSION=1.2.0" || bad "version skew across scripts"
# NTFS transient-lock retry in ff-clean (rookery's load-bearing worktree-remove retry)
grep -q 'retrying in 1s' "$S/ff-clean.sh" \
  && ok "clean: worktree-remove NTFS retry present" || bad "clean: NTFS retry loop missing"

# --- effort lever (feature 5): effort is part of the cache key ------------------
EP="$TMP/effort.txt"; echo "effort test. FINAL REPLY: e" > "$EP"
check "spawn: effort lane first run -> 0" 0 bash "$S/ff-spawn.sh" --run r3 --id e --model sonnet --prompt-file "$EP" --repo "$REPO" --dry-run
check "spawn: effort lane identical -> cached" 3 bash "$S/ff-spawn.sh" --run r3 --id e --model sonnet --prompt-file "$EP" --repo "$REPO" --dry-run
# changing ONLY the effort must bust the cache (effort is baked into the OPTS key)
check "spawn: effort change -> cache miss" 0 bash "$S/ff-spawn.sh" --run r3 --id e --model sonnet --prompt-file "$EP" --repo "$REPO" --dry-run --effort high
jq -e '.packets[]|select(.id=="e")|.effort=="high"' "$REPO/.fleetflow/r3/manifest.json" >/dev/null \
  && ok "manifest records effort=high" || bad "manifest effort field wrong"

# --- cache/tmp redirect (feature 7) --------------------------------------------
CRT="$TMP/ffcache"; CDP="$TMP/cdp.txt"; echo "cache test. FINAL REPLY: c" > "$CDP"
FLEETFLOW_CACHE_ROOT="$CRT" bash "$S/ff-spawn.sh" --run r4 --id c --model sonnet --prompt-file "$CDP" --repo "$REPO" --dry-run >/dev/null 2>&1
[ -d "$CRT/r4-c" ] && ok "spawn: cache dir created under FLEETFLOW_CACHE_ROOT" || bad "spawn: cache dir not redirected to FLEETFLOW_CACHE_ROOT"

# --- ff-clean.sh (feature 8): autoclean lanes + cache --------------------------
check "ff-clean: usage -> 2" 2 bash "$S/ff-clean.sh"
check "ff-clean: no such run -> 2" 2 bash "$S/ff-clean.sh" --run ghost --repo "$REPO"
# fresh run, cache redirected, three DISTINCT-prompt worktree lanes (distinct so
# they don't cache-hit and skip worktree creation)
CLEANROOT="$TMP/cleancache"
for lid in cleanlane keeplane dirtlane; do
  echo "clean-$lid task. FINAL REPLY: $lid" > "$TMP/clean-$lid.txt"
  FLEETFLOW_CACHE_ROOT="$CLEANROOT" bash "$S/ff-spawn.sh" --run rc --id "$lid" --model sonnet \
    --prompt-file "$TMP/clean-$lid.txt" --repo "$REPO" --dry-run --worktree >/dev/null 2>&1
done
# keeplane gets a real commit (must survive every clean); dirtlane gets untracked junk
( cd "$REPO/.fleetflow/rc/wt-keeplane" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "real work" )
echo "junk" > "$REPO/.fleetflow/rc/wt-dirtlane/junk.txt"
[ -d "$CLEANROOT/rc-cleanlane" ] && ok "ff-clean: setup created cache dir" || bad "ff-clean: setup cache dir missing"
# no --force: cleanlane removed, dirtlane kept (dirty), keeplane kept (1 commit).
# pass the SAME FLEETFLOW_CACHE_ROOT to ff-clean so it finds the redirected dirs.
CL="$(FLEETFLOW_CACHE_ROOT="$CLEANROOT" bash "$S/ff-clean.sh" --run rc --repo "$REPO" 2>/dev/null)"
printf '%s' "$CL" | awk -F'\t' '$1=="cleanlane"&&$2=="removed"{f=1} END{exit !f}' && ok "ff-clean: removes zero-commit clean lane" || bad "ff-clean: clean lane not removed"
printf '%s' "$CL" | awk -F'\t' '$1=="dirtlane"&&$2=="kept"&&$3~/dirty/{f=1} END{exit !f}' && ok "ff-clean: keeps dirty zero-commit lane (no --force)" || bad "ff-clean: dirty lane mishandled"
printf '%s' "$CL" | awk -F'\t' '$1=="keeplane"&&$2=="kept"&&$3~/1 commits/{f=1} END{exit !f}' && ok "ff-clean: keeps committed lane" || bad "ff-clean: committed lane mishandled"
[ -d "$REPO/.fleetflow/rc/wt-cleanlane" ] && bad "ff-clean: clean worktree dir remains" || ok "ff-clean: clean worktree removed"
git -C "$REPO" show-ref --verify --quiet refs/heads/fleetflow/rc/keeplane && ok "ff-clean: committed branch preserved" || bad "ff-clean: keeper branch deleted"
# --force: dirtlane now removed; keeplane STILL kept (committed lanes are never force-removed)
CL2="$(FLEETFLOW_CACHE_ROOT="$CLEANROOT" bash "$S/ff-clean.sh" --run rc --repo "$REPO" --force 2>/dev/null)"
printf '%s' "$CL2" | awk -F'\t' '$1=="dirtlane"&&$2=="removed"{f=1} END{exit !f}' && ok "ff-clean: --force removes dirty zero-commit lane" || bad "ff-clean: --force dirty mishandled"
printf '%s' "$CL2" | awk -F'\t' '$1=="keeplane"&&$2=="kept"{f=1} END{exit !f}' && ok "ff-clean: --force still keeps committed lane" || bad "ff-clean: --force removed committed lane!"
[ -d "$CLEANROOT/rc-cleanlane" ] || [ -d "$CLEANROOT/rc-dirtlane" ] || [ -d "$CLEANROOT/rc-keeplane" ] \
  && bad "ff-clean: cache dir remains" || ok "ff-clean: cache dirs removed"

# --- state derivation (feature C): last journal record wins -----------------------
# a respawn appends "started" AFTER an old "result" -> the lane is running again,
# NOT done/failed (the last-result-wins bug this fixes).
RD5="$REPO/.fleetflow/r5"; mkdir -p "$RD5"
: > "$RD5/z.prompt.txt"   # mtime source for elapsed
printf '%s\n' \
  '{"type":"started","key":"v2:z","id":"z","model":"sonnet","phase":"build","v":"1.2.0"}' \
  '{"type":"result","key":"v2:z","id":"z","model":"sonnet","rc":0,"artifact":"x"}' \
  '{"type":"started","key":"v2:z","id":"z","model":"sonnet","phase":"build","v":"1.2.0"}' \
  > "$RD5/journal.jsonl"
bash "$S/ff-status.sh" --run r5 --repo "$REPO" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="z")|.state=="running"' >/dev/null \
  && ok "status: respawned lane (started,result,started) is running" || bad "status: respawned lane state wrong"
# regression guard: same lane with result-last is still done (common path unchanged)
printf '%s\n' \
  '{"type":"started","key":"v2:z","id":"z","model":"sonnet","phase":"build","v":"1.2.0"}' \
  '{"type":"result","key":"v2:z","id":"z","model":"sonnet","rc":0,"artifact":"x"}' \
  > "$RD5/journal.jsonl"
bash "$S/ff-status.sh" --run r5 --repo "$REPO" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="z")|.state=="done"' >/dev/null \
  && ok "status: result-last lane is still done (no regression)" || bad "status: result-last state wrong"

# --- stall detection (2026-07-27 incident: 2.7h hang reported as running) --------
# Two lanes spawned at the same instant; only one is still writing. elapsed_s
# cannot tell them apart - last_activity_s must.
check "status: rejects non-integer FLEETFLOW_STALL_SECONDS" 2 \
  env FLEETFLOW_STALL_SECONDS=abc bash "$S/ff-status.sh" --run r5 --repo "$REPO"
bash "$S/ff-status.sh" --run r5 --repo "$REPO" 2>/dev/null \
  | jq -e '.lanes[]|has("last_activity_s") and has("stalled")' >/dev/null \
  && ok "status: every lane carries last_activity_s + stalled" || bad "status: stall fields missing"
bash "$S/ff-status.sh" --run r5 --repo "$REPO" 2>/dev/null | jq -e '.stall_seconds==600' >/dev/null \
  && ok "status: default stall threshold is 600s" || bad "status: stall_seconds default wrong"

NOWS="$(date +%s)"
if touch -d "@$NOWS" "$TMP/.touchprobe" 2>/dev/null; then
  RD6="$REPO/.fleetflow/r6"; mkdir -p "$RD6"
  printf '%s\n' \
    '{"type":"started","key":"v2:w","id":"wedged","model":"codex","phase":"build","v":"1.2.0"}' \
    '{"type":"started","key":"v2:v","id":"livewire","model":"codex","phase":"build","v":"1.2.0"}' \
    > "$RD6/journal.jsonl"
  : > "$RD6/wedged.prompt.txt"; : > "$RD6/livewire.prompt.txt"
  EV='{"type":"item.completed","item":{"type":"command_execution","command":"ls"}}'
  echo "$EV" > "$RD6/wedged.events.jsonl"; echo "$EV" > "$RD6/livewire.events.jsonl"
  # both spawned 2.7h ago; wedged went silent 160s in, livewire is writing now
  touch -d "@$((NOWS-9720))" "$RD6/wedged.prompt.txt" "$RD6/livewire.prompt.txt"
  touch -d "@$((NOWS-9560))" "$RD6/wedged.events.jsonl"
  ST6="$(bash "$S/ff-status.sh" --run r6 --repo "$REPO" 2>/dev/null)"
  printf '%s' "$ST6" | jq -e '.lanes[]|select(.id=="wedged")|.state=="stalled" and .stalled==true' >/dev/null \
    && ok "status: silent running lane reports stalled" || bad "status: silent lane not stalled"
  printf '%s' "$ST6" | jq -e '.lanes[]|select(.id=="wedged")|.last_activity_s>9000 and .last_activity_s<10000' >/dev/null \
    && ok "status: stalled lane last_activity_s tracks the silence, not elapsed" \
    || bad "status: stalled last_activity_s wrong"
  printf '%s' "$ST6" | jq -e '.lanes[]|select(.id=="livewire")|.state=="running" and .stalled==false and .last_activity_s<120' >/dev/null \
    && ok "status: same-age lane still writing stays running" || bad "status: live lane misreported"
  # threshold is honoured in both directions
  FLEETFLOW_STALL_SECONDS=99999 bash "$S/ff-status.sh" --run r6 --repo "$REPO" 2>/dev/null \
    | jq -e '.lanes[]|select(.id=="wedged")|.state=="running"' >/dev/null \
    && ok "status: raised threshold un-stalls the lane" || bad "status: threshold not honoured (raise)"
  FLEETFLOW_STALL_SECONDS=1 bash "$S/ff-status.sh" --run r6 --repo "$REPO" 2>/dev/null \
    | jq -e '[.lanes[]|select(.stalled)]|length==2' >/dev/null \
    && ok "status: lowered threshold stalls both lanes" || bad "status: threshold not honoured (lower)"
  # a finished lane is never stalled, however long it has been silent
  FLEETFLOW_STALL_SECONDS=1 bash "$S/ff-status.sh" --run r5 --repo "$REPO" 2>/dev/null \
    | jq -e '.lanes[]|select(.id=="z")|.state=="done" and .stalled==false' >/dev/null \
    && ok "status: done lane never stalls" || bad "status: done lane wrongly stalled"

  # --- no live stream => no verdict (the false-positive guard) -------------------
  # A model whose artifact/stderr are created at launch and untouched until exit
  # (grok --output-format json; any claude lane whose transcript we can't locate)
  # looks silent from birth. Flagging that stalled would condemn every healthy
  # long lane, so those report live_signal=false and are never stalled.
  RD7="$REPO/.fleetflow/r7"; mkdir -p "$RD7/wt-son"
  printf '%s\n' \
    '{"type":"started","key":"v2:s","id":"son","model":"sonnet","phase":"build","v":"1.2.0"}' \
    '{"type":"started","key":"v2:g","id":"grk","model":"grok","phase":"build","v":"1.2.0"}' \
    > "$RD7/journal.jsonl"
  for lid in son grk; do : > "$RD7/$lid.prompt.txt"; : > "$RD7/$lid.err"; : > "$RD7/$lid.result.json"; done
  touch -d "@$((NOWS-1200))" "$RD7"/son.* "$RD7"/grk.*
  # HOME is redirected so the host-transcript lookup can't reach the real one
  ST7="$(HOME="$TMP/fakehome" bash "$S/ff-status.sh" --run r7 --repo "$REPO" 2>/dev/null)"
  printf '%s' "$ST7" | jq -e '.lanes[]|select(.id=="grk")|.state=="running" and .stalled==false and .live_signal==false' >/dev/null \
    && ok "status: grok lane with no live stream never stalls" || bad "status: grok lane false-stalled"
  printf '%s' "$ST7" | jq -e '.lanes[]|select(.id=="son")|.state=="running" and .live_signal==false' >/dev/null \
    && ok "status: unlocatable claude transcript reports live_signal=false" \
    || bad "status: claude lane without transcript misreported"
  printf '%s' "$ST7" | jq -e '.lanes[]|select(.id=="son")|.last_activity_s>1000' >/dev/null \
    && ok "status: uncovered lane still reports last_activity_s" || bad "status: last_activity_s not reported"

  # a worktree'd claude lane IS covered: its host transcript is unambiguous
  ENC="$(printf '%s' "$RD7/wt-son" | sed 's#[:\\/.]#-#g')"
  mkdir -p "$TMP/fakehome/.claude/projects/$ENC"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}\n' \
    > "$TMP/fakehome/.claude/projects/$ENC/sess.jsonl"
  HOME="$TMP/fakehome" bash "$S/ff-status.sh" --run r7 --repo "$REPO" 2>/dev/null \
    | jq -e '.lanes[]|select(.id=="son")|.live_signal==true and .stalled==false and .activity=="live: Edit"' >/dev/null \
    && ok "status: worktree claude lane picks up its live host transcript" \
    || bad "status: host transcript lookup failed"
  touch -d "@$((NOWS-1200))" "$TMP/fakehome/.claude/projects/$ENC/sess.jsonl"
  HOME="$TMP/fakehome" bash "$S/ff-status.sh" --run r7 --repo "$REPO" 2>/dev/null \
    | jq -e '.lanes[]|select(.id=="son")|.state=="stalled" and .stalled==true' >/dev/null \
    && ok "status: silent claude transcript does stall" || bad "status: silent claude lane not stalled"
else
  echo "  SKIP  stall detection (touch -d @epoch unsupported here)"
fi
# --- --exit-stalled: a watchdog exit code, never a change to the data ----------
check "status: --exit-stalled exits 0 when nothing is stalled" 0 \
  bash "$S/ff-status.sh" --run r1 --repo "$REPO" --exit-stalled
if touch -d "@$NOWS" "$TMP/.touchprobe" 2>/dev/null; then
  check "status: --exit-stalled exits 14 on a stalled lane" 14 \
    bash "$S/ff-status.sh" --run r6 --repo "$REPO" --exit-stalled
  SO="$(bash "$S/ff-status.sh" --run r6 --repo "$REPO" --exit-stalled 2>/dev/null)"
  printf '%s' "$SO" | jq -e '.lanes|length==2' >/dev/null \
    && ok "status: --exit-stalled still emits the full JSON" || bad "status: --exit-stalled ate the data"
fi

# --- abandonment (ADR-025): hours of total silence demote an in-flight lane ----
check "status: rejects non-integer FLEETFLOW_ABANDON_SECONDS" 2 \
  env FLEETFLOW_ABANDON_SECONDS=abc bash "$S/ff-status.sh" --run r5 --repo "$REPO"
bash "$S/ff-status.sh" --run r5 --repo "$REPO" 2>/dev/null | jq -e '.abandon_seconds==21600' >/dev/null \
  && ok "status: default abandonment threshold is 21600s (6h)" \
  || bad "status: abandon_seconds default wrong"
# a finished lane is never abandoned, however long ago it finished
FLEETFLOW_ABANDON_SECONDS=1 bash "$S/ff-status.sh" --run r5 --repo "$REPO" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="z")|.state=="done"' >/dev/null \
  && ok "status: done lane never abandons" || bad "status: done lane wrongly abandoned"
if touch -d "@$NOWS" "$TMP/.touchprobe" 2>/dev/null; then
  # r6 wedged (2.7h silent, live stream): under the 6h default it is STALLED, not
  # abandoned - the two thresholds are independent verdicts.
  bash "$S/ff-status.sh" --run r6 --repo "$REPO" 2>/dev/null \
    | jq -e '.lanes[]|select(.id=="wedged")|.state=="stalled"' >/dev/null \
    && ok "status: silence under the abandon threshold stays stalled" \
    || bad "status: stalled lane demoted too early"
  # past the threshold a stalled lane demotes to abandoned; state carries the
  # verdict, so the stalled flag drops with it
  FLEETFLOW_ABANDON_SECONDS=100 bash "$S/ff-status.sh" --run r6 --repo "$REPO" 2>/dev/null \
    | jq -e '.lanes[]|select(.id=="wedged")|.state=="abandoned" and .stalled==false' >/dev/null \
    && ok "status: stalled lane past the abandon threshold reads abandoned" \
    || bad "status: stalled lane not demoted to abandoned"
  # a lane still writing NEVER abandons, whatever the threshold
  FLEETFLOW_ABANDON_SECONDS=100 bash "$S/ff-status.sh" --run r6 --repo "$REPO" 2>/dev/null \
    | jq -e '.lanes[]|select(.id=="livewire")|.state=="running"' >/dev/null \
    && ok "status: live lane never abandons" || bad "status: live lane wrongly abandoned"
  # THE key new capability: abandonment applies even where live_signal=false -
  # lanes the stall detector can never cover (grok, non-worktree claude) finally
  # get a terminal verdict instead of reading running forever (ADR-025).
  HOME="$TMP/fakehome" FLEETFLOW_ABANDON_SECONDS=1000 bash "$S/ff-status.sh" --run r7 --repo "$REPO" 2>/dev/null \
    | jq -e '.lanes[]|select(.id=="grk")|.state=="abandoned" and .live_signal==false' >/dev/null \
    && ok "status: uncovered (live_signal=false) lane abandons past the threshold" \
    || bad "status: uncovered lane still running past the abandon threshold"
  # an abandonment demotion trips the --exit-stalled watchdog: for uncovered
  # lanes it is the FIRST silence verdict a watchdog can ever get
  check "status: --exit-stalled exits 14 on an abandoned lane" 14 \
    env FLEETFLOW_ABANDON_SECONDS=100 bash "$S/ff-status.sh" --run r6 --repo "$REPO" --exit-stalled
else
  echo "  SKIP  abandonment demotion (touch -d @epoch unsupported here)"
fi

# --- reap anchors (ff-spawn proc records + ff-clean --reap) --------------------
jq -e 'select(.type=="proc" and .id=="a") | has("pid") and has("winpid") and has("at")' \
  "$REPO/.fleetflow/r1/journal.jsonl" >/dev/null 2>&1 \
  && ok "spawn: journals a proc reap anchor" || bad "spawn: no proc reap anchor"
# the proc record must not hijack state derivation (it is not state-bearing)
RD8="$REPO/.fleetflow/r8"; mkdir -p "$RD8"; : > "$RD8/z.prompt.txt"
printf '%s\n' \
  '{"type":"started","key":"v2:z","id":"z","model":"sonnet","phase":"build","v":"1.2.0"}' \
  '{"type":"proc","id":"z","model":"sonnet","pid":1,"winpid":2,"at":1}' \
  '{"type":"result","key":"v2:z","id":"z","model":"sonnet","rc":0,"artifact":"x"}' \
  '{"type":"proc","id":"z","model":"sonnet","pid":3,"winpid":4,"at":2}' > "$RD8/journal.jsonl"
bash "$S/ff-status.sh" --run r8 --repo "$REPO" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="z")|.state=="done"' >/dev/null \
  && ok "status: trailing proc record does not hijack lane state" \
  || bad "status: proc record broke state derivation"
check "clean: --reap on a run with no anchors is a no-op, not an error" 0 \
  bash "$S/ff-clean.sh" --run r8 --repo "$REPO" --reap
grep -q 'join \[char\]9' "$S/ff-clean.sh" \
  && ok "clean: reap emits TSV via [char]9 (PS single quotes eat backtick-t)" \
  || bad "clean: reap tab emission is escape-fragile"

# --- ff-doctor windows.sandbox tripwire ---------------------------------------
grep -q 'codex debug prompt-input' "$S/ff-doctor.sh" \
  && ok "doctor: sandbox tripwire uses the config-only probe" \
  || bad "doctor: tripwire probe missing"
# code lines only - the guard comment names `codex sandbox` to explain the ban
grep -vE '^[[:space:]]*#' "$S/ff-doctor.sh" | grep -q 'codex sandbox' \
  && bad "doctor: must NOT invoke codex sandbox (provisioning is machine-global)" \
  || ok "doctor: never provisions a sandbox"
bash "$S/ff-doctor.sh" --offline 2>/dev/null | grep -qE "^codex-winsandbox-mode	(ok|advisory)" \
  && ok "doctor: reports which windows.sandbox mode lanes will get" \
  || echo "  SKIP  doctor: winsandbox-mode check (non-Windows host)"

# monitor renders stalled distinctly from running
grep -q '\.sq\.stalled' "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: stalled pip has its own style" || bad "monitor: stalled pip style missing"
grep -q 'l\.stalled' "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: renders the stalled flag" || bad "monitor: stalled flag unused"
grep -q 'inflight' "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: stalled lanes excluded from the finished tally" \
  || bad "monitor: stalled lanes counted as finished"

# monitor: tethered header + sort/size controls
grep -q 'position:sticky' "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: run header is tethered (sticky)" || bad "monitor: sticky header missing"
grep -q '"ff.sort"' "$HERE/../assets/ff-monitor.html" \
  && grep -q '|| "active"' "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: sort control defaults to active-first" \
  || bad "monitor: active-first sort default missing"
grep -q 'STATE_RANK' "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: active sort ranks running before stalled/failed/done" \
  || bad "monitor: state-rank sort missing"
grep -q 'data-size="s"' "$HERE/../assets/ff-monitor.html" \
  && grep -q '"ff.size"' "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: card-size control present + persisted" \
  || bad "monitor: card-size control missing"

# --- abandoned state (ADR-025): every surface renders it, ranks stay in step ----
# STATE_RANK has FIVE hand-synced copies (ff-aggregate.py, ff-widget.sh jq,
# dashboard sort, monitor sort, plus ff-status's implicit derivation order);
# pin the abandoned slot in each so they cannot drift apart silently.
grep -q '"stalled", "running", "failed", "abandoned", "done", "unknown"' "$S/ff-aggregate.py" \
  && ok "aggregate: STATE_RANK carries abandoned between failed and done" \
  || bad "aggregate: STATE_RANK missing abandoned"
grep -q '"stalled","running","failed","abandoned","done"' "$S/ff-widget.sh" \
  && ok "widget: jq rank carries abandoned" || bad "widget: jq rank missing abandoned"
grep -q '\.sq\.abandoned' "$HERE/../assets/ff-monitor.html" \
  && grep -q 'abandoned:3' "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: abandoned pip styled + ranked" || bad "monitor: abandoned state missing"

# --- dashboard: polish invariants -----------------------------------------------
DASH="$HERE/../assets/ff-dashboard.html"
# The zero-dependency rule IS the dashboard's architecture - one external URL
# would break file:// use, offline use, and the preview pane. Guard it here so a
# well-meaning CDN link cannot land quietly. Matches only real REFERENCES
# (src=/href=/url()/@import); the file also names a CDN inside a provenance
# comment, which is prose about where four SVG paths were copied from and is
# deliberately not a fetch.
grep -qE '(src|href)="https?://|url\(["'"'"']?https?://|@import' "$DASH" \
  && bad "dashboard: external asset reference introduced" \
  || ok "dashboard: still zero external dependencies"
grep -q 'rel="icon"' "$DASH" \
  && ok "dashboard: inline favicon present (no /favicon.ico 404)" \
  || bad "dashboard: favicon missing"
# The repaint suppressor: without it the pane is rebuilt every 3s and eats the
# page scroll offset and any keyboard focus inside it.
grep -q 'function paint' "$DASH" && grep -q 'lastHTML' "$DASH" \
  && ok "dashboard: paint() suppresses no-op repaints" \
  || bad "dashboard: repaint suppressor missing"
grep -q 'preventScroll' "$DASH" \
  && ok "dashboard: focus restored across a repaint" || bad "dashboard: focus restore missing"
# ff-monitor also stores "ff.sort" with a DISJOINT value set; served from one
# origin the two silently overwrite each other.
grep -q 'const LS = k => "ffd\.' "$DASH" \
  && ok "dashboard: localStorage namespaced away from ff-monitor" \
  || bad "dashboard: localStorage key collision with monitor"
# The history section's toggle key must be the literal the guards read
# (`__history__`) — it now flows through the navSection helper, so assert the
# call site rather than the rendered attribute.
grep -q 'navSection("__history__"' "$DASH" \
  && ok "dashboard: history toggle key matches its guard" \
  || bad "dashboard: history toggle key mismatch (group will not fold)"
# Accordion sections reuse the repo-group fold contract (shared collapsed set)
grep -q 'const navSection' "$DASH" && grep -q 'navSection("__projects__"' "$DASH" \
  && ok "dashboard: nav is sectioned (live/projects/history accordions)" \
  || bad "dashboard: nav accordion sections missing"
grep -q 'caret\[data-card\]' "$DASH" \
  && ok "dashboard: per-card caret is bound" || bad "dashboard: caret rendered but unbound"
# The sparkline must render BEFORE <div class="body">, or collapsing a card
# blanks the chart - which is exactly the signal collapse is meant to preserve.
python - "$DASH" <<'PY' && ok "dashboard: sparkline survives card collapse (outside .body)" \
  || bad "dashboard: sparkline is inside .body - collapse would hide every chart"
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
card = s[s.index("function laneCard"):]
card = card[:card.index("\nfunction ")]
spark, body = card.index("sparkline(l.density"), card.index('<div class="body">')
sys.exit(0 if spark < body else 1)
PY
grep -q -- '--run-rgb' "$DASH" \
  && ok "dashboard: halo keyframe follows the theme" || bad "dashboard: hard-coded halo colour"
grep -q 'PAL_DARK' "$DASH" && grep -q 'DARK.matches' "$DASH" \
  && ok "dashboard: model/repo palettes have dark variants" \
  || bad "dashboard: palettes are light-only"
grep -q '\.mix {' "$DASH" \
  && bad "dashboard: dead .mix CSS is back" || ok "dashboard: no dead .mix CSS"
# abandoned (ADR-025): faded amber, NEVER animated, never counted in flight -
# and its rank matches ff-aggregate.py's STATE_RANK.
grep -q '\.sq\.abandoned' "$DASH" \
  && ok "dashboard: abandoned pip has its own style" || bad "dashboard: abandoned pip style missing"
grep -q '"abandoned","abandoned"' "$DASH" \
  && ok "dashboard: abandoned state chip filterable" || bad "dashboard: abandoned missing from STATES"
grep -q 'abandoned:3, done:4' "$DASH" \
  && ok "dashboard: sort rank carries abandoned in the STATE_RANK slot" \
  || bad "dashboard: sort rank out of step with ff-aggregate STATE_RANK"
grep -q 's === "running" || s === "stalled"' "$DASH" \
  && ok "dashboard: abandoned is NOT in flight (inflight stays running|stalled)" \
  || bad "dashboard: inflight definition changed - abandoned must stay out of it"

# --- time-window lens (reporting granularity) -------------------------------------
# The window filters every view and roll-up; selection persists under ffd.*
# (ADR-013 - the monitor owns ff.*); weeks start MONDAY; the custom range is an
# in-page control, never a native prompt() (both bans test-enforced elsewhere).
grep -q '"ffd.window"' "$DASH" && grep -q '"ffd.winFrom"' "$DASH" \
  && ok "dashboard: time window persisted under ffd.* keys" \
  || bad "dashboard: time window keys missing or mis-namespaced"
grep -q '"thisquarter"' "$DASH" && grep -q '"lastweek"' "$DASH" && grep -q '"custom"' "$DASH" \
  && ok "dashboard: week/month/quarter/custom windows present" \
  || bad "dashboard: window options missing"
grep -q 'getDay() + 6) % 7' "$DASH" \
  && ok "dashboard: weeks start Monday" || bad "dashboard: Monday week-start math missing"
grep -q 'id="winfrom"' "$DASH" && grep -q 'id="winto"' "$DASH" \
  && ok "dashboard: custom range is an in-page control" \
  || bad "dashboard: custom range inputs missing"
# the lens is applied ONCE, upstream of every render path
grep -q 'doc = windowDoc(rawDoc)' "$DASH" \
  && ok "dashboard: window lens applied upstream of all views" \
  || bad "dashboard: windowDoc not wired into render()"
# blend pools must stay window-independent or a month's blended costs stop
# summing to the fee (see computePlanPools's guard comment)
grep -q 'rawDoc.runs || \[\]' "$DASH" \
  && ok "dashboard: plan-blend pools read the unfiltered document" \
  || bad "dashboard: plan pools follow the window - blended costs now lie"

# --- dashboard: fleet inventory view --------------------------------------------
grep -q 'const HARNESS' "$DASH" && grep -q 'function fleetView' "$DASH" \
  && ok "dashboard: fleet view present" || bad "dashboard: fleet view missing"
grep -q 'data-k="fleet"' "$DASH" \
  && ok "dashboard: fleet entry pinned in the nav" || bad "dashboard: fleet nav entry missing"
# Below 900px the sidebar is a CLOSED drawer, so the pinned nav row is not a
# reachable entry point - without an always-visible top-bar button the capacity
# view is invisible in a preview pane and reads as never built.
grep -q 'id="fleetbtn"' "$DASH" && grep -q '\.topbtn {' "$DASH" \
  && ok "dashboard: fleet reachable from the top bar at any width" \
  || bad "dashboard: fleet unreachable when the sidebar is a drawer"
# Every wide table scrolls inside its own box; the page body never scrolls
# sideways (a 7-column table used to drag the whole layout with it).
[ "$(grep -c '<div class="tablewrap">' "$DASH")" = "$(grep -c 'class="hist mono"' "$DASH")" ] \
  && ok "dashboard: every wide table is scroll-wrapped" \
  || bad "dashboard: an unwrapped table will scroll the page body"
grep -q 'h:" + h.k' "$DASH" \
  && ok "fleet view: harness cards collapse (namespaced off lane ids)" \
  || bad "fleet view: harness cards not collapsible"
grep -q 'function distBars' "$DASH" \
  && ok "fleet view: harness cards carry a token-distribution chart" \
  || bad "fleet view: harness cards have no chart"
# worktree_state is a TRI-state and the card must render all three: collapsing
# `reclaimed` (landed/cleaned - normal) into `none` (never had one - less
# isolation, no stall attribution) states the wrong one about a healthy run.
grep -q 'function worktreeLine' "$DASH" \
  && grep -q '"reclaimed"' "$DASH" && grep -q 'worktree_state' "$DASH" \
  && ok "dashboard: lane card distinguishes reclaimed from never-had-a-worktree" \
  || bad "dashboard: worktree tri-state collapsed back to two"
# ff-status can only count commits while the worktree directory exists, so on a
# reclaimed or never-had-one lane `commits:0` means UNMEASURED. The chip must be
# gated on that, not rendered unconditionally - an ungated chip tells the majority
# of a healthy fleet's lanes that they produced nothing.
grep -q 'const measuredCommits' "$DASH" \
  && grep -q 'measuredCommits(l) ? chip("git"' "$DASH" \
  && ok "dashboard: commits chip gated on a real measurement" \
  || bad "dashboard: commits chip asserts 0 where nothing was measured"
grep -q 'const PAGE_BUILD' "$DASH" && grep -q 'getElementById("build")' "$DASH" \
  && ok "dashboard: build marker rendered (stale-tab diagnosis)" \
  || bad "dashboard: no build marker"
# Every model ff-spawn accepts must appear in the capability matrix, or the view
# claims a capacity inventory it does not actually cover.
FLEETMISS=""
for b in glm codex grok pi sonnet opus haiku fable; do
  grep -q "k:\"$b\"" "$DASH" || FLEETMISS="$FLEETMISS $b"
done
[ -z "$FLEETMISS" ] && ok "fleet view covers every spawnable model" \
  || bad "fleet view missing model(s):$FLEETMISS"
grep -q 'pi:.*#1f8a9c' "$DASH" \
  && ok "dashboard: pi model has a palette entry" || bad "dashboard: pi missing from BRAIN"
# A --live probe spends real model calls; it must never be on the poll path.
grep -q 'probeDoctor(false, false)' "$DASH" && grep -q 'probeDoctor(true, true)' "$DASH" \
  && grep -q 'id="ffProbe"' "$DASH" \
  && ok "fleet view: live probe is click-gated, offline is automatic" \
  || bad "fleet view: doctor probe wiring wrong"
# The follow-up poll must stay on the SAME cache slot: re-polling the offline
# slot would silently discard the live verdict it is waiting for.
grep -q 'probeDoctor(live, false)' "$DASH" \
  && ok "fleet view: live probe polls its own slot until it settles" \
  || bad "fleet view: follow-up poll would discard the live verdict"
grep -q 'setInterval.*probeDoctor' "$DASH" \
  && bad "fleet view: live probe on a timer (spends model calls)" \
  || ok "fleet view: no timer-driven capacity probe"

# --- dashboard: pricing registry + cost honesty ---------------------------------
# The self-reported cost column was model-inconsistent (GLM prints an
# Anthropic-rate figure for z.ai traffic; codex/grok print nothing). The
# PRICING registry + per-model basis is the fix; guard its invariants.
grep -q 'const PRICING' "$DASH" && grep -q 'function laneCost' "$DASH" \
  && ok "dashboard: pricing registry + laneCost present" \
  || bad "dashboard: pricing machinery missing"
# every rated model must appear in the registry (rates or explicit null)
PMISS=""
for b in fable opus sonnet haiku glm codex grok pi; do
  grep -qE "^\s+$b:" "$DASH" || PMISS="$PMISS $b"
done
[ -z "$PMISS" ] && ok "pricing: every spawnable model has a registry entry" \
  || bad "pricing: registry missing model(s):$PMISS"
grep -q '"z.ai"' "$DASH" && grep -q '1.40' "$DASH" \
  && ok "pricing: GLM priced at z.ai rates, not Anthropic's" \
  || bad "pricing: z.ai rate card missing (GLM cost stays wrong)"
# basis choice persists under the dashboard's ffd.* namespace, never ff.*
grep -q '"ffd.pricing"' "$DASH" && grep -q '"ffd.planChoice"' "$DASH" \
  && ok "pricing: basis + plan tier persisted under ffd.* namespace" \
  || bad "pricing: basis/plan keys not namespaced (ffd.*)"
# plan basis must be tiered (Max 5x/20x etc.) and BLENDED, never a flat $0
grep -q 'const PLANS' "$DASH" && grep -q '"blended"' "$DASH" \
  && grep -q 'function computePlanPools' "$DASH" \
  && ok "pricing: tiered plans blend the monthly fee (never \$0)" \
  || bad "pricing: plan basis missing tiers or blending"
grep -q 'usd: 0, kind: "plan"' "$DASH" \
  && bad "pricing: plan lanes hardcoded to \$0 again" \
  || ok "pricing: no hardcoded \$0 plan lanes"
# estimates must be visually distinct from invoices: the ≈ marker
grep -q '"≈"' "$DASH" \
  && ok "pricing: estimates carry the ≈ marker" \
  || bad "pricing: estimates indistinguishable from reported cost"
# the settings surface is a styled in-app modal — native dialogs are banned
grep -qE 'window\.(alert|confirm|prompt)\(|[^.a-zA-Z](alert|confirm|prompt)\(' "$DASH" \
  && bad "dashboard: native browser dialog present (alert/confirm/prompt)" \
  || ok "dashboard: no native browser dialogs"
grep -q 'id="cogbtn"' "$DASH" && grep -q 'modal-wrap' "$DASH" \
  && ok "dashboard: cost settings cog + in-app modal present" \
  || bad "dashboard: cost settings surface missing"

# --- dashboard: FLEET / PROJECT / WAVE drill ------------------------------------
grep -q 'function projectView' "$DASH" && grep -q 'function aggStats' "$DASH" \
  && ok "dashboard: PROJECT drill level present" \
  || bad "dashboard: project view missing"
# repo header must be TWO controls: chevron folds, name drills into the project
grep -q 'class="tgl" data-toggle' "$DASH" && grep -q '"repo:" + label' "$DASH" \
  && ok "dashboard: repo name drills to project, chevron still folds" \
  || bad "dashboard: repo header lost its drill or its fold control"
# run cards on FLEET/PROJECT must click through to the wave
grep -q 'card clickcard' "$DASH" \
  && ok "dashboard: run cards click through to the wave" \
  || bad "dashboard: run cards are dead ends"
# breadcrumbs back up the hierarchy
grep -q 'class="crumb" data-k=""' "$DASH" \
  && ok "dashboard: breadcrumb back to the fleet level" \
  || bad "dashboard: no breadcrumb up the drill hierarchy"

# --- ff-serve: doctor endpoint ---------------------------------------------------
SRV="$HERE/../scripts/ff-serve.py"
grep -q '/api/doctor.json' "$SRV" \
  && ok "ff-serve: doctor endpoint routed" || bad "ff-serve: doctor endpoint missing"
grep -q 'class Doctor' "$SRV" \
  && ok "ff-serve: doctor cache/runner present" || bad "ff-serve: Doctor class missing"
# offline runs inline (fast); live MUST be backgrounded or the request blocks for
# minutes and is indistinguishable from a dead server.
grep -q 'threading.Thread(target=self._run' "$SRV" \
  && ok "ff-serve: live doctor probe is backgrounded" \
  || bad "ff-serve: live probe would block the request"
python -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$SRV" \
  && ok "ff-serve: parses" || bad "ff-serve: syntax error"

# --- roost integration (optional capability, conditional section) ----------------
grep -q '/api/roost.json' "$SRV" && grep -q 'class Roost' "$SRV" \
  && ok "ff-serve: roost endpoint + cache present" || bad "ff-serve: roost endpoint missing"
# absence of the binary is a capability gap, not an error — probed, never assumed
grep -q 'shutil.which("roost")' "$SRV" \
  && ok "ff-serve: roost availability probed, not assumed" \
  || bad "ff-serve: roost binary not probed"
grep -q 'threading.Thread(target=self._run, daemon=True)' "$SRV" \
  && ok "ff-serve: roost probe is backgrounded" || bad "ff-serve: roost probe would block"
grep -q 'function roostView' "$DASH" && grep -q 'roostDoc.available' "$DASH" \
  && ok "dashboard: roost pane present and gated on availability" \
  || bad "dashboard: roost pane missing or unconditional"
grep -q 'setInterval.*fetchRoost' "$DASH" \
  && bad "dashboard: roost on its own timer" \
  || ok "dashboard: roost fetches are tick/click driven only"
# roost's own widget (script-free, .rw-scoped) is embedded verbatim — the pane
# must not re-design a surface roost already ships
grep -q '\[self.bin, "widget"\]' "$SRV" && grep -q 'rw-host' "$DASH" \
  && ok "roost: ships its own widget, embedded verbatim (no redesign)" \
  || bad "roost: widget fragment not passed through"
# auth refresh mutates the token store: click-gated endpoint, never a timer
grep -q '/api/roost/refresh' "$SRV" && grep -q '"refresh", "--soon"' "$SRV" \
  && grep -q 'id="roostAuth"' "$DASH" \
  && ok "roost: auth refresh is a click-gated endpoint" \
  || bad "roost: auth refresh missing"
grep -q 'setInterval.*roost/refresh\|setInterval.*roostAuth' "$DASH" \
  && bad "roost: auth refresh on a timer (mutates token store)" \
  || ok "roost: no timer-driven auth refresh"

# --- ff-import.sh (feature B): native Workflow run import ------------------------
# build a synthetic native wf_ dir: journal.jsonl (started/result keyed by
# agentId) + two agent transcripts (one string content, one content-array).
WFD="$TMP/wf_ab12cd34-ef"; mkdir -p "$WFD"
printf '%s\n' \
  '{"type":"started","key":"v2:aaaa","agentId":"a01cb5f01fadf5610"}' \
  '{"type":"result","key":"v2:aaaa","agentId":"a01cb5f01fadf5610","result":{"verdict":"ok","score":7}}' \
  '{"type":"started","key":"v2:bbbb","agentId":"a02deadbeef00000"}' \
  > "$WFD/journal.jsonl"
jq -nc '{type:"user",message:{role:"user",content:"Refute the claim that X is safe."}}' \
  > "$WFD/agent-a01cb5f01fadf5610.jsonl"
jq -nc '{type:"user",message:{role:"user",content:[{type:"text",text:"Find any bugs in module Y."}]}}' \
  > "$WFD/agent-a02deadbeef00000.jsonl"
IMP="$(bash "$S/ff-import.sh" --wf "$WFD" --run imp1 --repo "$REPO" 2>/dev/null)"; IRC=$?
[ "$IRC" = "0" ] && ok "ff-import: exits 0 on import" || bad "ff-import: rc=$IRC"
printf '%s' "$IMP" | awk -F'\t' '$1=="a01cb5f01fadf5610"&&$2=="imported"{f=1} END{exit !f}' \
  && ok "ff-import: completed agent reported imported" || bad "ff-import: imported TSV wrong"
printf '%s' "$IMP" | awk -F'\t' '$1=="a02deadbeef00000"&&$2=="incomplete"{f=1} END{exit !f}' \
  && ok "ff-import: started-only agent reported incomplete" || bad "ff-import: incomplete TSV wrong"
PC="$(printf '%s' "$IMP" | awk -F'\t' '$1=="a01cb5f01fadf5610"{print $3}')"
[ -n "$PC" ] && [ "$PC" -gt 0 ] 2>/dev/null && ok "ff-import: prompt_chars > 0" || bad "ff-import: prompt_chars wrong ($PC)"
IRD="$REPO/.fleetflow/imp1"
[ -f "$IRD/a01cb5f01fadf5610.prompt.txt" ] && ok "ff-import: wrote prompt.txt (completed)" || bad "ff-import: prompt.txt missing"
grep -q "Refute the claim" "$IRD/a01cb5f01fadf5610.prompt.txt" && ok "ff-import: prompt extracted (string content)" || bad "ff-import: string-content prompt wrong"
grep -q "Find any bugs" "$IRD/a02deadbeef00000.prompt.txt" && ok "ff-import: prompt extracted (content array)" || bad "ff-import: array-content prompt wrong"
[ -f "$IRD/a01cb5f01fadf5610.result.json" ] && ok "ff-import: wrote result.json (completed)" || bad "ff-import: result.json missing"
[ ! -f "$IRD/a02deadbeef00000.result.json" ] && ok "ff-import: incomplete agent has no result.json" || bad "ff-import: incomplete got result.json"
jq -e '.is_error==false and (.result|fromjson|.verdict=="ok" and .score==7)' "$IRD/a01cb5f01fadf5610.result.json" >/dev/null \
  && ok "ff-import: result.json wraps native result (tojson)" || bad "ff-import: result.json shape wrong"
NJ="$IRD/journal.jsonl"
[ "$(jq -r 'select(.type=="result" and .id=="a01cb5f01fadf5610")|.model' "$NJ")" = "native" ] \
  && ok "ff-import: journal result model=native" || bad "ff-import: journal model wrong"
# phase lives on the started record (same convention as ff-spawn), not the result
[ "$(jq -r 'select(.type=="started" and .id=="a01cb5f01fadf5610")|.phase' "$NJ")" = "imported" ] \
  && ok "ff-import: journal phase=imported" || bad "ff-import: journal phase wrong"
[ -z "$(jq -r 'select(.type=="result" and .id=="a02deadbeef00000")' "$NJ")" ] \
  && ok "ff-import: incomplete agent has no result record" || bad "ff-import: incomplete got a result record"
jq -e --arg wf "$WFD" '.packets[]|select(.id=="a01cb5f01fadf5610")|.model=="native" and .imported_from==$wf' "$IRD/manifest.json" >/dev/null \
  && ok "ff-import: manifest packet model=native + imported_from" || bad "ff-import: manifest packet wrong"
# nothing to import -> exit 3
WFE="$TMP/wf_empty"; mkdir -p "$WFE"; : > "$WFE/journal.jsonl"
check "ff-import: empty wf journal -> 3" 3 bash "$S/ff-import.sh" --wf "$WFE" --run imp2 --repo "$REPO"
# ff-run resume SKIPS imported native packets (terminal, not replayable)
RRN="$(bash "$S/ff-run.sh" resume --run imp1 --repo "$REPO" 2>/dev/null)"; RCRR=$?
[ "$RCRR" = "0" ] && ok "ff-run: resume skips native packets (exit 0)" || bad "ff-run: resume on imported run rc=$RCRR"
printf '%s' "$RRN" | jq -e 'any(.[]; .id=="a01cb5f01fadf5610" and .status=="imported")' >/dev/null \
  && ok "ff-run: native packet reported imported (skipped)" || bad "ff-run: native packet not skipped"

# --- ADR conformance (the docs contract, eaten at home) -------------------------
# adr-lint ships with the adr-ops skill, not this repo; skip (loudly) if absent.
ADRL="$HOME/.claude/skills/adr-ops/scripts/adr-lint.py"
if [ -f "$ADRL" ] && command -v python >/dev/null 2>&1; then
  python "$ADRL" --strict --dir "$HERE/../docs/adr" >/dev/null 2>&1 \
    && ok "adr: docs/adr conforms (adr-lint --strict)" \
    || bad "adr: adr-lint --strict has findings (run it directly for detail)"
else
  echo "  SKIP  adr-lint unavailable (adr-ops skill or python missing)"
fi

# === waves (ADR-018) ===
FINDINGS="$S/ff-findings.sh"
WIDGET="$S/ff-widget.sh"
CATALOGUE="$HERE/../assets/wave-catalogue.json"
WREPO="$TMP/waves-repo"
mkdir -p "$WREPO"
git -C "$WREPO" init -q -b main
git -C "$WREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# --- findings ledger: dedup, waiver persistence, convergence, expiry ---------
if [ -f "$FINDINGS" ]; then
  FP1="111111111111"; FP2="222222222222"
  F1="$(jq -nc --arg fp "$FP1" '{fp:$fp,wave:"qa",severity:"medium",files:["src/a.ts"],claim:"Save loses edits",evidence:"first repro",status:"open",round:0,lane:"qa-1"}')"
  F1_DUP="$(jq -nc --arg fp "$FP1" '{fp:$fp,wave:"qa",severity:"medium",files:["src/a.ts"],claim:"Save loses edits",evidence:"newer repro",status:"open",round:1,lane:"qa-2"}')"
  F2="$(jq -nc --arg fp "$FP2" '{fp:$fp,wave:"security",severity:"high",files:["src/b.ts"],claim:"Input reaches shell",evidence:"metacharacters execute",status:"open",round:0,lane:"security-1"}')"
  printf '%s\n%s\n%s\n' "$F1" "$F1_DUP" "$F2" \
    | bash "$FINDINGS" append --run wledger --repo "$WREPO" >/dev/null 2>&1
  LRC=$?
  [ "$LRC" = "0" ] && ok "waves ledger: append accepts three findings" \
    || bad "waves ledger: append rc=$LRC"
  LC="$(bash "$FINDINGS" count --run wledger --repo "$WREPO" 2>/dev/null)"; LCRC=$?
  { [ "$LCRC" = "0" ] && printf '%s' "$LC" | jq -e '.open==2' >/dev/null; } \
    && ok "waves ledger: duplicate fp leaves two open findings" \
    || bad "waves ledger: duplicate fp count wrong (rc=$LCRC out=$LC)"
  jq -s -e 'length==2 and ([.[].fp]|unique|length)==2' "$WREPO/.fleetflow/wledger/findings.jsonl" >/dev/null 2>&1 \
    && ok "waves ledger: duplicate fp is upserted, not appended" \
    || bad "waves ledger: duplicate fp produced a third ledger record"

  # The ledger COMPUTES fp from content (§1) — a supplied fp is overridden, so
  # re-read the real ones. tr -d '\r': Windows jq.exe emits CRLF (same trap
  # ff-status/ff-widget/ff-run all guard — a raw capture breaks every = and -f).
  FP1="$(jq -sr '.[]|select(.claim=="Save loses edits").fp' "$WREPO/.fleetflow/wledger/findings.jsonl" | head -1 | tr -d '\r')"
  FP2="$(jq -sr '.[]|select(.claim=="Input reaches shell").fp' "$WREPO/.fleetflow/wledger/findings.jsonl" | head -1 | tr -d '\r')"

  bash "$FINDINGS" waive --run wledger --repo "$WREPO" --fp "$FP1" \
    --reason "accepted compatibility trade-off" >/dev/null 2>&1; LWRC=$?
  { [ "$LWRC" = "0" ] \
    && jq -e --arg fp "$FP1" 'any(.[]; .fp==$fp and .reason=="accepted compatibility trade-off")' "$WREPO/docs/waivers.json" >/dev/null \
    && jq -s -e --arg fp "$FP1" 'any(.[]; .fp==$fp and .status=="waived")' "$WREPO/.fleetflow/wledger/findings.jsonl" >/dev/null; } \
    && ok "waves ledger: waive upserts repo waiver and marks finding waived" \
    || bad "waves ledger: waive did not persist both states"

  printf '%s\n' "$F1" | bash "$FINDINGS" append --run wfresh --repo "$WREPO" >/dev/null 2>&1
  bash "$FINDINGS" apply-waivers --run wfresh --repo "$WREPO" >/dev/null 2>&1; LARC=$?
  { [ "$LARC" = "0" ] \
    && jq -s -e --arg fp "$FP1" 'any(.[]; .fp==$fp and .status=="waived")' "$WREPO/.fleetflow/wfresh/findings.jsonl" >/dev/null; } \
    && ok "waves ledger: repo waiver converges a fresh ledger to waived" \
    || bad "waves ledger: apply-waivers missed matching fp"

  WTMP="$TMP/waivers-expired.json"
  jq --arg fp "$FP2" '. + [{fp:$fp,reason:"time-limited",waived:"2000-01-01",expires:"2000-01-02"}]' \
    "$WREPO/docs/waivers.json" > "$WTMP" && mv "$WTMP" "$WREPO/docs/waivers.json"
  printf '%s\n' "$F2" | bash "$FINDINGS" append --run wexpired --repo "$WREPO" >/dev/null 2>&1
  bash "$FINDINGS" apply-waivers --run wexpired --repo "$WREPO" \
    >/dev/null 2>"$TMP/wexpired.err"; LERC=$?
  { [ "$LERC" = "0" ] \
    && jq -s -e --arg fp "$FP2" 'any(.[]; .fp==$fp and .status=="open")' "$WREPO/.fleetflow/wexpired/findings.jsonl" >/dev/null \
    && grep -qi 'expired' "$TMP/wexpired.err"; } \
    && ok "waves ledger: expired waiver ignored with stderr warning" \
    || bad "waves ledger: expired waiver was silent or applied"
else
  echo "  SKIP  waves ledger (ff-findings.sh absent)"
fi

# --- manifest compatibility + dry-run sibling state ---------------------------
HAS_WAVE=0
grep -qE '(^|[[:space:]])wave\)' "$S/ff-run.sh" 2>/dev/null && HAS_WAVE=1
WLEG="$WREPO/.fleetflow/wlegacy"; mkdir -p "$WLEG"
jq -nc '{run:"wlegacy",base:"main",created_by:"fixture",phases:["build","verify"],packets:[]}' \
  > "$WLEG/manifest.json"
: > "$WLEG/journal.jsonl"
WSTATUS="$(bash "$S/ff-run.sh" status --run wlegacy --repo "$WREPO" 2>/dev/null)"; WSRC=$?
{ [ "$WSRC" = "0" ] && printf '%s' "$WSTATUS" | jq -e '.run=="wlegacy"' >/dev/null; } \
  && ok "waves manifest: legacy strings-only manifest still parses" \
  || bad "waves manifest: legacy status failed (rc=$WSRC)"
if [ "$HAS_WAVE" = "1" ] && [ -f "$CATALOGUE" ]; then
  PHASES_BEFORE="$(jq -c '.phases' "$WLEG/manifest.json")"
  bash "$S/ff-run.sh" wave --run wlegacy --repo "$WREPO" --posture baseline --dry-run \
    >/dev/null 2>"$TMP/wlegacy-wave.err"; WDRC=$?
  PHASES_AFTER="$(jq -c '.phases' "$WLEG/manifest.json" 2>/dev/null)"
  [ "$WDRC" = "0" ] && ok "waves manifest: wave --dry-run accepts fixture run" \
    || bad "waves manifest: wave --dry-run rc=$WDRC"
  [ "$PHASES_BEFORE" = "$PHASES_AFTER" ] \
    && ok "waves manifest: phases array byte-identical after wave --dry-run" \
    || bad "waves manifest: frozen phases array changed"
  jq -e 'has("waves") and (.waves|type=="array")' "$WLEG/manifest.json" >/dev/null 2>&1 \
    && ok "waves manifest: waves state is a sibling key" \
    || bad "waves manifest: waves sibling missing after dry-run"
else
  echo "  SKIP  waves manifest dry-run sibling state (sequencer or catalogue absent)"
fi

# --- round is metadata, never cache identity ----------------------------------
if grep -q -- '--round)' "$S/ff-spawn.sh" 2>/dev/null; then
  RPKT="$TMP/round-packet.txt"; echo "round key test. FINAL REPLY: r" > "$RPKT"
  bash "$S/ff-spawn.sh" --run wround --id rk --model sonnet --prompt-file "$RPKT" \
    --repo "$WREPO" --dry-run --force --round 1 >/dev/null 2>&1; RR1=$?
  bash "$S/ff-spawn.sh" --run wround --id rk --model sonnet --prompt-file "$RPKT" \
    --repo "$WREPO" --dry-run --force --round 2 >/dev/null 2>&1; RR2=$?
  RKEYS="$(grep '"type":"started"' "$WREPO/.fleetflow/wround/journal.jsonl" 2>/dev/null \
    | jq -r 'select(.id=="rk")|.key')"
  { [ "$RR1" = "0" ] && [ "$RR2" = "0" ] \
    && [ "$(printf '%s\n' "$RKEYS" | sed '/^$/d' | wc -l | tr -d ' ')" = "2" ] \
    && [ "$(printf '%s\n' "$RKEYS" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')" = "1" ]; } \
    && ok "waves spawn: two rounds journal the same cache key" \
    || bad "waves spawn: round leaked into cache identity"
  grep -q '# round: NOT in key' "$S/ff-spawn.sh" \
    && ok "waves spawn: round-not-in-key guard marker present" \
    || bad "waves spawn: round-not-in-key guard marker missing"
else
  echo "  SKIP  waves spawn round key (round feature absent)"
fi

# --- chat widget output contract ----------------------------------------------
if [ -f "$WIDGET" ]; then
  WP1="$TMP/widget-a.txt"; WP2="$TMP/widget-b.txt"
  echo "widget A. FINAL REPLY: a" > "$WP1"; echo "widget B. FINAL REPLY: b" > "$WP2"
  bash "$S/ff-spawn.sh" --run wwidget --id wa --model sonnet --phase finder-alpha \
    --prompt-file "$WP1" --repo "$WREPO" --dry-run >/dev/null 2>&1
  bash "$S/ff-spawn.sh" --run wwidget --id wb --model codex --phase triage-beta \
    --prompt-file "$WP2" --repo "$WREPO" --dry-run >/dev/null 2>&1
  WM="$WREPO/.fleetflow/wwidget/manifest.json"; WMM="$TMP/widget-manifest.json"
  jq '. + {posture:"tested",fix_rounds:2,severity_floor:"medium",waves:[
      {name:"finder-alpha",kind:"finder",gate:"auto",status:"done",round:0},
      {name:"triage-beta",kind:"barrier",gate:"review",status:"gated",round:0},
      {name:"docs-gamma",kind:"docs",gate:"auto",status:"pending",round:0}
    ]}' "$WM" > "$WMM" && mv "$WMM" "$WM"
  : > "$WREPO/.fleetflow/wwidget/findings.jsonl"
  WHTML_FILE="$TMP/widget.html"
  bash "$WIDGET" --run wwidget --repo "$WREPO" > "$WHTML_FILE" 2>"$TMP/widget.err"; WHRC=$?
  WHTML="$(<"$WHTML_FILE")"
  [ "$WHRC" = "0" ] && [ -s "$WHTML_FILE" ] \
    && ok "waves widget: fixture renders an HTML fragment" \
    || bad "waves widget: render failed (rc=$WHRC)"
  HTTPS_N="$(printf '%s' "$WHTML" | grep -o 'https://' | wc -l | tr -d ' ')"
  { [ "$HTTPS_N" = "1" ] && printf '%s' "$WHTML" | grep -q 'href="https://fleetflow\.lab/'; } \
    && ok "waves widget: sole https occurrence is fleetflow.lab anchor" \
    || bad "waves widget: expected one fleetflow.lab https anchor (got $HTTPS_N)"
  printf '%s' "$WHTML" | grep -q 'http://' \
    && bad "waves widget: http URL emitted" || ok "waves widget: zero http occurrences"
  printf '%s' "$WHTML" | grep -qE '(alert|confirm|prompt)[[:space:]]*\(' \
    && bad "waves widget: native browser dialog call emitted" \
    || ok "waves widget: no alert/confirm/prompt calls"
  printf '%s' "$WHTML" | grep -q 'sendPrompt(' \
    && ok "waves widget: footer uses sendPrompt actions" \
    || bad "waves widget: sendPrompt action missing"
  WAVE_EXPECT="$(jq -r '.waves|length' "$WM" | tr -d '\r')"
  WAVE_RENDERED="$(grep -o 'class="ffw-seg"' "$WHTML_FILE" | wc -l | tr -d ' ')"
  [ "$WAVE_RENDERED" = "$WAVE_EXPECT" ] \
    && ok "waves widget: wave-bar segment count matches fixture waves" \
    || bad "waves widget: rendered $WAVE_RENDERED/$WAVE_EXPECT wave segments"
  WIDGET_HOST="$TMP/widget-host.html"
  sed '/\/\* ff-runcard:begin \*\//,/\/\* ff-runcard:end \*\//d' "$WHTML_FILE" > "$WIDGET_HOST"
  grep -qE '#[0-9a-fA-F]{6}' "$WIDGET_HOST" \
    && bad "waves widget: raw hex colour emitted outside runcard module" \
    || ok "waves widget: no non-module raw hex colours"
else
  echo "  SKIP  waves widget (ff-widget.sh absent)"
fi

# === runcard (ADR-019) ===
RUNCARD="$HERE/../assets/ff-runcard.js"
if [ ! -f "$RUNCARD" ]; then
  echo "  SKIP  runcard parity/hygiene/structure (ff-runcard.js absent)"
elif [ ! -f "$DASH" ]; then
  echo "  SKIP  runcard parity/hygiene/structure (ff-dashboard.html absent)"
elif [ ! -f "$WIDGET" ]; then
  echo "  SKIP  runcard parity/hygiene/structure (ff-widget.sh absent)"
elif [ ! -s "$WHTML_FILE" ]; then
  echo "  SKIP  runcard widget parity/structure (fixture output absent)"
else
  # Extract marker-delimited bytes without decoding or newline conversion. The
  # marker LINES are removed; every byte between them is preserved for cmp.
  extract_runcard_body() {
    python - "$1" "$2" <<'PY'
import pathlib
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
begin = b"/* ff-runcard:begin */"
end = b"/* ff-runcard:end */"
if data.count(begin) != 1 or data.count(end) != 1:
    raise SystemExit(1)

begin_at = data.index(begin)
begin_line = data.rfind(b"\n", 0, begin_at) + 1
begin_eol = data.find(b"\n", begin_at + len(begin))
if begin_eol < 0:
    raise SystemExit(1)
if data[begin_line:begin_at].strip(b" \t\r"):
    raise SystemExit(1)
if data[begin_at + len(begin):begin_eol].strip(b" \t\r"):
    raise SystemExit(1)

body_at = begin_eol + 1
end_at = data.index(end, body_at)
end_line = data.rfind(b"\n", body_at, end_at) + 1
if data[end_line:end_at].strip(b" \t\r"):
    raise SystemExit(1)
pathlib.Path(sys.argv[2]).write_bytes(data[body_at:end_line])
PY
  }

  DASH_BEGIN_N="$(grep -Fo '/* ff-runcard:begin */' "$DASH" | wc -l | tr -d ' ')"
  DASH_END_N="$(grep -Fo '/* ff-runcard:end */' "$DASH" | wc -l | tr -d ' ')"
  { [ "$DASH_BEGIN_N" = "1" ] && [ "$DASH_END_N" = "1" ]; } \
    && ok "runcard dashboard: markers occur exactly once" \
    || bad "runcard dashboard: marker counts begin=$DASH_BEGIN_N end=$DASH_END_N"

  WIDGET_BEGIN_N="$(grep -Fo '/* ff-runcard:begin */' "$WHTML_FILE" | wc -l | tr -d ' ')"
  WIDGET_END_N="$(grep -Fo '/* ff-runcard:end */' "$WHTML_FILE" | wc -l | tr -d ' ')"
  { [ "$WIDGET_BEGIN_N" = "1" ] && [ "$WIDGET_END_N" = "1" ]; } \
    && ok "runcard widget: markers occur exactly once" \
    || bad "runcard widget: marker counts begin=$WIDGET_BEGIN_N end=$WIDGET_END_N"

  DASH_RUNCARD="$TMP/dashboard-runcard.js"
  if extract_runcard_body "$DASH" "$DASH_RUNCARD" \
      && cmp -s "$RUNCARD" "$DASH_RUNCARD"; then
    ok "runcard parity: dashboard copy is byte-identical"
  else
    bad "runcard parity: dashboard copy differs from ff-runcard.js"
  fi

  WIDGET_RUNCARD="$TMP/widget-runcard.js"
  if extract_runcard_body "$WHTML_FILE" "$WIDGET_RUNCARD" \
      && cmp -s "$RUNCARD" "$WIDGET_RUNCARD"; then
    ok "runcard parity: widget copy is byte-identical"
  else
    bad "runcard parity: widget copy differs from ff-runcard.js"
  fi

  grep -Fq 'fetch(' "$RUNCARD" \
    && bad "runcard hygiene: fetch present" || ok "runcard hygiene: no fetch"
  # Match CALLS, not words - the module's contract comment names the banned
  # APIs ("no localStorage, no Date.now"), and a bare -F grep trips on the ban
  # itself (found at first integration, 2026-08-10).
  grep -qE 'localStorage[.[]' "$RUNCARD" \
    && bad "runcard hygiene: localStorage present" || ok "runcard hygiene: no localStorage"
  grep -qE 'Date\.now[[:space:]]*\(' "$RUNCARD" \
    && bad "runcard hygiene: Date.now present" || ok "runcard hygiene: no Date.now"
  grep -qE 'addEventListener[[:space:]]*\(' "$RUNCARD" \
    && bad "runcard hygiene: addEventListener present" || ok "runcard hygiene: no addEventListener"
  # Both declaration styles are legal: `function ffRunCard(` and
  # `var ffRunCard; ... ffRunCard = function (`.
  grep -qE '(function[[:space:]]+ffRunCard[[:space:]]*\(|ffRunCard[[:space:]]*=[[:space:]]*function)' "$RUNCARD" \
    && ok "runcard module: defines ffRunCard" || bad "runcard module: ffRunCard missing"
  grep -qE 'FF_RUNCARD_CSS[[:space:]]*=' "$RUNCARD" \
    && ok "runcard module: defines FF_RUNCARD_CSS" || bad "runcard module: FF_RUNCARD_CSS missing"

  # DATA is emitted as JSON assigned to a JS variable. Extract a balanced object
  # so nested counts/lanes do not fool a regex, then let jq enforce the wire shape.
  RUNCARD_DATA="$TMP/runcard-data.json"
  if python - "$WHTML_FILE" "$RUNCARD_DATA" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"\b(?:const|let|var)\s+DATA\s*=\s*", text)
if not match:
    raise SystemExit(1)
i = match.end()
while i < len(text) and text[i].isspace():
    i += 1
if i == len(text) or text[i] != "{":
    raise SystemExit(1)
start = i
depth = 0
quoted = False
escaped = False
for i in range(start, len(text)):
    char = text[i]
    if quoted:
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == '"':
            quoted = False
    elif char == '"':
        quoted = True
    elif char == "{":
        depth += 1
    elif char == "}":
        depth -= 1
        if depth == 0:
            pathlib.Path(sys.argv[2]).write_text(text[start:i + 1], encoding="utf-8")
            break
else:
    raise SystemExit(1)
PY
  then
    jq -e 'type=="object" and (.run|type=="string") and (.summary|type=="object") and (.lanes|type=="array")' \
      "$RUNCARD_DATA" >/dev/null 2>&1 \
      && ok "runcard widget: DATA runDoc jq-parses" \
      || bad "runcard widget: DATA is not the runDoc object"
  else
    bad "runcard widget: DATA object missing or malformed"
  fi

  python - "$WHTML_FILE" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
host = text.find('<div class="ffrc-host"')
wave = text.find('<div class="ffw-wavebar"')
raise SystemExit(0 if host >= 0 and wave > host else 1)
PY
  RUNCARD_POS_RC=$?
  [ "$RUNCARD_POS_RC" = "0" ] \
    && ok "runcard widget: wave bar is beneath the shared card" \
    || bad "runcard widget: wave bar is not beneath the shared card"
fi

# --- catalogue and finder packet contracts ------------------------------------
if [ -f "$CATALOGUE" ]; then
  jq empty "$CATALOGUE" >/dev/null 2>&1 \
    && ok "waves catalogue: JSON parses" || bad "waves catalogue: invalid JSON"
  CAT_ROOT="$HERE/.."; TEMPLATE_PATHS_OK=1
  while IFS= read -r template_path; do
    [ -f "$CAT_ROOT/$template_path" ] || TEMPLATE_PATHS_OK=0
  done < <(jq -r '.. | objects | .template? // empty, .cross_template? // empty' "$CATALOGUE" 2>/dev/null | tr -d '\r')
  [ "$TEMPLATE_PATHS_OK" = "1" ] \
    && ok "waves catalogue: every template path exists" \
    || bad "waves catalogue: missing template path"
  FINDER_TEMPLATES_OK=1
  while IFS= read -r template_path; do
    [ -f "$CAT_ROOT/$template_path" ] \
      && grep -q 'FINAL REPLY' "$CAT_ROOT/$template_path" \
      && grep -qi 'read-only' "$CAT_ROOT/$template_path" \
      || FINDER_TEMPLATES_OK=0
  done < <(jq -r '.waves[] | select(.kind=="finder") | .template' "$CATALOGUE" 2>/dev/null | tr -d '\r')
  [ "$FINDER_TEMPLATES_OK" = "1" ] \
    && ok "waves catalogue: finder templates declare read-only FINAL REPLY contract" \
    || bad "waves catalogue: finder template missing role or FINAL REPLY"
  jq -e '[.waves[].model] | all(.=="glm" or .=="codex" or .=="grok" or .=="pi" or .=="sonnet" or .=="opus" or .=="haiku" or .=="fable")' \
    "$CATALOGUE" >/dev/null 2>&1 \
    && ok "waves catalogue: every wave model is spawnable" \
    || bad "waves catalogue: unspawnable or missing wave model"
  jq -e '.waves.perf.postures==[]' "$CATALOGUE" >/dev/null 2>&1 \
    && ok "waves catalogue: perf is opt-in (empty postures)" \
    || bad "waves catalogue: perf unexpectedly belongs to a posture"
else
  echo "  SKIP  waves catalogue (wave-catalogue.json absent)"
fi

# --- stop gate has the watchdog/stall semantic exit code ----------------------
if [ "$HAS_WAVE" = "1" ] && [ -f "$CATALOGUE" ]; then
  WGATE="$WREPO/.fleetflow/wgate"; mkdir -p "$WGATE"
  jq -nc '{run:"wgate",base:"main",created_by:"fixture",phases:["build"],packets:[],
    posture:"baseline",fix_rounds:0,severity_floor:"medium",
    waves:[{name:"docs-parity",kind:"finder",gate:"stop",status:"gated",round:0}]}' \
    > "$WGATE/manifest.json"
  : > "$WGATE/journal.jsonl"
  # No --continue: arriving AT a stop gate exits 14 (§2); --continue CLEARS the
  # gate and proceeds (exit 0), which is the other half of the contract.
  check "waves gate: stop-gated fixture exits 14 on arrival" 14 \
    bash "$S/ff-run.sh" wave --run wgate --repo "$WREPO" --posture baseline
  check "waves gate: --continue clears the gate" 0 \
    bash "$S/ff-run.sh" wave --run wgate --repo "$WREPO" --continue
else
  echo "  SKIP  waves stop gate (sequencer absent)"
fi

# --- ff-archive: label parity, orchestrator carry-through ---------------------
# The dashboard renders live and archived runs side by side, so an archived
# record must not change identity or lose facts the live half shows.
bash -n "$S/ff-archive.sh" 2>/dev/null && ok "syntax ff-archive.sh" || bad "syntax ff-archive.sh"
bash "$S/ff-archive.sh" --help 2>/dev/null | grep -q "EXAMPLES" \
  && ok "ff-archive.sh --help has EXAMPLES" || bad "ff-archive.sh --help lacks EXAMPLES"

# A run driven from inside a Claude Code worktree session: toplevel is
# <repo>/.claude/worktrees/<slug>. basename() would label it with the slug
# alone, silently orphaning it from its repo's dashboard group forever.
WTREPO="$TMP/hostrepo/.claude/worktrees/zesty-lane-abc123"
mkdir -p "$WTREPO" && git -C "$WTREPO" init -q -b main
git -C "$WTREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
RDA="$WTREPO/.fleetflow/arch1"; mkdir -p "$RDA"
: > "$RDA/w.prompt.txt"
printf '%s\n' \
  '{"type":"started","key":"v2:w","id":"w","model":"sonnet","phase":"build","orchestrator":"fable","v":"1.2.0"}' \
  '{"type":"result","key":"v2:w","id":"w","model":"sonnet","rc":0,"artifact":"x"}' \
  > "$RDA/journal.jsonl"

# size, not existence: the isolated store already holds the ff-clean fixtures
ISO_STORE="$FLEETFLOW_HOME/history.jsonl"
iso_size() { [ -f "$ISO_STORE" ] && wc -c < "$ISO_STORE" | tr -d ' \r' || echo 0; }
ISO_BEFORE="$(iso_size)"

ARC="$(bash "$S/ff-archive.sh" --run arch1 --repo "$WTREPO" --dry-run 2>/dev/null)"
printf '%s' "$ARC" | jq -e '.repo_label=="hostrepo@zesty-lane-abc123"' >/dev/null \
  && ok "ff-archive: worktree run keeps its repo (repo@slug, matches aggregate)" \
  || bad "ff-archive: worktree run labelled '$(printf '%s' "$ARC" | jq -r '.repo_label')' (orphaned from its repo)"
printf '%s' "$ARC" | jq -e '.orchestrator=="fable"' >/dev/null \
  && ok "ff-archive: carries orchestrator (badge never guesses, so a dropped field is unrecoverable)" \
  || bad "ff-archive: dropped orchestrator - archived run reads 'unrecorded' forever"
# plain repos keep the basename they have always had
ARC2="$(bash "$S/ff-archive.sh" --run r1 --repo "$REPO" --dry-run 2>/dev/null)"
printf '%s' "$ARC2" | jq -e '.repo_label=="repo"' >/dev/null \
  && ok "ff-archive: non-worktree repo label unchanged (no regression)" \
  || bad "ff-archive: non-worktree label regressed"
# --dry-run must not append anywhere
[ "$ISO_BEFORE" = "$(iso_size)" ] \
  && ok "ff-archive: --dry-run appends nothing" \
  || bad "ff-archive: --dry-run appended to the store"

# --- ff-clean --landed / ff-sweep (ADR-020) -----------------------------------
# The safety-critical predicate on this repo: everything below asserts what must
# NOT be deleted. A regression here destroys a lane's only copy of real work.
bash -n "$S/ff-sweep.sh" 2>/dev/null && ok "syntax ff-sweep.sh" || bad "syntax ff-sweep.sh"
bash "$S/ff-sweep.sh" --help 2>/dev/null | grep -q "EXAMPLES" \
  && ok "ff-sweep.sh --help has EXAMPLES" || bad "ff-sweep.sh --help lacks EXAMPLES"
check "ff-sweep: bad flag -> 2" 2 bash "$S/ff-sweep.sh" --frobnicate

SWR="$TMP/swrepo"
mkdir -p "$SWR" && git -C "$SWR" init -q -b main
git -C "$SWR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
SWD="$SWR/.fleetflow/sw"; mkdir -p "$SWD"
jq -nc '{run:"sw",base:"main",created_by:"fixture",phases:["build"],packets:[]}' > "$SWD/manifest.json"
: > "$SWD/journal.jsonl"
mklane() { # id, then commit-and-merge?  builds a worktree lane with one commit
  git -C "$SWR" worktree add -q -b "fleetflow/sw/$1" "$SWD/wt-$1" main 2>/dev/null
  echo "$1" > "$SWD/wt-$1/$1.txt"
  git -C "$SWD/wt-$1" add -A
  git -C "$SWD/wt-$1" -c user.email=t@t -c user.name=t commit -q -m "lane $1"
}
mklane landed  && git -C "$SWR" merge -q --no-ff -m "land" "fleetflow/sw/landed"
mklane unmerged
mklane tracked && git -C "$SWR" merge -q --no-ff -m "land2" "fleetflow/sw/tracked"
echo "EDITED" >> "$SWD/wt-tracked/tracked.txt"        # tracked modification
mklane litter  && git -C "$SWR" merge -q --no-ff -m "land3" "fleetflow/sw/litter"
echo "scratch" > "$SWD/wt-litter/untracked-note.md"   # untracked leftover only

# THE LOAD-BEARING EQUIVALENCE (ADR-020): for a landed lane, `rev-list --count
# BASE..HEAD` is 0 and `merge-base --is-ancestor` is true - the SAME question.
# A `--landed` flag was built on the assumption they differed, and deleted when
# this fixture proved they do not. Pinning it here so nobody rebuilds it.
LHEAD="$(git -C "$SWD/wt-landed" rev-parse HEAD)"
[ "$(git -C "$SWR" rev-list --count "main..$LHEAD")" = "0" ] \
  && git -C "$SWR" merge-base --is-ancestor "$LHEAD" main \
  && ok "landed lane: rev-list==0 AND is-ancestor (ff-clean needs no --landed flag)" \
  || bad "landed-lane equivalence broken - ff-clean's zero-commit row no longer covers landed lanes"

# Plain ff-clean therefore already reclaims a landed+clean lane, and still keeps
# the unmerged one. This is the pre-existing contract, asserted because ff-sweep
# now depends on it.
CL1="$(bash "$S/ff-clean.sh" --run sw --repo "$SWR" --no-archive 2>/dev/null)"
printf '%s' "$CL1" | awk -F'\t' '$1=="landed"&&$2=="removed"{f=1} END{exit !f}' \
  && ok "ff-clean: landed+clean lane reclaimed with no new flag" \
  || bad "ff-clean: landed lane not reclaimed"
printf '%s' "$CL1" | awk -F'\t' '$1=="unmerged"&&$2=="kept"{f=1} END{exit !f}' \
  && ok "ff-clean: UNMERGED lane kept (work preserved)" \
  || bad "ff-clean: DELETED AN UNMERGED LANE"
[ -d "$SWD/wt-unmerged" ] && ok "ff-clean: unmerged worktree still on disk" \
  || bad "ff-clean: unmerged worktree gone"

# ff-sweep classifies read-only, and a tracked modification is never eligible -
# THIS is where the protection lives, because ff-clean --force is documented to
# discard a failed lane's dirty tree and must keep doing so.
SW="$(bash "$S/ff-sweep.sh" --repo "$SWR" --json 2>/dev/null)"
printf '%s' "$SW" | jq -e '.[0].verdict=="holds-work"' >/dev/null \
  && ok "ff-sweep: unmerged/tracked-modified lanes read holds-work" \
  || bad "ff-sweep: verdict wrong ($(printf '%s' "$SW" | jq -r '.[0].verdict'))"
printf '%s' "$SW" | jq -e '.[0].eligible==false' >/dev/null \
  && ok "ff-sweep: holds-work run is never eligible for reclaim" \
  || bad "ff-sweep: holds-work run marked ELIGIBLE (would destroy work)"
printf '%s' "$SW" | jq -e '.[0].archived==false' >/dev/null \
  && ok "ff-sweep: unarchived run reported as such" || bad "ff-sweep: archived flag wrong"
[ -d "$SWD/wt-unmerged" ] && [ -d "$SWD/wt-tracked" ] \
  && ok "ff-sweep --json: read-only, lanes untouched" \
  || bad "ff-sweep --json: mutated the tree"

# A run whose only blocker is untracked litter gets its own verdict, and is
# eligible ONLY with --include-untracked.
SWL="$TMP/swlit"; mkdir -p "$SWL" && git -C "$SWL" init -q -b main
git -C "$SWL" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
SWLD="$SWL/.fleetflow/lit"; mkdir -p "$SWLD"
jq -nc '{run:"lit",base:"main",created_by:"fixture",phases:["build"],packets:[]}' > "$SWLD/manifest.json"
: > "$SWLD/journal.jsonl"
git -C "$SWL" worktree add -q -b fleetflow/lit/a "$SWLD/wt-a" main 2>/dev/null
echo a > "$SWLD/wt-a/a.txt"; git -C "$SWLD/wt-a" add -A
git -C "$SWLD/wt-a" -c user.email=t@t -c user.name=t commit -q -m a
git -C "$SWL" merge -q --no-ff -m land fleetflow/lit/a
echo scratch > "$SWLD/wt-a/leftover.md"          # untracked ONLY
SWL1="$(bash "$S/ff-sweep.sh" --repo "$SWL" --json 2>/dev/null)"
printf '%s' "$SWL1" | jq -e '.[0].verdict=="landed-untracked"' >/dev/null \
  && ok "ff-sweep: untracked-only leftovers get their own verdict" \
  || bad "ff-sweep: untracked verdict wrong ($(printf '%s' "$SWL1" | jq -r '.[0].verdict'))"
printf '%s' "$SWL1" | jq -e '.[0].detail | test("leftover.md")' >/dev/null \
  && ok "ff-sweep: untracked paths are listed, never swept silently" \
  || bad "ff-sweep: untracked paths not disclosed"
printf '%s' "$SWL1" | jq -e '.[0].eligible==false' >/dev/null \
  && ok "ff-sweep: landed-untracked NOT eligible by default" \
  || bad "ff-sweep: landed-untracked eligible without opt-in"
bash "$S/ff-sweep.sh" --repo "$SWL" --include-untracked --json 2>/dev/null \
  | jq -e '.[0].eligible==true' >/dev/null \
  && ok "ff-sweep: --include-untracked opts it in" \
  || bad "ff-sweep: --include-untracked had no effect"

# --- ff-sweep SWEEP-PERF P1-P4 contract (plan SWEEPFAST-2026-08 §1) -------------
# Written against the §1 surface contract. The theme is ADR-020 / ADR-024 /
# report §7: a cache may hold PATHS and BYTES, never VERDICTS. Each fixture
# poisons a cache exactly the way a lazy implementation would trust it, then
# asserts the verdict still comes from live git. Every cache assertion below is
# TWO-SIDED: it first proves the poisoned/fresh entry is actually read (a real
# cache hit), so "the cache cannot flip a verdict" is never asserted against a
# cache the implementation merely ignores.
#
# Hermeticity: walk-mode invocations below resolve roots by precedence
# (--root > $FLEETFLOW_ROOTS > $FF_HOME/roots.txt). An inherited
# FLEETFLOW_ROOTS would outrank the temp roots.txt fixture and point discovery
# at REAL repositories, so it is unset for the whole section; the snapshot
# guard at the end of the section backstops the real caches themselves.
unset FLEETFLOW_ROOTS
real_sweep_state_snap() { # checksum the real store/roots/caches this section must not touch
  # aggregate-cache.json is deliberately NOT in this list: nothing in the sweep
  # section can write it (only ff-serve/ff-aggregate do, and the suite's
  # FLEETFLOW_HOME redirect keeps those away from the real one) - but the LIVE
  # fleetflow service rewrites the real file whenever an open dashboard tab
  # polls it, so snapshotting it across this section's multi-minute window made
  # the gate fail any time somebody had https://fleetflow.lab open.
  local f out=""
  for f in "${HOME:-}/.fleetflow/history.jsonl" \
           "${HOME:-}/.fleetflow/roots.txt" \
           "${HOME:-}/.fleetflow/cache/sweep-sizes.json"; do
    if [ -f "$f" ]; then out="${out}$(cksum "$f" 2>/dev/null | awk '{print $2":"$1}')"$'\n'
    else out="${out}none:$f"$'\n'; fi
  done
  printf '%s' "$out"
}
SWEEP_HERM_BEFORE="$(real_sweep_state_snap)"
bash "$S/ff-sweep.sh" --help 2>/dev/null | grep -q -- '--no-size' \
  && ok "ff-sweep: --help documents --no-size" || bad "ff-sweep: --help lacks --no-size"
bash "$S/ff-sweep.sh" --help 2>/dev/null | grep -q -- '--rediscover' \
  && ok "ff-sweep: --help documents --rediscover" || bad "ff-sweep: --help lacks --rediscover"
bash "$S/ff-sweep.sh" --help 2>/dev/null | grep -q -- '--discover-ttl' \
  && ok "ff-sweep: --help documents --discover-ttl" || bad "ff-sweep: --help lacks --discover-ttl"
bash "$S/ff-sweep.sh" --help 2>/dev/null | grep -q '900' \
  && ok "ff-sweep: --help documents the 900s discovery-TTL default" \
  || bad "ff-sweep: --help hides the discovery-TTL default"
check "ff-sweep: --discover-ttl parses" 0 \
  bash "$S/ff-sweep.sh" --repo "$SWL" --discover-ttl 60 --json
check "ff-sweep: FF_SWEEP_DISCOVER_TTL parses" 0 \
  env FF_SWEEP_DISCOVER_TTL=60 bash "$S/ff-sweep.sh" --repo "$SWL" --json
check "ff-sweep: --discover-ttl rejects garbage" 2 \
  bash "$S/ff-sweep.sh" --repo "$SWL" --discover-ttl soon --json

# porcelain-v2 predicate (P3) - the one change that can silently break the
# safety rule. In `status --porcelain=v2 --branch` output: `#` header lines are
# never counted as changes; `? ` lines are untracked, never tracked; and
# `# branch.oid (initial)` (unborn HEAD) means UNMERGED work - kept (ADR-020).
# Each case gets its OWN run dir so one lane's state cannot mask another's.
SWP="$TMP/swporc"
mkdir -p "$SWP" && git -C "$SWP" init -q -b main
git -C "$SWP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkrun() { # repo run: a run dir with one committed-but-UNMERGED lane
  local repo="$1" run="$2" d="$1/.fleetflow/$2"
  mkdir -p "$d"
  jq -nc --arg r "$run" '{run:$r,base:"main",created_by:"fixture",phases:["build"],packets:[]}' > "$d/manifest.json"
  : > "$d/journal.jsonl"
  git -C "$repo" worktree add -q -b "fleetflow/$run/a" "$d/wt-a" main 2>/dev/null
  echo "$run" > "$d/wt-a/a.txt"
  git -C "$d/wt-a" add -A
  git -C "$d/wt-a" -c user.email=t@t -c user.name=t commit -q -m "lane a"
}
mkrunlanded() { mkrun "$1" "$2" && git -C "$1" merge -q --no-ff -m "land $2" "fleetflow/$2/a"; }
mkrunlanded "$SWP" vclean
mkrunlanded "$SWP" vmix
echo EDIT >> "$SWP/.fleetflow/vmix/wt-a/a.txt"       # ONE tracked modification
echo stray > "$SWP/.fleetflow/vmix/wt-a/stray.md"    # ONE untracked file, INSIDE the
                                                     # lane (at the run root the lane's
                                                     # porcelain never sees it, and the
                                                     # mixed-state fixture stops testing
                                                     # tracked-vs-untracked precedence)
# Fixture-validity assert (re-verify round 2): prove the mix is REAL - the lane's
# own porcelain must show BOTH a tracked record and a `? ` untracked record, or
# the precedence assertion below is satisfiable by the tracked edit alone.
VMIXP="$(git -C "$SWP/.fleetflow/vmix/wt-a" status --porcelain=v2 2>/dev/null)"
printf '%s\n' "$VMIXP" | grep -q '^1 ' && printf '%s\n' "$VMIXP" | grep -q '^? ' \
  && ok "sweep: vmix fixture genuinely mixed (tracked + untracked both observed)" \
  || bad "sweep: vmix fixture is not mixed - precedence assertion is vacuous"
mkrunlanded "$SWP" vuntr
echo litter > "$SWP/.fleetflow/vuntr/wt-a/notes.md"  # untracked ONLY
mkrun "$SWP" vpunm                                   # committed, deliberately unmerged
# `2 ` records: a landed lane holding a STAGED RENAME. Rename detection makes
# porcelain-v2 emit `2 R. ...`; a parser matching only `1 ` lines would call
# this lane landed-and-clean -> reclaimable -> eligible. It must be holds-work.
mkrunlanded "$SWP" vren
git -C "$SWP/.fleetflow/vren/wt-a" mv a.txt b.txt    # staged rename -> `2 R.` record
# `u ` records: a landed lane holding UNMERGED index stages, hand-seeded via
# update-index --index-info (deterministic - no merge machinery needed). A
# parser matching only `1 `/`2 ` would call this lane reclaimable too.
mkrunlanded "$SWP" vuconf
UC_A="$(git -C "$SWP/.fleetflow/vuconf/wt-a" rev-parse HEAD:a.txt)"
UC_B="$(printf 'conflicting' | git -C "$SWP" hash-object -w --stdin)"
printf '100644 %s 1\tc.txt\n100644 %s 2\tc.txt\n100644 %s 3\tc.txt\n' \
  "$UC_A" "$UC_B" "$UC_A" \
  | git -C "$SWP/.fleetflow/vuconf/wt-a" update-index --index-info
# unborn HEAD: a `git init` with no commit prints `# branch.oid (initial)`
VOD="$SWP/.fleetflow/vorphan"; mkdir -p "$VOD/wt-a"
jq -nc '{run:"vorphan",base:"main",created_by:"fixture",phases:["build"],packets:[]}' > "$VOD/manifest.json"
: > "$VOD/journal.jsonl"
git -C "$VOD/wt-a" init -q -b main

SWPJ="$(bash "$S/ff-sweep.sh" --repo "$SWP" --json 2>/dev/null)"
printf '%s' "$SWPJ" | jq -e '.[]|select(.run=="vclean")|.verdict=="reclaimable"' >/dev/null \
  && ok "ff-sweep: clean landed lane stays landed (v2 # headers never counted as changes)" \
  || bad "ff-sweep: clean lane misread as holding work (headers counted as changes?)"
printf '%s' "$SWPJ" | jq -e '.[]|select(.run=="vmix")|.verdict=="holds-work" and .holding==1 and .eligible==false and (.detail|test("a:modified"))' >/dev/null \
  && ok "ff-sweep: 1 tracked mod + 1 untracked = one holding lane (tracked wins), never eligible" \
  || bad "ff-sweep: tracked+untracked lane miscounted"
printf '%s' "$SWPJ" | jq -e '.[]|select(.run=="vuntr")|.verdict=="landed-untracked"' >/dev/null \
  && ok "ff-sweep: ? lines stay untracked (never counted as tracked changes)" \
  || bad "ff-sweep: untracked-only lane misread as holds-work"
printf '%s' "$SWPJ" | jq -e '.[]|select(.run=="vorphan")|.verdict=="holds-work" and .eligible==false' >/dev/null \
  && ok "ff-sweep: unborn HEAD (branch.oid (initial)) treated as unmerged - kept" \
  || bad "ff-sweep: unborn-HEAD lane not kept"
printf '%s' "$SWPJ" | jq -e '.[]|select(.run=="vpunm")|.verdict=="holds-work" and .eligible==false' >/dev/null \
  && ok "ff-sweep: unmerged-commit lane kept" || bad "ff-sweep: unmerged lane not kept"
printf '%s' "$SWPJ" | jq -e '.[]|select(.run=="vren")|.verdict=="holds-work" and .holding==1 and .eligible==false' >/dev/null \
  && ok "ff-sweep: 2 (rename) records count as tracked - staged rename holds the lane" \
  || bad "ff-sweep: staged rename misread (2 records not counted as changes)"
printf '%s' "$SWPJ" | jq -e '.[]|select(.run=="vuconf")|.verdict=="holds-work" and .holding==1 and .eligible==false' >/dev/null \
  && ok "ff-sweep: u (unmerged) records count as tracked - conflicted lane held" \
  || bad "ff-sweep: unmerged index misread (u records not counted)"

# P2 age semantics: the default age is shallow and LABELLED approximate
# (`age_s_approx`); `--older-than` alone gates eligibility on the exact
# recursive walk. vclean gets every file aged 5d; vpunm gets ONLY its top-level
# files aged, so its lane-nested files stay fresh - a shallow gating walk would
# call it old, the exact one must not. vorphan is aged 5d AND holds work: an
# --older-than implementation that "filters" by silently dropping every
# holds-work run would also pass the vpunm assertion, so the old holds-work
# run must still be listed.
printf '%s' "$SWPJ" | jq -e '.[0]|has("age_s_approx") and (has("age_s")|not)' >/dev/null \
  && ok "ff-sweep: default rows carry age_s_approx and never exact age_s" \
  || bad "ff-sweep: default age field not marked approximate"
SWEEP_NOW="$(date +%s)"
if touch -d "@$SWEEP_NOW" "$TMP/.touchprobe" 2>/dev/null; then
  find "$SWP/.fleetflow/vclean" -type f -exec touch -d "@$((SWEEP_NOW-432000))" {} +
  find "$SWP/.fleetflow/vpunm" -maxdepth 1 -type f -exec touch -d "@$((SWEEP_NOW-432000))" {} +
  find "$SWP/.fleetflow/vorphan" -type f -exec touch -d "@$((SWEEP_NOW-432000))" {} +
  SWAG="$(bash "$S/ff-sweep.sh" --repo "$SWP" --older-than 1 --json 2>/dev/null)"
  printf '%s' "$SWAG" | jq -e '.[0]|has("age_s") and (has("age_s_approx")|not)' >/dev/null \
    && ok "ff-sweep: --older-than rows carry exact age_s and no approx key" \
    || bad "ff-sweep: --older-than age key shape wrong"
  printf '%s' "$SWAG" | jq -e '.[]|select(.run=="vclean")' >/dev/null \
    && ok "ff-sweep: --older-than still sees a fully-aged run (filter works)" \
    || bad "ff-sweep: --older-than dropped a genuinely old run"
  printf '%s' "$SWAG" | jq -e '.[]|select(.run=="vorphan")|.verdict=="holds-work" and .eligible==false' >/dev/null \
    && ok "ff-sweep: --older-than keeps an OLD holds-work run (age filter, not verdict filter)" \
    || bad "ff-sweep: --older-than dropped a holds-work run as its filter"
  printf '%s' "$SWAG" | jq -e '.[]|select(.run=="vpunm")' >/dev/null \
    && bad "ff-sweep: --older-than judged a lane-fresh run old (gating walk approximated)" \
    || ok "ff-sweep: --older-than uses the exact recursive walk (lane-nested fresh file wins)"
  # the DEFAULT traversal stays shallow: vpunm's top level is aged 5d while its
  # lane files are fresh - a default recursive walk would report ~0.
  SWAGDEF="$(bash "$S/ff-sweep.sh" --repo "$SWP" --json 2>/dev/null)"
  printf '%s' "$SWAGDEF" | jq -e '.[]|select(.run=="vpunm")|.age_s_approx>400000' >/dev/null \
    && ok "ff-sweep: default age walk is shallow (top-level mtime, lanes not walked)" \
    || bad "ff-sweep: default age walk is not shallow"
  printf '%s' "$SWAGDEF" | jq -e '.[]|select(.run=="vpunm")' >/dev/null \
    && ok "ff-sweep: unfiltered default still lists the lane-fresh run" \
    || bad "ff-sweep: default listing lost a run"
else
  echo "  SKIP  ff-sweep age-exactness (touch -d @epoch unsupported here)"
fi

# P4 --no-size: du is skipped, the bytes column prints `-`, the "on disk"
# roll-up is omitted - and none of that may touch a verdict. Every output
# assertion captures the exit code FIRST: without that, an early crash whose
# stderr happens to omit "on disk" satisfies the negative assertions.
sweepverdicts() { jq -r '.[]|[.run,.verdict,(.eligible|tostring)]|@tsv' | tr -d '\r' | sort; }
SVSIZED="$(bash "$S/ff-sweep.sh" --repo "$SWP" --json 2>/dev/null | sweepverdicts)"
SVNOSZ="$(bash "$S/ff-sweep.sh" --repo "$SWP" --no-size --json 2>/dev/null | sweepverdicts)"
[ -n "$SVSIZED" ] && [ "$SVSIZED" = "$SVNOSZ" ] \
  && ok "ff-sweep: --no-size changes no verdicts (bytes are display-only)" \
  || bad "ff-sweep: --no-size changed verdicts"
bash "$S/ff-sweep.sh" --repo "$SWP" --no-size >"$TMP/nosz.tsv" 2>"$TMP/nosz.err"; NOSZRC=$?
[ "$NOSZRC" = "0" ] && ok "ff-sweep: --no-size TSV run exits 0" \
  || bad "ff-sweep: --no-size TSV rc=$NOSZRC"
tr -d '\r' < "$TMP/nosz.tsv" | awk -F'\t' '$1=="vmix" && $6=="-"{f=1} END{exit !f}' \
  && ok "ff-sweep: --no-size prints - in the bytes column" \
  || bad "ff-sweep: --no-size bytes column is not '-'"
{ [ "$NOSZRC" = "0" ] && ! grep -q 'on disk' "$TMP/nosz.err"; } \
  && ok "ff-sweep: --no-size omits the on-disk roll-up" \
  || bad "ff-sweep: --no-size crashed or still prints the on-disk roll-up"
bash "$S/ff-sweep.sh" --repo "$SWP" --json >/dev/null 2>"$TMP/sz.err"
grep -q 'on disk' "$TMP/sz.err" \
  && ok "ff-sweep: sized run still prints the on-disk roll-up" \
  || bad "ff-sweep: sized run lost the on-disk roll-up (omission assert went vacuous)"
# du is REALLY skipped: a du shim first on PATH records every call. The sized
# positive control proves the shim is the du ff-sweep actually resolves -
# without it a PATH-healed resolution would make the skip assertion vacuous.
DUBIN="$TMP/du-bin"; mkdir -p "$DUBIN"
cat > "$DUBIN/du" <<'EOS'
#!/bin/sh
printf 'du\n' >> "$DUMARKER"
exit 0
EOS
chmod +x "$DUBIN/du"
rm -f "$FLEETFLOW_HOME/cache/sweep-sizes.json" "$TMP/du-marker"
DUMARKER="$TMP/du-marker" PATH="$DUBIN:$PATH" \
  bash "$S/ff-sweep.sh" --repo "$SWP" --json >/dev/null 2>&1
[ -s "$TMP/du-marker" ] \
  && ok "ff-sweep: du shim is the resolved du (sized sweep calls it)" \
  || bad "ff-sweep: du shim never called - control broken, skip assert is vacuous"
rm -f "$TMP/du-marker" "$FLEETFLOW_HOME/cache/sweep-sizes.json"
DUMARKER="$TMP/du-marker" PATH="$DUBIN:$PATH" \
  bash "$S/ff-sweep.sh" --repo "$SWP" --no-size --json >/dev/null 2>&1
[ ! -e "$TMP/du-marker" ] \
  && ok "ff-sweep: --no-size never invokes du" \
  || bad "ff-sweep: --no-size still ran du"

# P4 size cache: $FLEETFLOW_HOME/cache/sweep-sizes.json, keyed on the resolved
# lowercased run-dir path, value {fp, by, bytes, at} (§1). A poison fixture
# that guesses fp/by never HITS the cache - and a cache the reader ignores
# trivially cannot flip a verdict. So: let the sweep write the cache itself,
# verify the written shape, then poison ONLY the bytes of a real entry. The
# poisoned bytes being SERVED proves the hit; the verdict staying put proves
# bytes never feed classification.
mkdir -p "$FLEETFLOW_HOME/cache"
bash "$S/ff-sweep.sh" --repo "$SWP" --json >/dev/null 2>&1
SCF="$FLEETFLOW_HOME/cache/sweep-sizes.json"
[ -s "$SCF" ] \
  && ok "ff-sweep: sized sweep writes \$FLEETFLOW_HOME/cache/sweep-sizes.json" \
  || bad "ff-sweep: size cache not written"
jq -e 'type=="object" and (to_entries|length>0) and all(to_entries[];
         (.key|type)=="string"
         and ((.key | sub("^[A-Za-z]:"; "") | ascii_downcase) == (.key | sub("^[A-Za-z]:"; "")))
         and (.value.fp|type=="array") and (.value.fp|length)==2
         and (.value.fp[0]|type)=="number" and (.value.fp[1]|type)=="string"
         and (.value.by|type)=="string" and (.value.by|startswith("1.2.0:"))
         and (.value.bytes|type)=="number" and (.value.bytes>=0)
         and (.value.at|type)=="number")' "$SCF" >/dev/null \
  && ok "ff-sweep: size cache value shape is §1 (fp=[n,mtime-string], by=producer stamp)" \
  || bad "ff-sweep: size cache value shape wrong"
# Key = resolved lowercased run-dir path. NB the drive-letter quirk: bash
# lowercases the whole path, but handing it to native jq.exe as --arg runs it
# through MSYS argv conversion, which rewrites /c/... to C:/... and
# re-capitalises the drive. Compare case-insensitively for path identity; the
# shape check above (everything but the drive prefix already lowercase) is
# what actually pins the lowercasing.
VPKEY="$(jq -r 'to_entries[]|select(.key|endswith("/.fleetflow/vpunm"))|.key' "$SCF" | head -1 | tr -d '\r')"
VPRES="$( (cd "$SWP/.fleetflow/vpunm" && pwd -P) )"
command -v cygpath >/dev/null 2>&1 && VPRES="$(cygpath -m "$VPRES" 2>/dev/null || printf '%s' "$VPRES")"
VPKEY_LC="$(printf '%s' "$VPKEY" | tr 'A-Z' 'a-z' | sed 's#\\#/#g')"
VPRES_LC="$(printf '%s' "$VPRES" | tr 'A-Z' 'a-z' | sed 's#\\#/#g')"
[ -n "$VPKEY_LC" ] && [ "$VPKEY_LC" = "$VPRES_LC" ] \
  && ok "ff-sweep: size cache key is the resolved run-dir path (lowercased)" \
  || bad "ff-sweep: size cache key wrong ('$VPKEY_LC' vs '$VPRES_LC')"
SCPOIS="$TMP/sweep-sizes-poison.json"
jq --arg k "$VPKEY" '.[$k].bytes = 999999999' "$SCF" > "$SCPOIS" && mv "$SCPOIS" "$SCF"
SWPO="$(bash "$S/ff-sweep.sh" --repo "$SWP" --json 2>/dev/null)"
printf '%s' "$SWPO" | jq -e '.[]|select(.run=="vpunm")|.bytes==999999999' >/dev/null \
  && ok "ff-sweep: valid size-cache entry HITS (poisoned bytes served from cache)" \
  || bad "ff-sweep: size cache never hit (entry with the live fp/by ignored)"
printf '%s' "$SWPO" | jq -e '.[]|select(.run=="vpunm")|.verdict=="holds-work" and .eligible==false' >/dev/null \
  && ok "ff-sweep: a size-cache HIT cannot flip a verdict (bytes cached, verdicts never)" \
  || bad "ff-sweep: size-cache hit changed a verdict (SAFETY)"
printf 'not json{at all' > "$FLEETFLOW_HOME/cache/sweep-sizes.json"
check "ff-sweep: malformed size cache does not crash the sweep" 0 \
  bash "$S/ff-sweep.sh" --repo "$SWP" --json
bash "$S/ff-sweep.sh" --repo "$SWP" --json 2>/dev/null \
  | jq -e '.[]|select(.run=="vpunm")|.verdict=="holds-work"' >/dev/null \
  && ok "ff-sweep: malformed size cache falls back (verdict still computed)" \
  || bad "ff-sweep: malformed size cache broke classification"

# The classification is NEVER cached (§1 / ADR-024): change a lane's state
# BETWEEN invocations with every cache warm from the pass above. A stale
# verdict cache - exactly the shortcut the poison fixtures imitate - would
# keep answering `reclaimable` for the now-dirty lane.
SWLV="$TMP/swlive"; mkdir -p "$SWLV" && git -C "$SWLV" init -q -b main
git -C "$SWLV" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkrunlanded "$SWLV" live                              # landed + clean -> reclaimable
SWL1="$(bash "$S/ff-sweep.sh" --repo "$SWLV" --json 2>/dev/null)"   # warms the caches
printf '%s' "$SWL1" | jq -e '.[]|select(.run=="live")|.verdict=="reclaimable" and .eligible==true' >/dev/null \
  && ok "ff-sweep: landed-clean run reads reclaimable (pre-state-change)" \
  || bad "ff-sweep: pre-change verdict wrong"
echo "UNLANDED EDIT" >> "$SWLV/.fleetflow/live/wt-a/a.txt"           # tracked mod
SWL2="$(bash "$S/ff-sweep.sh" --repo "$SWLV" --json 2>/dev/null)"
printf '%s' "$SWL2" | jq -e '.[]|select(.run=="live")|.verdict=="holds-work" and .holding==1 and .eligible==false' >/dev/null \
  && ok "ff-sweep: verdict recomputed live after lane state changed (no cached verdict)" \
  || bad "ff-sweep: verdict stale after a state change (classification cached? SAFETY)"
git -C "$SWLV/.fleetflow/live/wt-a" checkout -- a.txt                # revert the edit
SWL3="$(bash "$S/ff-sweep.sh" --repo "$SWLV" --json 2>/dev/null)"
printf '%s' "$SWL3" | jq -e '.[]|select(.run=="live")|.verdict=="reclaimable" and .eligible==true' >/dev/null \
  && ok "ff-sweep: verdict reverts when the worktree does (both directions live)" \
  || bad "ff-sweep: revert not reflected (verdict stuck)"

# P1 discovery reuse: the dashboard's `_discovery` entry is read only when
# source and TTL line up; ANY parse failure falls through to the find walk;
# --rediscover bypasses even a well-formed cache; and the cache holds PATHS
# ONLY - a cached entry for a run that holds work must never yield an eligible
# row. Roots come from $FLEETFLOW_HOME/roots.txt (no --repo/--root and
# FLEETFLOW_ROOTS unset at the top of this section - the env var outranks
# roots.txt and would redirect discovery at real repositories), which is the
# only mode the cache applies to.
#
# Proving REUSE needs a run the find walk can never see: `phantom`'s
# .fleetflow sits 8 levels below the discovery root, one level past the walk's
# -maxdepth 7. phantom in the output == the cache was read; phantom absent ==
# the walk ran. Every miss probe therefore also asserts the walkable fixture
# run is still found, so "cache ignored" can never masquerade as "cache hit".
DROOT="$TMP/swdisc"; DREPO="$DROOT/drepo"
mkdir -p "$DREPO" && git -C "$DREPO" init -q -b main
git -C "$DREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkrun "$DREPO" disc                                  # committed, unmerged -> holds work
PHANTOM="$DROOT/l1/l2/l3/l4/l5/l6/l7/l8/.fleetflow/phantom"
mkdir -p "$PHANTOM"
jq -nc '{run:"phantom",base:"main",created_by:"fixture",phases:["build"],packets:[]}' \
  > "$PHANTOM/manifest.json"
: > "$PHANTOM/journal.jsonl"
printf '%s\n' "$DROOT" > "$FLEETFLOW_HOME/roots.txt"
DISC_NOW="$(date +%s)"
if command -v cygpath >/dev/null 2>&1; then
  DISC_RD="$(cygpath -w "$DREPO/.fleetflow/disc")"; DISC_ROOT="$(cygpath -w "$DROOT")"
else DISC_RD="$DREPO/.fleetflow/disc"; DISC_ROOT="$DROOT"; fi
DISC_SRC="$FLEETFLOW_HOME/roots.txt"
disco_write() { # age-offset-seconds, source, include-phantom (0|1)
  jq -nc --argjson at "$((DISC_NOW - $1))" --arg src "$2" \
    --arg rd "$DISC_RD" --arg rt "$DISC_ROOT" --arg ph "$PHANTOM" --argjson phx "$3" '
    [ {rundir:$rd, run:"disc", repo:"drepo", repo_label:"drepo", root:$rt} ]
    + (if $phx == 1
       then [{rundir:$ph, run:"phantom", repo:"l8", repo_label:"l8", root:$rt}]
       else [] end)
    | {_discovery:{at:$at, source:$src, errors:[], entries:.}}' \
    > "$FLEETFLOW_HOME/cache/aggregate-cache.json"
}
# malformed cache -> the find walk must still find the fixture run
printf '{"_discovery": this is not json' > "$FLEETFLOW_HOME/cache/aggregate-cache.json"
DMAL_RC=0; DMAL="$(bash "$S/ff-sweep.sh" --json 2>/dev/null)" || DMAL_RC=$?
[ "$DMAL_RC" = 0 ] \
  && ok "ff-sweep: malformed aggregate-cache.json does not crash the sweep" \
  || bad "ff-sweep: malformed discovery cache crashed the sweep (rc=$DMAL_RC)"
printf '%s' "$DMAL" | jq -e '.[]|select(.run=="disc")|.verdict=="holds-work" and .eligible==false' >/dev/null \
  && ok "ff-sweep: malformed discovery cache falls through to the find walk" \
  || bad "ff-sweep: malformed discovery cache lost the fixture run"
# HIT: fresh, source-matching cache. disc's rundir is Windows-separated, as
# ff-aggregate.py writes it - the sweep must normalise. phantom proves the
# entries were actually served; disc's verdict proves cached PATHS still get
# live classification (the poison shape: a sweep caching verdicts would serve
# `reclaimable` for a work-holding run).
disco_write 0 "$DISC_SRC" 1
DHIT="$(bash "$S/ff-sweep.sh" --json 2>/dev/null)"
printf '%s' "$DHIT" | jq -e 'any(.[]; .run=="phantom")' >/dev/null \
  && ok "ff-sweep: fresh matching discovery cache IS reused (phantom run served)" \
  || bad "ff-sweep: discovery cache never hit (sweep always walks)"
printf '%s' "$DHIT" | jq -e '.[]|select(.run=="phantom")|.verdict=="reclaimable"' >/dev/null \
  && ok "ff-sweep: cache-sourced run still classified live from its path" \
  || bad "ff-sweep: cache-sourced row not classified"
printf '%s' "$DHIT" | jq -e '.[]|select(.run=="disc")|.verdict=="holds-work" and .eligible==false' >/dev/null \
  && ok "ff-sweep: cached discovery path still classified live (no eligible row for work)" \
  || bad "ff-sweep: discovery cache leaked into the verdict (SAFETY)"
# source mismatch -> miss -> walk
disco_write 0 "some-other-source" 1
DSRC="$(bash "$S/ff-sweep.sh" --json 2>/dev/null)"
printf '%s' "$DSRC" | jq -e 'any(.[]; .run=="phantom")' >/dev/null \
  && bad "ff-sweep: discovery cache used despite a source mismatch" \
  || ok "ff-sweep: source mismatch falls back to the find walk"
printf '%s' "$DSRC" | jq -e 'any(.[]; .run=="disc")' >/dev/null \
  && ok "ff-sweep: source-miss walk still finds the fixture run" \
  || bad "ff-sweep: source-miss walk lost the fixture run"
# TTL expiry (default 900s; cache 1h stale) -> miss -> walk
disco_write 3600 "$DISC_SRC" 1
DTTL="$(bash "$S/ff-sweep.sh" --json 2>/dev/null)"
printf '%s' "$DTTL" | jq -e 'any(.[]; .run=="phantom")' >/dev/null \
  && bad "ff-sweep: stale discovery cache used past the default TTL" \
  || ok "ff-sweep: expired discovery cache falls back to the walk (default TTL < 1h)"
printf '%s' "$DTTL" | jq -e 'any(.[]; .run=="disc")' >/dev/null \
  && ok "ff-sweep: expired-cache walk still finds the fixture run" \
  || bad "ff-sweep: expired-cache walk lost the fixture run"
# env TTL override: the same 1h-stale entry is fresh under FF_SWEEP_DISCOVER_TTL
disco_write 3600 "$DISC_SRC" 1
DENV="$(FF_SWEEP_DISCOVER_TTL=7200 bash "$S/ff-sweep.sh" --json 2>/dev/null)"
printf '%s' "$DENV" | jq -e 'any(.[]; .run=="phantom")' >/dev/null \
  && ok "ff-sweep: FF_SWEEP_DISCOVER_TTL extends reuse (env TTL honoured)" \
  || bad "ff-sweep: FF_SWEEP_DISCOVER_TTL ignored"
# CLI TTL override: --discover-ttl 7200 does the same
disco_write 3600 "$DISC_SRC" 1
DCLI="$(bash "$S/ff-sweep.sh" --discover-ttl 7200 --json 2>/dev/null)"
printf '%s' "$DCLI" | jq -e 'any(.[]; .run=="phantom")' >/dev/null \
  && ok "ff-sweep: --discover-ttl extends reuse (CLI TTL affects behaviour)" \
  || bad "ff-sweep: --discover-ttl has no behavioural effect"
# --rediscover bypasses even a fresh, matching cache
disco_write 0 "$DISC_SRC" 1
DRDY="$(bash "$S/ff-sweep.sh" --rediscover --json 2>/dev/null)"
printf '%s' "$DRDY" | jq -e 'any(.[]; .run=="phantom")' >/dev/null \
  && bad "ff-sweep: --rediscover used the discovery cache" \
  || ok "ff-sweep: --rediscover bypasses the discovery cache (find walk runs)"
printf '%s' "$DRDY" | jq -e 'any(.[]; .run=="disc")' >/dev/null \
  && ok "ff-sweep: --rediscover walk still finds the fixture run" \
  || bad "ff-sweep: --rediscover walk lost the fixture run"

# §1: the find walk prunes BELOW .fleetflow - a run a worker nested inside its
# own lane worktree (a repo cloned mid-run) is not fleetflow litter to reap.
# The fixture lives under the discovery root and the probe runs in WALK mode
# (--rediscover, roots.txt) - `--repo` mode never calls find_run_dirs, so a
# --repo probe could not see the prune at all.
NWR="$DROOT/nrepo"; mkdir -p "$NWR" && git -C "$NWR" init -q -b main
git -C "$NWR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkrunlanded "$NWR" outer
NEST="$NWR/.fleetflow/outer/wt-a/nested/.fleetflow/inner"
mkdir -p "$NEST"
jq -nc '{run:"inner",base:"main",created_by:"fixture",phases:["build"],packets:[]}' \
  > "$NEST/manifest.json"
: > "$NEST/journal.jsonl"
NWJ="$(bash "$S/ff-sweep.sh" --rediscover --json 2>/dev/null)"
printf '%s' "$NWJ" | jq -e 'any(.[]; .run=="inner")' >/dev/null \
  && bad "ff-sweep: walk descended below .fleetflow (nested run discovered)" \
  || ok "ff-sweep: find prunes below .fleetflow (lane-nested runs undiscovered)"
printf '%s' "$NWJ" | jq -e 'any(.[]; .run=="outer")' >/dev/null \
  && ok "ff-sweep: the hosting run itself is still discovered (walk mode)" \
  || bad "ff-sweep: hosting run lost"
NWRJ="$(bash "$S/ff-sweep.sh" --repo "$NWR" --json 2>/dev/null)"
printf '%s' "$NWRJ" | jq -e 'any(.[]; .run=="inner")' >/dev/null \
  && bad "ff-sweep: --repo mode listed a nested run" \
  || ok "ff-sweep: --repo mode stays at the top level of .fleetflow"

# ADR-020 deletion safety: --reclaim must remove EXACTLY the eligible rows.
# Everything above only READ `.eligible`; an implementation that reported it
# correctly but ignored it during deletion passed vacuously. keepme holds an
# unmerged commit (must survive); goner/dryone are landed and clean (must go).
# ADR-011 is asserted too: the removed run must be in the history store first.
RCL="$TMP/swrecl"; mkdir -p "$RCL" && git -C "$RCL" init -q -b main
git -C "$RCL" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkrun "$RCL" keepme                                  # committed, UNMERGED - must survive
mkrunlanded "$RCL" goner                             # landed + clean - must go
mkrunlanded "$RCL" dryone                            # landed + clean - dry run must keep
mkrunlanded "$RCL" dirty                             # landed, then ONE tracked edit - must survive
echo EDIT >> "$RCL/.fleetflow/dirty/wt-a/a.txt"
mkrunlanded "$RCL" litter                            # landed + untracked only - no opt-in, must survive
echo note > "$RCL/.fleetflow/litter/wt-a/note.md"
# `active` verdict on a lane that is landed AND clean: the journal says a second
# lane started but never returned, so classify() must say active/ineligible even
# though ff-clean alone would happily remove the clean worktree. This is the row
# that proves --reclaim re-checks eligibility rather than delegating safety to
# ff-clean's (weaker) dirty/committed lane defenses.
mkrunlanded "$RCL" zomb                              # landed + clean, one lane never returned
printf '{"type":"started","id":"b","at":1}\n' >> "$RCL/.fleetflow/zomb/journal.jsonl"
bash "$S/ff-sweep.sh" --repo "$RCL" --reclaim --dry-run >"$TMP/recl-dry.out" 2>"$TMP/recl-dry.err"; RDRY=$?
{ [ "$RDRY" = "0" ] && [ -d "$RCL/.fleetflow/dryone" ] && grep -q 'would remove' "$TMP/recl-dry.err"; } \
  && ok "ff-sweep --reclaim --dry-run: says what it would remove, removes nothing" \
  || bad "ff-sweep --reclaim --dry-run removed something (rc=$RDRY)"
ZOMBV="$(awk -F'\t' '$1=="zomb" {print $3}' "$TMP/recl-dry.out" | tr -d '\r')"
[ "$ZOMBV" = "active" ] \
  && ok "ff-sweep: never-returned lane reads active (not reclaimable)" \
  || bad "ff-sweep: active run misread as '$ZOMBV'"
FLEETFLOW_CACHE_ROOT="$TMP/swrecl-cache" \
  bash "$S/ff-sweep.sh" --repo "$RCL" --reclaim >/dev/null 2>"$TMP/recl.err"; RRC=$?
[ "$RRC" = "0" ] && ok "ff-sweep --reclaim exits 0" || bad "ff-sweep --reclaim rc=$RRC"
[ ! -d "$RCL/.fleetflow/goner" ] && [ ! -d "$RCL/.fleetflow/dryone" ] \
  && ok "ff-sweep --reclaim: eligible run dirs removed" \
  || bad "ff-sweep --reclaim left an eligible run dir behind"
[ -d "$RCL/.fleetflow/keepme" ] && [ -f "$RCL/.fleetflow/keepme/wt-a/a.txt" ] \
  && ok "ff-sweep --reclaim: holds-work run dir and its worktree survive (ADR-020)" \
  || bad "ff-sweep --reclaim DESTROYED AN INELIGIBLE RUN (SAFETY)"
grep -q keepme "$RCL/.fleetflow/keepme/wt-a/a.txt" \
  && ok "ff-sweep --reclaim: unmerged lane's file content intact" \
  || bad "ff-sweep --reclaim: surviving lane's work corrupted"
[ -d "$RCL/.fleetflow/dirty" ] && grep -q EDIT "$RCL/.fleetflow/dirty/wt-a/a.txt" \
  && ok "ff-sweep --reclaim: tracked-modified run survives (no --force without opt-in)" \
  || bad "ff-sweep --reclaim DESTROYED A TRACKED-MODIFIED RUN (SAFETY)"
[ -d "$RCL/.fleetflow/litter" ] && [ -f "$RCL/.fleetflow/litter/wt-a/note.md" ] \
  && ok "ff-sweep --reclaim: landed-untracked run survives without --include-untracked" \
  || bad "ff-sweep --reclaim removed an untracked-opt-out run (SAFETY)"
[ -d "$RCL/.fleetflow/zomb" ] && [ -f "$RCL/.fleetflow/zomb/wt-a/a.txt" ] \
  && ok "ff-sweep --reclaim: active (never-returned) run survives though its lane is clean" \
  || bad "ff-sweep --reclaim DESTROYED AN ACTIVE RUN (SAFETY)"
jq -e 'select(.run=="goner")' "$FLEETFLOW_HOME/history.jsonl" >/dev/null 2>&1 \
  && ok "ff-sweep --reclaim: archived the run before removing it (ADR-011)" \
  || bad "ff-sweep --reclaim removed a run with no history record"

# hermeticity backstop: FLEETFLOW_HOME redirected every cache written above,
# and the unset FLEETFLOW_ROOTS at the top of the section kept discovery off
# real repositories. The end-of-suite guard covers the real history store by
# byte count only - this one checksums the roots and caches a sweep would
# touch, so a redirect regression fails HERE, named.
SWEEP_HERM_AFTER="$(real_sweep_state_snap)"
[ "$SWEEP_HERM_BEFORE" = "$SWEEP_HERM_AFTER" ] \
  && ok "sweep section left the real store, roots and caches untouched" \
  || bad "sweep section touched real machine state"

# --- ff-chip: manually spawned chips as first-class lanes -----------------------
bash -n "$S/ff-chip.sh" 2>/dev/null && ok "syntax ff-chip.sh" || bad "syntax ff-chip.sh"
bash "$S/ff-chip.sh" --help 2>/dev/null | grep -q "EXAMPLES" \
  && ok "ff-chip.sh --help has EXAMPLES" || bad "ff-chip.sh --help lacks EXAMPLES"
check "ff-chip: no subcommand -> 2" 2 bash "$S/ff-chip.sh"
check "ff-chip: bad subcommand -> 2" 2 bash "$S/ff-chip.sh" frobnicate --run r --id a
check "ff-chip: open without a task -> 2" 2 bash "$S/ff-chip.sh" open --run r --id a --repo "$REPO"
check "ff-chip: close an unknown lane -> 3" 3 bash "$S/ff-chip.sh" close --run r1 --id ghost --repo "$REPO"
# "chip" must stay UNSPAWNABLE - a chip is launched by a human click, so a
# process that tries to spawn one is a bug, not a feature (mirrors "native").
check "ff-chip: chip is not a spawnable model" 2 \
  bash "$S/ff-spawn.sh" --run r1 --id c --model chip --prompt-file "$PKT" --repo "$REPO"

CHR="$TMP/chiprepo"; mkdir -p "$CHR" && git -C "$CHR" init -q -b main
git -C "$CHR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
CHOUT="$(bash "$S/ff-chip.sh" open --run ch --id lane1 --repo "$CHR" --task "Do the thing." 2>/dev/null)"
[ -d "$CHR/.fleetflow/ch/wt-lane1" ] \
  && ok "ff-chip open: creates the lane worktree (chip never touches the primary checkout)" \
  || bad "ff-chip open: no worktree lane"
git -C "$CHR" show-ref --verify --quiet refs/heads/fleetflow/ch/lane1 \
  && ok "ff-chip open: lane branch created" || bad "ff-chip open: no lane branch"
printf '%s' "$CHOUT" | grep -q 'cd "'"$CHR"'/.fleetflow/ch/wt-lane1"' \
  && ok "ff-chip open: seed prompt sends the chip into its lane first" \
  || bad "ff-chip open: seed prompt lacks the cd into the lane"
printf '%s' "$CHOUT" | grep -q "HARD CONSTRAINTS" \
  && ok "ff-chip open: seed prompt carries the guard preamble" \
  || bad "ff-chip open: guard preamble missing (chip would be unguarded)"
jq -e 'select(.type=="started" and .id=="lane1") | .model=="chip"' \
  "$CHR/.fleetflow/ch/journal.jsonl" >/dev/null 2>&1 \
  && ok "ff-chip open: journals a started record (model chip)" \
  || bad "ff-chip open: no started record"
jq -e '.packets[] | select(.id=="lane1") | .model=="chip" and .worktree==true' \
  "$CHR/.fleetflow/ch/manifest.json" >/dev/null 2>&1 \
  && ok "ff-chip open: manifest packet upserted" || bad "ff-chip open: no manifest packet"
# The heartbeat seed: without it a fresh lane reads `stalled` on the first poll
# (no transcript -> garbage last_activity), which is wrong for a chip nobody has
# clicked yet. Regression-guarded because the file looks like litter.
bash "$S/ff-status.sh" --run ch --repo "$CHR" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="lane1")|.state=="running" and .stalled==false' >/dev/null \
  && ok "ff-chip open: fresh lane reads running, not stalled (heartbeat seeded)" \
  || bad "ff-chip open: fresh lane misreported as stalled"
bash "$S/ff-status.sh" --run ch --repo "$CHR" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="lane1")|.live_signal==true' >/dev/null \
  && ok "ff-chip: lane carries live_signal (transcript introspection applies)" \
  || bad "ff-chip: no live_signal - chip lane would be invisible while running"

# close measures the lane rather than trusting a self-report
echo x > "$CHR/.fleetflow/ch/wt-lane1/x.txt"
git -C "$CHR/.fleetflow/ch/wt-lane1" add x.txt
git -C "$CHR/.fleetflow/ch/wt-lane1" -c user.email=t@t -c user.name=t commit -q -m "chip work"
bash "$S/ff-chip.sh" close --run ch --id lane1 --repo "$CHR" --note "did it" >/dev/null 2>&1
jq -e '.chip.commits==1 and .is_error==false' "$CHR/.fleetflow/ch/lane1.result.json" >/dev/null 2>&1 \
  && ok "ff-chip close: commits MEASURED from the lane, not self-reported" \
  || bad "ff-chip close: result envelope wrong"
bash "$S/ff-status.sh" --run ch --repo "$CHR" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="lane1")|.state=="done"' >/dev/null \
  && ok "ff-chip close: lane flips to done" || bad "ff-chip close: lane not done"
bash "$S/ff-collect.sh" --run ch --id lane1 --repo "$CHR" >/dev/null 2>&1 \
  && ok "ff-chip: closed lane gates through ff-collect unchanged" \
  || bad "ff-chip: ff-collect cannot read a chip lane"
# a failed chip closes nonzero and says so
bash "$S/ff-chip.sh" open --run ch --id lane2 --repo "$CHR" --task "abandoned" >/dev/null 2>&1
check "ff-chip close --rc 10 exits 10" 10 \
  bash "$S/ff-chip.sh" close --run ch --id lane2 --repo "$CHR" --rc 10 --note "wrong approach"
# resume reports chip packets as skipped - never silently dropped
bash "$S/ff-run.sh" resume --run ch --repo "$CHR" 2>/dev/null \
  | jq -e '[.[]|select(.status=="chip")] | length == 2' >/dev/null \
  && ok "ff-run resume: chip packets reported skipped (not replayed, not dropped)" \
  || bad "ff-run resume: chip packets mishandled"

# === ff-plan (ADR-026..031) ===
# Written BLIND against the frozen contract (C1 surface, C2 lint JSON/text,
# C3 frontmatter checks, C4 draft) — the implementation lands in a parallel
# lane, so assertions exercising lint/draft are EXPECTED to fail against the
# seeded stub here (subcommands exit 3) and are gated at integration.
# NB: ff-plan is deliberately NOT added to the syntax/help loop at the top of
# this file — that loop greps stdout only, while the stub (conformantly)
# prints usage to stderr; C1 says "stdout+stderr contains EXAMPLES", so the
# help grep below must capture both streams.
PLAN="$S/ff-plan.sh"
PREPO="$TMP/planrepo"
mkdir -p "$PREPO" && git -C "$PREPO" init -q -b main
git -C "$PREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# packet writer: frontmatter stays inside the restricted YAML subset C3
# parses (flat scalars + two-space "- item" lists between --- fences)
plan_pkt() { # run id, packet bytes on stdin
  mkdir -p "$PREPO/.fleetflow/$1/packets"
  cat > "$PREPO/.fleetflow/$1/packets/$2.task.md"
}

# static pins on the seeded templates (draft/roles lanes own the bytes; these
# pin the markers ff-plan draft is contracted to use — ADR-031)
grep -qF '<!-- role card prepended here by ff-plan draft -->' "$HERE/../assets/packet.tmpl.md" \
  && ok "ff-plan: packet.tmpl.md carries the role-card prepend marker" \
  || bad "ff-plan: role-card prepend marker missing from packet.tmpl.md"
[ "$(ls "$HERE/../assets/roles/"*.role.md 2>/dev/null | wc -l | tr -d ' ')" = "12" ] \
  && ok "ff-plan: twelve role cards seeded in assets/roles" \
  || bad "ff-plan: assets/roles does not hold 12 role cards"

bash -n "$PLAN" 2>/dev/null && ok "syntax ff-plan.sh" || bad "syntax ff-plan.sh"

# --- C1: surface + exit codes --------------------------------------------------
PLANHELP="$(bash "$PLAN" --help 2>&1)"; PLANRC=$?
{ [ "$PLANRC" = "0" ] && printf '%s' "$PLANHELP" | grep -q "EXAMPLES"; } \
  && ok "ff-plan: --help exits 0 with EXAMPLES on stdout+stderr" \
  || bad "ff-plan: --help rc=$PLANRC or EXAMPLES missing from stdout+stderr"
check "ff-plan: bogus subcommand -> 2" 2 bash "$PLAN" bogus

# --- C3 fixtures: one concern per run; packets only (lint's substrate is the
# packets dir — no manifest is contractually required) --------------------------
plan_pkt pconf a1 <<'PKT'
---
id: a1
role: Builder
class: build
model: sonnet
owns:
  - src/a.txt
modifies: []
registries: []
depends_on: []
---

Build A. FINAL REPLY: one line.
PKT
plan_pkt pconf a2 <<'PKT'
---
id: a2
role: Builder
class: build
model: sonnet
owns:
  - src/a.txt
modifies: []
registries: []
depends_on: []
---

Build B on the SAME file. FINAL REPLY: one line.
PKT
plan_pkt pdis d1 <<'PKT'
---
id: d1
role: Builder
class: build
model: sonnet
owns:
  - src/d1.txt
modifies: []
registries: []
depends_on: []
---

Build D1. FINAL REPLY: one line.
PKT
plan_pkt pdis d2 <<'PKT'
---
id: d2
role: Builder
class: build
model: sonnet
owns:
  - src/d2.txt
modifies: []
registries: []
depends_on: []
---

Build D2. FINAL REPLY: one line.
PKT
plan_pkt pcyc c1 <<'PKT'
---
id: c1
role: Builder
class: build
model: sonnet
owns:
  - src/c1.txt
modifies: []
registries: []
depends_on:
  - c2
---

Build C1 after C2. FINAL REPLY: one line.
PKT
plan_pkt pcyc c2 <<'PKT'
---
id: c2
role: Builder
class: build
model: sonnet
owns:
  - src/c2.txt
modifies: []
registries: []
depends_on:
  - c1
---

Build C2 after C1. FINAL REPLY: one line.
PKT
plan_pkt pdang g1 <<'PKT'
---
id: g1
role: Builder
class: build
model: sonnet
owns:
  - src/g1.txt
modifies: []
registries: []
depends_on:
  - ghost
---

Wait for a lane that does not exist. FINAL REPLY: one line.
PKT
plan_pkt prole r1 <<'PKT'
---
id: r1
role: Pirate
class: build
model: sonnet
owns:
  - src/r1.txt
modifies: []
registries: []
depends_on: []
---

A role outside the twelve. FINAL REPLY: one line.
PKT
plan_pkt preg e1 <<'PKT'
---
id: e1
role: Builder
class: build
model: sonnet
owns:
  - src/e1.txt
modifies: []
registries:
  - pyproject.toml
depends_on: []
---

E1. FINAL REPLY: one line.
PKT
plan_pkt preg e2 <<'PKT'
---
id: e2
role: Builder
class: build
model: sonnet
owns:
  - src/e2.txt
modifies: []
registries:
  - pyproject.toml
depends_on: []
---

E2 racing E1 on the registry. FINAL REPLY: one line.
PKT
plan_pkt pwarn w1 <<'PKT'
---
id: w1
role: Builder
class: build
model: sonnet
owns:
  - src/w.txt
modifies: []
registries: []
depends_on: []
---

W1 owns the file. FINAL REPLY: one line.
PKT
plan_pkt pwarn w2 <<'PKT'
---
id: w2
role: Scholar
class: build
model: sonnet
owns:
  - src/other.txt
modifies:
  - src/w.txt
registries: []
depends_on: []
---

W2 only modifies it. FINAL REPLY: one line.
PKT
plan_pkt proute t1 <<'PKT'
---
id: t1
role: Inspector
class: verify
model: glm
owns:
  - src/t1.txt
modifies: []
registries: []
depends_on: []
---

Verify on glm. FINAL REPLY: one line.
PKT
plan_pkt pbare naked <<'PKT'
No frontmatter at all — a legacy packet body, pre-ADR-026. FINAL REPLY: one
line. Frontmatter-dependent checks must report disarmed, not fail.
PKT

# --- C2: lint JSON on the conflict fixture --------------------------------------
check "ff-plan: lint conflicting owns exits 10" 10 \
  bash "$PLAN" lint --run pconf --repo "$PREPO" --json
PJ="$(bash "$PLAN" lint --run pconf --repo "$PREPO" --json 2>/dev/null)"; PJRC=$?
{ [ "$PJRC" = "10" ] \
  && printf '%s' "$PJ" | jq -e 'any(.findings[]; .check=="scope-conflict" and .severity=="hard")' >/dev/null; } \
  && ok "ff-plan: owns x owns overlap is a hard scope-conflict finding" \
  || bad "ff-plan: no hard scope-conflict finding (rc=$PJRC)"
printf '%s' "$PJ" | jq -e '(.findings|length)>=1 and all(.findings[];
    has("check") and has("severity") and has("packets") and has("files") and has("detail")
    and (.severity=="hard" or .severity=="warn")
    and ((.packets|type)=="array") and ((.files|type)=="array"))' >/dev/null 2>&1 \
  && ok "ff-plan: every finding carries the C2 key set" \
  || bad "ff-plan: finding objects deviate from the C2 shape"
printf '%s' "$PJ" | jq -e '(.checks|length)>=1 and all(.checks[];
    has("name") and has("armed") and has("reason") and ((.armed|type)=="boolean"))' >/dev/null 2>&1 \
  && ok "ff-plan: checks report name/armed/reason with a boolean armed" \
  || bad "ff-plan: checks array deviates from the C2 shape (ADR-030 armed status)"
# text mode: FINDING/CHECK lines (strip \r — Windows jq/bash emit CRLF); grep
# both streams since only the contract for stdout is "data", not its certainty
PTXT="$(bash "$PLAN" lint --run pconf --repo "$PREPO" 2>&1 | tr -d '\r')"
{ printf '%s\n' "$PTXT" | grep -q '^FINDING scope-conflict' \
  && printf '%s\n' "$PTXT" | grep -qE '^CHECK [A-Za-z0-9._-]+ armed'; } \
  && ok "ff-plan: text mode prints FINDING and CHECK armed lines" \
  || bad "ff-plan: text-mode FINDING/CHECK armed lines missing"

# --- C2/C3: clean fixture, then one hard rule per fixture ------------------------
DJ="$(bash "$PLAN" lint --run pdis --repo "$PREPO" --json 2>/dev/null)"; DJRC=$?
{ [ "$DJRC" = "0" ] && printf '%s' "$DJ" | jq -e '(.findings|length)==0' >/dev/null; } \
  && ok "ff-plan: disjoint owns lint clean (exit 0, findings empty)" \
  || bad "ff-plan: disjoint fixture not clean (rc=$DJRC)"
CJ="$(bash "$PLAN" lint --run pcyc --repo "$PREPO" --json 2>/dev/null)"; CJRC=$?
{ [ "$CJRC" = "10" ] \
  && printf '%s' "$CJ" | jq -e 'any(.findings[]; .check=="dep-edges" and .severity=="hard")' >/dev/null; } \
  && ok "ff-plan: dependency cycle is a hard dep-edges finding" \
  || bad "ff-plan: cycle not reported as hard dep-edges (rc=$CJRC)"
GJ="$(bash "$PLAN" lint --run pdang --repo "$PREPO" --json 2>/dev/null)"; GJRC=$?
{ [ "$GJRC" = "10" ] \
  && printf '%s' "$GJ" | jq -e 'any(.findings[]; .check=="dep-edges" and .severity=="hard")' >/dev/null; } \
  && ok "ff-plan: depends_on a missing id is a hard dep-edges finding" \
  || bad "ff-plan: dangling dependency not reported (rc=$GJRC)"
RJ="$(bash "$PLAN" lint --run prole --repo "$PREPO" --json 2>/dev/null)"; RJRC=$?
{ [ "$RJRC" = "10" ] \
  && printf '%s' "$RJ" | jq -e 'any(.findings[]; .check=="packet-contract")' >/dev/null; } \
  && ok "ff-plan: role outside the twelve is a packet-contract finding" \
  || bad "ff-plan: bad role not reported (rc=$RJRC)"
EGJ="$(bash "$PLAN" lint --run preg --repo "$PREPO" --json 2>/dev/null)"; EGRC=$?
{ [ "$EGRC" = "10" ] \
  && printf '%s' "$EGJ" | jq -e 'any(.findings[]; .check=="scope-conflict" and .severity=="hard")' >/dev/null; } \
  && ok "ff-plan: shared registries entry is a hard scope-conflict (ADR-030)" \
  || bad "ff-plan: registries overlap not hard (rc=$EGRC)"
WJ="$(bash "$PLAN" lint --run pwarn --repo "$PREPO" --json 2>/dev/null)"; WJRC=$?
{ [ "$WJRC" = "10" ] \
  && printf '%s' "$WJ" | jq -e 'any(.findings[]; .check=="scope-conflict" and .severity=="warn")' >/dev/null; } \
  && ok "ff-plan: owns x modifies overlap is a warn scope-conflict" \
  || bad "ff-plan: owns/modifies warn missing (rc=$WJRC)"
RTJ="$(bash "$PLAN" lint --run proute --repo "$PREPO" --json 2>/dev/null)"; RTRC=$?
{ [ "$RTRC" = "10" ] \
  && printf '%s' "$RTJ" | jq -e 'any(.findings[]; .check=="routing" and .severity=="warn")' >/dev/null; } \
  && ok "ff-plan: verify/judge class on glm is a warn routing finding" \
  || bad "ff-plan: glm routing warn missing (rc=$RTRC)"
BJ="$(bash "$PLAN" lint --run pbare --repo "$PREPO" --json 2>/dev/null)"; BJRC=$?
{ [ "$BJRC" = "0" ] \
  && printf '%s' "$BJ" | jq -e '(.findings|length)==0 and any(.checks[]; .armed==false)' >/dev/null; } \
  && ok "ff-plan: frontmatter-less packet -> no finding, a check reports disarmed" \
  || bad "ff-plan: bare packet mishandled (rc=$BJRC)"
BTXT="$(bash "$PLAN" lint --run pbare --repo "$PREPO" 2>&1 | tr -d '\r')"
printf '%s\n' "$BTXT" | grep -qE '^CHECK [A-Za-z0-9._-]+ disarmed' \
  && ok "ff-plan: text mode reports the disarmed check" \
  || bad "ff-plan: no CHECK disarmed line for the bare packet"

# --- C4: draft scaffolds the plan, refuses to clobber ----------------------------
check "ff-plan: draft with missing spec -> 3" 3 \
  bash "$PLAN" draft --run pmiss --spec "$TMP/no-such-spec.md" --repo "$PREPO"
PSPEC="$TMP/plan-spec.md"
printf '# Spec: shopfront\n\nBuild the shopfront.\n## Requirements\n- it works\n' > "$PSPEC"
bash "$PLAN" draft --run pdraft --spec "$PSPEC" --repo "$PREPO" >/dev/null 2>&1; PDRC=$?
PDDOC="$PREPO/docs/plans/PDRAFT-$(date +%Y-%m).md"
{ [ "$PDRC" = "0" ] && [ -f "$PDDOC" ] && [ -d "$PREPO/.fleetflow/pdraft/packets" ]; } \
  && ok "ff-plan: draft creates plan doc (uppercased run, YYYY-MM) + packets dir" \
  || bad "ff-plan: draft scaffolding wrong (rc=$PDRC doc=$PDDOC)"
PM="$PREPO/.fleetflow/pdraft/manifest.json"
jq -e '.created_by=="ff-plan"' "$PM" >/dev/null 2>&1 \
  && ok "ff-plan: manifest created_by is ff-plan" \
  || bad "ff-plan: manifest created_by wrong"
jq -e '(.plan|type)=="object" and (.plan|has("shape")) and (.plan|has("bounds"))' "$PM" >/dev/null 2>&1 \
  && ok "ff-plan: manifest plan key carries shape and bounds" \
  || bad "ff-plan: manifest plan key missing shape/bounds"
check "ff-plan: re-draft without --force -> 2" 2 \
  bash "$PLAN" draft --run pdraft --spec "$PSPEC" --repo "$PREPO"
jq -e '(.phases|type)=="array" and all(.phases[]; type=="string")' "$PM" >/dev/null 2>&1 \
  && ok "ff-plan: phases stays an array of strings" \
  || bad "ff-plan: phases is not an array of strings"

# --- the suite never touches the real machine-level store ----------------------
# Guards the isolation exported at the top of this file. Without it, ff-clean's
# archive-before-remove (ADR-011) writes throwaway `rc` runs into the history
# the machine-wide dashboard renders - and nothing ever cleans them out.
REAL_STORE_AFTER="$(real_store_size)"
[ "$REAL_STORE_BEFORE" = "$REAL_STORE_AFTER" ] \
  && ok "suite left ~/.fleetflow/history.jsonl untouched" \
  || bad "suite WROTE to the real history store ($REAL_STORE_BEFORE -> $REAL_STORE_AFTER bytes)"

echo "=== $PASS passed, $FAILN failed ==="
[ "$FAILN" = 0 ] || exit 1
exit 0
