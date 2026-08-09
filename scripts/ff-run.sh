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
                      at/below, escalated above. --dry-run resolves the plan
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
FIX_ROUNDS=2 SEV_FLOOR="medium" GATES="" WAVEADJ=""
FIX_ROUNDS_SET=0 SEV_FLOOR_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --posture) POSTURE="${2:-}"; shift 2 ;;
    --attend) ATTEND="${2:-}"; shift 2 ;;
    --gate) GATES="${GATES}${GATES:+,}${2:-}"; shift 2 ;;
    --wave) WAVEADJ="${2:-}"; shift 2 ;;
    --fix-rounds) FIX_ROUNDS="${2:-}"; FIX_ROUNDS_SET=1; shift 2 ;;
    --severity-floor) SEV_FLOOR="${2:-}"; SEV_FLOOR_SET=1; shift 2 ;;
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
    '{run:$run,base:"main",created_by:$by,phases:[],packets:[]}' > "$MANIFEST"
fi

if [ "$CONTINUE" = 1 ] && [ -z "$POSTURE" ]; then
  POSTURE="$(jqr '.posture // empty' "$MANIFEST")"
  [ -n "$POSTURE" ] || { err "--continue with no --posture and none recorded in manifest for run '$RUN'"; exit 2; }
fi
case "$POSTURE" in baseline|tested|hardened|complete) ;; *) err "invalid or missing --posture '$POSTURE' (baseline|tested|hardened|complete)"; exit 2 ;; esac

# --continue without an explicit --fix-rounds/--severity-floor keeps the
# manifest's recorded value instead of silently resetting to the CLI default -
# the same "manifest is truth on resume" rule --posture already gets above.
if [ "$CONTINUE" = 1 ]; then
  if [ "$FIX_ROUNDS_SET" = 0 ]; then
    mfr="$(jqr '.fix_rounds // empty' "$MANIFEST")"; [ -n "$mfr" ] && FIX_ROUNDS="$mfr"
  fi
  if [ "$SEV_FLOOR_SET" = 0 ]; then
    msf="$(jqr '.severity_floor // empty' "$MANIFEST")"; [ -n "$msf" ] && SEV_FLOOR="$msf"
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
  jq --arg posture "$POSTURE" --argjson fr "$FIX_ROUNDS" --arg sf "$SEV_FLOOR" \
    '.posture = $posture | .fix_rounds = $fr | .severity_floor = $sf' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
else
  # Fresh resolution: finder waves are every catalogue entry whose `postures`
  # array names the chosen posture (cumulative membership is catalogue DATA,
  # not sequencer logic - e.g. qa.postures=[tested,hardened,complete]).
  FINDER_NAMES="$(jqr --arg p "$POSTURE" \
    '.waves | to_entries[] | select(.value.kind=="finder") | select((.value.postures // []) | index($p)) | .key' \
    "$CATALOGUE")"
  FINDERS=()
  while IFS= read -r w; do [ -n "$w" ] && FINDERS+=("$w"); done <<<"$FINDER_NAMES"

  if [ -n "$WAVEADJ" ]; then
    IFS=',' read -ra ADJS <<< "$WAVEADJ"
    for adj in "${ADJS[@]}"; do
      [ -n "$adj" ] || continue
      op="${adj:0:1}"; name="${adj:1}"
      case "$op" in
        +)
          jq -e --arg w "$name" '.waves[$w]' "$CATALOGUE" >/dev/null 2>&1 || { err "unknown wave in --wave: $name"; exit 2; }
          case " ${FINDERS[*]:-} " in *" $name "*) ;; *) FINDERS+=("$name") ;; esac
          ;;
        -)
          NEWF=()
          for f in "${FINDERS[@]:-}"; do [ -n "$f" ] && [ "$f" != "$name" ] && NEWF+=("$f"); done
          FINDERS=("${NEWF[@]:-}")
          ;;
        *) err "invalid --wave entry '$adj' (must start with + or -)"; exit 2 ;;
      esac
    done
  fi

  ALL_WAVES=("${FINDERS[@]:-}" triage fix docs-sync)

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
  for f in "${FINDERS[@]:-}"; do [ -n "$f" ] && add_wave "$f" finder; done
  add_wave triage barrier
  add_wave fix fix
  add_wave docs-sync docs

  # sibling-key upsert (ADR-017 pattern): `phases`/`packets` untouched.
  jq --argjson waves "$WAVES_JSON" --arg posture "$POSTURE" --argjson fr "$FIX_ROUNDS" --arg sf "$SEV_FLOOR" \
    '.waves = $waves | .posture = $posture | .fix_rounds = $fr | .severity_floor = $sf' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
