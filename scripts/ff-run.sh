#!/usr/bin/env bash
# ff-run.sh - whole-run replay/status/wave sequencing for a fleetflow run.
#
# resume: replay every packet in <run>/manifest.json through ff-spawn, IN
#   MANIFEST ORDER, sequential. Unchanged packets cache-hit (ff-spawn exit 3)
#   and are reported "cached"; changed/new packets run live. A per-lane summary
#   goes to stderr; a JSON result array goes to stdout. Exit 0 if every lane is
#   ok or cached, 10 if any lane failed.
# status: convenience alias for ff-status (its JSON on stdout, identical exit).
# wave: post-build wave pipeline (ADR-018) - posture selects finder depth,
#   gate selects attendance. See usage() below and docs/adr/ADR-018-*.
# stdout: the JSON result list (resume) / ff-status JSON (status) /
#   wave-plan-or-summary JSON (wave). stderr: chatter.
#
# Exit codes: 0 ok/cached/all-waves-done | 2 usage | 10 a lane/wave failed
#             14 a wave gated with policy=stop (review-gated waves exit 0)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"

usage() {
  cat <<'EOF'
Usage: ff-run.sh resume  --run NAME [--repo PATH]
       ff-run.sh status  --run NAME [--repo PATH]
       ff-run.sh wave    --run NAME --posture P [--attend none|land|each]
                         [--gate WAVE=POLICY]... [--wave +perf,-a11y]
                         [--fix-rounds N] [--severity-floor S]
                         [--target diff|staging=URL]
                         [--dry-run] [--continue] [--repo PATH]

  resume --run NAME   replay every packet in <run>/manifest.json through
                      ff-spawn, in order. Unchanged packets cache-hit ("cached"),
                      changed/new ones run live. JSON result list on stdout.
  status --run NAME   alias for ff-status (run status JSON on stdout).
  wave --run NAME     post-build pipeline: finders -> triage -> fix ->
                      re-verify -> docs-sync (ADR-018). --posture selects
                      which finder waves run (baseline|tested|hardened|
                      complete); --attend is a MACRO setting each wave's
                      default gate (none->all auto; land->last wave review;
                      each->every wave review) - an explicit --gate WAVE=POLICY
                      (auto|review|stop) overrides the macro for that wave.
                      --wave +NAME/-NAME adds/removes a wave from the resolved
                      set (e.g. +perf, -a11y) - first invocation only; a
                      resumed run's wave plan is manifest truth.
                      --fix-rounds N (default 2) bounds the fix/re-verify loop;
                      0 degrades to report-only. --severity-floor S
                      (low|medium|high|critical, default medium) is auto-fixed
                      at/below, escalated above. --target (default diff) aims
                      the finder waves: diff inspects the change; staging=URL
                      drives the running product at URL - full interaction
                      permitted, but lanes NEVER deploy/restart/reconfigure
                      the target service (ADR-032). --dry-run resolves the plan
                      and generates finder packets into <run>/dryrun/ without
                      spawning. --continue resumes from manifest wave state
                      (first non-done wave; clears a pending gate).
  --repo PATH         repo root (default: git toplevel of cwd)

ENV (wave subcommand test/override seam)
  FLEETFLOW_WAVE_ROOT       anchor dir for catalogue template paths (default:
                            fleetflow tool root, i.e. dirname of scripts/)
  FLEETFLOW_WAVE_CATALOGUE  path to wave-catalogue.json (default:
                            $FLEETFLOW_WAVE_ROOT/assets/wave-catalogue.json)
  FLEETFLOW_WAVE_SCHEMA     path to findings.schema.json (default:
                            $FLEETFLOW_WAVE_ROOT/assets/findings.schema.json)
  FLEETFLOW_FINDINGS_BIN    path to ff-findings.sh (default: sibling of this
                            script)

EXAMPLES
  ff-run.sh resume --run currency
  ff-run.sh resume --run currency --repo /path/to/repo | jq '.[] | select(.status!="cached")'
  ff-run.sh status --run currency | jq '.lanes | length'
  ff-run.sh wave --run audit --posture tested --attend land
  ff-run.sh wave --run audit --posture hardened --gate fix=review --fix-rounds 1
  ff-run.sh wave --run audit --posture tested --dry-run
  ff-run.sh wave --run audit --posture tested --target staging=https://audit.staging.example
  ff-run.sh wave --run audit --continue
EOF
}

err() { echo "ff-run: $*" >&2; }

# --- wave subcommand (ADR-018) -----------------------------------------------
# Everything below is a self-contained function, called from main() before its
# existing resume/status handling - resume and status stay byte-identical.
#
# subst_template: literal %%KEY%% substitution via bash parameter-expansion
# pattern replace (NOT sed) - a re-verify/fix packet embeds raw findings JSON,
# which can carry '/', '&', and other sed-hazardous bytes. Reading the whole
# template into a variable and doing ${var//%%KEY%%/val} treats the search
# side as a literal (no glob metachars appear in "%%KEY%%") and the value side
# as plain text, so no escaping scheme is needed for either side.
subst_template() {
  local tmpl="$1"; shift
  local content
  content="$(cat "$tmpl")"
  while [ $# -ge 2 ]; do
    content="${content//%%$1%%/$2}"
    shift 2
  done
  printf '%s\n' "$content"
}

wave_main() {
RUN="" REPO="" POSTURE="" ATTEND="none" DRYRUN=0 CONTINUE=0
FIX_ROUNDS=2 SEV_FLOOR="medium" GATES="" WAVEADJ="" TARGET="diff"
FIX_ROUNDS_SET=0 SEV_FLOOR_SET=0 POSTURE_SET=0 TARGET_SET=0
while [ $# -gt 0 ]; do
  # flags that take a value: fail loudly instead of leaving $1 unconsumed - a
  # bare `shift 2` with only one argument left silently no-ops (shift errors
  # but the loop doesn't check it), which spins forever re-matching the same
  # flag. Guard every value-taking flag before the dispatch below.
  case "$1" in
    --run|--repo|--posture|--attend|--gate|--wave|--fix-rounds|--severity-floor|--target)
      [ $# -ge 2 ] || { err "missing value for $1"; usage >&2; exit 2; }
      ;;
  esac
  case "$1" in
    --run) RUN="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --posture) POSTURE="$2"; POSTURE_SET=1; shift 2 ;;
    --attend) ATTEND="$2"; shift 2 ;;
    --gate) GATES="${GATES}${GATES:+,}$2"; shift 2 ;;
    --wave) WAVEADJ="$2"; shift 2 ;;
    --fix-rounds) FIX_ROUNDS="$2"; FIX_ROUNDS_SET=1; shift 2 ;;
    --severity-floor) SEV_FLOOR="$2"; SEV_FLOOR_SET=1; shift 2 ;;
    --target) TARGET="$2"; TARGET_SET=1; shift 2 ;;
    --dry-run) DRYRUN=1; shift ;;
    --continue) CONTINUE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
command -v git >/dev/null || { err "git required"; exit 2; }
echo "$RUN" | grep -qE '^[a-z0-9-]+$' || { err "invalid or missing --run"; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }
case "$ATTEND" in none|land|each) ;; *) err "invalid --attend '$ATTEND' (none|land|each)"; exit 2 ;; esac
echo "$FIX_ROUNDS" | grep -qE '^[0-9]+$' || { err "invalid --fix-rounds (non-negative integer)"; exit 2; }
case "$SEV_FLOOR" in low|medium|high|critical) ;; *) err "invalid --severity-floor '$SEV_FLOOR'"; exit 2 ;; esac
# --target (ADR-032): `diff` (inspect the change - today's behaviour) or
# `staging=<http(s) url>` (drive the running product at that URL). Nothing
# else - no prod tier, no environment names; each waits for evidence of need.
case "$TARGET" in
  diff) ;;
  staging=http://?*|staging=https://?*) ;;
  *) err "invalid --target '$TARGET' (diff | staging=<http(s)://url>)"; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$HERE/ff-spawn.sh"
