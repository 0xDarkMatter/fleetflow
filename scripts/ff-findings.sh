#!/usr/bin/env bash
# ff-findings.sh - findings ledger CLI for post-build waves (ADR-018 §1).
#
# WHY THIS EXISTS: every finder wave (qa, security, a11y, ...) emits defects;
# triage, fix packets, re-verify, gates, and the dashboards all need to read
# and mutate the SAME set of records without re-parsing prose. The ledger is
# .fleetflow/<run>/findings.jsonl, one JSON object per line, keyed by a
# content fingerprint (fp) so re-runs and re-verify rounds dedupe instead of
# piling up duplicate rows for the same defect.
#
# Ledger record: {id, fp, wave, severity, files[], claim, evidence, status,
# round, lane, ts}. `ts` is epoch-at-append and lives ONLY in the ledger -
# never in a packet (ADR-012 cache-key purity: a timestamp in a prompt makes
# every packet a fresh cache key).
#
# ATOMICITY: every mutating command loads the full ledger into memory,
# transforms it, and writes it back via mktemp + mv (never a bare `>>`).
# A simple append can't be a blind `>>` here because dedupe-by-fp sometimes
# means REWRITING an existing line (bump round/evidence/status), not just
# adding one - so the whole-file temp+mv discipline from ff-spawn.sh's
# manifest upsert applies, not the single-line-append discipline from
# ff-archive.sh's history store.
#
# stdout: JSON (data). stderr: chatter.
# Exit codes: 0 ok (including zero results/zero matches) | 2 usage/bad input
#             | 3 run or ledger missing
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"

usage() {
  cat <<'EOF'
Usage: ff-findings.sh append        --run NAME [--repo PATH] [--json JSON]
                                     [--round N] [--lane ID]
       ff-findings.sh list          --run NAME [--repo PATH]
                                     [--status S] [--severity S] [--wave W]
                                     [--min-severity S]
       ff-findings.sh count         --run NAME [--repo PATH]
                                     [--status S] [--severity S] [--wave W]
                                     [--min-severity S]
       ff-findings.sh set-status    --run NAME [--repo PATH] --fp FP --status S
       ff-findings.sh waive         --run NAME [--repo PATH] --fp FP --reason R
                                     [--expires DATE]
       ff-findings.sh apply-waivers --run NAME [--repo PATH]

  append          read finding(s) from --json or stdin: a single object, a
                  bare JSON array, an object with a "findings" array (the
                  finder FINAL REPLY shape, assets/findings.schema.json), or
                  newline-delimited JSON. Each finding needs wave, severity,
                  files[], claim, evidence. id/fp/ts are assigned here.
                  Dedupes by fp: an existing fp updates round/evidence/status
                  ONLY IF the incoming record's round is >= the stored one
                  (older/equal-round re-submissions of an already-advanced
                  finding are reported skipped, not applied); otherwise a new
                  record is appended with id "<wave>-<seq>" (zero-padded, per
                  wave). --round/--lane stamp records that omit those fields
                  (finder replies never carry them; the caller - fix/re-verify
                  loop - knows its own round and lane).
  list            filtered JSON array of ledger records, newest-appended last.
  count           filtered {"open":n,"fixed":n,"escalated":n,"waived":n}.
  set-status      set one record's status by fp (open|fixed|escalated|waived).
  waive           upsert docs/waivers.json (repo-level, committed; created
                  with [] if absent) AND set the matching ledger record's
                  status to "waived" if it already exists there.
  apply-waivers   mark every OPEN ledger record whose fp appears in
                  docs/waivers.json as "waived". Entries whose "expires"
                  (ISO date) has passed are skipped and warned on stderr.

  --min-severity S   filter to severity >= S on the low<medium<high<critical
                      ladder (combines with --severity as an AND, though
                      using both is rarely useful).

EXAMPLES
  echo '{"findings":[{"wave":"qa","severity":"high","files":["src/x.ts"],
    "claim":"null deref on empty cart","evidence":"repro: ..."}]}' \
    | ff-findings.sh append --run wave1 --round 0 --lane qa-1

  ff-findings.sh list --run wave1 --status open --min-severity high
  ff-findings.sh count --run wave1
  ff-findings.sh set-status --run wave1 --fp a1b2c3d4e5f6 --status fixed
  ff-findings.sh waive --run wave1 --fp a1b2c3d4e5f6 --reason "accepted risk, see #42"
  ff-findings.sh apply-waivers --run wave1