fi

# --- dry-run: resolve + generate finder packets, spawn nothing --------------
if [ "$DRYRUN" = 1 ]; then
  mkdir -p "$RUNDIR/dryrun"
  for f in "${FINDERS[@]:-}"; do
    [ -n "$f" ] || continue
    tmpl="$(jqr --arg w "$f" '.waves[$w].template // empty' "$CATALOGUE")"
    if [ -z "$tmpl" ] || [ ! -f "$WAVE_ROOT/$tmpl" ]; then
      err "dry-run: template missing for wave '$f' ($tmpl)"; continue
    fi
    lanes="$(jqr --arg w "$f" '.waves[$w].lanes // 1' "$CATALOGUE")"
    n=1
    while [ "$n" -le "$lanes" ]; do
      subst_template "$WAVE_ROOT/$tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "" \
        FINDINGS_JSON "[]" SEVERITY_RUBRIC "$SEV_RUBRIC" > "$RUNDIR/dryrun/${f}-${n}.task.md"
      n=$((n+1))
    done
  done
  err "dry-run: resolved $(jq 'length' <<<"$WAVES_JSON") wave(s) for posture '$POSTURE', packets under $RUNDIR/dryrun/"
  jq -nc --argjson waves "$WAVES_JSON" --arg posture "$POSTURE" --argjson fr "$FIX_ROUNDS" --arg sf "$SEV_FLOOR" \
    '{dry_run:true,posture:$posture,fix_rounds:$fr,severity_floor:$sf,waves:$waves}'
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
always_escalate_kw() {
  printf '%s' "$1" | grep -qiE 'auth|crypto|permission|schema|migrat|dependenc|public.?api|package\.json|requirements\.txt|cargo\.toml|go\.mod|poetry\.lock'
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

run_finder_wave() {
  local name="$1" model effort maxturns lanes tmpl n=1 lane_fail=0
  model="$(jqr --arg w "$name" '.waves[$w].model // "sonnet"' "$CATALOGUE")"
  effort="$(jqr --arg w "$name" '.waves[$w].effort // ""' "$CATALOGUE")"
  maxturns="$(jqr --arg w "$name" '.waves[$w].max_turns // 80' "$CATALOGUE")"
  lanes="$(jqr --arg w "$name" '.waves[$w].lanes // 1' "$CATALOGUE")"
  tmpl="$(jqr --arg w "$name" '.waves[$w].template // empty' "$CATALOGUE")"
  [ -n "$tmpl" ] && [ -f "$WAVE_ROOT/$tmpl" ] || { err "finder wave '$name': template missing ($tmpl)"; return 10; }
  while [ "$n" -le "$lanes" ]; do
    local lid="${name}-${n}" pf art rc=0
    pf="$RUNDIR/packets/${lid}.task.md"
    subst_template "$WAVE_ROOT/$tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "" \
      FINDINGS_JSON "[]" SEVERITY_RUBRIC "$SEV_RUBRIC" > "$pf"
    art="$(bash "$SPAWN" --run "$RUN" --id "$lid" --model "$model" --phase "$name" \
      --prompt-file "$pf" --max-turns "$maxturns" --repo "$REPO" --worktree \
      ${effort:+--effort "$effort"} --schema "$SCHEMA" 2>>"$RUNDIR/$lid.spawn.err")" || rc=$?
    case "$rc" in
      0|3)
        local out
        out="$(bash "$COLLECT" --run "$RUN" --id "$lid" --repo "$REPO" --schema 2>>"$RUNDIR/$lid.collect.err")" \
          && printf '%s' "$out" | jq -c --arg wave "$name" --arg lane "$lid" \
               '(if type=="array" then . else (.findings // []) end)[] | . + {wave:$wave,lane:$lane}' 2>/dev/null \
             | bash "$FINDINGS" append --run "$RUN" --repo "$REPO" 2>>"$RUNDIR/$lid.findings.err" \
          || { err "finder lane $lid: collect/schema gate failed"; lane_fail=1; }
        ;;
      *) err "finder lane $lid failed (rc=$rc)"; lane_fail=1 ;;
    esac
    n=$((n+1))
  done
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
      touched="$(printf '%s' "$files_text" | tr ' ' '\n' | xargs -I{} python "$ADR_TOOL" --repo "$REPO" {} 2>/dev/null || true)"
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

  local fix_model; fix_model="$(jqr '.fix.model // "sonnet"' "$CATALOGUE")"
  local round=0 any_open=1
  while [ "$round" -lt "$FIX_ROUNDS" ] && [ "$any_open" = 1 ]; do
    round=$((round+1))
    set_wave_round fix "$round"
    any_open=0
    local i=0
    for key in $(jqr 'keys[]' <<<"$groups"); do
      i=$((i+1))
      local gfindings gid pf rc=0 do_not_commit=""
      gfindings="$(jq -c --arg k "$key" '.[$k]' <<<"$groups")"
      gid="fix-${round}-${i}"
      pf="$RUNDIR/packets/${gid}.task.md"
      [ "$fix_model" = "codex" ] && do_not_commit="DO NOT COMMIT - leave changes in the working tree, report FILES_CHANGED (ADR-006).
