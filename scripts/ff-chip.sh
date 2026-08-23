#!/usr/bin/env bash
# ff-chip.sh - make a manually spawned Claude Code chip a first-class lane.
#
# WHY THIS EXISTS: a `spawn_task` chip is a real unit of parallel work, but it
# is invisible to fleetflow and hostile to it. Per claude-code#64605 a chip
# session starts in the PRIMARY CHECKOUT on whatever branch is currently out -
# so it dirties the very tree `ff-collect --check-main-clean` watches (ADR-009),
# and two chips on one repo collide in a single index. It also contributes
# nothing to ff-status, the dashboard, cost roll-ups, or teardown, because
# nothing journalled it.
#
# The fix is not a new worker class - it is giving the chip the same lane a
# spawned worker gets, and journalling it the same way:
#
#   open   -> worktree lane + branch + guard preamble + `started` record +
#             manifest packet (model "chip"), then prints the seed prompt to
#             paste into spawn_task
#   close  -> `result` record from the lane's actual state, after which
#             ff-collect / ff-status / ff-clean / ff-archive / ff-sweep all
#             treat it as an ordinary lane
#
# THE FREE PART, and the reason this is cheap: ff-status's live-lane
# introspection is gated on state=="running" and the WORKTREE PATH, not on the
# model (ff-status.sh ~L275). A chip working in `.fleetflow/<run>/wt-<id>`
# writes its transcript to ~/.claude/projects/<encoded-workdir>/, which is
# exactly where ff-status already looks - so tokens, tools, density, model_id
# and stall detection all work with no new code. `started` with no `result` is
# what makes the lane read as running; that is the whole trick.
#
# "chip" is deliberately NOT a spawnable model (ff-spawn rejects it, like
# "native"): fleetflow cannot launch a chip - a human clicks it - so `ff-run
# resume` skips chip packets rather than pretending to replay them. Same
# terminal-fact treatment ff-import gives native Workflow results.
#
# stdout: `open` -> the seed prompt (data). `close`/`list` -> TSV.
# stderr: chatter. Exit: 0 ok | 2 usage | 3 no such lane | 10 lane failed
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ff-chip.sh open  --run NAME --id ID (--task TEXT | --task-file F)
                        [--repo PATH] [--phase P] [--base B] [--orchestrator M]
       ff-chip.sh close --run NAME --id ID [--repo PATH] [--rc N] [--note TEXT]
       ff-chip.sh list  --run NAME [--repo PATH]

  open   Create the lane a chip should work in and print the seed prompt for
         spawn_task. The lane is a real worktree (fleetflow/<run>/<id>), so the
         chip never touches the primary checkout - the whole point.
  close  Record the chip's outcome. Reads the lane's real state (commits,
         dirty, HEAD) rather than trusting a self-report. Until you run this the
         lane reads `running`, which is what gives you live telemetry.
  list   Chip lanes in this run, with state.

  --task TEXT       the chip's brief (or --task-file F to read it from a file)
  --phase P         phase label for roll-ups (default: chip)
  --base B          branch to fork the lane from (default: manifest base or main)
  --rc N            close with a nonzero code to mark the lane failed
  --note TEXT       one-line outcome recorded in the result envelope

  A chip lane is NOT replayable: `ff-run resume` skips it, because fleetflow
  cannot click a chip. To continue the work, spawn a normal lane and paste the
  chip's result into its packet (the hub-and-spoke handoff, ADR-005).

EXAMPLES
  ff-chip.sh open --run dns --id settings-page --task "Add the Settings page."
  ff-chip.sh open --run dns --id probe --task-file notes/probe.md --phase verify
  ff-chip.sh close --run dns --id settings-page --note "3 commits, tests green"
  ff-chip.sh close --run dns --id probe --rc 10 --note "abandoned: wrong approach"
  ff-chip.sh list --run dns
EOF
}

err() { echo "ff-chip: $*" >&2; }
tsv() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

[ $# -gt 0 ] || { usage >&2; exit 2; }
CMD="$1"; shift
case "$CMD" in
  open|close|list) ;;
  -h|--help) usage; exit 0 ;;
  *) err "unknown subcommand: $CMD"; usage >&2; exit 2 ;;
esac

RUN="" ID="" REPO="" TASK="" TASK_FILE="" PHASE="chip" BASE="" RC=0 NOTE="" ORCH="${FLEETFLOW_ORCHESTRATOR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --id) ID="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    --task-file) TASK_FILE="${2:-}"; shift 2 ;;
    --phase) PHASE="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --rc) RC="${2:-}"; shift 2 ;;
    --note) NOTE="${2:-}"; shift 2 ;;
    --orchestrator) ORCH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
