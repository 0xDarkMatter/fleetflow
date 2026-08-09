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
for s in ff-spawn.sh ff-collect.sh ff-status.sh ff-doctor.sh ff-run.sh ff-clean.sh ff-import.sh; do
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
  WHTML="$(bash "$WIDGET" --run wwidget --repo "$WREPO" 2>"$TMP/widget.err")"; WHRC=$?
  [ "$WHRC" = "0" ] && [ -n "$WHTML" ] \
    && ok "waves widget: fixture renders an HTML fragment" \
    || bad "waves widget: render failed (rc=$WHRC)"
  HTTPS_N="$(printf '%s' "$WHTML" | grep -o 'https://' | wc -l | tr -d ' ')"
  { [ "$HTTPS_N" = "1" ] && printf '%s' "$WHTML" | grep -q 'href="https://fleetflow\.lab/'; } \
    && ok "waves widget: sole https occurrence is fleetflow.lab anchor" \
    || bad "waves widget: expected one fleetflow.lab https anchor (got $HTTPS_N)"
  printf '%s' "$WHTML" | grep -q 'http://' \
    && bad "waves widget: http URL emitted" || ok "waves widget: zero http occurrences"
  printf '%s' "$WHTML" | grep -qE '(^|[^[:alnum:]_.])(alert|confirm|prompt)[[:space:]]*\(' \
    && bad "waves widget: native browser dialog call emitted" \
    || ok "waves widget: no alert/confirm/prompt calls"
  printf '%s' "$WHTML" | grep -q 'sendPrompt(' \
    && ok "waves widget: footer uses sendPrompt actions" \
    || bad "waves widget: sendPrompt action missing"
  WAVE_EXPECT="$(jq -r '.waves|length' "$WM" | tr -d '\r')"; WAVE_RENDERED=0
  while IFS= read -r wave_name; do
    printf '%s' "$WHTML" | grep -q "$wave_name" && WAVE_RENDERED=$((WAVE_RENDERED+1))
  done < <(jq -r '.waves[].name' "$WM" | tr -d '\r')
  [ "$WAVE_RENDERED" = "$WAVE_EXPECT" ] \
    && ok "waves widget: wave-bar segment count matches fixture waves" \
    || bad "waves widget: rendered $WAVE_RENDERED/$WAVE_EXPECT wave segments"
  printf '%s' "$WHTML" | grep -qE '#[0-9a-fA-F]{6}' \
    && bad "waves widget: raw hex colour emitted" || ok "waves widget: no raw hex colours"
else
  echo "  SKIP  waves widget (ff-widget.sh absent)"
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

echo "=== $PASS passed, $FAILN failed ==="
[ "$FAILN" = 0 ] || exit 1
exit 0