EOF
}

err() { echo "ff-findings: $*" >&2; }

SEV_ENUM="low medium high critical"
STATUS_ENUM="open fixed escalated waived"

is_in() { local x="$1"; shift; for w in "$@"; do [ "$x" = "$w" ] && return 0; done; return 1; }

# reqval N FLAG - guards the flag-parse loop's "${2:-}; shift 2" idiom
# (finding 8d368218ec13): a flag as the LAST argument leaves $2 empty and
# `shift 2` a no-op, so $1 never advances and the loop spins forever. Call
# with the loop's own $# (BEFORE consuming the value) so a missing value
# errors out instead of re-presenting the same flag.
reqval() { [ "$1" -ge 2 ] || { err "$2 requires a value"; usage >&2; exit 2; }; }

# validate_ledger - abort (exit 10) if $LEDGER exists but any line fails jq
# parse; the ledger is NEVER rewritten in that state (append/list/count all
# route through this before deriving output from ledger contents).
validate_ledger() {
  [ -f "$LEDGER" ] || return 0
  local jq_err
  jq_err="$(jq -c -s '.' "$LEDGER" 2>&1 >/dev/null)"
  if [ $? -ne 0 ]; then
    err "ledger is malformed, not modified: $jq_err"
    exit 10
  fi
}

# validate_waivers_file - abort (exit 10) if $WAIVERS exists but is not valid
# JSON, or is valid JSON that is not an array; docs/waivers.json is NEVER
# overwritten in that state. Sets WAIVERS_JSON to "[]" when absent, else the
# parsed array. Called before ANY read or write of the waivers file (waive
# upserts it, apply-waivers only reads it).
validate_waivers_file() {
  WAIVERS_JSON="[]"
  [ -f "$WAIVERS" ] || return 0
  local perr wtype
  perr="$(jq -c '.' "$WAIVERS" 2>&1 >/dev/null)"
  if [ $? -ne 0 ]; then
    err "waivers file is not valid JSON, not modified: $perr"
    exit 10
  fi
  wtype="$(jq -r 'type' "$WAIVERS" 2>/dev/null)"
  if [ "$wtype" != "array" ]; then
    err "waivers file is not a JSON array (type: $wtype), not modified"
    exit 10
  fi
  WAIVERS_JSON="$(jq -c '.' "$WAIVERS" 2>/dev/null)"
}

# acquire_lock - portable mkdir-spinlock around the ledger read-modify-write
# (finding 182717958712): two concurrent appends/mutations both loading the
# whole ledger then mv-replacing it is last-writer-wins. mkdir is atomic
# even on Windows Git Bash, unlike flock. Bounded wait ~10s, then exit 10.
# Released by an EXIT trap so it clears on any exit path (success or error).
acquire_lock() {
  LOCKDIR="$RUNDIR/.findings.lock"
  local waited=0
  until mkdir "$LOCKDIR" 2>/dev/null; do
    waited=$((waited+1))
    [ "$waited" -lt 100 ] || { err "timed out waiting for findings lock: $LOCKDIR"; exit 10; }
    sleep 0.1
  done
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
}

# write_ledger ARRAY_JSON - one record per line, temp+mv (see header comment).
write_ledger() {
  local arr="$1" tmp
  tmp="$(mktemp "$RUNDIR/findings.jsonl.XXXXXX" 2>/dev/null)" || { err "mktemp failed"; exit 3; }
  if ! printf '%s' "$arr" | jq -c '.[]' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; err "failed to serialize ledger"; exit 3
  fi
  mv -f "$tmp" "$LEDGER"
}

# load_ledger - EXISTING = ledger contents as a JSON array ("[]" if absent/empty).
load_ledger() {
  validate_ledger
  EXISTING="$(jq -c -s '.' "$LEDGER" 2>/dev/null)"
  [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ] || EXISTING="[]"
}