COLLECT="$HERE/ff-collect.sh"
STATUS="$HERE/ff-status.sh"
# template paths inside the catalogue are written relative to the fleetflow
# tool root (e.g. "assets/wave-packets/qa.tmpl.md") - WAVE_ROOT is that anchor,
# overridable so a self-test fixture catalogue can point at its own templates
# without touching the real assets/ tree.
WAVE_ROOT="${FLEETFLOW_WAVE_ROOT:-$HERE/..}"
CATALOGUE="${FLEETFLOW_WAVE_CATALOGUE:-$WAVE_ROOT/assets/wave-catalogue.json}"
SCHEMA="${FLEETFLOW_WAVE_SCHEMA:-$WAVE_ROOT/assets/findings.schema.json}"
FINDINGS="${FLEETFLOW_FINDINGS_BIN:-$HERE/ff-findings.sh}"
SEV_RUBRIC="critical=data loss/auth bypass/crash on main path; high=wrong results/injection/broken feature; medium=degraded UX/missing validation/perf cliff; low=polish/naming/minor inconsistency"

# jq.exe on Windows emits CRLF; command substitution only strips the trailing
# \n, so a bare `jq -r` capture here comes back with a trailing \r baked into
# the value (breaks -f tests, wave-name comparisons, jq --arg lookups). Same
# root cause ff-status.sh documents for journal reads - jqr() is this
# function's equivalent of its `tr -d '\r'` calls. Every "jq -r" below this
# point (wave_main only) goes through jqr instead.
jqr() { jq -r "$@" | tr -d '\r'; }

# missing sibling-lane deliverables degrade gracefully to a clear exit-2 error
# (ADR-018 §4/§1 are contracts this lane codes against, not implementations it
# owns) - EXCEPT the catalogue, which is needed even for --dry-run planning.
[ -f "$CATALOGUE" ] || { err "wave catalogue not found: $CATALOGUE (assets/wave-catalogue.json not landed yet)"; exit 2; }
jq empty "$CATALOGUE" 2>/dev/null || { err "wave catalogue is not valid JSON: $CATALOGUE"; exit 2; }

RUNDIR="$REPO/.fleetflow/$RUN"
mkdir -p "$RUNDIR/packets"
MANIFEST="$RUNDIR/manifest.json"
if [ ! -f "$MANIFEST" ]; then
  jq -nc --arg run "$RUN" --arg by "ff-run/$FF_VERSION" \
    '{run:$run,base:"main",created_by:$by,phases:[],packets:[]}' > "$MANIFEST.tmp" \
    && mv -f "$MANIFEST.tmp" "$MANIFEST"
fi

# provenance for finder/fix/regression packets' %%BASE_SHA%% - a pure function
# of the recorded run base (never a timestamp, never round-dependent), so it
# stays ADR-012-clean while telling a lane which tree it's auditing.
REPO_BASE_REF="$(jqr '.base // "main"' "$MANIFEST" 2>/dev/null)"; [ -n "$REPO_BASE_REF" ] || REPO_BASE_REF="main"
REPO_BASE_SHA="$(git -C "$REPO" rev-parse "$REPO_BASE_REF" 2>/dev/null || git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")"

if [ -z "$POSTURE" ]; then
  POSTURE="$(jqr '.posture // empty' "$MANIFEST")"
  [ -n "$POSTURE" ] || { err "no --posture given and none recorded in manifest for run '$RUN'"; exit 2; }
fi
case "$POSTURE" in baseline|tested|hardened|complete) ;; *) err "invalid or missing --posture '$POSTURE' (baseline|tested|hardened|complete)"; exit 2 ;; esac

# Manifest is truth on ANY resume (a waves key exists), not only --continue:
# a re-invocation without explicit --fix-rounds/--severity-floor keeps the
# recorded values instead of silently resetting them to CLI defaults. An
# explicit --posture that CONTRADICTS the posture already recorded for a
# resolved wave set is rejected outright - the wave set was frozen for the
# OLD posture, so silently relabeling it misrepresents which finders ran.
HAS_WAVES="$(jq '(.waves // []) | length' "$MANIFEST" 2>/dev/null || echo 0)"
if [ "$CONTINUE" = 1 ] || [ "${HAS_WAVES:-0}" -gt 0 ]; then
  if [ "${HAS_WAVES:-0}" -gt 0 ] && [ "$POSTURE_SET" = 1 ]; then
    RECORDED_POSTURE="$(jqr '.posture // empty' "$MANIFEST")"
    if [ -n "$RECORDED_POSTURE" ] && [ "$RECORDED_POSTURE" != "$POSTURE" ]; then
      err "--posture '$POSTURE' contradicts the posture already resolved for run '$RUN' ('$RECORDED_POSTURE') - the wave set was frozen for '$RECORDED_POSTURE'; start a new --run to change posture"
      exit 2
    fi
  fi
  if [ "$FIX_ROUNDS_SET" = 0 ]; then
    mfr="$(jqr '.fix_rounds // empty' "$MANIFEST")"; [ -n "$mfr" ] && FIX_ROUNDS="$mfr"
  fi
  if [ "$SEV_FLOOR_SET" = 0 ]; then
    msf="$(jqr '.severity_floor // empty' "$MANIFEST")"; [ -n "$msf" ] && SEV_FLOOR="$msf"
  fi
  if [ "$TARGET_SET" = 0 ]; then
    mtg="$(jqr '.target // empty' "$MANIFEST")"; [ -n "$mtg" ] && TARGET="$mtg"
  fi
fi

wave_status() { jqr --arg n "$1" '(.waves[] | select(.name==$n) | .status) // "pending"' "$MANIFEST"; }
set_wave_status() {
  jq --arg n "$1" --arg s "$2" \
    '.waves = (.waves | map(if .name==$n then .status=$s else . end))' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
}
set_wave_round() {
  jq --arg n "$1" --argjson r "$2" \
    '.waves = (.waves | map(if .name==$n then .round=$r else . end))' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
}

EXISTING_WAVES="$(jq -c '.waves // []' "$MANIFEST")"
EXISTING_COUNT="$(jq 'length' <<<"$EXISTING_WAVES")"

if [ "$EXISTING_COUNT" -gt 0 ]; then
  # Resuming: the manifest's `waves` array is the single source of truth for
  # names/order/gates (§2/§3) - --wave/--gate on a resumed run would silently
  # disagree with what was already spawned, so they are ignored (loudly) here
  # rather than reconciled.
  [ -n "$WAVEADJ$GATES" ] && err "note: --wave/--gate ignored for run '$RUN' - wave plan is already resolved (manifest is truth)"
  ALL_WAVES=(); FINDERS=()
  while IFS= read -r n; do ALL_WAVES+=("$n"); done < <(jqr '.[].name' <<<"$EXISTING_WAVES")
  while IFS= read -r n; do FINDERS+=("$n"); done < <(jqr '.[] | select(.kind=="finder") | .name' <<<"$EXISTING_WAVES")
  WAVES_JSON="$EXISTING_WAVES"
  if [ "$DRYRUN" != 1 ]; then
    jq --arg posture "$POSTURE" --argjson fr "$FIX_ROUNDS" --arg sf "$SEV_FLOOR" --arg tg "$TARGET" \
      '.posture = $posture | .fix_rounds = $fr | .severity_floor = $sf | .target = $tg' \
      "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
  fi
