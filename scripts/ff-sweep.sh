#!/usr/bin/env bash
# ff-sweep.sh - machine-wide housekeeping: what has fleetflow left on disk, and
# what is provably safe to reclaim.
#
# WHY THIS EXISTS: ff-clean answers "tear down THIS run". Nothing answered "what
# is still on disk across every repo on this box", and ff-clean's decision table
# never auto-removes a committed lane - correct while the work is unlanded,
# wrong forever after. So every SUCCESSFUL run's lanes accumulated silently:
# 1.6 GB across 12 never-cleaned runs in a single repo when this was measured
# (2026-08-12), plus 27 stale branches and 6 registered worktrees. `.fleetflow/`
# is gitignored, so `git status` could not see it either.
#
# A run dir is RECLAIMABLE only when BOTH hold:
#   1. it is already archived to the history store, so the record outlives the
#      directory (ADR-011 archive-before-remove); and
#   2. every lane is landed - its commits are an ancestor of the run's base -
#      or has no worktree left at all.
# Everything else is reported and left alone. Unmerged commits and dirty trees
# are original work that no merge contains; no sweep may delete them.
# See docs/adr/ADR-020-sweep-reclaims-only-archived-and-landed.md.
#
# BOUNDARY - this script owns `<repo>/.fleetflow/` and NOTHING ELSE. It never
# touches `.claude/worktrees/`: those are Claude Code session state, they are
# not fleetflow's to reap, and one that looks abandoned may be a live session.
# The discovery walk descends THROUGH .claude/worktrees to find runs hosted
# inside a session's worktree, but only ever acts on the .fleetflow dir it finds
# there.
#
# Teardown itself is NOT reimplemented here: reclaiming shells out to
# ff-clean.sh, which owns the NTFS retry, cache-dir removal, the archive step,
# and the reap anchors. This script is discovery + policy only.
#
# ff-clean needed NO new flag for this, which is worth writing down because it
# is not obvious and a `--landed` flag was built and then deleted before this
# shipped: `git rev-list --count $BASE..HEAD` is ALREADY 0 for a landed lane -
# it is the same question as `merge-base --is-ancestor` - so ff-clean's existing
# "zero commits + clean -> removed" row reclaims landed lanes today. The disk
# that accumulated was never ff-clean refusing; it was ff-clean never being run.
# Visibility, not a new teardown rule, is what was missing. See ADR-020.
#
# stdout: TSV (run, repo_label, verdict, lanes, bytes, detail) or --json.
# stderr: chatter. Exit codes: 0 ok | 2 usage | 3 no runs found
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FF_HOME="${FLEETFLOW_HOME:-$HOME/.fleetflow}"

usage() {
  cat <<'EOF'
Usage: ff-sweep.sh [--list] [--root PATH]... [--repo PATH] [--older-than DAYS] [--json]
       ff-sweep.sh --reclaim [--root PATH]... [--repo PATH] [--older-than DAYS] [--dry-run]

  --list            report only (default): every fleetflow run dir still on disk
  --reclaim         remove the run dirs whose verdict is `reclaimable`
  --dry-run         with --reclaim, print what would be removed and stop
  --root PATH       discovery root (repeatable)
  --repo PATH       a single repo instead of a root walk
  --older-than N    only consider runs whose newest file is older than N days
  --json            emit a JSON array instead of TSV
  --no-size         skip disk sizing (bytes is `-` in TSV and null in JSON)
  --rediscover      ignore the dashboard's cached discovery paths
  --discover-ttl N  reuse cached discovery for N seconds (default: 900;
                    env FF_SWEEP_DISCOVER_TTL)

  --include-untracked
                    also reclaim `landed-untracked` runs (see below). Their
                    untracked paths are printed by --list first; read them.

VERDICTS
  reclaimable       archived AND every lane landed (or gone) - safe to remove
  landed-untracked  every lane landed, but untracked leftovers exist. KEPT
                    unless --include-untracked. The paths are always listed.
  holds-work        a lane has TRACKED modifications or unmerged commits - KEPT
  not-archived      no history record yet (--reclaim archives it first) - KEPT
  active            a lane never returned a result - KEPT

  Only `reclaimable` is ever removed by default. A run with tracked
  modifications or unmerged commits is never deleted under any flag.

  ROOTS resolve like ff-aggregate.py: --root (repeatable) > $FLEETFLOW_ROOTS
  (os path separator) > ~/.fleetflow/roots.txt > the current git repo.

EXAMPLES
  ff-sweep.sh                                  # what is on this box
  ff-sweep.sh --json | jq -r '.[] | select(.verdict=="reclaimable") | .rundir'
  ff-sweep.sh --reclaim --dry-run              # what WOULD be removed
  ff-sweep.sh --reclaim --older-than 14        # reclaim landed runs over 2w old
  ff-sweep.sh --repo X:/Evolution7/Ledger --list | column -t
  ff-sweep.sh --no-size                        # fast verdicts without du
  ff-sweep.sh --rediscover                     # force a fresh root walk
  ff-sweep.sh --discover-ttl 60                # reuse discovery for one minute
EOF
}