# main() wrapper - parse-before-execute guard (incident 2026-08-01; see the
# matching comment in ff-run.sh / ff-spawn.sh). Forces a full parse of this
# file before any line executes, so a concurrent skills-sync rewrite can't
# kill a run with a phantom syntax error mid-command. DO NOT unwrap this.
main() {

[ $# -gt 0 ] || { err "a subcommand is required"; usage >&2; exit 2; }
CMD="$1"; shift
case "$CMD" in
  append|list|count|set-status|waive|apply-waivers) ;;
  -h|--help) usage; exit 0 ;;
  *) err "unknown subcommand: $CMD"; usage >&2; exit 2 ;;
esac

RUN="" REPO="" JSON_ARG="" ROUND_FLAG="" LANE_FLAG=""
FILTER_STATUS="" FILTER_SEVERITY="" FILTER_WAVE="" FILTER_MINSEV=""
FP="" NEW_STATUS="" REASON="" EXPIRES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) reqval $# --run; RUN="$2"; shift 2 ;;
    --repo) reqval $# --repo; REPO="$2"; shift 2 ;;
    --json) reqval $# --json; JSON_ARG="$2"; shift 2 ;;
    --round) reqval $# --round; ROUND_FLAG="$2"; shift 2 ;;
    --lane) reqval $# --lane; LANE_FLAG="$2"; shift 2 ;;
    --status) reqval $# --status; FILTER_STATUS="$2"; NEW_STATUS="$2"; shift 2 ;;
    --severity) reqval $# --severity; FILTER_SEVERITY="$2"; shift 2 ;;
    --wave) reqval $# --wave; FILTER_WAVE="$2"; shift 2 ;;
    --min-severity) reqval $# --min-severity; FILTER_MINSEV="$2"; shift 2 ;;
    --fp) reqval $# --fp; FP="$2"; shift 2 ;;
    --reason) reqval $# --reason; REASON="$2"; shift 2 ;;
    --expires) reqval $# --expires; EXPIRES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
case "$RUN" in
  *[!a-z0-9-]*|'') err "invalid --run '$RUN' (must match ^[a-z0-9-]+\$)"; exit 2 ;;
esac
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

RUNDIR="$REPO/.fleetflow/$RUN"
LEDGER="$RUNDIR/findings.jsonl"
WAIVERS="$REPO/docs/waivers.json"

if [ "$CMD" != "append" ]; then
  [ -d "$RUNDIR" ] || { err "no such run: $RUNDIR"; exit 3; }
fi

if [ -n "$FILTER_SEVERITY" ] && ! is_in "$FILTER_SEVERITY" $SEV_ENUM; then
  err "bad --severity '$FILTER_SEVERITY' (want: $SEV_ENUM)"; exit 2
fi
if [ -n "$FILTER_MINSEV" ] && ! is_in "$FILTER_MINSEV" $SEV_ENUM; then
  err "bad --min-severity '$FILTER_MINSEV' (want: $SEV_ENUM)"; exit 2
fi
if [ -n "$FILTER_STATUS" ] && [ "$CMD" != "set-status" ] && ! is_in "$FILTER_STATUS" $STATUS_ENUM; then
  err "bad --status '$FILTER_STATUS' (want: $STATUS_ENUM)"; exit 2
fi

# jq helper: severity rank for --min-severity comparisons.
SEVRANK_DEF='def sevrank(s): {low:0,medium:1,high:2,critical:3}[s];'

case "$CMD" in