else
  # Fresh resolution: finder waves are every catalogue entry whose `postures`
  # array names the chosen posture (cumulative membership is catalogue DATA,
  # not sequencer logic - e.g. qa.postures=[tested,hardened,complete]).
  FINDER_NAMES="$(jqr --arg p "$POSTURE" \
    '.waves | to_entries[] | select(.value.kind=="finder") | select((.value.postures // []) | index($p)) | .key' \
    "$CATALOGUE")"
  FINDERS=()
  while IFS= read -r w; do [ -n "$w" ] && FINDERS+=("$w"); done <<<"$FINDER_NAMES"

  # regression-family waves: catalogue entries with kind=="fix" (a mutation
  # wave, not a plain finder) whose postures name the chosen posture -
  # scheduled after fix/re-verify, before docs-sync (below).
  REGRESSION_NAMES="$(jqr --arg p "$POSTURE" \
    '.waves | to_entries[] | select(.value.kind=="fix") | select((.value.postures // []) | index($p)) | .key' \
    "$CATALOGUE")"
  REGRESSIONS=()
  while IFS= read -r w; do [ -n "$w" ] && REGRESSIONS+=("$w"); done <<<"$REGRESSION_NAMES"

  if [ -n "$WAVEADJ" ]; then
    IFS=',' read -ra ADJS <<< "$WAVEADJ"
    for adj in "${ADJS[@]}"; do
      [ -n "$adj" ] || continue
      op="${adj:0:1}"; name="${adj:1}"
      case "$op" in
        +)
          jq -e --arg w "$name" '.waves[$w]' "$CATALOGUE" >/dev/null 2>&1 || { err "unknown wave in --wave: $name"; exit 2; }
          case " ${FINDERS[*]} " in *" $name "*) ;; *) FINDERS+=("$name") ;; esac
          ;;
        -)
          NEWF=()
          for f in "${FINDERS[@]}"; do [ -n "$f" ] && [ "$f" != "$name" ] && NEWF+=("$f"); done
          FINDERS=()
          [ "${#NEWF[@]}" -gt 0 ] && FINDERS=("${NEWF[@]}")
          ;;
        *) err "invalid --wave entry '$adj' (must start with + or -)"; exit 2 ;;
      esac
    done
  fi

  # An empty finder set is a real config error, not a valid "nothing to run"
  # plan - a mis-adjusted --wave that strips every finder must fail loudly
  # here rather than injecting an unnamed wave into the pipeline downstream.
  [ "${#FINDERS[@]}" -gt 0 ] || { err "no finder waves selected for posture '$POSTURE' after --wave adjustments - nothing to run"; exit 2; }

  ALL_WAVES=()
  [ "${#FINDERS[@]}" -gt 0 ] && ALL_WAVES+=("${FINDERS[@]}")
  ALL_WAVES+=(triage fix)
  [ "${#REGRESSIONS[@]}" -gt 0 ] && ALL_WAVES+=("${REGRESSIONS[@]}")
  ALL_WAVES+=(docs-sync land)

  declare -A GATE_MAP=()
  if [ -n "$GATES" ]; then
    IFS=',' read -ra GS <<< "$GATES"
    for g in "${GS[@]}"; do
      [ -n "$g" ] || continue
      gw="${g%%=*}"; gp="${g#*=}"
      case "$gp" in auto|review|stop) ;; *) err "invalid --gate policy in '$g' (auto|review|stop)"; exit 2 ;; esac
      case " ${ALL_WAVES[*]} " in *" $gw "*) ;; *) err "unknown wave in --gate: $gw"; exit 2 ;; esac
      GATE_MAP["$gw"]="$gp"
    done
  fi

  LAST_WAVE="${ALL_WAVES[${#ALL_WAVES[@]}-1]}"
  gate_for() {
    local w="$1" default="auto"
    case "$ATTEND" in
      land) [ "$w" = "$LAST_WAVE" ] && default="review" ;;
      each) default="review" ;;
    esac
    printf '%s' "${GATE_MAP[$w]:-$default}"
  }

  WAVES_JSON="[]"
  add_wave() {
    local name="$1" kind="$2" gate; gate="$(gate_for "$name")"
    WAVES_JSON="$(jq -nc --argjson arr "$WAVES_JSON" --arg n "$name" --arg k "$kind" --arg g "$gate" \
      '$arr + [{name:$n,kind:$k,gate:$g,status:"pending",round:0}]')"
  }
  for f in "${FINDERS[@]}"; do [ -n "$f" ] && add_wave "$f" finder; done
  add_wave triage barrier
  add_wave fix fix
  for r in "${REGRESSIONS[@]:-}"; do [ -n "$r" ] && add_wave "$r" regression; done
  add_wave docs-sync docs
  add_wave land land

  if [ "$DRYRUN" != 1 ]; then
    # sibling-key upsert (ADR-017 pattern): `phases`/`packets` untouched.
    jq --argjson waves "$WAVES_JSON" --arg posture "$POSTURE" --argjson fr "$FIX_ROUNDS" --arg sf "$SEV_FLOOR" --arg tg "$TARGET" \
      '.waves = $waves | .posture = $posture | .fix_rounds = $fr | .severity_floor = $sf | .target = $tg' \
      "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
  else
    # dry-run must not freeze the RESOLVED plan (that's the side effect that
    # made a throwaway --dry-run permanently ignore --wave/--gate on the real
    # run afterward) - but it DOES stamp an empty `waves` sibling key onto a
    # legacy manifest, so tooling that only checks "is this run wave-aware"
    # sees the shape immediately. An empty array keeps EXISTING_COUNT at 0,
    # so the next real invocation still resolves fresh.
    jq 'if has("waves") then . else .waves = [] end' "$MANIFEST" > "$MANIFEST.tmp" \
      && mv -f "$MANIFEST.tmp" "$MANIFEST"
  fi
fi

# --- dry-run: resolve + generate finder packets, spawn nothing --------------
# No manifest write happens on this path (both branches above are guarded by
# DRYRUN above) - a throwaway --dry-run must not freeze the wave plan for the
# real run that follows.
if [ "$DRYRUN" = 1 ]; then
  mkdir -p "$RUNDIR/dryrun"
  DRYRUN_FAIL=0
  for f in "${FINDERS[@]:-}"; do
    [ -n "$f" ] || continue
    tmpl="$(jqr --arg w "$f" '.waves[$w].template // empty' "$CATALOGUE")"
    if [ -z "$tmpl" ] || [ ! -f "$WAVE_ROOT/$tmpl" ]; then
      err "dry-run: template missing for wave '$f' ($tmpl)"; DRYRUN_FAIL=1; continue
    fi
    lanes="$(jqr --arg w "$f" '.waves[$w].lanes // 1' "$CATALOGUE")"
    n=1
    while [ "$n" -le "$lanes" ]; do
      subst_template "$WAVE_ROOT/$tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "$REPO_BASE_SHA" \
        TARGET "$TARGET" FINDINGS_JSON "[]" SEVERITY_RUBRIC "$SEV_RUBRIC" > "$RUNDIR/dryrun/${f}-${n}.task.md"
      n=$((n+1))
    done
  done
  if [ "$DRYRUN_FAIL" = 1 ]; then
    err "dry-run: plan is INVALID - one or more selected waves have no template; nothing spawned, packets partial/absent under $RUNDIR/dryrun/"
    jq -nc --argjson waves "$WAVES_JSON" --arg posture "$POSTURE" --argjson fr "$FIX_ROUNDS" --arg sf "$SEV_FLOOR" --arg tg "$TARGET" \
      '{dry_run:true,valid:false,posture:$posture,fix_rounds:$fr,severity_floor:$sf,target:$tg,waves:$waves}'
    return 2
  fi
  err "dry-run: resolved $(jq 'length' <<<"$WAVES_JSON") wave(s) for posture '$POSTURE', packets under $RUNDIR/dryrun/"
  jq -nc --argjson waves "$WAVES_JSON" --arg posture "$POSTURE" --argjson fr "$FIX_ROUNDS" --arg sf "$SEV_FLOOR" --arg tg "$TARGET" \
    '{dry_run:true,valid:true,posture:$posture,fix_rounds:$fr,severity_floor:$sf,target:$tg,waves:$waves}'
  return 0