err() { echo "ff-sweep: $*" >&2; }

MODE=list OLDER="" JSON=0 DRY=0 REPO_ONE="" UNTRACKED_OK=0 NO_SIZE=0 REDISCOVER=0
DISCOVER_TTL="${FF_SWEEP_DISCOVER_TTL:-900}"
ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --reclaim) MODE=reclaim; shift ;;
    --include-untracked) UNTRACKED_OK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --json) JSON=1; shift ;;
    --no-size) NO_SIZE=1; shift ;;
    --rediscover) REDISCOVER=1; shift ;;
    --discover-ttl) [ $# -ge 2 ] || { err "--discover-ttl requires seconds"; exit 2; }; DISCOVER_TTL="$2"; shift 2 ;;
    --root) ROOTS+=("${2:-}"); shift 2 ;;
    --repo) REPO_ONE="${2:-}"; shift 2 ;;
    --older-than) OLDER="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
command -v git >/dev/null || { err "git required"; exit 2; }
case "${OLDER:-0}" in ''|*[!0-9]*) [ -z "$OLDER" ] || { err "--older-than wants a number of days"; exit 2; } ;; esac
case "$DISCOVER_TTL" in ''|*[!0-9]*) err "--discover-ttl wants a number of seconds"; exit 2 ;; esac

# --- discovery ----------------------------------------------------------------
# Mirrors ff-aggregate.py's resolve_roots() precedence exactly so the sweep and
# the dashboard can never disagree about which repos exist on this machine.
resolve_roots() {
  if [ "${#ROOTS[@]}" -gt 0 ]; then printf '%s\n' "${ROOTS[@]}"; return; fi
  if [ -n "${FLEETFLOW_ROOTS:-}" ]; then
    printf '%s' "$FLEETFLOW_ROOTS" | tr ';:' '\n\n' | awk 'NF'
    return
  fi
  if [ -f "$FF_HOME/roots.txt" ]; then
    local n
    n="$(awk 'NF && $0 !~ /^[[:space:]]*#/' "$FF_HOME/roots.txt" | tr -d '\r')"
    if [ -n "$n" ]; then printf '%s\n' "$n"; return; fi
  fi
  git rev-parse --show-toplevel 2>/dev/null
}

# The aggregate discovery cache records which precedence branch produced its
# roots. Keep this in lock-step with resolve_roots() and ff-aggregate.py.
roots_source() {
  if [ "${#ROOTS[@]}" -gt 0 ]; then printf '%s\n' "--root"; return; fi
  if [ -n "${FLEETFLOW_ROOTS:-}" ]; then printf '%s\n' "FLEETFLOW_ROOTS"; return; fi
  if [ -f "$FF_HOME/roots.txt" ] \
     && awk 'NF && $0 !~ /^[[:space:]]*#/{found=1} END{exit !found}' "$FF_HOME/roots.txt"; then
    printf '%s\n' "$FF_HOME/roots.txt"
    return
  fi
  printf '%s\n' "git toplevel (fallback)"
}

