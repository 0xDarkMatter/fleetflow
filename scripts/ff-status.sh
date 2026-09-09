#!/usr/bin/env bash
# ff-status.sh - emit a fleetflow run's live status as JSON (the data feed
# behind assets/ff-monitor.html, and a machine-readable run summary on its own).
#
# Reads the run journal + artifacts; never modifies anything. Lane state is
# derived from journal records (started-without-result = running), timings
# from artifact mtimes, activity from lane commits (claude models) or the
# codex event stream (item.completed counts + last item). A running lane whose
# activity signal has gone silent past FLEETFLOW_STALL_SECONDS is reported
# `stalled` (see the stall block below for why that state has to exist), and a
# running/stalled lane silent past FLEETFLOW_ABANDON_SECONDS is demoted to
# `abandoned` - final, no longer in flight (ADR-025).
# stdout: the JSON document (data only). stderr: chatter.
#
# Exit codes: 0 ok | 2 usage | 14 stalled lane(s) (only with --exit-stalled)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"

usage() {
  cat <<'EOF'
Usage: ff-status.sh --run NAME [--repo PATH] [--out FILE] [--watch SECONDS]

  --run NAME       run name under <repo>/.fleetflow/
  --repo PATH      repo root (default: git toplevel of cwd)
  --out FILE       write JSON to FILE instead of stdout
  --watch SECONDS  loop forever, rewriting --out every SECONDS (requires --out)
  --exit-stalled   exit 14 if any lane is stalled (still emits the JSON first).
                   With --watch this turns the loop into a watchdog: it polls
                   until a lane stalls, then exits 14.

Lane state: running | stalled | abandoned | done | failed. A lane is `stalled`
once its LIVE stream (codex/pi --json events, claude/glm session transcript, or
the worker-authored wt-<id>/.ff-heartbeat file) has been silent longer than
FLEETFLOW_STALL_SECONDS (default 600). `last_activity_s` is reported for every
lane; `live_signal` says whether the lane has a stream that could substantiate
a stall at all - where it is false, `stalled` is always false and means
"cannot tell", not "healthy". A running or stalled lane whose last_activity_s
exceeds FLEETFLOW_ABANDON_SECONDS (default 21600 = 6h) is demoted to
`abandoned` - a FINAL verdict, applied regardless of live_signal, because at
that timescale "nothing at all has been written for hours and there is no
result" is decisive where a minute-scale stall claim would not be (ADR-025).

Tokens: `tokens` is LEGACY and model-INCONSISTENT (codex = grand total, claude
models = output only) - frozen because ff-monitor.html renders it. Compare lanes
and runs with `tokens_total` / `tokens_in` / `tokens_cached` / `tokens_out`,
which mean the same thing for every model. `cost_usd` is the worker's own
self-reported spend (claude models only) and is null where unavailable.

ENV
  FLEETFLOW_STALL_SECONDS    silence before a running lane reads stalled (600)
  FLEETFLOW_ABANDON_SECONDS  silence before an in-flight lane reads abandoned (21600)

EXAMPLES
  ff-status.sh --run currency | jq '.lanes[] | {id, state, elapsed_s}'
  ff-status.sh --run currency | jq '.lanes[] | select(.stalled) | {id, last_activity_s}'
  ff-status.sh --run currency --out .fleetflow/currency/status.json --watch 3
  ff-status.sh --run currency --exit-stalled >/dev/null || echo "a lane is wedged"
EOF
}

err() { echo "ff-status: $*" >&2; }

RUN="" REPO="" OUT="" WATCH="" EXIT_STALLED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --watch) WATCH="${2:-}"; shift 2 ;;
    --exit-stalled) EXIT_STALLED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
