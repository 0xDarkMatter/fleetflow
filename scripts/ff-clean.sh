#!/usr/bin/env bash
# ff-clean.sh - reclaim a fleetflow run's lanes, branches, and cache dirs.
#
# Per lane (worktree lane under <run>/wt-<id>):
#   zero commits + clean      -> git worktree remove + branch -D   ("removed")
#   zero commits + dirty      -> "kept" unless --force              (--force removes)
#   N>0 commits               -> "kept (N commits)"                 (never auto-remove)
#   locked ACL-litter dir     -> "locked (needs elevation)"         (continue, non-fatal)
# Then removes each lane's cache dir under FLEETFLOW_CACHE_ROOT (default
# $HOME/.fleet-worker/cache/<run>-<id>). Removal never aborts the run: a locked
# lane is reported and skipped, and the script exits 0 once it has tried them all.
# stdout: one TSV line per lane: id<TAB>status<TAB>detail. stderr: chatter.
#
# CONTRACT CHANGE (1.2.0): this script now ARCHIVES the run before it removes
# anything - one JSON line appended to ~/.fleetflow/history.jsonl via
# ff-archive.sh. Nothing about lane removal changed, and the TSV on stdout is
# byte-identical; the addition is a write to a file OUTSIDE the repo. It is the
# default because teardown is the last moment the run's data exists, and a
# history step you have to remember is a history step that does not happen.
# Opt out with --no-archive. Archiving is best-effort: its failure is reported
# and never blocks the clean.
#
# Exit codes: 0 done (incl. some locked lanes) | 2 usage / no such run
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"

usage() {
  cat <<'EOF'
Usage: ff-clean.sh --run NAME [--repo PATH] [--force] [--no-archive]
       ff-clean.sh --run NAME --reap [--force]

  --run NAME      run name under <repo>/.fleetflow/
  --repo PATH     repo root (default: git toplevel of cwd)
  --no-archive    skip the pre-clean history append (see below)
  --force         also remove DIRTY zero-commit lanes (committed lanes are
                  ALWAYS kept - land or branch them first, then clean).
                  With --reap, actually terminate the orphans.
  --reap          report worker processes still alive from this run instead of
                  touching lanes. Report-only unless --force. Windows only -
                  identifies orphans by walking up to the reap anchors ff-spawn
                  journalled, so a Codex you started yourself is never a match.

  Lanes with commits are never removed (their work would be lost); clean only
  after ff-collect has gated them and the orchestrator has landed/branched the
  keepers. Locked codex sandbox-litter dirs are reported and skipped.

  BEFORE removing anything, the run is archived to ~/.fleetflow/history.jsonl
  (ff-archive.sh) so it survives in the dashboard's history section after its
  directory is gone. --no-archive skips that. Archiving never blocks a clean.

EXAMPLES
  ff-clean.sh --run currency
  ff-clean.sh --run currency --force
  ff-clean.sh --run currency --no-archive       # tear down, keep no record
  ff-clean.sh --run currency --repo /path/to/repo | column -t
  ff-clean.sh --run currency --reap             # list this run's stray workers
  ff-clean.sh --run currency --reap --force     # and kill them
EOF
}

err() { echo "ff-clean: $*" >&2; }
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }   # id <TAB> status <TAB> detail

RUN="" REPO="" FORCE=0 REAP=0 ARCHIVE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --reap) REAP=1; shift ;;
    --no-archive) ARCHIVE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
command -v git >/dev/null || { err "git required"; exit 2; }
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

RUNDIR="$REPO/.fleetflow/$RUN"
MANIFEST="$RUNDIR/manifest.json"
[ -d "$RUNDIR" ] || { err "no such run: $RUNDIR"; exit 2; }

CACHE_ROOT="${FLEETFLOW_CACHE_ROOT:-$HOME/.fleet-worker/cache}"
BASE="$(jq -r '.base // "main"' "$MANIFEST" 2>/dev/null)"; [ -n "$BASE" ] || BASE="main"