# find_run_dirs: every <repo>/.fleetflow/<run>/ holding a journal.jsonl.
# `find` rather than fd: this ships to any host and may not have fd installed,
# and the repo's rule is bash + jq, no new runtime deps. The prune list mirrors
# ff-aggregate.py's PRUNE; `.claude` is deliberately NOT pruned (runs hosted
# inside a Claude Code worktree session are real runs - see the BOUNDARY note).
find_run_dirs() {
  local root="$1"
  [ -d "$root" ] || { err "root is not a directory: $root"; return 0; }
  find "$root" -maxdepth 7 \( \
      -name node_modules -o -name .git -o -name .venv -o -name venv \
      -o -name __pycache__ -o -name dist -o -name build -o -name target \
      -o -name .next -o -name .nuxt -o -name .cache -o -name .pytest_cache \
      -o -name .mypy_cache -o -name vendor -o -name .terraform \
      -o -name AppData -o -name Library \
    \) -prune -o -type d -name .fleetflow -print -prune 2>/dev/null \
  | while read -r ffdir; do
      local d
      for d in "$ffdir"/*/; do
        [ -f "${d}journal.jsonl" ] || continue   # e.g. a served monitor/ dir
        printf '%s\n' "${d%/}"
      done
    done
}

# Read-only coupling to ff-aggregate.py's shared `_discovery` shape. The caller
# falls back to find_run_dirs on every parse, source, age, or shape failure.
read_discovery_cache() {
  local cache="$FF_HOME/cache/aggregate-cache.json" source="$1" now="$2"
  [ -f "$cache" ] || return 1
  jq -r --arg source "$source" --argjson now "$now" --argjson ttl "$DISCOVER_TTL" '
    ._discovery as $d
    | if (($d | type) == "object"
          and ($d.entries | type) == "array"
          and ([ $d.entries[] | (.rundir | type) ] | all(. == "string"))
          and ($d.source == $source
               or (($d.source | gsub("\\\\";"/") | ascii_downcase)
                   == ($source | gsub("\\\\";"/") | ascii_downcase)))
          and ($d.at | type) == "number"
          and ($now - $d.at) < $ttl)
      then ($d.entries[].rundir | gsub("\\\\";"/"))
      else error("discovery cache miss") end' "$cache" 2>/dev/null \
    | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

# repo_label: same worktree collapse as ff-archive.sh / ff-aggregate.py, so one
# run reads with one name everywhere it is displayed.
repo_label() {
  local p="${1//\\//}" base
  case "$p" in
    */.claude/worktrees/*)
      base="${p%%/.claude/worktrees/*}"
      printf '%s@%s' "${base##*/}" "${p##*/}" ;;
    *) printf '%s' "${p##*/}" ;;
  esac
}

# archived_p <repo> <run>: does the history store already hold this run? The key
# is (repo, run) lowercased - the same key ff-aggregate.py's load_history() uses
# to decide last-record-wins, so "archived" means exactly "the dashboard will
# still show this run after the directory is gone".
HIST="$FF_HOME/history.jsonl"
TMP_FILES=()
cleanup_tmp() { local f; for f in "${TMP_FILES[@]}"; do rm -f "$f"; done; }
trap cleanup_tmp EXIT
EMPTY_JSON="$(mktemp ./ff-sweep-empty.XXXXXX)"; TMP_FILES+=("$EMPTY_JSON")
HIST_KEYS="$(mktemp ./ff-sweep-history.XXXXXX)"; TMP_FILES+=("$HIST_KEYS")
if [ -f "$HIST" ]; then
  jq -sr '.[] | [((.repo // "") | ascii_downcase), ((.run // "") | ascii_downcase)] | @tsv' \
    "$HIST" 2>/dev/null | tr -d '\r' | sort -u > "$HIST_KEYS"