fi

[ -f "$FINDINGS" ] || { err "ff-findings.sh not found: $FINDINGS (scripts/ff-findings.sh not landed yet)"; exit 2; }
[ -f "$SCHEMA" ] || { err "findings schema not found: $SCHEMA (assets/findings.schema.json not landed yet)"; exit 2; }

sev_rank() { case "$1" in low) echo 1 ;; medium) echo 2 ;; high) echo 3 ;; critical) echo 4 ;; *) echo 2 ;; esac; }
FLOOR_RANK="$(sev_rank "$SEV_FLOOR")"

# heuristic escalation match (best-effort - the mechanical half of triage; the
# adr-touching.py check below covers ADR-governed paths, this covers the
# category keywords the catalogue's always_escalate list names). Deliberately
# permissive (false positives just escalate a finding a human can waive/clear;
# false negatives would silently auto-fix something that should not be).
# The regex is BUILT FROM the catalogue's always_escalate array (catalogue
# DATA, not a hardcoded literal here) - each entry is {name,pattern}; edit the
# catalogue to add/adjust a category, never this function.
ESCALATE_RE="$(jqr '[.always_escalate[]?.pattern] | join("|")' "$CATALOGUE")"
always_escalate_kw() {
  [ -n "$ESCALATE_RE" ] || return 1
  printf '%s' "$1" | grep -qiE "$ESCALATE_RE"
}
ADR_TOOL=""
for cand in "$HOME/.claude/skills/adr-ops/scripts/adr-touching.py" "$(command -v adr-touching.py 2>/dev/null || true)"; do
  [ -n "$cand" ] && [ -f "$cand" ] && { ADR_TOOL="$cand"; break; }
done
USE_ADR=0
if [ -d "$REPO/docs/adr" ]; then
  if [ -n "$ADR_TOOL" ]; then USE_ADR=1; else err "triage: adr-touching tool not found - skipping ADR-governed-path escalation check"; fi
fi

# --- per-wave runners ---------------------------------------------------------

# spawn_finder_lane WAVE LANE_ID MODEL TEMPLATE MAX_TURNS EFFORT - one finder
# lane, gated and its findings appended. Echoes "1" on failure (caller ORs
# into lane_fail) so both the primary-lane loop and the cross-provider lane
# below share the exact same spawn/collect/append path.
spawn_finder_lane() {
  local name="$1" lid="$2" model="$3" tmpl="$4" maxturns="$5" effort="$6" pf rc=0
  pf="$RUNDIR/packets/${lid}.task.md"
  # TARGET is a run-level input like BASE_SHA (never a timestamp, same for
  # every lane of the run), so embedding it stays ADR-012 cache-key clean.
  subst_template "$WAVE_ROOT/$tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "$REPO_BASE_SHA" \
    TARGET "$TARGET" FINDINGS_JSON "[]" SEVERITY_RUBRIC "$SEV_RUBRIC" > "$pf"
  bash "$SPAWN" --run "$RUN" --id "$lid" --model "$model" --phase "$name" \
    --prompt-file "$pf" --max-turns "$maxturns" --repo "$REPO" --worktree \
    ${effort:+--effort "$effort"} --schema "$SCHEMA" >/dev/null 2>>"$RUNDIR/$lid.spawn.err" || rc=$?
  case "$rc" in
    0|3)
      local out
      out="$(bash "$COLLECT" --run "$RUN" --id "$lid" --repo "$REPO" --schema 2>>"$RUNDIR/$lid.collect.err")" \
        && printf '%s' "$out" | jq -c --arg wave "$name" --arg lane "$lid" \
             '(if type=="array" then . else (.findings // []) end)[] | . + {wave:$wave,lane:$lane}' 2>/dev/null \
           | bash "$FINDINGS" append --run "$RUN" --repo "$REPO" 2>>"$RUNDIR/$lid.findings.err" \
        || { err "finder lane $lid: collect/schema gate failed"; return 1; }
      ;;
    *) err "finder lane $lid failed (rc=$rc)"; return 1 ;;
  esac
  return 0
}

run_finder_wave() {
  local name="$1" model effort maxturns lanes tmpl n=1 lane_fail=0
  model="$(jqr --arg w "$name" '.waves[$w].model // "sonnet"' "$CATALOGUE")"
  effort="$(jqr --arg w "$name" '.waves[$w].effort // ""' "$CATALOGUE")"
  maxturns="$(jqr --arg w "$name" '.waves[$w].max_turns // 80' "$CATALOGUE")"
  lanes="$(jqr --arg w "$name" '.waves[$w].lanes // 1' "$CATALOGUE")"
  tmpl="$(jqr --arg w "$name" '.waves[$w].template // empty' "$CATALOGUE")"
  [ -n "$tmpl" ] && [ -f "$WAVE_ROOT/$tmpl" ] || { err "finder wave '$name': template missing ($tmpl)"; return 10; }
  while [ "$n" -le "$lanes" ]; do
    spawn_finder_lane "$name" "${name}-${n}" "$model" "$tmpl" "$maxturns" "$effort" || lane_fail=1
    n=$((n+1))
  done

  # cross-provider lane (ADR-018 "security cross-provider" routing): a
  # SEPARATE lane on a DIFFERENT model AND a different template, so its
  # packet is never byte-identical to the primary lane's - no cache-key
  # collision possible, by construction, without touching ff-spawn's key.
  local cross_model cross_tmpl
  cross_model="$(jqr --arg w "$name" '.waves[$w].cross // empty' "$CATALOGUE")"
  cross_tmpl="$(jqr --arg w "$name" '.waves[$w].cross_template // empty' "$CATALOGUE")"
  if [ -n "$cross_model" ] && [ -n "$cross_tmpl" ]; then
    if [ -f "$WAVE_ROOT/$cross_tmpl" ]; then
      spawn_finder_lane "$name" "${name}-cross" "$cross_model" "$cross_tmpl" "$maxturns" "$effort" || lane_fail=1
    else
      err "finder wave '$name': cross template missing ($cross_tmpl)"; lane_fail=1
    fi
  fi
  [ "$lane_fail" = 0 ]
}