# --- append ------------------------------------------------------------------
append)
  mkdir -p "$RUNDIR" 2>/dev/null || { err "cannot create $RUNDIR"; exit 3; }
  acquire_lock

  if [ -n "$JSON_ARG" ]; then RAW="$JSON_ARG"; else RAW="$(cat)"; fi
  [ -n "$RAW" ] || { err "no input (stdin empty and --json not given)"; exit 2; }

  NORM="$(printf '%s' "$RAW" | jq -c -s '
    if length == 1 and (.[0] | type == "array") then .[0]
    elif length == 1 and (.[0] | type == "object") and (.[0] | has("findings")) then .[0].findings
    else .
    end' 2>/dev/null)"
  [ -n "$NORM" ] && [ "$NORM" != "null" ] || { err "input is not valid JSON or JSONL"; exit 2; }

  N="$(printf '%s' "$NORM" | jq 'length' 2>/dev/null)"
  [ -n "$N" ] 2>/dev/null || { err "input did not parse to a list of findings"; exit 2; }

  load_ledger
  NOW="$(date +%s)"
  TOUCHED="[]"
  APPENDED=0; UPDATED=0; SKIPPED=0
  i=0
  while [ "$i" -lt "$N" ]; do
    REC="$(printf '%s' "$NORM" | jq -c ".[$i]")"
    WAVE="$(printf '%s' "$REC" | jq -r '.wave // empty')"
    SEV="$(printf '%s' "$REC" | jq -r '.severity // empty')"
    FILES="$(printf '%s' "$REC" | jq -c 'if (.files|type)=="array" then .files else empty end' 2>/dev/null)"
    CLAIM="$(printf '%s' "$REC" | jq -r '.claim // empty')"
    EVID="$(printf '%s' "$REC" | jq -r '.evidence // empty')"

    if [ -z "$WAVE" ] || [ -z "$SEV" ] || [ -z "$FILES" ] || [ -z "$CLAIM" ] || [ -z "$EVID" ]; then
      err "record $i: missing required field (need wave/severity/files[]/claim/evidence) - skipped"
      SKIPPED=$((SKIPPED+1)); i=$((i+1)); continue
    fi
    if ! is_in "$SEV" $SEV_ENUM; then
      err "record $i: bad severity '$SEV' (want: $SEV_ENUM) - skipped"
      SKIPPED=$((SKIPPED+1)); i=$((i+1)); continue
    fi

    RROUND="$(printf '%s' "$REC" | jq -r 'if (.round|type)=="number" then .round else empty end' 2>/dev/null)"
    ROUND="${RROUND:-${ROUND_FLAG:-0}}"
    case "$ROUND" in ''|*[!0-9]*) ROUND=0 ;; esac
    RLANE="$(printf '%s' "$REC" | jq -r '.lane // empty')"
    LANE="${RLANE:-$LANE_FLAG}"
    RSTATUS="$(printf '%s' "$REC" | jq -r '.status // empty')"
    STATUS="${RSTATUS:-open}"
    is_in "$STATUS" $STATUS_ENUM || STATUS="open"

    # fp = first 12 hex of sha256(wave "\n" sorted-files-joined-by-comma "\n"
    # claim, lowercased with runs of whitespace collapsed to one space) -
    # constructed here because this is the only place a finding's identity is
    # ever computed; triage/fix/re-verify all key off the result, never
    # re-derive it.
    FILES_SORTED_JSON="$(printf '%s' "$FILES" | jq -c 'sort')"
    FILES_SORTED="$(printf '%s' "$FILES_SORTED_JSON" | jq -r 'join(",")')"
    CLAIM_NORM="$(printf '%s' "$CLAIM" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')"
    FP="$(printf '%s\n%s\n%s' "$WAVE" "$FILES_SORTED" "$CLAIM_NORM" | ff_sha256 | cut -c1-12)"

    MATCH_IDX="$(printf '%s' "$EXISTING" | jq -r --arg fp "$FP" '[.[] | .fp] | index($fp) // -1' 2>/dev/null)"
    if [ -n "$MATCH_IDX" ] && [ "$MATCH_IDX" != "-1" ] && [ "$MATCH_IDX" != "null" ]; then
      EXIST_ROUND="$(printf '%s' "$EXISTING" | jq -r ".[$MATCH_IDX].round // 0")"
      if [ "$ROUND" -ge "$EXIST_ROUND" ] 2>/dev/null; then
        EXISTING="$(printf '%s' "$EXISTING" | jq -c --argjson idx "$MATCH_IDX" --argjson round "$ROUND" \
          --arg evid "$EVID" --arg status "$STATUS" \
          '.[$idx].round = $round | .[$idx].evidence = $evid | .[$idx].status = $status')"
        TOUCHED="$(printf '%s' "$TOUCHED" | jq -c --argjson r "$(printf '%s' "$EXISTING" | jq -c ".[$MATCH_IDX]")" '. + [$r]')"
        UPDATED=$((UPDATED+1))
      else
        err "record $i (fp $FP): incoming round $ROUND < stored round $EXIST_ROUND - skipped"
        SKIPPED=$((SKIPPED+1))
      fi
    else
      SEQ="$(printf '%s' "$EXISTING" | jq -r --arg w "$WAVE" \
        '[.[] | select(.wave==$w) | (.id | capture("-(?<n>[0-9]+)$"; "") | .n | tonumber)] | max // -1' 2>/dev/null)"
      case "$SEQ" in ''|*[!0-9-]*) SEQ=-1 ;; esac
      SEQ=$((SEQ+1))
      ID="$(printf '%s-%03d' "$WAVE" "$SEQ")"
      NEWREC="$(jq -nc --arg id "$ID" --arg fp "$FP" --arg wave "$WAVE" --arg sev "$SEV" \
        --argjson files "$FILES_SORTED_JSON" --arg claim "$CLAIM" --arg evid "$EVID" --arg status "$STATUS" \
        --argjson round "$ROUND" --arg lane "$LANE" --argjson ts "$NOW" \
        '{id:$id,fp:$fp,wave:$wave,severity:$sev,files:$files,claim:$claim,evidence:$evid,
          status:$status,round:$round,lane:$lane,ts:$ts}')"
      EXISTING="$(printf '%s' "$EXISTING" | jq -c --argjson r "$NEWREC" '. + [$r]')"
      TOUCHED="$(printf '%s' "$TOUCHED" | jq -c --argjson r "$NEWREC" '. + [$r]')"
      APPENDED=$((APPENDED+1))
    fi
    i=$((i+1))
  done

  write_ledger "$EXISTING"
  err "append: $APPENDED new, $UPDATED updated, $SKIPPED skipped -> $LEDGER"
  printf '%s\n' "$TOUCHED" | jq -c '.'
  exit 0
  ;;