command -v git >/dev/null || { err "git required"; exit 2; }
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
echo "$RUN" | grep -qE '^[a-z0-9-]+$' || { err "invalid --run '$RUN' ([a-z0-9-]+)"; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

RUNDIR="$REPO/.fleetflow/$RUN"
JOURNAL="$RUNDIR/journal.jsonl"
MANIFEST="$RUNDIR/manifest.json"

if [ "$CMD" != list ]; then
  [ -n "$ID" ] || { err "--id required"; usage >&2; exit 2; }
  echo "$ID" | grep -qE '^[A-Za-z0-9._-]+$' || { err "invalid --id '$ID'"; exit 2; }
fi

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
if [ "$CMD" = list ]; then
  [ -f "$JOURNAL" ] || { err "no run '$RUN' at $RUNDIR"; exit 3; }
  jq -sr '
    (map(select(.type=="started" and .model=="chip")) | map(.id) | unique) as $s
    | (map(select(.type=="result"  and .model=="chip")) | map({(.id): .rc}) | add // {}) as $r
    | $s[] | [., (if ($r[.] // null) == null then "open"
                  elif $r[.] == 0 then "closed" else "failed" end),
              (($r[.] // "") | tostring)] | @tsv' "$JOURNAL" 2>/dev/null | tr -d '\r'
  exit 0
fi

# ---------------------------------------------------------------------------
# open
# ---------------------------------------------------------------------------
if [ "$CMD" = open ]; then
  [ -n "$TASK" ] || [ -n "$TASK_FILE" ] || { err "--task or --task-file required"; usage >&2; exit 2; }
  [ -z "$TASK_FILE" ] || [ -f "$TASK_FILE" ] || { err "--task-file not found: $TASK_FILE"; exit 2; }

  mkdir -p "$RUNDIR/packets"
  # Keep the scratch tree out of git without editing the repo's .gitignore -
  # same mechanism ff-spawn and ff-import use.
  EXCL="$(git -C "$REPO" rev-parse --absolute-git-dir)/info/exclude"
  mkdir -p "$(dirname "$EXCL")"
  grep -qs '^\.fleetflow/$' "$EXCL" 2>/dev/null || echo ".fleetflow/" >> "$EXCL"
  grep -qs '^\.ff-heartbeat$' "$EXCL" 2>/dev/null || echo ".ff-heartbeat" >> "$EXCL"

  PACKET_FILE="$RUNDIR/packets/$ID.task.md"
  if [ -n "$TASK_FILE" ]; then
    cp "$TASK_FILE" "$PACKET_FILE"
  else
    printf '%s\n' "$TASK" > "$PACKET_FILE"
  fi

  # Effective prompt, assembled exactly like ff-spawn's: guard preamble, then
  # the heartbeat clause (this lane IS a worktree), then the packet. A chip is a
  # full Claude Code session with the same escape potential as any worker, so it
  # gets the same guard - that is what makes ADR-009's escape check meaningful
  # for chips at all.
  SENT="$RUNDIR/$ID.prompt.txt"
  : > "$SENT"
  PRE="$HERE/../assets/guard-preamble.txt"
  [ -f "$PRE" ] && cat "$PRE" >> "$SENT"
  cat >> "$SENT" <<'EOF'
- HEARTBEAT: after each major step (a file finished, tests run, a phase begun), append one short line to ./.ff-heartbeat in your cwd, e.g.:  echo "tests green" >> .ff-heartbeat
  This is your liveness signal to the orchestrator; a long silence reads as a wedged worker. Do not commit this file.
EOF
  echo >> "$SENT"
  cat "$PACKET_FILE" >> "$SENT"

  # Cache key: same construction as ff-spawn (model, effective prompt, opts).
  # It is computed for SHAPE COMPATIBILITY - every reader keys on it - not to
  # enable replay: a chip is launched by a human click, so a cache hit could
  # never be acted on. ff-run resume skips chip packets for that reason.
  OPTS="turns=0|wt=1|schema=|effort=|model="
  KEY="v2:$( { printf '%s\n' "chip"; cat "$SENT"; printf '%s' "$OPTS"; } | ff_sha256 | cut -d' ' -f1)"

  [ -n "$BASE" ] || BASE="$(jq -r '.base // "main"' "$MANIFEST" 2>/dev/null | tr -d '\r')"
  [ -n "$BASE" ] && [ "$BASE" != "null" ] || BASE="main"
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$BASE" || BASE="HEAD"

  WORKDIR="$RUNDIR/wt-$ID"
  if [ ! -d "$WORKDIR" ]; then
    git -C "$REPO" worktree add -q -b "fleetflow/$RUN/$ID" "$WORKDIR" "$BASE" \
      || { err "worktree add failed for $ID"; exit 10; }
    err "lane created: $WORKDIR (branch fleetflow/$RUN/$ID off $BASE)"
  else
    err "lane already exists: $WORKDIR (reusing)"
  fi

  # Seed the heartbeat AT OPEN, or the lane reads `stalled` from the first
  # ff-status poll: with no transcript and no heartbeat, last_activity_s falls
  # back to a garbage epoch (~33 days measured) and trips the detector
  # instantly. A spawned worker never shows this because it starts writing
  # within seconds; the gap between opening a chip lane and a HUMAN CLICKING
  # the chip is minutes or hours, so the chip is the first lane class where the
  # window is real. Seeding it starts the activity clock at open, which also
  # makes the eventual stall honest rather than noisy: a chip lane still silent
  # past FLEETFLOW_STALL_SECONDS is one nobody ever clicked, and that is worth
  # surfacing. (ADR-008: trust activity, not state.)
  [ -f "$WORKDIR/.ff-heartbeat" ] || echo "lane opened, awaiting chip" > "$WORKDIR/.ff-heartbeat"

  # Manifest packet. worktree:true and max_turns:0 are both honest - a chip has
  # no turn cap, so the worktree + stall detector are its only bounds (the same
  # position pi lanes are in).
  MENTRY="$(jq -nc --arg id "$ID" --arg p "$PHASE" --arg pf "$PACKET_FILE" --arg k "$KEY" \
    '{id:$id,model:"chip",phase:$p,prompt_file:$pf,worktree:true,max_turns:0,
      effort:"",schema:"",key:$k,round:0}')"
  if [ ! -s "$MANIFEST" ]; then
    jq -nc --arg run "$RUN" --arg base "$BASE" --arg by "ff-chip/$FF_VERSION" \
      --argjson entry "$MENTRY" --arg phase "$PHASE" --arg o "$ORCH" \
      '{run:$run,base:$base,created_by:$by,
        orchestrator:(if $o=="" then null else $o end),
        phases:[$phase],packets:[$entry]}' > "$MANIFEST"
  else
    jq --argjson entry "$MENTRY" --arg id "$ID" --arg phase "$PHASE" --arg o "$ORCH" \
      '.packets = ((.packets // []) | map(select(.id != $id))) + [$entry]
       | .phases = (((.phases // []) + [$phase]) | unique)
       | .orchestrator = (.orchestrator // (if $o=="" then null else $o end))' \
      "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
  fi

  # `started` with no `result` is what makes ff-status read the lane as running,
  # which is what switches on the live transcript introspection. Do not "tidy"
  # this by writing both records at open time.
  if ! jq -es --arg id "$ID" --arg k "$KEY" \
       '[.[] | objects | select(.type=="started" and .id==$id and .key==$k)] | length > 0' \
       "$JOURNAL" >/dev/null 2>&1; then
    jq -nc --arg k "$KEY" --arg id "$ID" --arg p "$PHASE" --arg v "$FF_VERSION" --arg o "$ORCH" \
      '{type:"started",key:$k,id:$id,model:"chip",phase:$p,v:$v,round:0,
        model_id:null,
        orchestrator:(if $o=="" then null else $o end)}' >> "$JOURNAL"
  fi

  # The seed prompt. The lane path is ABSOLUTE here on purpose: the guard's
  # relative-paths-only rule governs what the worker WRITES, and the chip has to
  # be told where to stand before it can obey it. Everything after the cd is
  # relative, as the guard requires.
  #
  # The cwd check is not ceremony. ff-status resolves a lane's transcript by
  # encoding the SESSION's cwd, so a chip started in its own fresh worktree
  # (the chip UI offers that at click time) writes its transcript - and the
  # ./.ff-heartbeat the guard asks for - somewhere fleetflow does not look. The
  # lane then goes dark and eventually reads stalled while the chip works fine.
  # This repo cannot enforce a click, so the best it can do is make the chip
  # notice and say so. See ADR-021.
  cat <<EOF
You are lane \`$ID\` of fleetflow run \`$RUN\`.

FIRST, before anything else, work in this lane and nowhere else:

    cd "$WORKDIR"

That is a git worktree on branch \`fleetflow/$RUN/$ID\`. Do NOT work in the
repository root, do not switch branches, and do not touch any path outside this
worktree - sibling lanes and the orchestrator are using them concurrently.
You may commit in this lane; that is how your work is landed.

This lane was created FOR you, so you did not need to be started in a fresh
worktree of your own. If you were - i.e. your session began somewhere under
\`.claude/worktrees/\` rather than in the lane above - then say so in your first
message and in your FINAL REPLY. Your work is still fine, but the orchestrator's
live view of this lane will be blank and it will eventually look stalled, so it
needs to know to read your reply instead of the dashboard.

$(cat "$SENT")

WHEN YOU ARE DONE, report your outcome in the final reply, then tell the
operator to close the lane:

    bash "$HERE/ff-chip.sh" close --run $RUN --id $ID --repo "$REPO" --note "<one line>"

Until that runs, this lane reads as still-running on the dashboard.
EOF
  err "seed prompt above - paste it into spawn_task, then run 'ff-chip close' when it finishes"
  exit 0
fi

# ---------------------------------------------------------------------------
# close
# ---------------------------------------------------------------------------
[ -f "$JOURNAL" ] || { err "no run '$RUN' at $RUNDIR"; exit 3; }
KEY="$(jq -r --arg id "$ID" 'select(.type=="started" and .model=="chip" and .id==$id) | .key' \
       "$JOURNAL" 2>/dev/null | tr -d '\r' | tail -1)"
[ -n "$KEY" ] || { err "no open chip lane '$ID' in run '$RUN' (was it opened with ff-chip open?)"; exit 3; }

WORKDIR="$RUNDIR/wt-$ID"
BASE="$(jq -r '.base // "main"' "$MANIFEST" 2>/dev/null | tr -d '\r')"
[ -n "$BASE" ] && [ "$BASE" != "null" ] || BASE="main"
git -C "$REPO" show-ref --verify --quiet "refs/heads/$BASE" || BASE="HEAD"

# Measured, never self-reported. A chip's own account of what it did is exactly
# the thing a gate exists to check - the same reason ff-status derives tokens
# from transcripts rather than trusting a worker's prose (SKILL.md, verdict
# metadata). Commits and dirt are facts the lane cannot misstate.
COMMITS=0 DIRTY=0 HEAD_SHA=""
if [ -d "$WORKDIR" ]; then
  COMMITS="$(git -C "$WORKDIR" rev-list --count "$BASE..HEAD" 2>/dev/null || echo 0)"
  [ -n "$(git -C "$WORKDIR" status --porcelain 2>/dev/null)" ] && DIRTY=1
  HEAD_SHA="$(git -C "$WORKDIR" rev-parse --short HEAD 2>/dev/null || true)"
else
  err "WARN: lane worktree $WORKDIR is gone - recording the close anyway"
fi

case "${RC:-0}" in ''|*[!0-9]*) err "--rc wants a number"; exit 2 ;; esac
IS_ERR=false; [ "$RC" -ne 0 ] && IS_ERR=true

ART="$RUNDIR/$ID.result.json"
jq -nc --argjson err "$IS_ERR" --arg note "$NOTE" --argjson commits "${COMMITS:-0}" \
  --argjson dirty "$( [ "$DIRTY" = 1 ] && echo true || echo false )" \
  --arg head "$HEAD_SHA" --arg branch "fleetflow/$RUN/$ID" \
  '{is_error:$err,
    result:("chip lane closed" + (if $note=="" then "" else ": " + $note end)
            + " (" + ($commits|tostring) + " commits"
            + (if $dirty then ", dirty tree" else "" end)
            + (if $head=="" then "" else ", HEAD " + $head end) + ")"),
    chip:{commits:$commits,dirty:$dirty,head:$head,branch:$branch}}' > "$ART"

jq -nc --arg k "$KEY" --arg id "$ID" --argjson rc "$RC" --arg a "$ART" \
  '{type:"result",key:$k,id:$id,model:"chip",rc:$rc,artifact:$a}' >> "$JOURNAL"

tsv "$ID" "$( [ "$RC" -eq 0 ] && echo closed || echo failed )" \
    "$COMMITS commits$( [ "$DIRTY" = 1 ] && echo ', dirty' )"
err "lane $ID closed (rc=$RC) - it is now an ordinary lane for collect/status/clean/sweep"
[ "$RC" -eq 0 ] || exit 10
exit 0