run_triage_wave() {
  bash "$FINDINGS" apply-waivers --run "$RUN" --repo "$REPO" >/dev/null 2>>"$RUNDIR/triage.err" \
    || err "triage: apply-waivers failed (non-fatal, continuing)"

  local open_findings escalated=0 autogroup="[]"
  open_findings="$(bash "$FINDINGS" list --run "$RUN" --repo "$REPO" --status open 2>>"$RUNDIR/triage.err")"
  [ -n "$open_findings" ] || open_findings="[]"

  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    local fp sev rank claim files_text esc=0
    fp="$(jqr '.fp' <<<"$finding")"
    sev="$(jqr '.severity' <<<"$finding")"
    rank="$(sev_rank "$sev")"
    [ "$rank" -gt "$FLOOR_RANK" ] && esc=1
    claim="$(jqr '.claim' <<<"$finding")"
    files_text="$(jqr '(.files // []) | join(" ")' <<<"$finding")"
    if [ "$esc" = 0 ] && always_escalate_kw "$(printf '%s %s' "$claim" "$files_text" | tr '[:upper:]' '[:lower:]')"; then
      esc=1
    fi
    if [ "$esc" = 0 ] && [ "$USE_ADR" = 1 ] && [ -n "$files_text" ]; then
      local touched=""
      touched="$(printf '%s' "$files_text" | tr ' ' '\n' | xargs -I{} "$FF_PYTHON" "$ADR_TOOL" --repo "$REPO" {} 2>/dev/null || true)"
      [ -n "$touched" ] && esc=1
    fi
    if [ "$esc" = 1 ]; then
      bash "$FINDINGS" set-status --run "$RUN" --repo "$REPO" --fp "$fp" --status escalated >/dev/null 2>>"$RUNDIR/triage.err"
      escalated=$((escalated+1))
    else
      autogroup="$(jq -nc --argjson arr "$autogroup" --argjson f "$finding" '$arr + [$f]')"
    fi
  done < <(printf '%s' "$open_findings" | jq -c '.[]')

  # union-find grouping: findings sharing any file share a group (file-disjoint
  # fix packets - the mechanical half of triage per ADR-018/§3).
  declare -A PARENT=() FILE_OWNER=()
  find_root() { local x="$1"; while [ "${PARENT[$x]}" != "$x" ]; do x="${PARENT[$x]}"; done; printf '%s' "$x"; }
  union() { local ra rb; ra="$(find_root "$1")"; rb="$(find_root "$2")"; [ "$ra" != "$rb" ] && PARENT["$ra"]="$rb"; }
  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    local fp; fp="$(jqr '.fp' <<<"$finding")"
    PARENT["$fp"]="$fp"
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      if [ -n "${FILE_OWNER[$file]:-}" ]; then union "$fp" "${FILE_OWNER[$file]}"; else FILE_OWNER["$file"]="$fp"; fi
    done < <(jqr '(.files // [])[]' <<<"$finding")
  done < <(printf '%s' "$autogroup" | jq -c '.[]')

  declare -A FGROUPS=()
  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    local fp root; fp="$(jqr '.fp' <<<"$finding")"; root="$(find_root "$fp")"
    FGROUPS["$root"]="${FGROUPS[$root]:+${FGROUPS[$root]},}$fp"
  done < <(printf '%s' "$autogroup" | jq -c '.[]')

  local groups_json="{}"
  for root in "${!FGROUPS[@]}"; do
    local members entry
    members="$(printf '%s\n' "${FGROUPS[$root]}" | tr ',' '\n' | jq -R . | jq -sc .)"
    entry="$(jq -nc --argjson arr "$autogroup" --argjson m "$members" '$arr | map(select(.fp as $f | $m | index($f) != null))')"
    groups_json="$(jq -nc --argjson g "$groups_json" --arg k "$root" --argjson v "$entry" '$g + {($k): $v}')"
  done
  printf '%s' "$groups_json" > "$RUNDIR/triage-groups.json"
  err "triage: $escalated escalated, $(jq 'length' <<<"$autogroup") queued for fix across $(jq 'keys|length' <<<"$groups_json") group(s)"
  return 0
}