fi
archived_p() {
  local key="${1,,}"$'\t'"${2,,}"
  grep -Fxq "$key" "$HIST_KEYS"
}

# Size data is cosmetic: this cache is never consulted by classify(). Its
# fingerprint mirrors ff-aggregate.py's non-recursive child-count/newest-mtime
# shape, while the producer stamp invalidates entries when this reader changes.
SIZE_CACHE="$FF_HOME/cache/sweep-sizes.json"
SIZE_BASE="$(mktemp ./ff-sweep-sizes-base.XXXXXX)"; TMP_FILES+=("$SIZE_BASE")
SIZE_UPDATES="$(mktemp ./ff-sweep-sizes-updates.XXXXXX)"; TMP_FILES+=("$SIZE_UPDATES")
if [ "$NO_SIZE" = 0 ] && [ -f "$SIZE_CACHE" ]; then
  jq -c 'if type == "object" then . else {} end' "$SIZE_CACHE" 2>/dev/null > "$SIZE_BASE" \
    || printf '{}\n' > "$SIZE_BASE"
else
  printf '{}\n' > "$SIZE_BASE"
fi
SIZE_BY="$FF_VERSION:$(stat -c '%Y:%s' "$HERE/ff-sweep.sh" 2>/dev/null || printf '?')"

size_fingerprint() {
  find "$1" -mindepth 1 -maxdepth 1 -printf '%T@\n' 2>/dev/null \
    | awk 'BEGIN{n=0;m=0;r="0"} {n++; if ($1>m) {m=$1;r=$0}} END{printf "[%d,\"%s\"]\n", n, r}'
}

dir_bytes() {
  local rundir="$1" resolved key fp bytes
  resolved="$(cd "$rundir" 2>/dev/null && pwd -P)" || resolved="$rundir"
  key="${resolved//\\//}"; key="${key,,}"
  fp="$(size_fingerprint "$rundir")"
  bytes="$(jq -er --arg k "$key" --argjson fp "$fp" --arg by "$SIZE_BY" '
    .[$k] | select(.fp == $fp and .by == $by and (.bytes | type) == "number"
                  and .bytes >= 0) | .bytes' "$SIZE_BASE" 2>/dev/null | tr -d '\r')"
  case "$bytes" in ''|*[!0-9]*) bytes="" ;; esac
  if [ -z "$bytes" ]; then
    bytes="$(du -s "$rundir" 2>/dev/null | awk '{print $1*1024}')"
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    jq -nc --arg key "$key" --argjson fp "$fp" --arg by "$SIZE_BY" \
      --argjson bytes "$bytes" --argjson at "$NOW" \
      '{key:$key,value:{fp:$fp,by:$by,bytes:$bytes,at:$at}}' >> "$SIZE_UPDATES"
  fi
  printf '%s\n' "$bytes"
}

write_size_cache() {
  [ -s "$SIZE_UPDATES" ] || return
  [ "$NO_SIZE" = 0 ] || return
  mkdir -p "$FF_HOME/cache" || return
  local tmp="$SIZE_CACHE.tmp.$$"
  jq -s '.[0] as $base | reduce (.[1:][]) as $u ($base; .[$u.key] = $u.value)' \
    "$SIZE_BASE" "$SIZE_UPDATES" > "$tmp" 2>/dev/null && mv -f "$tmp" "$SIZE_CACHE"
  rm -f "$tmp"
}

