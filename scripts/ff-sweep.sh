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
EOF
}

err() { echo "ff-sweep: $*" >&2; }

MODE=list OLDER="" JSON=0 DRY=0 REPO_ONE="" UNTRACKED_OK=0
ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --reclaim) MODE=reclaim; shift ;;
    --include-untracked) UNTRACKED_OK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --json) JSON=1; shift ;;
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
    \) -prune -o -type d -name .fleetflow -print 2>/dev/null \
  | while read -r ffdir; do
      local d
      for d in "$ffdir"/*/; do
        [ -f "${d}journal.jsonl" ] || continue   # e.g. a served monitor/ dir
        printf '%s\n' "${d%/}"
      done
    done
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
archived_p() {
  [ -f "$HIST" ] || return 1
  jq -sr --arg repo "$1" --arg run "$2" '
    [.[] | select(((.repo // "") | ascii_downcase) == ($repo | ascii_downcase)
                  and ((.run // "") | ascii_downcase) == ($run | ascii_downcase))] | length' \
    "$HIST" 2>/dev/null | tr -d '\r' | grep -qv '^0$'
}

dir_bytes() { du -s "$1" 2>/dev/null | awk '{print $1*1024}' || echo 0; }

# --- per-run verdict ----------------------------------------------------------
# Delegates lane state to the same facts ff-clean reads (manifest base, wt-* dirs,
# rev-list, status --porcelain). Deliberately NOT a second implementation of
# ff-status: this asks a narrower question ("is the work in the base yet?") that
# ff-status does not answer at all.
classify() {
  local rundir="$1" repo="$2" run="$3"
  local manifest="$rundir/manifest.json" base wt id
  local lanes=0 landed=0 holding=0 gone=0 running=0 detail=""

  base="$(jq -r '.base // "main"' "$manifest" 2>/dev/null | tr -d '\r')"
  [ -n "$base" ] && [ "$base" != "null" ] || base="main"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$base" || base="HEAD"

  # a lane still in flight makes the whole run untouchable regardless of disk
  if [ -f "$rundir/journal.jsonl" ]; then
    running="$(jq -sr '
      (map(select(.type=="started")) | map(.id) | unique) as $s
      | (map(select(.type=="result")) | map(.id) | unique) as $r
      | ($s - $r) | length' "$rundir/journal.jsonl" 2>/dev/null | tr -d '\r')"
    case "${running:-0}" in ''|*[!0-9]*) running=0 ;; esac
  fi

  # TRACKED changes and UNTRACKED files are not the same risk, and collapsing
  # them made the sweep useless in practice: measured on this box, every large
  # landed run was blocked by exactly ONE untracked leftover per lane (a plan
  # doc, a screenshots dir) while holding zero tracked modifications. A tracked
  # edit is work the base does not have; an untracked file usually is not, but
  # occasionally is - so it gets its own verdict and its paths are always
  # printed, never silently swept.
  local untracked=0 upaths=""
  for wt in "$rundir"/wt-*; do
    [ -d "$wt" ] || continue
    lanes=$((lanes+1))
    id="$(basename "$wt")"; id="${id#wt-}"
    local st tracked untr
    st="$(git -C "$wt" status --porcelain 2>/dev/null)"
    tracked="$(printf '%s\n' "$st" | grep -c '^[^?]' || true)"
    untr="$(printf '%s\n' "$st" | grep -c '^??' || true)"
    if [ "${tracked:-0}" -gt 0 ]; then
      holding=$((holding+1)); detail="${detail}${detail:+,}$id:modified"
    elif ! git -C "$repo" merge-base --is-ancestor \
           "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" "$base" 2>/dev/null; then
      holding=$((holding+1)); detail="${detail}${detail:+,}$id:unmerged"
    else
      landed=$((landed+1))
      if [ "${untr:-0}" -gt 0 ]; then
        untracked=$((untracked+untr))
        upaths="${upaths}${upaths:+,}$(printf '%s\n' "$st" | awk '/^\?\?/{print $2}' | paste -sd' ' -)"
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$verdict" "$lanes" "$landed" "$holding" "$archived" "$detail"
}

# --- walk ---------------------------------------------------------------------
NOW="$(date +%s)"
RUNDIRS=""
if [ -n "$REPO_ONE" ]; then
  [ -d "$REPO_ONE/.fleetflow" ] || { err "no .fleetflow in $REPO_ONE"; exit 3; }
  for d in "$REPO_ONE/.fleetflow"/*/; do
    [ -f "${d}journal.jsonl" ] && RUNDIRS="$RUNDIRS${d%/}