# --- list ----------------------------------------------------------------
list)
  [ -f "$LEDGER" ] || { printf '[]\n'; exit 0; }
  validate_ledger
  jq -c -s "$SEVRANK_DEF"'
    map(select(
      ($status == "" or .status == $status) and
      ($severity == "" or .severity == $severity) and
      ($wave == "" or .wave == $wave) and
      ($minsev == "" or (sevrank(.severity) >= sevrank($minsev)))
    ))' \
    --arg status "$FILTER_STATUS" --arg severity "$FILTER_SEVERITY" \
    --arg wave "$FILTER_WAVE" --arg minsev "$FILTER_MINSEV" \
    "$LEDGER"
  exit 0
  ;;

# --- count -----------------------------------------------------------------
count)
  [ -f "$LEDGER" ] || { printf '{"open":0,"fixed":0,"escalated":0,"waived":0}\n'; exit 0; }
  validate_ledger
  jq -c -s "$SEVRANK_DEF"'
    ( map(select(
        ($status == "" or .status == $status) and
        ($severity == "" or .severity == $severity) and
        ($wave == "" or .wave == $wave) and
        ($minsev == "" or (sevrank(.severity) >= sevrank($minsev)))
      ))
      | group_by(.status) | map({key: .[0].status, value: length}) | from_entries
    ) as $counts
    | {open:0,fixed:0,escalated:0,waived:0} + $counts' \
    --arg status "$FILTER_STATUS" --arg severity "$FILTER_SEVERITY" \
    --arg wave "$FILTER_WAVE" --arg minsev "$FILTER_MINSEV" \
    "$LEDGER"
  exit 0
  ;;

# --- set-status --------------------------------------------------------------
set-status)
  [ -n "$FP" ] || { err "--fp required"; usage >&2; exit 2; }
  [ -n "$NEW_STATUS" ] || { err "--status required"; usage >&2; exit 2; }
  is_in "$NEW_STATUS" $STATUS_ENUM || { err "bad --status '$NEW_STATUS' (want: $STATUS_ENUM)"; exit 2; }
  [ -f "$LEDGER" ] || { err "no ledger for run '$RUN'"; exit 3; }

  acquire_lock
  load_ledger
  MATCH_IDX="$(printf '%s' "$EXISTING" | jq -r --arg fp "$FP" '[.[] | .fp] | index($fp) // -1')"
  [ "$MATCH_IDX" != "-1" ] && [ "$MATCH_IDX" != "null" ] || { err "no finding with fp '$FP'"; exit 2; }

  EXISTING="$(printf '%s' "$EXISTING" | jq -c --argjson idx "$MATCH_IDX" --arg status "$NEW_STATUS" \
    '.[$idx].status = $status')"
  write_ledger "$EXISTING"
  printf '%s' "$EXISTING" | jq -c ".[$MATCH_IDX]"
  exit 0
  ;;

