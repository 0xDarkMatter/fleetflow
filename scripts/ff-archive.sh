#!/usr/bin/env bash
# ff-archive.sh - persist a compact summary of a run to the MACHINE-LEVEL
# history store, so the run survives the deletion of its own directory.
#
# WHY THIS EXISTS: everything fleetflow knows about a run lives in
# <repo>/.fleetflow/<run>/, and ff-clean deletes that. Before this script, a
# completed run simply ceased to exist - no record of what ran, how long it
# took, or what it cost. The store therefore lives OUTSIDE any repo
# (~/.fleetflow/history.jsonl, override with $FLEETFLOW_HOME) and is
# append-only: appending is atomic enough for concurrent runs, and a torn final
# line costs one record instead of the file.
#
# Readers take the LAST record per (repo, run), so re-archiving supersedes
# rather than duplicates. That is what makes it safe for ff-clean to archive on
# every teardown without tracking whether it already did.
#
# stdout: the JSON record that was appended (data). stderr: chatter.
# Exit codes: 0 archived | 2 usage / no such run | 3 nothing to archive
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ff-archive.sh --run NAME [--repo PATH] [--store FILE] [--dry-run]

  --run NAME    run name under <repo>/.fleetflow/
  --repo PATH   repo root (default: git toplevel of cwd)
  --store FILE  history file (default: $FLEETFLOW_HOME/history.jsonl,
                which itself defaults to ~/.fleetflow/history.jsonl)
  --dry-run     print the record to stdout WITHOUT appending it

Writes one JSON line: run identity, wall-clock span, per-state lane counts,
model-consistent token totals, self-reported cost, and a per-lane digest
(id, model, phase, state, elapsed, tokens, commits, cost). Prompts, diffs, and
transcripts are NOT copied - this is an index of what happened, not a backup.

ff-clean.sh archives automatically before it removes anything; call this
directly only to snapshot a run you are keeping, or to re-archive after more
lanes have landed.

ENV
  FLEETFLOW_HOME  machine-level fleetflow state dir (default ~/.fleetflow)

EXAMPLES
  ff-archive.sh --run slack-w3
  ff-archive.sh --run slack-w3 --repo X:/Forma/forma/slack --dry-run | jq .
  jq -r 'select(.run=="slack-w3") | .cost_usd' ~/.fleetflow/history.jsonl | tail -1
EOF
}

err() { echo "ff-archive: $*" >&2; }

RUN="" REPO="" STORE="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --store) STORE="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

RUNDIR="$REPO/.fleetflow/$RUN"
[ -f "$RUNDIR/journal.jsonl" ] || { err "no journal at $RUNDIR - nothing to archive"; exit 3; }

FF_HOME="${FLEETFLOW_HOME:-$HOME/.fleetflow}"
[ -n "$STORE" ] || STORE="$FF_HOME/history.jsonl"

STATUS="$(bash "$HERE/ff-status.sh" --run "$RUN" --repo "$REPO" 2>/dev/null)"
[ -n "$STATUS" ] || { err "ff-status produced nothing for '$RUN'"; exit 3; }

NOW="$(date +%s)"
# Roll-up rules mirror ff-aggregate.py's roll_up() exactly - the dashboard shows
# live and archived runs side by side, so a run must not change shape or verdict
# the moment it moves from one section to the other.
REC="$(printf '%s' "$STATUS" | jq -c \
  --arg v "$FF_VERSION" --argjson now "$NOW" --arg label "$(basename "$REPO")" '
  . as $s
  | (.lanes // []) as $L
  | ($L | map(select(.cost_usd != null))) as $costed
  | ($L | map(select(.state=="running" or .state=="stalled"))) as $inflight
  | ($L | map(.state) | group_by(.) | map({key:.[0], value:length}) | from_entries) as $counts
  | (["stalled","running","failed","done"] | map(select($counts[.] // 0 > 0)) | .[0] // "unknown") as $state
  | {
      schema: "fleetflow/history/1", v: $v,
      run: $s.run, repo: $s.repo, repo_label: $label,
      archived_at: $now,
      started: ([$L[].started | select(. > 0)] | min // 0),
      ended: (if ($inflight | length) > 0 then null else $now end),
      elapsed_s: ([$L[].elapsed_s // 0] | max // 0),
      state: $state, counts: $counts, lane_count: ($L | length),
      tokens_total: ([$L[].tokens_total // 0] | add // 0),
      tokens_in:    ([$L[].tokens_in    // 0] | add // 0),
      tokens_cached:([$L[].tokens_cached// 0] | add // 0),
      tokens_out:   ([$L[].tokens_out   // 0] | add // 0),
      cost_usd: (if ($costed | length) > 0 then ([$costed[].cost_usd] | add) else null end),
      cost_lanes: ($costed | length),
      cost_partial: (($costed | length) < ($L | length)),
      models: ([$L[] | (.model // .brain)] | unique),
      phases: ([$L[].phase // "build"] | unique),
      lanes: [$L[] | {id, model: (.model // .brain), phase, state, elapsed_s, commits,
                      tokens_total, tokens_out, cost_usd}]
    }')"

[ -n "$REC" ] || { err "could not build a record for '$RUN'"; exit 3; }

if [ "$DRY" = 1 ]; then
  printf '%s\n' "$REC"
  err "dry run - nothing appended to $STORE"
  exit 0
fi

mkdir -p "$(dirname "$STORE")" 2>/dev/null || true
# >> on a single line under the pipe-buffer size is the atomicity this relies on;
# a failed append must not look like a success, hence the explicit check.
if printf '%s\n' "$REC" >> "$STORE"; then
  printf '%s\n' "$REC"
  err "archived '$RUN' -> $STORE"
else
  err "could not append to $STORE"
  exit 3
fi
exit 0