# --- per-run verdict ----------------------------------------------------------
# Delegates lane state to the same facts ff-clean reads (manifest base, wt-* dirs,
# rev-list, status --porcelain). Deliberately NOT a second implementation of
# ff-status: this asks a narrower question ("is the work in the base yet?") that
# ff-status does not answer at all.
declare -A BASE_REFS=()
classify() {
  local rundir="$1" repo="$2" run="$3"
  local manifest="$rundir/manifest.json" journal="$rundir/journal.jsonl" base wt id base_key
  local lanes=0 landed=0 holding=0 gone=0 running=0 detail=""
  local manifest_in="$manifest" journal_in="$journal"

  [ -f "$manifest_in" ] || manifest_in="$EMPTY_JSON"
  [ -f "$journal_in" ] || journal_in="$EMPTY_JSON"
  IFS=$'\t' read -r base running < <(jq -nr --rawfile m "$manifest_in" --rawfile j "$journal_in" '
    ($m | fromjson? // {}) as $manifest
    | ($j | split("\n") | map(fromjson?)) as $journal
    | [($manifest.base // "main"), ((([$journal[] | select(.type=="started") | .id] | unique)
      - ([$journal[] | select(.type=="result") | .id] | unique)) | length)] | @tsv' 2>/dev/null | tr -d '\r')
  [ -n "$base" ] && [ "$base" != "null" ] || base="main"
  case "${running:-0}" in ''|*[!0-9]*) running=0 ;; esac
  base_key="${repo,,}"$'\t'"${base,,}"
  if [ -z "${BASE_REFS[$base_key]+x}" ]; then
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$base"; then
      BASE_REFS[$base_key]="$base"
    else
      BASE_REFS[$base_key]=HEAD
    fi
  fi

  base="${BASE_REFS[$base_key]}"
  # TRACKED changes and UNTRACKED files are not the same risk, and collapsing
  # them made the sweep useless in practice: measured on this box, every large
  # landed run was blocked by exactly ONE untracked leftover per lane (a plan
  # doc, a screenshots dir) while holding zero tracked modifications. A tracked
  # edit is work the base does not have; an untracked file usually is not, but
  # occasionally is - so it gets its own verdict and its paths are always
  # printed, never silently swept.
  local untracked=0 upaths="" tracked untr oid line path
  for wt in "$rundir"/wt-*; do
    [ -d "$wt" ] || continue
    lanes=$((lanes+1))
    id="${wt##*/}"; id="${id#wt-}"
    tracked=0; untr=0; oid=""; path=""
    while IFS= read -r line; do
      case "$line" in
        '1 '*|'2 '*|'u '*) tracked=$((tracked+1)) ;;
        '? '*)
          untr=$((untr+1)); path="${line#??}"
          upaths="${upaths}${upaths:+ }$path" ;;
        '# branch.oid '*) oid="${line#\# branch.oid }" ;;
        '# '*) ;; # porcelain-v2 headers are metadata, never tracked changes
      esac
    done < <(git -C "$wt" status --porcelain=v2 --branch 2>/dev/null)
    if [ "$tracked" -gt 0 ]; then
      holding=$((holding+1)); detail="${detail}${detail:+,}$id:modified"
    elif [ -z "$oid" ] || [ "$oid" = "(initial)" ] \
         || ! git -C "$repo" merge-base --is-ancestor "$oid" "$base" 2>/dev/null; then
      holding=$((holding+1)); detail="${detail}${detail:+,}$id:unmerged"
    else
      landed=$((landed+1))
      if [ "$untr" -gt 0 ]; then
        untracked=$((untracked+untr))
      fi
    fi
  done
  [ "$lanes" = 0 ] && gone=1

  # Verdict describes the WORK only. "Is it archived yet?" is a separate,
  # independently fixable fact - archiving is non-destructive (ADR-011), so
  # --reclaim just does it rather than making the operator run a second command.
  local verdict archived=false
  archived_p "$repo" "$run" && archived=true
  if [ "${running:-0}" -gt 0 ]; then verdict=active; detail="${running} lane(s) never returned"
  elif [ "$holding" -gt 0 ]; then verdict=holds-work
  elif [ "$untracked" -gt 0 ]; then verdict=landed-untracked; detail="$untracked untracked: $upaths"
  else verdict=reclaimable
    [ "$gone" = 1 ] && detail="no lanes on disk" || detail="$landed landed"
  fi
  CLASSIFY_VERDICT="$verdict" CLASSIFY_LANES="$lanes" CLASSIFY_LANDED="$landed"
  CLASSIFY_HOLDING="$holding" CLASSIFY_ARCHIVED="$archived" CLASSIFY_DETAIL="$detail"
}