run_fix_wave() {
  [ -f "$RUNDIR/triage-groups.json" ] || { err "fix: no triage-groups.json (triage produced nothing to fix)"; return 0; }
  local groups; groups="$(cat "$RUNDIR/triage-groups.json")"
  [ "$(jq 'keys|length' <<<"$groups")" -gt 0 ] || { err "fix: no groups to fix"; return 0; }

  local fix_model fix_tmpl fix_provider
  fix_model="$(jqr '.fix.model // "sonnet"' "$CATALOGUE")"
  fix_tmpl="$(jqr '.fix.template // empty' "$CATALOGUE")"
  [ -n "$fix_tmpl" ] && [ -f "$WAVE_ROOT/$fix_tmpl" ] || { err "fix: template missing ($fix_tmpl)"; return 10; }
  fix_provider="$(jqr --arg m "$fix_model" '.providers[$m] // "anthropic"' "$CATALOGUE")"

  local round=0 any_open=1
  while [ "$round" -lt "$FIX_ROUNDS" ] && [ "$any_open" = 1 ]; do
    round=$((round+1))
    set_wave_round fix "$round"
    any_open=0

    # Recomputed EVERY round from currently-open findings only: a finding a
    # prior round already confirmed fixed (status stays "fixed" for good) or
    # escalated must never be re-spawned into another fix lane - group
    # membership (which files are file-disjoint) is fixed at triage, but
    # which of a group's findings still need work shrinks round over round.
    local open_findings; open_findings="$(bash "$FINDINGS" list --run "$RUN" --repo "$REPO" --status open 2>/dev/null)"
    [ -n "$open_findings" ] || open_findings="[]"

    declare -A FP_TO_GID=()
    local i=0
    for key in $(jqr 'keys[]' <<<"$groups"); do
      local group_fps gfindings gid pf rc=0
      group_fps="$(jq -c --arg k "$key" '.[$k] | map(.fp)' <<<"$groups")"
      gfindings="$(jq -c --argjson fps "$group_fps" '[.[] | select(.fp as $f | $fps | index($f) != null)]' <<<"$open_findings")"
      [ "$(jq 'length' <<<"$gfindings")" -gt 0 ] || continue

      i=$((i+1))
      any_open=1
      gid="fix-${round}-${i}"
      pf="$RUNDIR/packets/${gid}.task.md"
      while IFS= read -r fp; do [ -n "$fp" ] && FP_TO_GID["$fp"]="$gid"; done < <(jqr '.[].fp' <<<"$gfindings")

      # ADR-012 cache-key purity: strip ledger-only fields (ts/id/lane/status/
      # round) before a finding record is embedded in a packet body - fp
      # stays (content-pure), the rest is manifest/journal metadata only.
      subst_template "$WAVE_ROOT/$fix_tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "$REPO_BASE_SHA" \
        FINDINGS_JSON "$(jq -c '[.[] | del(.ts,.id,.lane,.status,.round)]' <<<"$gfindings")" \
        SEVERITY_RUBRIC "$SEV_RUBRIC" > "$pf"
      bash "$SPAWN" --run "$RUN" --id "$gid" --model "$fix_model" --phase fix \
        --prompt-file "$pf" --max-turns 100 --repo "$REPO" --worktree \
        >/dev/null 2>>"$RUNDIR/$gid.spawn.err" || rc=$?
      case "$rc" in
        0|3)
          if bash "$COLLECT" --run "$RUN" --id "$gid" --repo "$REPO" --auto-commit >/dev/null 2>>"$RUNDIR/$gid.collect.err"; then
            jqr '.[].fp' <<<"$gfindings" | while IFS= read -r fp; do
              bash "$FINDINGS" set-status --run "$RUN" --repo "$REPO" --fp "$fp" --status fixed \
                >/dev/null 2>>"$RUNDIR/$gid.findings.err"
            done
          else
            err "fix lane $gid: gate failed"
          fi
          ;;
        *) err "fix lane $gid failed (rc=$rc)" ;;
      esac
    done

    # re-verify: ONLY findings THIS round's fix loop marked fixed - the
    # global `--status fixed` list also holds prior rounds' already-confirmed
    # findings, which must never be re-verified again (budget-burn ADR-018's
    # anti-oscillation rule exists to prevent, arriving by a different door).
    local round_fixed round_fps_json
    round_fixed="$(bash "$FINDINGS" list --run "$RUN" --repo "$REPO" --status fixed 2>/dev/null)"
    [ -n "$round_fixed" ] || round_fixed="[]"
    round_fps_json="$(printf '%s\n' "${!FP_TO_GID[@]}" | jq -R 'select(length>0)' | jq -sc .)"
    round_fixed="$(jq -c --argjson fps "$round_fps_json" '[.[] | select(.fp as $f | $fps | index($f) != null)]' <<<"$round_fixed")"

    local j=0
    while IFS= read -r finding; do
      [ -n "$finding" ] || continue
      j=$((j+1))
      local fp wv gid branch base_sha rvid rvpf rvrc=0 still_open=0 prior_round
      fp="$(jqr '.fp' <<<"$finding")"
      wv="$(jqr '.wave' <<<"$finding")"
      gid="${FP_TO_GID[$fp]:-}"
      rvid="reverify-${round}-${j}"

      # base-SHA-per-group (ADR-018's "Consequence for ADR-012"): the SPECIFIC
      # fix lane's own committed branch for THIS finding's group, never an
      # arbitrary lane's. A missing branch means the fix never landed a
      # commit for that group - fail loudly and re-open the finding rather
      # than silently falling through to ff-spawn's `main` default, which
      # would re-verify the UNFIXED tree and always refute a real fix.
      branch=""; base_sha=""
      if [ -n "$gid" ]; then
        branch="fleetflow/$RUN/$gid"
        base_sha="$(git -C "$REPO" rev-parse --verify -q "refs/heads/$branch" 2>/dev/null || echo "")"
      fi
      if [ -z "$base_sha" ]; then
        err "re-verify: FIX BRANCH MISSING for fp $fp (expected refs/heads/fleetflow/$RUN/${gid:-<unknown>}) - cannot verify against a fixed tree, re-opening finding"
        still_open=1
      else
        local tmpl rv_model rv_provider
        tmpl="$(jqr --arg w "$wv" '.waves[$w].template // empty' "$CATALOGUE")"
        if [ -z "$tmpl" ] || [ ! -f "$WAVE_ROOT/$tmpl" ]; then
          err "re-verify: no template for wave '$wv', leaving fp $fp fixed"
        else
          rv_model="$(jqr --arg w "$wv" '.waves[$w].model // "sonnet"' "$CATALOGUE")"
          rv_provider="$(jqr --arg m "$rv_model" '.providers[$m] // "anthropic"' "$CATALOGUE")"
          # "different provider than fix" - enforced via the catalogue's
          # providers map, not a model-NAME comparison (haiku/opus/sonnet all
          # resolve to "anthropic" and would otherwise pass as "different").
          # Fallback order codex -> glm -> opus: health can't be probed here
          # (ff-doctor gates actual spawnability), so codex is picked first
          # deterministically as the cheapest genuinely-different provider.
          if [ "$rv_provider" = "$fix_provider" ]; then
            local cand cand_provider
            for cand in codex glm opus; do
              cand_provider="$(jqr --arg m "$cand" '.providers[$m] // "anthropic"' "$CATALOGUE")"
              if [ "$cand_provider" != "$fix_provider" ]; then rv_model="$cand"; break; fi
            done
          fi
          rvpf="$RUNDIR/packets/${rvid}.task.md"
          # ADR-012 purity: strip ledger-only fields before embedding, same
          # as the fix packet above; fp stays.
          # TARGET here too: re-verify replays the FINDER's template, which
          # carries %%TARGET%% - without it the placeholder survives raw.
          subst_template "$WAVE_ROOT/$tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "$base_sha" \
            TARGET "$TARGET" FINDINGS_JSON "$(jq -c '[. | del(.ts,.id,.lane,.status,.round)]' <<<"$finding")" \
            SEVERITY_RUBRIC "$SEV_RUBRIC" > "$rvpf"
          # --base pins the re-verify worktree to the FIXED tree (this
          # finding's group's committed branch), not ff-spawn's `main` default.
          bash "$SPAWN" --run "$RUN" --id "$rvid" --model "$rv_model" --phase reverify \
            --prompt-file "$rvpf" --max-turns 60 --repo "$REPO" --base "$branch" --worktree --schema "$SCHEMA" \
            >/dev/null 2>>"$RUNDIR/$rvid.spawn.err" || rvrc=$?
          if [ "$rvrc" = 0 ] || [ "$rvrc" = 3 ]; then
            local rvout rvcount
            rvout="$(bash "$COLLECT" --run "$RUN" --id "$rvid" --repo "$REPO" --schema 2>>"$RUNDIR/$rvid.collect.err")" || rvout="[]"
            rvcount="$(jq '(if type=="array" then . else (.findings // []) end) | length' <<<"${rvout:-[]}" 2>/dev/null)"
            [ "${rvcount:-1}" != "0" ] && still_open=1
          else
            still_open=1
          fi
        fi
      fi

      if [ "$still_open" = 1 ]; then
        prior_round="$(jqr '.round // 0' <<<"$finding")"
        if [ "${prior_round:-0}" -ge 1 ]; then
          bash "$FINDINGS" set-status --run "$RUN" --repo "$REPO" --fp "$fp" --status escalated \
            >/dev/null 2>>"$RUNDIR/$rvid.err"
          err "re-verify: $fp refuted twice - escalated (anti-oscillation)"
        else
          bash "$FINDINGS" append --run "$RUN" --repo "$REPO" \
            --json "$(jq -c '. + {status:"open",round:((.round // 0)+1)}' <<<"$finding")" \
            >/dev/null 2>>"$RUNDIR/$rvid.err"
          any_open=1
        fi
      fi
    done < <(printf '%s' "$round_fixed" | jq -c '.[]')
  done
  return 0
}

run_docs_wave() {
  local fixed_count
  fixed_count="$(bash "$FINDINGS" count --run "$RUN" --repo "$REPO" 2>/dev/null | jqr '.fixed // 0' 2>/dev/null)"
  if [ "${fixed_count:-0}" = "0" ]; then
    err "docs-sync: no fixed findings, skipping (behaviour unchanged)"
    set_wave_status docs-sync skipped
    return 0
  fi
  # docs-sync is catalogue data like every other wave - it lives in
  # .waves["docs-sync"] (kind:"docs"), read via the same `.waves[$w]`
  # accessor as finder waves, not a top-level per-run hardcoded fallback.
  local model tmpl pf rc=0
  model="$(jqr --arg w "docs-sync" '.waves[$w].model // "haiku"' "$CATALOGUE")"
  tmpl="$(jqr --arg w "docs-sync" '.waves[$w].template // empty' "$CATALOGUE")"
  [ -n "$tmpl" ] && [ -f "$WAVE_ROOT/$tmpl" ] || { err "docs-sync: template missing ($tmpl)"; return 10; }
  local fixed_findings stripped
  fixed_findings="$(bash "$FINDINGS" list --run "$RUN" --repo "$REPO" --status fixed 2>/dev/null)"
  [ -n "$fixed_findings" ] || fixed_findings="[]"
  stripped="$(jq -c '[.[] | del(.ts,.id,.lane,.status,.round)]' <<<"$fixed_findings")"
  pf="$RUNDIR/packets/docs-sync-1.task.md"
  subst_template "$WAVE_ROOT/$tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "$REPO_BASE_SHA" \
    FINDINGS_JSON "$stripped" SEVERITY_RUBRIC "$SEV_RUBRIC" > "$pf"
  bash "$SPAWN" --run "$RUN" --id docs-sync-1 --model "$model" --phase docs-sync \
    --prompt-file "$pf" --max-turns 60 --repo "$REPO" --worktree \
    >/dev/null 2>>"$RUNDIR/docs-sync-1.spawn.err" || rc=$?
  case "$rc" in
    0|3) bash "$COLLECT" --run "$RUN" --id docs-sync-1 --repo "$REPO" --auto-commit \
           >/dev/null 2>>"$RUNDIR/docs-sync-1.collect.err" || return 10 ;;
    *) return 10 ;;
  esac
  return 0
}