# enumerate lane ids: manifest packets (authoritative) + any wt-* dirs left on
# disk (e.g. manifest pruned but lanes remain) + journal started ids (fallback).
list_lane_ids() {
  local ids=""
  [ -f "$MANIFEST" ] && ids="$(jq -r '.packets[].id' "$MANIFEST" 2>/dev/null)"
  local d
  for d in "$RUNDIR"/wt-*; do
    [ -d "$d" ] || continue
    ids="$ids
$(basename "$d" | sed 's/^wt-//')"
  done
  if [ -z "$ids" ] && [ -f "$RUNDIR/journal.jsonl" ]; then
    ids="$(jq -r 'select(.type=="started") | .id' "$RUNDIR/journal.jsonl" 2>/dev/null)"
  fi
  printf '%s\n' "$ids" | awk 'NF && !seen[$0]++'
}

# remove_lane <id> <force>: worktree remove (+ branch -D on success). Reports
# "locked" if the OS refuses to delete (codex AppContainer-ACL litter).
# Removal is retried 3x with 1s backoff: on NTFS a just-exited worker (or AV
# scanner) often holds a transient junction/handle lock that clears within a
# second - rookery's GitWorktreeLifecycle carries the same load-bearing retry.
# Only a lock that survives all attempts is a real "locked" (needs elevation).
remove_lane() {
  local id="$1" f="$2" wt="$RUNDIR/wt-$id" br="fleetflow/$RUN/$id" wflag="" try
  [ "$f" = 1 ] && wflag="--force"
  for try in 1 2 3; do
    if git -C "$REPO" worktree remove $wflag "$wt" 2>>"$RUNDIR/$id.clean.err"; then
      git -C "$REPO" branch -D "$br" >/dev/null 2>>"$RUNDIR/$id.clean.err" \
        && emit "$id" removed "worktree + branch gone" \
        || emit "$id" removed "worktree gone (branch delete skipped)"
      return 0
    fi
    [ "$try" -lt 3 ] && { err "worktree remove failed for $id (attempt $try/3), retrying in 1s"; sleep 1; }
  done
  emit "$id" locked "needs elevation (see $RUNDIR/$id.clean.err)"
}

# clean_cache <id>: best-effort removal of the lane's cache/tmp dir.
clean_cache() {
  local id="$1" c="$CACHE_ROOT/$RUN-$id"
  [ -d "$c" ] || return 0
  if rm -rf "$c" 2>>"$RUNDIR/$id.clean.err"; then err "cache removed: $c"
  else err "cache locked (needs elevation): $c"; fi
}

# --- reap: kill worker processes the wrapper left behind -----------------------
# TaskStop (or killing the background Bash task) kills ff-spawn, not the worker:
# on 2026-07-27 five codex.exe / codex-code-mode-host.exe survived a lane kill.
# Reaping by image name alone would also kill the user's own interactive Codex,
# so we match by ANCESTRY instead: every candidate must descend from a WINPID
# ff-spawn journalled for this run. `at` bounds PID reuse - a process that
# started before its anchor cannot be that anchor's child.
# Windows-only by nature (Win32_Process); elsewhere the POSIX process group dies
# with the wrapper, so there is nothing to reap.
reap_run() {
  local anchors since ps1 out
  anchors="$(jq -r 'select(.type=="proc" and .winpid != null) | .winpid' "$RUNDIR/journal.jsonl" 2>/dev/null \
             | awk 'NF && !seen[$0]++' | paste -sd, -)"
  since="$(jq -r 'select(.type=="proc") | .at' "$RUNDIR/journal.jsonl" 2>/dev/null | sort -n | head -1)"
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) err "--reap is Windows-only (elsewhere the worker dies with its process group)"; return 0 ;;
  esac
  if [ -z "$anchors" ]; then
    err "no reap anchors journalled for '$RUN' (run predates ff-spawn's proc records)"
    return 0
  fi
  command -v powershell.exe >/dev/null || { err "powershell.exe not found - cannot enumerate processes"; return 0; }
  err "reaping run '$RUN': anchors=[$anchors] since=$since force=$FORCE"
  # PowerShell does the walk: one CIM snapshot, index by ProcessId, climb each
  # codex* process's parent chain (bounded) looking for an anchor.
  ps1="\$ErrorActionPreference='Stop'