# --- waive -------------------------------------------------------------------
waive)
  [ -n "$FP" ] || { err "--fp required"; usage >&2; exit 2; }
  [ -n "$REASON" ] || { err "--reason required"; usage >&2; exit 2; }
  [ -f "$LEDGER" ] || { err "no ledger for run '$RUN'"; exit 3; }

  acquire_lock
  validate_waivers_file
  WEXISTING="$WAIVERS_JSON"
  TODAY="$(date +%F)"
  mkdir -p "$(dirname "$WAIVERS")" 2>/dev/null || true

  EXPJSON="null"
  [ -n "$EXPIRES" ] && EXPJSON="\"$EXPIRES\""
  WENTRY="$(jq -nc --arg fp "$FP" --arg reason "$REASON" --arg waived "$TODAY" --argjson expires "$EXPJSON" \
    '{fp:$fp,reason:$reason,waived:$waived,expires:$expires}')"
  WEXISTING="$(printf '%s' "$WEXISTING" | jq -c --argjson e "$WENTRY" --arg fp "$FP" \
    '(map(select(.fp != $fp))) + [$e]')"
  WTMP="$(mktemp "$(dirname "$WAIVERS")/waivers.json.XXXXXX" 2>/dev/null)" || { err "mktemp failed"; exit 3; }
  printf '%s\n' "$WEXISTING" | jq '.' > "$WTMP" && mv -f "$WTMP" "$WAIVERS" \
    || { rm -f "$WTMP"; err "failed to write $WAIVERS"; exit 3; }

  load_ledger
  MATCH_IDX="$(printf '%s' "$EXISTING" | jq -r --arg fp "$FP" '[.[] | .fp] | index($fp) // -1')"
  if [ "$MATCH_IDX" != "-1" ] && [ "$MATCH_IDX" != "null" ]; then
    EXISTING="$(printf '%s' "$EXISTING" | jq -c --argjson idx "$MATCH_IDX" '.[$idx].status = "waived"')"
    write_ledger "$EXISTING"
  else
    err "fp '$FP' not yet in ledger - waiver recorded, will apply on a future apply-waivers/append"
  fi
  printf '%s\n' "$WENTRY"
  exit 0
  ;;

# --- apply-waivers -------------------------------------------------------
apply-waivers)
  [ -f "$WAIVERS" ] || { err "no waivers file at $WAIVERS - nothing to apply"; printf '{"applied":0,"expired":0}\n'; exit 0; }
  [ -f "$LEDGER" ] || { err "no ledger for run '$RUN'"; exit 3; }

  acquire_lock
  validate_waivers_file
  WLIST="$WAIVERS_JSON"
  TODAY="$(date +%F)"

  load_ledger
  APPLIED=0; EXPIRED=0
  WN="$(printf '%s' "$WLIST" | jq 'length')"
  i=0
  while [ "$i" -lt "$WN" ]; do
    WFP="$(printf '%s' "$WLIST" | jq -r ".[$i].fp")"
    WEXP="$(printf '%s' "$WLIST" | jq -r ".[$i].expires // empty")"
    if [ -n "$WEXP" ] && [ "$WEXP" \< "$TODAY" ]; then
      err "waiver for fp '$WFP' expired on $WEXP - ignored"
      EXPIRED=$((EXPIRED+1)); i=$((i+1)); continue
    fi
    MATCH_IDX="$(printf '%s' "$EXISTING" | jq -r --arg fp "$WFP" \
      '[.[] | .fp] | index($fp) // -1')"
    if [ "$MATCH_IDX" != "-1" ] && [ "$MATCH_IDX" != "null" ]; then
      CUR_STATUS="$(printf '%s' "$EXISTING" | jq -r ".[$MATCH_IDX].status")"
      if [ "$CUR_STATUS" = "open" ]; then
        EXISTING="$(printf '%s' "$EXISTING" | jq -c --argjson idx "$MATCH_IDX" '.[$idx].status = "waived"')"
        APPLIED=$((APPLIED+1))
      fi
    fi
    i=$((i+1))
  done

  write_ledger "$EXISTING"
  err "apply-waivers: $APPLIED applied, $EXPIRED expired-and-ignored"
  jq -nc --argjson a "$APPLIED" --argjson e "$EXPIRED" '{applied:$a,expired:$e}'
  exit 0
  ;;

esac

}

main "$@"