run_regression_wave() {
  local name="$1" model tmpl pf rc=0
  model="$(jqr --arg w "$name" '.waves[$w].model // "sonnet"' "$CATALOGUE")"
  tmpl="$(jqr --arg w "$name" '.waves[$w].template // empty' "$CATALOGUE")"
  [ -n "$tmpl" ] && [ -f "$WAVE_ROOT/$tmpl" ] || { err "regression wave '$name': template missing ($tmpl)"; return 10; }
  local fixed_findings stripped
  fixed_findings="$(bash "$FINDINGS" list --run "$RUN" --repo "$REPO" --status fixed 2>/dev/null)"
  [ -n "$fixed_findings" ] || fixed_findings="[]"
  stripped="$(jq -c '[.[] | del(.ts,.id,.lane,.status,.round)]' <<<"$fixed_findings")"
  pf="$RUNDIR/packets/${name}-1.task.md"
  subst_template "$WAVE_ROOT/$tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "$REPO_BASE_SHA" \
    FINDINGS_JSON "$stripped" SEVERITY_RUBRIC "$SEV_RUBRIC" > "$pf"
  bash "$SPAWN" --run "$RUN" --id "${name}-1" --model "$model" --phase "$name" \
    --prompt-file "$pf" --max-turns 60 --repo "$REPO" --worktree \
    >/dev/null 2>>"$RUNDIR/${name}-1.spawn.err" || rc=$?
  case "$rc" in
    0|3) bash "$COLLECT" --run "$RUN" --id "${name}-1" --repo "$REPO" --auto-commit \
           >/dev/null 2>>"$RUNDIR/${name}-1.collect.err" || return 10 ;;
    *) return 10 ;;
  esac
  return 0
}