"
  done
else
  while read -r root; do
    [ -n "$root" ] || continue
    RUNDIRS="$RUNDIRS$(find_run_dirs "$root")
"
  done < <(resolve_roots)
fi
RUNDIRS="$(printf '%s' "$RUNDIRS" | awk 'NF && !seen[$0]++')"
[ -n "$RUNDIRS" ] || { err "no fleetflow run dirs found"; exit 3; }

ROWS="[]"
TOT_BYTES=0 REC_BYTES=0 NREC=0 NRUN=0
while read -r rundir; do
  [ -n "$rundir" ] || continue
  run="$(basename "$rundir")"
  repo="$(dirname "$(dirname "$rundir")")"
  # Newest file in the run dir = when this run was last touched. `find -printf`
  # is GNU (Git Bash ships GNU findutils); if it is unavailable the age reads 0,
  # which means "just touched" and therefore SKIPS --older-than - failing toward
  # keeping a run rather than deleting one.
  newest="$(find "$rundir" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)"
  case "${newest:-}" in ''|*[!0-9]*) newest=0 ;; esac
  if [ "$newest" -gt 0 ]; then age_s=$(( NOW - newest )); else age_s=0; fi
  if [ -n "$OLDER" ] && [ "$age_s" -lt $(( OLDER * 86400 )) ]; then continue; fi

  IFS="$(printf '\t')" read -r verdict lanes landed holding archived detail \
    < <(classify "$rundir" "$repo" "$run")
  bytes="$(dir_bytes "$rundir")"
  NRUN=$((NRUN+1)); TOT_BYTES=$((TOT_BYTES+bytes))
  eligible=false
  if [ "$verdict" = reclaimable ] \
     || { [ "$verdict" = landed-untracked ] && [ "$UNTRACKED_OK" = 1 ]; }; then
    eligible=true; NREC=$((NREC+1)); REC_BYTES=$((REC_BYTES+bytes))
  fi

  ROWS="$(jq -nc --argjson R "$ROWS" --arg rundir "$rundir" --arg run "$run" \
    --arg repo "$repo" --arg label "$(repo_label "$repo")" --arg verdict "$verdict" \
    --argjson lanes "$lanes" --argjson landed "$landed" --argjson holding "$holding" \
    --argjson bytes "$bytes" --argjson age_s "$age_s" --arg detail "$detail" \
    --argjson archived "$archived" --argjson eligible "$eligible" \
    '$R + [{rundir:$rundir, run:$run, repo:$repo, repo_label:$label, verdict:$verdict,
            lanes:$lanes, landed:$landed, holding:$holding, bytes:$bytes,
            age_s:$age_s, archived:$archived, eligible:$eligible, detail:$detail}]')"
done < <(printf '%s\n' "$RUNDIRS")

human() { awk -v b="$1" 'BEGIN{u="B";s=b;
  if(s>=1073741824){s/=1073741824;u="G"}else if(s>=1048576){s/=1048576;u="M"}
  else if(s>=1024){s/=1024;u="K"} printf (u=="B"?"%d%s":"%.1f%s"), s, u}'; }

if [ "$JSON" = 1 ]; then
  printf '%s\n' "$ROWS" | jq .
else
  printf '%s\n' "$ROWS" | jq -r '.[] | [.run, .repo_label, .verdict,
    "\(.landed)/\(.lanes) landed", (if .archived then "archived" else "unarchived" end),
    .bytes, .detail] | @tsv' | tr -d '\r'
fi
err "$NRUN run dir(s), $(human "$TOT_BYTES") on disk; $NREC reclaimable ($(human "$REC_BYTES"))"

# --- reclaim ------------------------------------------------------------------
if [ "$MODE" = reclaim ]; then
  if [ "$NREC" = 0 ]; then err "nothing reclaimable"; exit 0; fi
  if [ "$DRY" = 1 ]; then
    err "dry run - would remove $NREC run dir(s), freeing $(human "$REC_BYTES")"
    exit 0
  fi
  while IFS="$(printf '\t')" read -r rundir was_archived; do
    [ -n "$rundir" ] || continue
    run="$(basename "$rundir")"; repo="$(dirname "$(dirname "$rundir")")"
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
  done < <(printf '%s\n' "$ROWS" | jq -r '.[] | select(.eligible) | [.rundir, (.archived|tostring)] | @tsv')
fi
exit 0