# --- walk ---------------------------------------------------------------------
NOW="$(date +%s)"
RUNDIRS=""
DISCOVERY_HIT=0
if [ -n "$REPO_ONE" ]; then
  [ -d "$REPO_ONE/.fleetflow" ] || { err "no .fleetflow in $REPO_ONE"; exit 3; }
  for d in "$REPO_ONE/.fleetflow"/*/; do
    [ -f "${d}journal.jsonl" ] && RUNDIRS="$RUNDIRS${d%/}
"
  done
elif [ "${#ROOTS[@]}" = 0 ] && [ "$REDISCOVER" = 0 ]; then
  source="$(roots_source)"
  if RUNDIRS="$(read_discovery_cache "$source" "$NOW")"; then
    DISCOVERY_HIT=1
  else
    RUNDIRS=""
  fi
fi
if [ -z "$RUNDIRS" ] && [ -z "$REPO_ONE" ] && [ "$DISCOVERY_HIT" = 0 ]; then
  while read -r root; do
    [ -n "$root" ] || continue
    RUNDIRS="$RUNDIRS$(find_run_dirs "$root")
"
  done < <(resolve_roots)
fi
RUNDIRS="$(printf '%s' "$RUNDIRS" | awk 'NF && !seen[$0]++')"
[ -n "$RUNDIRS" ] || { err "no fleetflow run dirs found"; exit 3; }

ROWS_FILE="$(mktemp ./ff-sweep-rows.XXXXXX)"; TMP_FILES+=("$ROWS_FILE")
TOT_BYTES=0 REC_BYTES=0 NREC=0 NRUN=0
while read -r rundir; do
  [ -f "$rundir/journal.jsonl" ] || continue
  run="${rundir##*/}"
  repo="${rundir%/.fleetflow/*}"
  # Exact recursive age is eligibility input under --older-than. Otherwise the
  # shallow display-only approximation avoids walking every lane worktree.
  if [ -n "$OLDER" ]; then
    newest="$(find "$rundir" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)"
    age_key=age_s
  else
    newest="$(find "$rundir" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)"
    age_key=age_s_approx
  fi
  case "${newest:-}" in ''|*[!0-9]*) newest=0 ;; esac
  if [ "$newest" -gt 0 ]; then age_s=$(( NOW - newest )); else age_s=0; fi
  if [ -n "$OLDER" ] && [ "$age_s" -lt $(( OLDER * 86400 )) ]; then continue; fi

  classify "$rundir" "$repo" "$run"
  verdict="$CLASSIFY_VERDICT" lanes="$CLASSIFY_LANES" landed="$CLASSIFY_LANDED"
  holding="$CLASSIFY_HOLDING" archived="$CLASSIFY_ARCHIVED" detail="$CLASSIFY_DETAIL"
  bytes_json=null
  if [ "$NO_SIZE" = 0 ]; then
    bytes_json="$(dir_bytes "$rundir")"
    TOT_BYTES=$((TOT_BYTES+bytes_json))
  fi
  NRUN=$((NRUN+1))
  eligible=false
  if [ "$verdict" = reclaimable ] \
     || { [ "$verdict" = landed-untracked ] && [ "$UNTRACKED_OK" = 1 ]; }; then
    eligible=true; NREC=$((NREC+1))
    [ "$NO_SIZE" = 1 ] || REC_BYTES=$((REC_BYTES+bytes_json))
  fi

  jq -nc --arg rundir "$rundir" --arg run "$run" --arg repo "$repo" \
    --arg label "$(repo_label "$repo")" --arg verdict "$verdict" \
    --argjson lanes "$lanes" --argjson landed "$landed" --argjson holding "$holding" \
    --argjson bytes "$bytes_json" --arg age_key "$age_key" --argjson age_s "$age_s" \
    --arg detail "$detail" --argjson archived "$archived" --argjson eligible "$eligible" \
    '{rundir:$rundir, run:$run, repo:$repo, repo_label:$label, verdict:$verdict,
      lanes:$lanes, landed:$landed, holding:$holding, bytes:$bytes,
      archived:$archived, eligible:$eligible, detail:$detail} + {($age_key):$age_s}' \
    >> "$ROWS_FILE"