\$anchors = @($anchors)
\$since = [DateTimeOffset]::FromUnixTimeSeconds($since).UtcDateTime
\$map = @{}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object { \$map[[int]\$_.ProcessId] = \$_ }
foreach (\$p in @(\$map.Values)) {
  if (\$p.Name -notlike 'codex*') { continue }
  if (\$p.CreationDate -and \$p.CreationDate.ToUniversalTime() -lt \$since) { continue }
  \$cur = \$p; \$hops = 0; \$hit = \$false
  while (\$cur -ne \$null -and \$hops -lt 12) {
    if (\$anchors -contains [int]\$cur.ParentProcessId) { \$hit = \$true; break }
    \$cur = \$map[[int]\$cur.ParentProcessId]; \$hops++
  }
  if (-not \$hit) { continue }
  \$status = 'alive'
  if ('$FORCE' -eq '1') {
    try { Stop-Process -Id \$p.ProcessId -Force -ErrorAction Stop; \$status = 'killed' }
    catch { \$status = 'kill-failed' }
  }
  # [char]9, not a backtick escape: PowerShell single-quoted strings do NOT
  # process \` sequences, so '{0}\`t{1}' emits a literal backtick-t (caught in test).
  (\$p.ProcessId, \$p.Name, \$status) -join [char]9
}"
  out="$(powershell.exe -NoProfile -NonInteractive -Command "$ps1" 2>/dev/null | tr -d '\r')"
  if [ -z "$out" ]; then
    err "no surviving worker processes from this run"
  else
    printf '%s\n' "$out"
    [ "$FORCE" = 1 ] || err "report only - re-run with --force to terminate"
  fi
}

if [ "$REAP" = 1 ]; then
  reap_run
  exit 0
fi

# Archive FIRST: after the loop below, the lanes ff-status reads may be gone.
# Best-effort by design - losing the history record is bad, but refusing to
# clean up because of it would be worse, so this can only ever warn.
if [ "$ARCHIVE" = 1 ]; then
  if bash "$HERE/ff-archive.sh" --run "$RUN" --repo "$REPO" >/dev/null 2>>"$RUNDIR/archive.err"; then
    err "archived to ${FLEETFLOW_HOME:-$HOME/.fleetflow}/history.jsonl"
  else
    err "WARNING: archive failed (see $RUNDIR/archive.err) - cleaning anyway"
  fi
fi

NLANES="$(list_lane_ids | wc -l | tr -d ' ')"
err "cleaning run '$RUN': $NLANES lane(s); FORCE=$FORCE; base=$BASE; cache=$CACHE_ROOT"
if [ "$NLANES" = "0" ]; then
  err "no lanes to clean"
  exit 0
fi

# base ref must exist for rev-list counting; fall back to HEAD once for the run
git -C "$REPO" show-ref --verify --quiet "refs/heads/$BASE" || BASE="HEAD"

while read -r id; do
  [ -n "$id" ] || continue
  wt="$RUNDIR/wt-$id"
  if [ -d "$wt" ]; then
    commits="$(git -C "$wt" rev-list --count "$BASE..HEAD" 2>/dev/null || echo 0)"
    dirt="$(git -C "$wt" status --porcelain 2>/dev/null)"
    if [ "${commits:-0}" -eq 0 ] && [ -z "$dirt" ]; then
      remove_lane "$id" 0
    elif [ "${commits:-0}" -eq 0 ] && [ -n "$dirt" ]; then
      if [ "$FORCE" = 1 ]; then remove_lane "$id" 1
      else emit "$id" kept "dirty, zero commits (use --force)"; fi
    else
      emit "$id" kept "$commits commits"
    fi
  else
    emit "$id" kept "no worktree lane"
  fi
  clean_cache "$id"
done < <(list_lane_ids)

exit 0