"
      { printf '%s' "$do_not_commit"; echo "Fix the following findings (JSON array):"; jq -c . <<<"$gfindings"; } > "$pf"
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

    # re-verify: replay the producing finder's template on a DIFFERENT provider
    # than the fix lane, with BASE_SHA of that fix round substituted (ADR-012
    # corollary - `round` itself never enters the packet/key, only BASE_SHA does).
    local base_sha=""
    base_sha="$(git -C "$RUNDIR/wt-fix-${round}-1" rev-parse HEAD 2>/dev/null || echo "")"
    local fixed_findings; fixed_findings="$(bash "$FINDINGS" list --run "$RUN" --repo "$REPO" --status fixed 2>/dev/null)"
    [ -n "$fixed_findings" ] || fixed_findings="[]"
    local j=0
    while IFS= read -r finding; do
      [ -n "$finding" ] || continue
      j=$((j+1))
      local fp wv tmpl rv_model rvid rvpf rvrc=0 still_open=0 prior_round
      fp="$(jqr '.fp' <<<"$finding")"
      wv="$(jqr '.wave' <<<"$finding")"
      tmpl="$(jqr --arg w "$wv" '.waves[$w].template // empty' "$CATALOGUE")"
      [ -n "$tmpl" ] && [ -f "$WAVE_ROOT/$tmpl" ] || { err "re-verify: no template for wave '$wv', leaving fp $fp fixed"; continue; }
      rv_model="$(jqr --arg w "$wv" '.waves[$w].model // "sonnet"' "$CATALOGUE")"
      # "different provider than fix" - no formal model->provider table exists
      # yet, so same-model-as-fix is the one case forced off it (opus fallback).
      [ "$rv_model" = "$fix_model" ] && rv_model="opus"
      rvid="reverify-${round}-${j}"
      rvpf="$RUNDIR/packets/${rvid}.task.md"
      subst_template "$WAVE_ROOT/$tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "$base_sha" \
        FINDINGS_JSON "$(jq -c '[.]' <<<"$finding")" SEVERITY_RUBRIC "$SEV_RUBRIC" > "$rvpf"
      bash "$SPAWN" --run "$RUN" --id "$rvid" --model "$rv_model" --phase reverify \
        --prompt-file "$rvpf" --max-turns 60 --repo "$REPO" --worktree --schema "$SCHEMA" \
        >/dev/null 2>>"$RUNDIR/$rvid.spawn.err" || rvrc=$?
      if [ "$rvrc" = 0 ] || [ "$rvrc" = 3 ]; then
        local rvout rvcount
        rvout="$(bash "$COLLECT" --run "$RUN" --id "$rvid" --repo "$REPO" --schema 2>>"$RUNDIR/$rvid.collect.err")" || rvout="[]"
        rvcount="$(jq '(if type=="array" then . else (.findings // []) end) | length' <<<"${rvout:-[]}" 2>/dev/null)"
        [ "${rvcount:-1}" != "0" ] && still_open=1
      else
        still_open=1
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
    done < <(printf '%s' "$fixed_findings" | jq -c '.[]')
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
  local model tmpl pf rc=0
  model="$(jqr '.["docs-sync"].model // "haiku"' "$CATALOGUE")"
  tmpl="$(jqr '.["docs-sync"].template // "assets/wave-packets/docs-sync.tmpl.md"' "$CATALOGUE")"
  [ -f "$WAVE_ROOT/$tmpl" ] || { err "docs-sync: template missing ($tmpl)"; return 10; }
  pf="$RUNDIR/packets/docs-sync-1.task.md"
  subst_template "$WAVE_ROOT/$tmpl" RUN "$RUN" REPO_HINT "$REPO" BASE_SHA "" \
    FINDINGS_JSON "[]" SEVERITY_RUBRIC "$SEV_RUBRIC" > "$pf"
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
    --argjson fr "$FIX_ROUNDS" --arg sf "$SEV_FLOOR" \
    '{posture:$posture,fix_rounds:$fr,severity_floor:$sf,waves:$waves,
      skipped:[$waves[] | select(.status=="skipped") | .name],
      findings:$findings,waived:$waived,cost_by_wave:$costs}'
}