command -v jq >/dev/null || { err "jq required"; exit 2; }
[ -z "$WATCH" ] || [ -n "$OUT" ] || { err "--watch requires --out"; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
RUNDIR="$REPO/.fleetflow/$RUN"
[ -f "$RUNDIR/journal.jsonl" ] || { err "no journal at $RUNDIR"; exit 2; }
STALL_S="${FLEETFLOW_STALL_SECONDS:-600}"
echo "$STALL_S" | grep -qE '^[0-9]+$' || { err "FLEETFLOW_STALL_SECONDS must be an integer"; exit 2; }
# Abandonment threshold (ADR-025): hours, not minutes, on purpose. The stall
# detector answers "is this wedged RIGHT NOW" and needs a live stream to say so;
# abandonment answers "has this run been walked away from", and at a 6h horizon
# total filesystem silence + no result envelope is decisive even for lanes the
# stall detector cannot cover (live_signal:false).
ABANDON_S="${FLEETFLOW_ABANDON_SECONDS:-21600}"
echo "$ABANDON_S" | grep -qE '^[0-9]+$' || { err "FLEETFLOW_ABANDON_SECONDS must be an integer"; exit 2; }

# One stat for the WHOLE run dir instead of ~6 per lane. Process spawns dominate
# this script's cost on Windows (~150ms each): a 23-lane run was paying ~20s just
# to ask the filesystem for mtimes it could have got in a single call.
declare -A MT
prime_mtimes() {
  MT=()
  local f t
  while IFS='|' read -r f t; do [ -n "$f" ] && MT["$f"]="$t"; done \
    < <(stat -c '%n|%Y' "$RUNDIR"/* 2>/dev/null)
}
# Falls back to a real stat for anything outside the run dir (a journalled
# artifact path can be spelled differently from $RUNDIR/...), so the cache is a
# fast path, never a source of wrong answers.
mtime() {
  local v="${MT[$1]:-}"
  if [ -n "$v" ]; then printf '%s\n' "$v"; else stat -c %Y "$1" 2>/dev/null || echo 0; fi
}

# spawner_alive PID WINPID -> 0 when the ff-spawn process that owns a lane is
# still running. Prefers the Windows pid (global; tasklist) over the MSYS pid,
# which is visible only inside the same MSYS runtime - a spawn from another
# bash would read falsely dead by `kill -0`. UNKNOWN MEANS ALIVE: this probe
# may only ever err toward today's behaviour (wait for ADR-025's horizon),
# never toward a demotion. Only called for in-flight lanes, so its cost is
# one tasklist per running lane, not per lane.
spawner_alive() {
  local pid="$1" winpid="$2"
  if [ -n "$winpid" ] && [ "$winpid" != "null" ] && command -v tasklist >/dev/null 2>&1; then
    # tasklist prints "INFO: No tasks are running..." on a miss, exit 0 either
    # way - match the pid column, never the exit code or a non-empty line.
    # MSYS_NO_PATHCONV: Git Bash rewrites the `/FI` and `/NH` switches into
    # `C:/Program Files/Git/FI` before a native exe sees them (observed
    # 2026-09-09), so without it tasklist only ever prints a usage error.
    MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $winpid" /NH 2>/dev/null | tr -d '\r' \
      | grep -qE "(^|[[:space:]])$winpid([[:space:]]|$)" && return 0
    return 1
  fi
  if [ -n "$pid" ] && [ "$pid" != "null" ]; then
    kill -0 "$pid" 2>/dev/null && return 0
    return 1
  fi
  return 0
}

# scan_transcript FILE -> ONE tab-separated line, ONE gawk pass over a claude/glm
# session transcript. Replaces three greps plus an awk.
#
# Output is TSV, not shell assignments: the values include free-form tool names and
# model_id ids, and building `eval`-able quoting inside a single-quoted awk program
# inside a shell function is three levels of escaping deep - it broke on the first
# apostrophe. `read` with IFS=tab has no such failure mode. Fields, in order:
#   dens  basis  tools  tout  tin  tcache  ttotal  lasttool  model_id
#
# Counting rules are matched to the greps this replaces, deliberately: `tools`
# counts LINES containing a tool_use (what `grep -c` did), while the token sums
# count EVERY occurrence (what `grep -o | awk` did). They differ, and quietly
# "fixing" either would move numbers ff-monitor.html already renders.
#
# The density strip is REAL wall-clock: these transcripts carry per-record ISO
# timestamps, so unlike codex's untimed stream the buckets mean elapsed time.
scan_transcript() {
  awk -v N=20 '
    {
      line = $0
      if (match(line, /"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        st = substr(line, RSTART + 13, 19); gsub(/[-T:]/, " ", st)
        tv = mktime(st)
        if (tv > 0) { n++; ts[n] = tv; if (lo == 0 || tv < lo) lo = tv; if (tv > hi) hi = tv }
      }
      if (line ~ /"type":"tool_use"/) tools++
      rest = line
      while (match(rest, /"name":"[A-Za-z_]+"/)) {
        lasttool = substr(rest, RSTART + 8, RLENGTH - 9); rest = substr(rest, RSTART + RLENGTH)
      }
      rest = line
      # the TRANSCRIPT record key is "model" - external format, not renamed by
      # the fleetflow brain->model refactor; the awk var holds our model_id
      while (match(rest, /"model":"[^"]+"/)) {
        model_id = substr(rest, RSTART + 9, RLENGTH - 10); rest = substr(rest, RSTART + RLENGTH)
      }
      for (k = 1; k <= 4; k++) {
        key = (k == 1 ? "output_tokens" : k == 2 ? "input_tokens" \
             : k == 3 ? "cache_read_input_tokens" : "cache_creation_input_tokens")
        rest = line
        while (match(rest, "\"" key "\":[0-9]+")) {
          sums[k] += substr(rest, RSTART + length(key) + 3, RLENGTH - length(key) - 3) + 0
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
    }
    END {
      for (b = 0; b < N; b++) d[b] = 0
      if (n > 0) {
        span = hi - lo
        for (i = 1; i <= n; i++) {
          b = (span > 0) ? int((ts[i] - lo) * N / span) : 0
          if (b > N - 1) b = N - 1
          d[b]++
        }
      }
      out = "["; for (b = 0; b < N; b++) out = out (b ? "," : "") d[b]; out = out "]"
      printf "%s\ttime\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n", out, tools + 0, sums[1], sums[2],
             sums[3] + sums[4], sums[1] + sums[2] + sums[3] + sums[4], lasttool, model_id
    }
  ' "$1" 2>/dev/null
}

emit() {
  local now lanefile id model state started finished elapsed art commits last_c tools activity tokens etail rc
  local T enc f m last_act idle stalled live
  local landed authored verdict tests fchg deferred stop_reason denials summary eerr jpid jwinpid
  local base_ref integ integ_sha base_sha cand fra
  # NOT local: --exit-stalled reads it after emit returns, and in --watch mode it
  # must reset every tick so a lane that resumes writing clears the verdict.
  STALL_ANY=0
  prime_mtimes
  # Which lanes were SPAWNED with --worktree. Without this, a landed-and-cleaned
  # lane is indistinguishable from one that never had a worktree - and those mean
  # opposite things: the first is the normal end of a healthy lane, the second is
  # the case where the stall detector cannot attribute a transcript and therefore
  # reports "cannot tell" rather than "healthy".
  WT_INTENT=""
  [ -f "$RUNDIR/manifest.json" ] && WT_INTENT="|$(jq -r '
    (.packets // [])[] | select(.worktree == true) | .id' "$RUNDIR/manifest.json" 2>/dev/null \
    | tr -d '\r' | tr '\n' '|')"
  # --- landedness, resolved ONCE per emit (ADR-035) ---------------------------
  # Mirrors ff-clean's rule exactly: the integration ref is the manifest base
  # when that names a live branch, else main, else master, else the MAIN repo's
  # HEAD - resolved to a sha HERE, in the main repo, before any lane-side git
  # sees it. A symbolic "HEAD" handed to a worktree resolves to the worktree's
  # own HEAD and every lane reads as a self-compare (ff-clean lost a 2-commit
  # lane to exactly that on 2026-08-25). Until 2026-09-09 this script counted
  # against a hardcoded "main..HEAD", which is wrong whenever a wave re-plans
  # from a lane branch (godaddy-build's base is fleetflow/godaddy-build/perf-groups-a).
  base_ref="$(jq -r '.base // ""' "$RUNDIR/manifest.json" 2>/dev/null | tr -d '\r')"
  integ=""
  for cand in "$base_ref" main master; do
    [ -n "$cand" ] || continue
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$cand"; then integ="$cand"; break; fi
  done
  [ -n "$integ" ] || integ="HEAD"
  # An integration ref that has ITSELF been integrated is no longer the
  # integration ref. A wave re-planned from a lane branch leaves the manifest
  # base naming that lane; once it lands, the branch is a frozen ancestor of
  # main (godaddy-build: base perf-groups-a sat 95 commits BEHIND main) and
  # measuring against it read all 93 landed lanes as unmerged. If main contains
  # the chosen ref, main is the ref. Monotone by construction - HEAD ⊂ base
  # implies HEAD ⊂ main - so this only ever ADDS landed verdicts that are true.
  # Mirrored in ff-clean; the two must move together (ADR-035, amendment).
  if [ "$integ" != "main" ] && git -C "$REPO" show-ref --verify --quiet refs/heads/main \
     && git -C "$REPO" merge-base --is-ancestor "$integ" main 2>/dev/null; then
    integ="main"
  fi
  integ_sha="$(git -C "$REPO" rev-parse --verify --quiet "$integ^{commit}" 2>/dev/null | tr -d '\r')"
  # A lane's OWN commit count survives landing only when the base is a FROZEN
  # sha (ff-plan records `rev-parse HEAD` at authoring time). Against a branch
  # base the range collapses to 0 the moment the lane lands, which is the very
  # ambiguity `landed` exists to remove - so a branch base yields no count.
  base_sha=""
  case "$base_ref" in
    *[!0-9a-fA-F]*|"") ;;
    *) [ "${#base_ref}" -ge 7 ] && base_sha="$(git -C "$REPO" rev-parse --verify --quiet "$base_ref^{commit}" 2>/dev/null | tr -d '\r')" ;;
  esac
  now=$(date +%s)
  # Lane records accumulate in a FILE, one JSON object per line - NEVER in a shell
  # variable. Folding each lane into a growing `$L + [...]` array reads better and
  # is exactly what this replaced: that form passed the whole accumulated array
  # back through jq's argv once per lane, so argv bytes were QUADRATIC in lane
  # count. Past ~37 lanes it exceeded the Windows command-line limit, jq died with
  # "Argument list too long", `$(...)` collapsed the accumulator to the empty
  # string, and every remaining lane then failed `--argjson L ""`. emit produced
  # nothing at all, so the machine-wide dashboard rendered its three LARGEST runs
  # (godaddy-build at 123 lanes, newbook-v1, tess-v1) as empty "could not read
  # this run" cards while every small run looked fine (2026-09-09).
  # argv now carries exactly one lane's fields regardless of lane count, and the
  # array is assembled by slurping this file on stdin - a redirection bash
  # performs, so no temp path is ever handed to jq (jq here is a native Windows
  # binary that would not resolve an MSYS /tmp path).
  # Do NOT "simplify" this back into a variable.
  lanefile="$(mktemp)" || { err "cannot create temp file for lane records"; return 1; }
  # ONE jq pass over the journal for every lane's identity and state, not six per
  # lane. Semantics are unchanged, field for field (see each line below); this is
  # purely about process count. Windows spawns cost ~150ms, so a 23-lane run was
  # paying ~17s just to re-read the same small file 138 times - enough that the
  # machine-wide aggregator timed out on its biggest runs.
  #
  # Rows are 0x1f-separated (see the `read` below for why not tab). Safe because
  # every field is an id, a model name, a phase name, a record type, an integer
  # rc, a pid, or a filesystem path - none of which can contain 0x1f.
  # The row delimiter is the ASCII unit separator (0x1f), NOT a tab, and that
  # is load-bearing: tab is IFS *whitespace*, so `read` collapses a run of
  # tabs into one separator and every empty column (rc, artifact and model_id
  # are all empty on a running lane) shifts the later fields left. That is
  # how a running lane silently lost its journalled model_id, and how the
  # proc pid added 2026-09-09 never reached the loop. 0x1f is not whitespace,
  # so empty columns stay empty. No field can contain it.
  while IFS="$(printf '\037')" read -r id model phase last_type rc art jmodel jpid jwinpid; do
    [ -n "$id" ] || continue
    if [ "$last_type" = "started" ]; then state="running"; finished=0
    elif [ -z "$rc" ]; then state="running"; finished=0
    elif [ "$rc" = "0" ]; then state="done"; finished=$(mtime "$art")
    else state="failed"; finished=$(mtime "$art"); fi
    started=$(mtime "$RUNDIR/$id.prompt.txt")
    if [ "$finished" -gt 0 ]; then elapsed=$((finished - started)); else elapsed=$((now - started)); fi
    [ "$elapsed" -ge 0 ] || elapsed=0

    commits=0; last_c=""; wt=""; branch=""; wtstate="none"; landed=null; authored=null
    case "$WT_INTENT" in *"|$id|"*) wtstate="reclaimed" ;; esac
    if [ -d "$RUNDIR/wt-$id" ]; then
      wt="$RUNDIR/wt-$id"; branch="fleetflow/$RUN/$id"; wtstate="present"
      # `commits` is the UNMERGED count against the integration ref - the same
      # number ff-clean's reclaim decision uses - and `landed` is its zero case
      # made explicit. Both are needed: a bare 0 meant either "landed" or "never
      # committed", and on a fully landed run every card read `0 commits`
      # (godaddy-build, 122 of 123 lanes, 2026-09-09). is-ancestor is an exit
      # code; the range walk (count + newest subject in one `git log`) only runs
      # for lanes that are NOT landed.
      if [ -n "$integ_sha" ]; then
        if git -C "$wt" merge-base --is-ancestor HEAD "$integ_sha" 2>/dev/null; then
          landed=true
        else
          landed=false
          gitlog="$(git -C "$wt" log --format=%s "$integ_sha..HEAD" -- 2>/dev/null)"
          if [ -n "$gitlog" ]; then
            commits="$(printf '%s\n' "$gitlog" | wc -l | tr -d ' ')"
            last_c="$(printf '%s\n' "$gitlog" | head -1 | head -c 90)"
          fi
        fi
      fi
      if [ -n "$base_sha" ]; then
        authored="$(git -C "$wt" rev-list --count "$base_sha..HEAD" 2>/dev/null | tr -d '\r')"
        [ -n "$authored" ] || authored=null
      fi
    fi

    # --- token accounting ------------------------------------------------------
    # `tokens` is LEGACY and deliberately unchanged: codex lanes report a grand
    # total, claude-model lanes report output only. ff-monitor.html renders that
    # field, so its meaning is frozen. The tokens_* quartet added beside it is
    # model-CONSISTENT (in = fresh input, cached = cache reads, out, total) and is
    # what any cross-lane or cross-run comparison must use - comparing a codex
    # lane's legacy 5.4M against a glm lane's legacy 42.6k compares a total
    # against an output count. cost_usd is null wherever it cannot be sourced:
    # claude models report `total_cost_usd` themselves, codex reports none, and a
    # fabricated dollar figure is worse than an absent one.
    tools=0; activity=""; tokens=0; T=""
    tin=0; tcache=0; tout=0; ttotal=0; cost=null; dens="[]"; dbasis=null
    # --- final-reply contract -----------------------------------------------------
    # The builder role card (assets/roles/builder.role.md) REQUIRES the worker's
    # final reply to carry STATUS / TESTS: <passed>/<failed> / FILES_CHANGED: <n>,
    # and DEFERRED when partial; 115 of godaddy-build's 123 artifacts honour it.
    # Those are the lane's OUTCOME, where everything else here is effort, so the
    # card wants them. They are parsed INSIDE the two jq passes below (rawfile /
    # .result) - never as a third process per lane: ff-status already spends
    # ~360ms/lane on Windows spawns and a 123-lane run takes 88s of the
    # aggregator's 180s budget. Empty means "not in the reply" - the dashboard
    # shows nothing rather than a placeholder.
    verdict=""; tests=""; fchg=""; deferred=""; stop_reason=""; denials=0; summary=""; eerr=""
    # Journalled launch model_id is the FLOOR; a worker that reports what it
    # actually ran (modelUsage, transcript) overrides it below, because an
    # alias like "glm" is less true than the resolved "GLM-5.2".
    model_id="${jmodel:-}"
    if [ "$model" = "codex" ] && [ -f "$RUNDIR/$id.events.jsonl" ]; then
      # ONE jq over the event stream, not four. Same numbers, a quarter of the
      # processes - and the density strip rides along for free because the pass is
      # already walking every item.
      #
      # density_basis is "sequence", NOT "time", and that distinction is the whole
      # reason the field exists: codex's --json stream carries NO timestamps, so
      # these buckets are item ordinals, not wall-clock. Labelling them a time
      # series would be a lie the chart cannot disown.
      # codex writes its final reply to <id>.last.txt; ride it in as a rawfile so
      # the contract parse costs no extra process. $ARGS.named keeps the program
      # valid when the file is absent (a lane still running has none).
      fra=(); [ -f "$RUNDIR/$id.last.txt" ] && fra=(--rawfile fr "$RUNDIR/$id.last.txt")
      eval "$(jq -sr --argjson N 20 "${fra[@]}" '
        def fldl($t; $k; $n):
          ($t | gsub("\r"; "") | split("\n")) as $ls
          | ([range($ls | length) | select($ls[.] | test("^\\s*\\**" + $k + "\\**\\s*:"; "i"))] | first) as $i
          | if $i == null then "" else
              ($ls[$i] | sub("^\\s*\\**" + $k + "\\**\\s*:\\**\\s*"; ""; "i")) as $head
              | (reduce $ls[($i + 1):][] as $l ({acc: [], stop: false};
                  if .stop then .
                  elif ($l | test("^\\s*\\**[A-Z_]{3,}\\**\\s*:")) then .stop = true
                  elif ($l | test("^\\s*$")) then (if ((.acc | length) > 0 or ($head | length) > 0) then .stop = true else . end)
                  else .acc += [$l] end)).acc as $rest
              | ([$head] + $rest | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0)) | join(" "))
              | sub("\\s*\\**\\s*$"; "") | .[0:$n]
            end;
        def fld($t; $k): fldl($t; $k; 400);
        (($ARGS.named.fr // "") | tostring) as $fr
        | [.[] | select(.type=="item.completed")] as $items
        | ([.[] | select(.usage != null) | .usage] | last // {}) as $u
        | ($items | length) as $n
        | (if $n == 0 then [range($N)|0]
           else reduce range($n) as $i ([range($N)|0];
                  .[ (($i * $N / $n) | floor | if . > ($N-1) then ($N-1) else . end) ] += 1)
           end) as $d
        | "tools=\([$items[] | select(.item.type=="command_execution")] | length) " +
          "tokens=\($u.total_tokens // (($u.input_tokens // 0) + ($u.output_tokens // 0))) " +
          "tin=\(($u.input_tokens // 0) - ($u.cached_input_tokens // 0)) " +
          "tcache=\($u.cached_input_tokens // 0) tout=\($u.output_tokens // 0) " +
          "ttotal=\(($u.input_tokens // 0) + ($u.output_tokens // 0)) " +
          "dens=\($d | tojson | @sh) dbasis=\("\"sequence\"" | @sh) " +
          "activity=\(($items | last | .item
              | (.type + ": " + ((.command // .text // "") | gsub("\n";" ") | .[0:70]))) // "" | @sh) " +
          "verdict=\(fld($fr; "STATUS") | ascii_downcase | .[0:24] | @sh) tests=\(fld($fr; "TESTS") | @sh) " +
          "fchg=\(fld($fr; "FILES_CHANGED") | @sh) deferred=\(fld($fr; "DEFERRED") | @sh) " +
          "summary=\(fldl($fr; "SUMMARY"; 1500) | @sh)"
        ' "$RUNDIR/$id.events.jsonl" 2>/dev/null)"
    elif [ "$state" != "running" ] && [ -f "$RUNDIR/$id.result.json" ]; then
      # ONE jq over the result envelope. `model_id` comes from modelUsage, which is
      # the only place the EXACT id a claude-model worker actually ran on survives
      # (e.g. "GLM-5.2", not the "glm" alias it was launched with). Picked by
      # output tokens so a run that briefly touched a small model_id still reports the
      # model_id that did the work.
      eval "$(jq -r '
        def fldl($t; $k; $n):
          ($t | gsub("\r"; "") | split("\n")) as $ls
          | ([range($ls | length) | select($ls[.] | test("^\\s*\\**" + $k + "\\**\\s*:"; "i"))] | first) as $i
          | if $i == null then "" else
              ($ls[$i] | sub("^\\s*\\**" + $k + "\\**\\s*:\\**\\s*"; ""; "i")) as $head
              | (reduce $ls[($i + 1):][] as $l ({acc: [], stop: false};
                  if .stop then .
                  elif ($l | test("^\\s*\\**[A-Z_]{3,}\\**\\s*:")) then .stop = true
                  elif ($l | test("^\\s*$")) then (if ((.acc | length) > 0 or ($head | length) > 0) then .stop = true else . end)
                  else .acc += [$l] end)).acc as $rest
              | ([$head] + $rest | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0)) | join(" "))
              | sub("\\s*\\**\\s*$"; "") | .[0:$n]
            end;
        def fld($t; $k): fldl($t; $k; 400);
        ((.result // .text // "") | if type == "string" then . else tojson end) as $fr
        | .usage as $u
        | "tokens=\($u.output_tokens // 0) tools=\(.num_turns // 0) " +
          "tin=\($u.input_tokens // 0) " +
          "tcache=\(($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0)) " +
          "tout=\($u.output_tokens // 0) " +
          "ttotal=\(($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.output_tokens // 0)) " +
          # claude -p prices its own turn; for GLM this is the CLI Anthropic-rate
          # estimate, not the z.ai invoice - a magnitude, not an amount owed.
          "cost=\(.total_cost_usd // "null") " +
          "model_id=\((.modelUsage // {} | to_entries | sort_by(-.value.outputTokens) | .[0].key) // "" | @sh) " +
          # stop_reason and permission_denials are the two envelope fields that
          # change a verdict: max_tokens means the worker was CUT OFF mid-reply,
          # and a denial means it asked for something the harness refused.
          "stop_reason=\(.stop_reason // "" | @sh) denials=\((.permission_denials // []) | length) " +
          "verdict=\(fld($fr; "STATUS") | ascii_downcase | .[0:24] | @sh) tests=\(fld($fr; "TESTS") | @sh) " +
          "fchg=\(fld($fr; "FILES_CHANGED") | @sh) deferred=\(fld($fr; "DEFERRED") | @sh) " +
          # what the envelope itself says about a failure: claude -p writes it
          # HERE, not on stderr - 27 of 68 failed lanes on this box had an
          # empty .err. (No apostrophes in this comment: it sits inside the
          # single-quoted jq program.)
          "eerr=\((if ((.is_error // false) == true) or ((.subtype // "success") | tostring | startswith("error"))
                   then ((.subtype // "error") | tostring) + " after " + ((.num_turns // 0) | tostring) + " turn(s)"
                        + (if .stop_reason then " - stop_reason " + (.stop_reason | tostring) else "" end)
                        + (if .api_error_status then " - api " + (.api_error_status | tostring) else "" end)
                        + (if ((.result | type) == "string" and (.result | length) > 0) then ": " + (.result | gsub("\n"; " ") | .[0:120]) else "" end)
                   else "" end) | @sh) " +
          "summary=\(fldl($fr; "SUMMARY"; 1500) | @sh)"
        ' "$RUNDIR/$id.result.json" 2>/dev/null | head -1)"
      [ -n "${cost:-}" ] || cost=null
    elif [ "$state" = "running" ]; then
      # claude -p persists its session transcript as it runs - the only live
      # signal a claude-model lane emits. GLM workers get an isolated config dir
      # (fleet-worker), so theirs is easy to find; Anthropic-model workers use
      # host auth, so theirs lands under ~/.claude/projects/<encoded-workdir>/.
      T="$(ls -t "${FLEETFLOW_CFG_BASE:-$HOME/.fleet-worker}/cfg-ff-$id/projects"/*/*.jsonl 2>/dev/null | head -1)"
      if [ -z "$T" ] && [ -d "$RUNDIR/wt-$id" ]; then
        # Worktree lanes ONLY. Their workdir is unique to the lane, so the newest
        # transcript in its project dir is unambiguously this lane's. A
        # non-worktree lane shares the repo dir with its siblings AND with the
        # orchestrator's own session - guessing there would attribute someone
        # else's activity to this lane, which is worse than reporting none.
        # Encoding is ff-spawn's archive_transcript() rule: [:\/.] -> "-" per char.
        enc="$(printf '%s' "$RUNDIR/wt-$id" | sed 's#[:\\/.]#-#g')"
        T="$(ls -t "$HOME/.claude/projects/$enc"/*.jsonl 2>/dev/null | head -1)"
      fi
      if [ -n "$T" ]; then
        IFS="$(printf '\t')" read -r dens dbasis tools tout tin tcache ttotal lasttool smodel \
          < <(scan_transcript "$T")
        [ -n "${dens:-}" ] || dens="[]"
        [ -z "${dbasis:-}" ] && dbasis=null || dbasis="\"$dbasis\""
        tokens="${tout:-0}"
        [ -z "${lasttool:-}" ] || activity="live: $lasttool"
        [ -z "${smodel:-}" ] || model_id="$smodel"
      fi
    fi
    # A finished claude-model lane keeps its archived transcript, so its density
    # strip is recoverable too. Deliberately NOT fed into the stall block below:
    # an archived transcript is a record, not a live stream, and treating it as
    # one would let a long-dead lane look like it was still writing.
    if [ "$dens" = "[]" ] && [ -f "$RUNDIR/$id.transcript.jsonl" ]; then
      IFS="$(printf '\t')" read -r dens _b _t _o _i _c _tt _lt _m \
        < <(scan_transcript "$RUNDIR/$id.transcript.jsonl")
      [ -n "${dens:-}" ] || dens="[]"
      [ "$dens" = "[]" ] || dbasis='"time"'
    fi
    for _t in tin tcache tout ttotal; do
      eval "[ -n \"\${$_t:-}\" ] && echo \"\${$_t}\" | grep -qE '^[0-9]+$' || $_t=0"
    done
    # heartbeat fallback: for running lanes with no introspectable stream
    # (grok), the worker's own last heartbeat line is the best activity we have
    if [ "$state" = "running" ] && [ -z "$activity" ] && [ -s "$RUNDIR/wt-$id/.ff-heartbeat" ]; then
      activity="hb: $(tail -1 "$RUNDIR/wt-$id/.ff-heartbeat" 2>/dev/null | head -c 70)"
    fi
    [ -n "$activity" ] || activity="${last_c:-working}"
    etail="$(awk '{
        gsub(/\033\[[0-9;]*[a-zA-Z]/, ""); gsub(/\r/, "");
        sub(/^[ \t|]+/, ""); sub(/[ \t]+$/, "");
        if ($0 ~ /[A-Za-z]{3,}/) last = $0
      } END { print substr(last, 1, 200) }' "$RUNDIR/$id.err" 2>/dev/null)"
    # .err is a redirect of the worker's stderr and was EMPTY on 27 of this
    # box's 68 failed lanes (2026-09-09): claude -p reports its failure in the
    # envelope (subtype error_max_turns, api_error_status, stop_reason), not on
    # stderr. Fall back to it so a failed lane always says why.
    [ -n "$etail" ] || etail="${eerr:-}"

    # --- stall detection (incident 2026-07-27, run bkv2p2) --------------------
    # elapsed_s cannot distinguish a working lane from a wedged one: a codex lane
    # blocked on an un-approvable UAC prompt (see ff-spawn's windows.sandbox
    # guard) keeps `state: running` with a climbing clock forever - two lanes hid
    # that way for 2.7h. The ONE signal that separates them from outside the
    # process is whether the lane is still WRITING.
    #
    # Two tiers, and the split is load-bearing. A LIVE STREAM is a file the model
    # appends to WHILE it works: codex's --json event stream, or a claude/glm
    # session transcript. Only those can substantiate a stall. The artifact and
    # stderr are created by the shell's redirect at LAUNCH and then sit untouched
    # until exit, so on their own they prove nothing - counting them as evidence
    # flagged every healthy 10-minute sonnet lane as stalled, and grok under
    # --output-format json (buffers to exit) has no live stream at all. They still
    # count toward last_activity_s, since a write there IS real activity, but
    # never toward the verdict.
    #
    # NEVER CLAIM A STALL YOU CANNOT SUBSTANTIATE: no live stream, no verdict.
    # `live_signal` reports which lanes the detector actually covers, so a
    # `stalled: false` it cannot back up is never read as a clean bill of health.
    #
    # wt-<id>/.ff-heartbeat is the third live stream: the WORKER creates and
    # appends it per major step (guard clause injected by ff-spawn for worktree
    # lanes). Unlike the artifact/.err redirects it cannot exist without the
    # worker having written it, so its existence proves convention-following
    # and its mtime is real work - this is what covers grok worktree lanes
    # without touching grok's buffered result envelope.
    last_act=0; live=false
    for f in "$RUNDIR/$id.events.jsonl" "$T" "$RUNDIR/wt-$id/.ff-heartbeat"; do
      [ -n "$f" ] && [ -f "$f" ] || continue
      live=true
      m="$(mtime "$f")"; [ "$m" -gt "$last_act" ] && last_act="$m"
    done
    for f in "$RUNDIR/$id.last.txt" "$RUNDIR/$id.result.json" "$RUNDIR/$id.err"; do
      [ -f "$f" ] || continue
      m="$(mtime "$f")"; [ "$m" -gt "$last_act" ] && last_act="$m"
    done
    # nothing on disk yet (just spawned): measure silence from the lane's start
    [ "$last_act" -gt 0 ] || last_act=$started
    idle=$((now - last_act)); [ "$idle" -ge 0 ] || idle=0
    stalled=false
    if [ "$state" = "running" ] && [ "$live" = true ] && [ "$idle" -gt "$STALL_S" ]; then
      state="stalled"; stalled=true; STALL_ANY=1
    fi
    # --- dead spawner (ADR-025 addendum, 2026-09-09) -----------------------------
    # A lane's `result` record is journaled by ff-spawn AFTER its worker exits.
    # If ff-spawn itself is gone (its Bash tool call died with the session, the
    # machine rebooted) no result can ever arrive and the lane reads `running`
    # until the 6h abandonment horizon. A dead spawner is a process fact,
    # decisive at any timescale - ADR-025's reasoning about hours of silence,
    # applied to the one signal that needs no waiting. spawner_alive errs toward
    # alive, so a probe that cannot tell changes nothing. Journal-free like
    # abandonment: a respawn's fresh `started` record revives the lane.
    if { [ "$state" = "running" ] || [ "$state" = "stalled" ]; } && [ -n "${jpid:-}${jwinpid:-}" ] \
       && ! spawner_alive "${jpid:-}" "${jwinpid:-}"; then
      state="abandoned"; stalled=false; STALL_ANY=1
      activity="spawner pid ${jwinpid:-$jpid} is gone - no result will be journaled"
    fi
    # --- abandonment (ADR-025) ------------------------------------------------
    # A second, much longer silence horizon that - unlike the stall verdict -
    # needs NO live stream: `idle` here already includes artifact/.err/result
    # mtimes (a write there IS real activity) and falls back to the lane's own
    # start time, so for every lane it is a true lower bound on how long nothing
    # whatsoever has happened. Past ABANDON_S with no result envelope the lane is
    # not "possibly still thinking" - it was walked away from. `abandoned` is
    # FINAL and not in flight: the dashboard stops animating it, roll-ups stop
    # counting it live, and the graduated re-read timer stops burning on it.
    # The stalled flag drops with the demotion - state carries the verdict now -
    # but STALL_ANY still trips so an --exit-stalled watchdog fires on lanes the
    # stall detector could never cover (live_signal:false).
    if { [ "$state" = "running" ] || [ "$state" = "stalled" ]; } && [ "$idle" -gt "$ABANDON_S" ]; then
      state="abandoned"; stalled=false; STALL_ANY=1
    fi

    # `-n` (null input) is load-bearing, not habit: this runs inside a
    # `while read` whose stdin is the journal process substitution, and a jq that
    # read stdin would swallow the remaining lanes.
    jq -nc \
      --arg id "$id" --arg model "$model" --arg state "$state" --arg activity "$activity" \
      --arg last_c "$last_c" --arg etail "$etail" --arg art "${art:-}" --arg phase "${phase:-build}" \
      --argjson started "$started" --argjson elapsed "$elapsed" \
      --argjson idle "$idle" --argjson stalled "$stalled" --argjson live "$live" \
      --argjson commits "${commits:-0}" --argjson tools "${tools:-0}" --argjson tokens "${tokens:-0}" \
      --argjson tin "${tin:-0}" --argjson tcache "${tcache:-0}" --argjson tout "${tout:-0}" \
      --argjson ttotal "${ttotal:-0}" --argjson cost "${cost:-null}" \
      --argjson dens "${dens:-[]}" --argjson dbasis "${dbasis:-null}" \
      --arg model_id "${model_id:-}" --arg wt "${wt:-}" --arg branch "${branch:-}" \
      --arg wtstate "${wtstate:-none}" \
      --arg verdict "${verdict:-}" --arg tests "${tests:-}" --arg fchg "${fchg:-}" \
      --arg deferred "${deferred:-}" --arg stop_reason "${stop_reason:-}" --arg summary "${summary:-}" \
      --argjson denials "${denials:-0}" --argjson landed "${landed:-null}" --argjson authored "${authored:-null}" \
      '{id:$id,model:$model,phase:$phase,state:$state,started:$started,elapsed_s:$elapsed,
        last_activity_s:$idle,stalled:$stalled,live_signal:$live,
        commits:$commits,tools:$tools,tokens:$tokens,
        tokens_in:$tin,tokens_cached:$tcache,tokens_out:$tout,tokens_total:$ttotal,
        cost_usd:$cost,density:$dens,density_basis:$dbasis,
        model_id:(if $model_id=="" then null else $model_id end),
        worktree:(if $wt=="" then null else $wt end),
        worktree_state:$wtstate,
        branch:(if $branch=="" then null else $branch end),
        activity:$activity,
        last_commit:$last_c,artifact:$art,err_tail:$etail,
        verdict:(if $verdict=="" then null else $verdict end),
        tests:(if $tests=="" then null else $tests end),
        files_changed:(if $fchg=="" then null else $fchg end),
        deferred:(if $deferred=="" then null else $deferred end),
        summary:(if $summary=="" then null else $summary end),
        stop_reason:(if $stop_reason=="" then null else $stop_reason end),
        permission_denials:$denials,landed:$landed,commits_authored:$authored}' >> "$lanefile" \
      || { err "lane $id: failed to serialise status record"; rm -f "$lanefile"; return 1; }
  done < <(jq -sr '
      . as $all
      # lane ids: every id that has a "started" record, in first-appearance order
      | ([$all[] | select(.type=="started") | .id]
         | reduce .[] as $i ([]; if (index($i) == null) then . + [$i] else . end)) as $ids
      | $ids[] | . as $id
      | ([$all[] | select(.id == $id)]) as $recs
      # state derives from the LAST STATE-BEARING record for this id: a respawn
      # appends a fresh "started" AFTER an old "result", which means the lane is
      # running again. last-result-wins would wrongly show done/failed.
      # The started/result filter is load-bearing: ff-spawn also appends "proc"
      # records (reap anchors), and any future record type would otherwise become
      # the "last" one and silently break state derivation for that lane.
      | ($recs | map(select(.type=="started" or .type=="result"))) as $sr
      | ($recs | map(select(.type=="result"))) as $res
      | [ $id,
          # alias: legacy journals wrote `brain` (with `model` as the LAUNCH id,
          # so brain must win the fallback); post-rename journals write `model`
          ((($recs[0].brain) // ($recs[0].model)) // "null" | tostring),
          (($recs | map(select(.type=="started")) | .[0].phase // "build") | tostring),
          (($sr | last | .type) // ""),
          (if ($res | length) == 0 then "" else (($res | last | .rc) // "null" | tostring) end),
          (if ($res | length) == 0 then "" else (($res | last | .artifact) // "null" | tostring) end),
          # journalled launch model id - the only record of it for codex/grok.
          # Post-rename it is `model_id`; in legacy journals it lived under
          # `model` (alongside `brain`), so only read `model` when `brain` exists.
          (($recs | map(select(.type=="started")) | last) as $s
           | (($s.model_id) // (if ($s.brain != null) then $s.model else null end)) // ""),
          # spawner identity from the LAST proc record (a respawn appends a new
          # one): the MSYS pid and, on Windows, the global winpid. A dead spawner
          # can never journal a result - the loop probes it (ADR-025 addendum).
          ((($recs | map(select(.type=="proc")) | last | .pid) // "") | tostring),
          ((($recs | map(select(.type=="proc")) | last | .winpid) // "") | tostring)
        ] | join("")' "$RUNDIR/journal.jsonl" 2>/dev/null | tr -d '\r')
# tr -d '\r' is load-bearing, not tidiness: journals are written with CRLF line
# endings on Windows and jq's stdout carries the CR through. The per-lane
# `jq | head -1` pipes this replaced were absorbing it; reading jq directly does
# not, and a lone trailing CR on the artifact path silently turned every
# `stat` on it into "file not found" (so every done lane reported elapsed 0).
# No field here can legitimately contain a CR.
  local manifest="null"
  if [ -f "$RUNDIR/manifest.json" ]; then
    manifest="$(jq -c '{packet_count:(.packets|length), phases:(.phases // []),
                        orchestrator:(.orchestrator // null), base:(.base // null)}' \
                  "$RUNDIR/manifest.json" 2>/dev/null)"
  fi
  # Run-level orchestrator: the journal is authoritative (it is written per spawn
  # and cannot be edited by a later manifest rewrite); the manifest is the fallback.
  local orch
  orch="$(jq -r 'select(.type=="started" and .orchestrator != null) | .orchestrator' \
          "$RUNDIR/journal.jsonl" 2>/dev/null | tr -d '\r' | tail -1)"
  [ -n "$orch" ] || orch="$(jq -r '.orchestrator // ""' "$RUNDIR/manifest.json" 2>/dev/null | tr -d '\r')"
  # `-s` slurps the per-lane NDJSON on STDIN into the lanes array. The `<` is a
  # bash redirection, so jq never receives $lanefile as an argument - see the
  # accumulator comment above for why that matters. An empty file slurps to `[]`,
  # which is the correct answer for a run with no lanes.
  if ! jq -sc --arg run "$RUN" --arg repo "$REPO" --argjson now "$now" --arg orch "$orch" \
    --argjson manifest "${manifest:-null}" --argjson stall "$STALL_S" --argjson abandon "$ABANDON_S" \
    '{run:$run,repo:$repo,generated_at:$now,stall_seconds:$stall,abandon_seconds:$abandon,
      orchestrator:(if $orch=="" then null else $orch end),
      lanes:.,manifest:$manifest}' < "$lanefile"; then
    err "failed to assemble status JSON"
    rm -f "$lanefile"
    return 1
  fi
  rm -f "$lanefile"
}

STALL_ANY=0
# the JSON is always emitted first - --exit-stalled changes the exit code, never
# the data product, so a caller can pipe and branch in the same invocation.
if [ -n "$WATCH" ]; then
  err "watching every ${WATCH}s -> $OUT (ctrl-c to stop)"
  while :; do
    emit > "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
    if [ "$EXIT_STALLED" = 1 ] && [ "$STALL_ANY" = 1 ]; then
      err "stalled lane detected - exiting 14"; exit 14
    fi
    sleep "$WATCH"
  done
elif [ -n "$OUT" ]; then
  # emit's status is PROPAGATED, never swallowed. This script used to end in an
  # unconditional `exit 0`, so a failed emit exited 0 with empty stdout and the
  # only thing standing between that and a silently blank dashboard was
  # ff-aggregate's `not out.strip()` guard. A reader that asks for status and is
  # told "success, here is nothing" is worse than one that is told it failed.
  emit > "$OUT" || exit 1
else
  emit || exit 1
fi
[ "$EXIT_STALLED" = 1 ] && [ "$STALL_ANY" = 1 ] && { err "stalled lane(s) detected"; exit 14; }
exit 0