# run_land_wave: the fixed pipeline's terminal stage (ADR-018 §3 "... ->
# docs-sync -> land"). Prints the fleet-ops handoff summary - branches ready
# to land, their diffstat, the test command to run first - and NEVER merges
# or pushes. Landing and deploy stay human/fleet-ops-gated; this wave is
# report-only by design (see docs/adr/ADR-018 "Non-goals: No posture deploys").
run_land_wave() {
  local branches
  branches="$(git -C "$REPO" for-each-ref --format='%(refname:short)' "refs/heads/fleetflow/$RUN/*" 2>/dev/null)"
  err "land: fleet-ops handoff for run '$RUN' - review and land these branches yourself; this wave never merges or pushes:"
  if [ -n "$branches" ]; then
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      local diffstat
      diffstat="$(git -C "$REPO" diff --shortstat "${REPO_BASE_REF}...${b}" 2>/dev/null)"
      err "  - $b${diffstat:+  ($diffstat)}"
    done <<<"$branches"
  else
    err "  (no fleetflow/$RUN/* branches found under $REPO)"
  fi
  err "land: run the repo's test/check command on each branch before merging"
  err "land: deploy remains maintainer-gated from an interactive session regardless (ADR-018 non-goals)"
  return 0
}

print_summary() {
  local findings_counts="null" waived=0 costs="[]" ff_status
  findings_counts="$(bash "$FINDINGS" count --run "$RUN" --repo "$REPO" 2>/dev/null)"
  [ -n "$findings_counts" ] || findings_counts="null"
  waived="$(jqr '.waived // 0' <<<"$findings_counts" 2>/dev/null)"; [ -n "$waived" ] || waived=0
  if [ -f "$RUNDIR/journal.jsonl" ]; then
    ff_status="$(bash "$STATUS" --run "$RUN" --repo "$REPO" 2>/dev/null)"
    [ -n "$ff_status" ] || ff_status="{}"
    costs="$(jq -c '[(.lanes // []) | group_by(.phase)[] |
      {phase:.[0].phase, tokens_total:(map(.tokens_total // 0)|add),
       cost_usd:(if (map(.cost_usd)|any(.==null)) then null else (map(.cost_usd)|add) end)}]' \
      <<<"$ff_status" 2>/dev/null)"
    [ -n "$costs" ] || costs="[]"
  fi
  jq -nc --argjson waves "$(jq -c '.waves // []' "$MANIFEST")" --argjson findings "$findings_counts" \
    --argjson waived "$waived" --argjson costs "$costs" --arg posture "$POSTURE" \
    --argjson fr "$FIX_ROUNDS" --arg sf "$SEV_FLOOR" --arg tg "$TARGET" \
    '{posture:$posture,fix_rounds:$fr,severity_floor:$sf,target:$tg,waves:$waves,
      skipped:[$waves[] | select(.status=="skipped") | .name],
      findings:$findings,waived:$waived,cost_by_wave:$costs}'
}

# --- pipeline execution: finders -> triage -> fix -> regression -> docs-sync
#     -> land -------------------------------------------------------------
for wave_name in "${ALL_WAVES[@]}"; do
  st="$(wave_status "$wave_name")"
  if [ "$st" = "done" ] || [ "$st" = "skipped" ]; then
    err "wave $wave_name: already $st, skipping"
    continue
  fi
  if [ "$st" = "failed" ]; then
    # A failed wave is NEVER silently converted to done - --continue means
    # "retry it" (fall through to the normal execution path below), not
    # "pretend it passed". Without --continue, re-encountering it re-reports
    # the failure and exits 10 again (idempotent, like the gated branch below).
    if [ "$CONTINUE" = 1 ]; then
      err "wave $wave_name: retrying previously failed wave (--continue)"
    else
      err "wave $wave_name: previously failed, awaiting --continue to retry"
      print_summary
      exit 10
    fi
  fi
  if [ "$st" = "gated" ]; then
    if [ "$CONTINUE" = 1 ]; then
      err "wave $wave_name: gate cleared via --continue"
      set_wave_status "$wave_name" done
      continue
    else
      # Idempotent gate signal: re-encountering a stop gate without --continue
      # exits 14 again (a watchdog reading 0 here would call a gated run
      # green). A review gate halts the pipeline exactly like a stop gate -
      # the ONLY difference is the exit code (0 vs 14) - both require
      # --continue to proceed; review is not merely informational.
      policy="$(jqr --arg n "$wave_name" '(.waves[] | select(.name==$n) | .gate)' "$MANIFEST")"
      err "wave $wave_name: still gated, awaiting --continue"
      print_summary
      [ "$policy" = "stop" ] && exit 14
      exit 0
    fi
  fi
  set_wave_status "$wave_name" running
  kind="$(jqr --arg n "$wave_name" '(.waves[] | select(.name==$n) | .kind)' "$MANIFEST")"
  rc=0
  case "$kind" in
    finder)     run_finder_wave "$wave_name" || rc=$? ;;
    barrier)    run_triage_wave || rc=$? ;;
    fix)        run_fix_wave || rc=$? ;;
    regression) run_regression_wave "$wave_name" || rc=$? ;;
    docs)       run_docs_wave || rc=$? ;;
    land)       run_land_wave || rc=$? ;;
    *) err "wave $wave_name: unknown kind '$kind'"; rc=2 ;;
  esac
  if [ "$rc" != 0 ]; then
    err "wave $wave_name failed (rc=$rc)"
    set_wave_status "$wave_name" failed
    print_summary
    exit 10
  fi
  st="$(wave_status "$wave_name")"
  # A skipped wave is still REPORTED (no silent caps) but a review/stop gate
  # on it must halt exactly as it would for a wave that actually ran - a
  # gate is a request to look before proceeding, and "there was nothing to
  # do" is itself something the operator asked to be told before continuing.
  [ "$st" = "skipped" ] || set_wave_status "$wave_name" done
  policy="$(jqr --arg n "$wave_name" '(.waves[] | select(.name==$n) | .gate)' "$MANIFEST")"
  case "$policy" in
    review) set_wave_status "$wave_name" gated; print_summary; exit 0 ;;
    stop)   set_wave_status "$wave_name" gated; print_summary; exit 14 ;;
  esac
done

print_summary
return 0
}

# main() wrapper - parse-before-execute guard (incident 2026-08-01; see the
# matching comment in ff-spawn.sh). bash parses script files incrementally
# during execution, so a concurrent edit or skills sync rewriting this file
# while a multi-minute resume loop is running kills the run with a phantom
# syntax error. main() forces a full parse up front. Body deliberately NOT
# re-indented. DO NOT unwrap this as a "simplification".
main() {

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$HERE/ff-spawn.sh"

MODE="" RUN="" REPO=""
[ $# -gt 0 ] || { err "a subcommand is required (resume|status|wave)"; usage >&2; exit 2; }
case "$1" in
  wave) shift; wave_main "$@"; exit $? ;;
  resume) MODE="resume"; shift ;;
  status) MODE="status"; shift ;;
  -h|--help) usage; exit 0 ;;
  *) err "unknown subcommand: $1"; usage >&2; exit 2 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --run|--repo) [ $# -ge 2 ] || { err "missing value for $1"; usage >&2; exit 2; } ;;
  esac
  case "$1" in
    --run) RUN="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
command -v git >/dev/null || { err "git required"; exit 2; }
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

# status = alias for ff-status (hand off and let it own exit codes).
# exec THROUGH bash: a direct exec needs the +x bit, which zip installs and
# mode-dropping checkouts lose — Git Bash fakes modes, so only Linux notices.
if [ "$MODE" = "status" ]; then
  if [ -n "$REPO" ]; then exec bash "$HERE/ff-status.sh" --run "$RUN" --repo "$REPO"; fi
  exec bash "$HERE/ff-status.sh" --run "$RUN"
fi

RUNDIR="$REPO/.fleetflow/$RUN"
MANIFEST="$RUNDIR/manifest.json"
[ -f "$MANIFEST" ] || { err "no manifest at $MANIFEST (run ff-spawn first)"; exit 2; }

# Snapshot the packets ONCE, before replay. ff-spawn upserts each packet on the
# way in (remove-then-append), which REORDERS the live manifest - so re-reading
# .packets[$i] mid-loop would drift and revisit the same packet. The snapshot is
# the replay contract: spawn order = the order captured here, frozen.
PACKETS="$(jq -c '.packets' "$MANIFEST" 2>/dev/null)"
N="$(printf '%s' "$PACKETS" | jq -r 'length' 2>/dev/null)"
[ "${N:-0}" -gt 0 ] 2>/dev/null || { err "manifest has no packets to replay"; exit 2; }

err "resume: replaying $N packet(s) from $MANIFEST (sequential)"
err "  #   id                       model     status"
err "  --  -----------------------  --------  --------"
RESULTS="[]"
ANY_FAIL=0
i=0
while [ "$i" -lt "$N" ]; do
  pid="$(printf '%s' "$PACKETS" | jq -r ".[$i].id")"
  # legacy manifests wrote `brain`; packets never carried a launch-model key,
  # so the plain fallback is unambiguous here
  pmodel="$(printf '%s' "$PACKETS" | jq -r ".[$i] | (.model // .brain)")"
  # imported native packets are terminal facts, not replayable ("native" is not a
  # spawnable model - ff-spawn rejects it). ff-run resume SKIPS them; to continue
  # from an imported result, spawn a fresh lane with a real model. See ff-import.
  if [ "$pmodel" = "native" ]; then
    err "  $((i+1))   $(printf '%-23s' "$pid")  native     imported (skipped)"
    RESULTS="$(jq -nc --argjson R "$RESULTS" --arg id "$pid" --arg s "imported" --argjson rc 0 \
      '$R + [{id:$id,status:$s,rc:$rc}]')"
    i=$((i+1)); continue
  fi
  # chip packets are the same class of terminal fact: a chip is launched by a
  # HUMAN CLICK, so there is nothing for fleetflow to replay - re-running one
  # would need a person, not a process. Reported, never silently dropped (the
  # no-silent-caps rule). Re-open a fresh chip with ff-chip open, or spawn a
  # normal lane and paste the chip's result into its packet. See ff-chip.sh.
  if [ "$pmodel" = "chip" ]; then
    err "  $((i+1))   $(printf '%-23s' "$pid")  chip       manual lane (skipped)"
    RESULTS="$(jq -nc --argjson R "$RESULTS" --arg id "$pid" --arg s "chip" --argjson rc 0 \
      '$R + [{id:$id,status:$s,rc:$rc}]')"
    i=$((i+1)); continue
  fi
  pphase="$(printf '%s' "$PACKETS" | jq -r ".[$i].phase // \"build\"")"
  ppf="$(printf '%s' "$PACKETS" | jq -r ".[$i].prompt_file")"
  pwt="$(printf '%s' "$PACKETS" | jq -r ".[$i].worktree // false")"
  pmt="$(printf '%s' "$PACKETS" | jq -r ".[$i].max_turns // 100")"
  peff="$(printf '%s' "$PACKETS" | jq -r ".[$i].effort // \"\"")"
  psch="$(printf '%s' "$PACKETS" | jq -r ".[$i].schema // \"\"")"
  # worktree is a boolean string ("true"/"false"); both are non-empty, so gate on
  # the literal value rather than ${pwt:+...} (which would always fire).
  WT_FLAG=""; [ "$pwt" = "true" ] && WT_FLAG="1"

  bash "$SPAWN" --run "$RUN" --id "$pid" --model "$pmodel" --phase "$pphase" \
    --prompt-file "$ppf" --max-turns "$pmt" --repo "$REPO" \
    ${WT_FLAG:+--worktree} ${peff:+--effort "$peff"} ${psch:+--schema "$psch"} \
    >/dev/null 2>>"$RUNDIR/$pid.resume.err"
  rc=$?
  case "$rc" in
    0) status="ran" ;;
    3) status="cached" ;;
    *) status="failed"; ANY_FAIL=1 ;;
  esac
  err "  $((i+1))   $(printf '%-23s' "$pid")  $(printf '%-8s' "$pmodel")  $status${rc:+ (rc=$rc)}"
  RESULTS="$(jq -nc --argjson R "$RESULTS" --arg id "$pid" --arg s "$status" --argjson rc "$rc" \
    '$R + [{id:$id,status:$s,rc:$rc}]')"
  i=$((i+1))
done

RAN="$(printf '%s' "$RESULTS" | jq -r '[.[]|select(.status=="ran")]|length')"
CACHED="$(printf '%s' "$RESULTS" | jq -r '[.[]|select(.status=="cached")]|length')"
FAILED="$(printf '%s' "$RESULTS" | jq -r '[.[]|select(.status=="failed")]|length')"
err "  --"
err "  summary: $RAN ran, $CACHED cached, $FAILED failed"

printf '%s\n' "$RESULTS"
[ "$ANY_FAIL" = 1 ] && exit 10
exit 0

}

main "$@"