# --- pipeline execution: finders -> triage -> fix -> docs-sync ---------------
for wave_name in "${ALL_WAVES[@]}"; do
  st="$(wave_status "$wave_name")"
  if [ "$st" = "done" ] || [ "$st" = "skipped" ]; then
    err "wave $wave_name: already $st, skipping"
    continue
  fi
  if [ "$st" = "gated" ]; then
    if [ "$CONTINUE" = 1 ]; then
      err "wave $wave_name: gate cleared via --continue"
      set_wave_status "$wave_name" done
      continue
    else
      err "wave $wave_name: still gated, awaiting --continue"
      print_summary
      exit 0
    fi
  fi
  set_wave_status "$wave_name" running
  kind="$(jqr --arg n "$wave_name" '(.waves[] | select(.name==$n) | .kind)' "$MANIFEST")"
  rc=0
  case "$kind" in
    finder) run_finder_wave "$wave_name" || rc=$? ;;
    barrier) run_triage_wave || rc=$? ;;
    fix) run_fix_wave || rc=$? ;;
    docs) run_docs_wave || rc=$? ;;
    *) err "wave $wave_name: unknown kind '$kind'"; rc=2 ;;
  esac
  if [ "$rc" != 0 ]; then
    err "wave $wave_name failed (rc=$rc)"
    set_wave_status "$wave_name" gated
    print_summary
    exit 10
  fi
  st="$(wave_status "$wave_name")"
  [ "$st" = "skipped" ] && continue
  set_wave_status "$wave_name" done
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
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
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