done < <(printf '%s\n' "$RUNDIRS")
write_size_cache
ROWS="$(jq -s . "$ROWS_FILE")"

human() { awk -v b="$1" 'BEGIN{u="B";s=b;
  if(s>=1073741824){s/=1073741824;u="G"}else if(s>=1048576){s/=1048576;u="M"}
  else if(s>=1024){s/=1024;u="K"} printf (u=="B"?"%d%s":"%.1f%s"), s, u}'; }

if [ "$JSON" = 1 ]; then
  printf '%s\n' "$ROWS" | jq .
else
  printf '%s\n' "$ROWS" | jq -r '.[] | [.run, .repo_label, .verdict,
    "\(.landed)/\(.lanes) landed", (if .archived then "archived" else "unarchived" end),
    (if .bytes == null then "-" else (.bytes | tostring) end), .detail] | @tsv' | tr -d '\r'
fi
if [ "$NO_SIZE" = 1 ]; then
  err "$NRUN run dir(s); $NREC reclaimable"
else
  err "$NRUN run dir(s), $(human "$TOT_BYTES") on disk; $NREC reclaimable ($(human "$REC_BYTES"))"
fi

# --- reclaim ------------------------------------------------------------------
if [ "$MODE" = reclaim ]; then
  if [ "$NREC" = 0 ]; then err "nothing reclaimable"; exit 0; fi
  if [ "$DRY" = 1 ]; then
    if [ "$NO_SIZE" = 1 ]; then
      err "dry run - would remove $NREC run dir(s)"
    else
      err "dry run - would remove $NREC run dir(s), freeing $(human "$REC_BYTES")"
    fi
    exit 0
  fi
  while IFS=$'\t' read -r rundir was_archived; do
    [ -n "$rundir" ] || continue
    run="${rundir##*/}"; repo="${rundir%/.fleetflow/*}"
    # Archive FIRST if the record is missing - the whole safety story is that a
    # removed run still exists in history (ADR-011). Refuse to remove if it fails.
    if [ "$was_archived" != true ]; then
      if bash "$HERE/ff-archive.sh" --run "$run" --repo "$repo" >/dev/null 2>&1; then
        err "archived $run before removal"
      else
        err "SKIPPED $rundir (archive failed - refusing to remove an unrecorded run)"
        continue
      fi
    fi
    # ff-clean owns teardown (NTFS retry, cache dirs, reap anchors) and needs NO
    # new flag: `rev-list --count $BASE..HEAD` is already 0 for a landed lane
    # (identical to merge-base --is-ancestor), so its "zero commits + clean"
    # row reclaims landed lanes today. --force is added ONLY for
    # landed-untracked runs, where classify() has already proven every lane has
    # zero TRACKED modifications - that check lives here, not in ff-clean,
    # because ff-clean's --force is documented to discard a failed lane's dirty
    # tree and must keep doing so. --no-archive: the record was verified present
    # a moment ago.
    cflags="--no-archive"
    [ "$UNTRACKED_OK" = 1 ] && cflags="$cflags --force"
    bash "$HERE/ff-clean.sh" --run "$run" --repo "$repo" $cflags >/dev/null 2>&1
    if ls -d "$rundir"/wt-* >/dev/null 2>&1; then
      err "kept $rundir (a lane survived teardown - inspect before retrying)"
    elif rm -rf "$rundir" 2>/dev/null; then
      err "removed $rundir"
    else
      err "could not remove $rundir (locked - may need elevation)"
    fi
  done < <(printf '%s\n' "$ROWS" | jq -r '.[] | select(.eligible) | [.rundir, (.archived|tostring)] | @tsv' | tr -d '\r')
fi
exit 0
