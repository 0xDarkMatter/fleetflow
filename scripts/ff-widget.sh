#!/usr/bin/env bash
# ff-widget.sh - renders an inline chat-card HTML FRAGMENT for a fleetflow run,
# for the claude.ai chat sandbox's `show_widget` (ADR-018 §5).
#
# Per ADR-019, the run header (title/badges, orch badge, path, lanes-ran line,
# pip strip, tokens-per-lane chart+legend, stat row) is NOT built here — it is
# rendered by the ONE canonical module `assets/ff-runcard.js`
# (`ffRunCard(runDoc, {surface:"chat"})` -> HTML string) that this script reads
# at runtime and inlines VERBATIM between `/* ff-runcard:begin */` /
# `/* ff-runcard:end */` markers, so a parity test can byte-compare the
# embedded copy against the source module (assets/ff-dashboard.html embeds the
# same module for its own run-detail header). This script's job shrinks to:
# gather data, build the `runDoc` wire format (ADR-019/RUNCARD-2026-08 §1),
# and render the chat-only controls BENEATH the card (wave bar, findings
# strip, sendPrompt buttons) that stay outside the shared module by design.
#
# Self-containment (mirrors ADR-003's zero-external-references doctrine): the
# ONLY external reference this fragment ever emits is the literal
# "https://fleetflow.lab" anchor href in the footer. Tabler icon classes
# (`ti ti-...`) on the chat-only controls are NOT a fetch here - the host page
# loads the Tabler font, this fragment only references its CSS classes.
# `tests/run.sh` greps this script's output for http(s) occurrences and
# expects exactly that one hit.
#
# Data sources, all optional-degrading per the ADR:
#   ff-status.sh --run   (required - no run, no fragment)
#   assets/ff-runcard.js (required - no module, no fragment; ADR-019)
#   manifest.json .waves + .posture (sibling key, ADR-018 §2; absent/empty ->
#     wave bar falls back to manifest.phases, all segments neutral)
#   ff-findings.sh count (absent script, or a failed/empty call -> findings
#     strip omitted entirely)
#
# stdout: HTML fragment (no doctype/html/head/body). stderr: chatter.
# Exit codes: 0 ok | 2 usage | 3 run missing
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"

usage() {
  cat <<'EOF'
Usage: ff-widget.sh --run NAME [--repo PATH] [--max-lanes N]

  --run NAME       run name under <repo>/.fleetflow/ (required)
  --repo PATH      repo root (default: git toplevel of cwd)
  --max-lanes N    cap on lanes fed to the run-card's chart/pip-strip - the
                   stat row still reports the true totals across ALL lanes
                   (default: 10)

Renders an HTML fragment (no doctype/html/head/body) on stdout, for the
claude.ai chat sandbox's `show_widget`. The run-card header is rendered by
the shared assets/ff-runcard.js module (ADR-019); this script gathers data
from ff-status.sh, the run's manifest.json (wave/posture state), and
ff-findings.sh (if present) for open-findings counts - every data source
except the module itself degrades gracefully when absent.

EXAMPLES
  ff-widget.sh --run currency
  ff-widget.sh --run currency --repo /path/to/repo --max-lanes 6
  ff-widget.sh --run currency > fragment.html
EOF
}

err() { echo "ff-widget: $*" >&2; }

# reqval N FLAG - guards the flag-parse loop's "${2:-}; shift 2" idiom
# (finding 8d368218ec13): a flag as the LAST argument leaves $2 empty and
# `shift 2` a no-op, so $1 never advances and the loop spins forever. Call
# with the loop's own $# (BEFORE consuming the value) so a missing value
# errors out instead of re-presenting the same flag.
reqval() { [ "$1" -ge 2 ] || { err "$2 requires a value"; usage >&2; exit 2; }; }

# escape a raw string for HTML text/attribute context (jq's @html covers
# < > & ' " - safe inside both double- and single-quoted attributes).
html_esc() { printf '%s' "$1" | jq -Rr '@html'; }

# a JS call embedded as an HTML attribute value: JSON-quote the string (so JS
# sees proper escaping of its own quotes/backslashes) then HTML-escape the
# whole thing (so the double quotes JSON produces are safe inside either kind
# of HTML attribute quoting) - two passes, two different escaping domains.
js_call_attr() {
  jq -nr --arg fn "$1" --arg t "$2" '($fn + "(" + ($t|@json) + ")") | @html'
}

# jqr FILTER [ARGS...] - jq -r piped through CRLF strip. jq.exe on Windows
# emits CRLF; a lone trailing \r on a captured value silently breaks `case`/
# `[` comparisons downstream (ff-status.sh/ff-run.sh hit this same trap on
# their own reads - see ff-status.sh's journal-parsing comment).
jqr() { jq -r "$@" | tr -d '\r'; }

humanize_secs() {
  local s="${1:-0}"
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if [ "$s" -ge 86400 ]; then printf '%dd%02dh' $((s/86400)) $(((s%86400)/3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s/60)) $((s%60))
  else printf '%ss' "$s"
  fi
}

humanize_tokens() {
  local n="${1:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  jq -nr --argjson n "$n" '
    if $n == 0 then "-"
    elif $n >= 1000000000 then (($n/1000000000*100|round)/100|tostring)+"B"
    elif $n >= 1000000 then (($n/1000000*10|round)/10|tostring)+"M"
    elif $n >= 1000 then (($n/1000*10|round)/10|tostring)+"k"
    else ($n|tostring)
    end'
}

# main() wrapper - parse-before-execute guard (see ff-run.sh:38 / ff-spawn.sh
# for the incident this defends against). Body deliberately NOT re-indented.
main() {

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_BIN="$HERE/ff-status.sh"
# override point for tests - the real sibling script is ff-findings.sh, which
# may not exist yet in a repo mid-build (its lane owns it, ADR-018 §1); this
# script never assumes it is present.
FINDINGS_BIN="${FLEETFLOW_FINDINGS_BIN:-$HERE/ff-findings.sh}"
# ADR-019: the shared run-card module, same resolution convention as
# ff-run.sh's wave-catalogue lookup - resolved from THIS repo's assets/, not
# the run's own repo (--repo may point anywhere).
RUNCARD_JS="$HERE/../assets/ff-runcard.js"

RUN="" REPO="" MAX_LANES=10
while [ $# -gt 0 ]; do
  case "$1" in
    --run) reqval $# --run; RUN="$2"; shift 2 ;;
    --repo) reqval $# --repo; REPO="$2"; shift 2 ;;
    --max-lanes) reqval $# --max-lanes; MAX_LANES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
command -v git >/dev/null || { err "git required"; exit 2; }
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
case "$MAX_LANES" in ''|*[!0-9]*) err "--max-lanes must be a positive integer"; exit 2 ;; esac
[ "$MAX_LANES" -gt 0 ] || { err "--max-lanes must be a positive integer"; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }
[ -f "$RUNCARD_JS" ] || { err "run-card module not found: $RUNCARD_JS (assets/ff-runcard.js not landed yet - ADR-019)"; exit 2; }

RUNDIR="$REPO/.fleetflow/$RUN"
[ -f "$RUNDIR/journal.jsonl" ] || { err "no run at $RUNDIR (run ff-spawn first)"; exit 3; }

STATUS_JSON="$(bash "$STATUS_BIN" --run "$RUN" --repo "$REPO" 2>/dev/null)"
[ -n "$STATUS_JSON" ] && printf '%s' "$STATUS_JSON" | jq -e . >/dev/null 2>&1 || { err "ff-status.sh failed for run $RUN"; exit 3; }

# manifest .waves/.posture are a SIBLING key ff-status does not forward
# (it only passes through packet_count/phases/orchestrator/base) - read the
# manifest directly for wave-pipeline state.
MANIFEST="$RUNDIR/manifest.json"
WAVES_JSON="null"
if [ -f "$MANIFEST" ]; then
  WAVES_JSON="$(jq -c '.waves // null' "$MANIFEST" 2>/dev/null)"
  [ -n "$WAVES_JSON" ] || WAVES_JSON="null"
fi

# normalize to [{name,status}] regardless of source: real waves keep their
# status; a legacy manifest (no .waves key at all) falls back to
# .manifest.phases with every segment neutral ("pending" - no status data
# exists to colour it). A manifest with an explicitly resolved EMPTY waves
# array (finding 4ed6b5add2f7) is a different state than "legacy" - it must
# not masquerade as one, so it renders a single neutral "no waves resolved"
# segment instead of falling back to phases.
WAVE_ROWS="$(printf '%s' "$STATUS_JSON" | jq -c --argjson w "$WAVES_JSON" '
  (.manifest.phases // []) as $ph
  | if ($w == null) then
      [$ph[] | {name: ., status: "pending"}]
    elif ($w|length) > 0 then
      [$w[] | {name: (.name // "?"), status: (.status // "pending")}]
    else
      [{name: "no waves resolved", status: "pending"}]
    end')"
WAVE_COUNT="$(printf '%s' "$WAVE_ROWS" | jq -r 'length')"
DROP_PENDING_LABELS=0
[ "$WAVE_COUNT" -gt 8 ] && DROP_PENDING_LABELS=1
GATED_WAVE="$(printf '%s' "$WAVE_ROWS" | jq -r '[.[] | select(.status=="gated")][0].name // empty')"

SEGMENTS_HTML=""
if [ "$WAVE_COUNT" -gt 0 ]; then
  while IFS=$'\t' read -r wname wstatus; do
    [ -n "$wname" ] || continue
    case "$wstatus" in
      done) fill="var(--bg-success)"; fg="var(--text-success)" ;;
      running) fill="var(--bg-accent)"; fg="var(--text-accent)" ;;
      gated) fill="var(--bg-warning)"; fg="var(--text-warning)" ;;
      failed) fill="var(--bg-danger)"; fg="var(--text-danger)" ;;
      *) fill="var(--surface-1)"; fg="var(--text-muted)" ;;   # pending, skipped
    esac
    label_span=""
    if [ "$DROP_PENDING_LABELS" = 0 ] || [ "$wstatus" != "pending" ]; then
      label_span="<span class=\"ffw-seg-label\">$(html_esc "$wname")</span>"
    fi
    title_attr="$(html_esc "$wname — $wstatus")"
    SEGMENTS_HTML="$SEGMENTS_HTML<div class=\"ffw-seg\" style=\"background:$fill;color:$fg;\" title=\"$title_attr\">$label_span</div>"
  # tr -d '\r' is load-bearing on Windows: jq.exe emits CRLF, and a trailing
  # \r on $wstatus silently fails every `case` match below (ff-status.sh hit
  # the identical bug on its own TSV reads - see its journal-parsing comment).
  done < <(printf '%s' "$WAVE_ROWS" | jq -r '.[] | [.name, .status] | @tsv' | tr -d '\r')
fi

# --- cost roll-up (feeds runDoc.cost; ≈/* semantics preserved from the old
# metric-cell rendering, now surfaced via the module's stat row) -------------
COST_SUM="$(printf '%s' "$STATUS_JSON" | jq -r '[.lanes[].cost_usd | select(. != null)] | add // 0')"
COST_REPORTED="$(printf '%s' "$STATUS_JSON" | jq -r '[.lanes[] | select(.cost_usd != null)] | length')"
LANES_TOTAL="$(printf '%s' "$STATUS_JSON" | jq -r '.lanes | length')"
COST_UNCOSTED=$((LANES_TOTAL - COST_REPORTED))
if [ "$COST_REPORTED" -eq 0 ]; then
  COST_USD_JSON="null"; COST_PARTIAL_JSON="false"
else
  COST_USD_JSON="$(jq -nr --argjson a "$COST_SUM" '($a*100|round)/100')"
  if [ "$COST_UNCOSTED" -gt 0 ]; then COST_PARTIAL_JSON="true"; else COST_PARTIAL_JSON="false"; fi
fi

# repo_label: short human-scannable name. The dashboard's ff-aggregate.py
# does multi-root worktree-collapsing (repo_label()); irrelevant here since
# --repo names exactly one repo, so a basename is the whole job.
REPO_LABEL="$(basename "$REPO")"

# --- runDoc: the ADR-019/RUNCARD-2026-08 §1 wire format the module renders --
# state precedence mirrors ff-aggregate.py's STATE_RANK - first non-empty
# bucket, in order, wins the run-level state tag.
DATA_JSON="$(printf '%s' "$STATUS_JSON" | jq -c \
  --arg repo_label "$REPO_LABEL" \
  --argjson waves "$WAVES_JSON" \
  --argjson cost_usd "$COST_USD_JSON" \
  --argjson cost_partial "$COST_PARTIAL_JSON" \
  --argjson max "$MAX_LANES" \
  '
  def rank: ["stalled","running","failed","done"];
  (.lanes // []) as $lanes
  | (reduce $lanes[] as $l ({}; .[$l.state] = ((.[$l.state] // 0) + 1))) as $counts
  | ((rank | map(select($counts[.] != null)) | .[0]) // "unknown") as $state
  | {
      run: .run,
      repo: .repo,
      repo_label: $repo_label,
      orchestrator: .orchestrator,
      summary: {
        state: $state,
        idle_s: ([$lanes[] | select(.state=="stalled") | .last_activity_s] | max // 0),
        counts: $counts,
        lane_count: ($lanes | length),
        elapsed_s: ([$lanes[].elapsed_s] | if length > 0 then max else 0 end),
        tokens_total: ([$lanes[].tokens_total] | add // 0),
        tokens_out: ([$lanes[].tokens_out] | add // 0),
        models: ([$lanes[].model] | map(select(. != null)) | unique | sort),
        model_ids: ([$lanes[].model_id] | map(select(. != null)) | unique | sort)
      },
      lanes: ([$lanes[] | {id, model, model_id, state, tokens_total: (.tokens_total // 0)}] | .[0:$max]),
      waves: $waves,
      # cost is PRE-FORMATTED here (module wire format wants {display,title} -
      # the module never touches money, ADR-019 §1). ≈ = contains estimates,
      # * = uncosted lanes remain - same honesty markers as the dashboard.
      cost: (if $cost_usd == null then null else {
        display: ("≈$" + ($cost_usd | tostring) + (if $cost_partial then "*" else "" end)),
        title: (if $cost_partial then "estimate; some lanes report no cost" else "estimate from lane-reported costs" end)
      } end)
    }
    | if .waves == null then del(.waves) else . end
    | if .cost == null then del(.cost) else . end
  ')"
# a run/repo name containing a literal "</script" would otherwise close the
# embedding <script> tag early - JSON has no such sequence naturally, so this
# only ever fires on adversarial input, but it is cheap insurance.
DATA_JS="$(printf '%s' "$DATA_JSON" | sed 's#</#<\\/#g')"

# --- findings strip (only when findings exist at all) ------------------------
FINDINGS_BIN_RESOLVED="$FINDINGS_BIN"
FINDINGS_AVAILABLE=0
FIND_OPEN=0 FIND_TOTAL=0
if [ -f "$FINDINGS_BIN_RESOLVED" ]; then
  FCOUNT_JSON="$(bash "$FINDINGS_BIN_RESOLVED" count --run "$RUN" --repo "$REPO" 2>/dev/null)"
  if [ -n "$FCOUNT_JSON" ] && printf '%s' "$FCOUNT_JSON" | jq -e . >/dev/null 2>&1; then
    FINDINGS_AVAILABLE=1
    FIND_OPEN="$(printf '%s' "$FCOUNT_JSON" | jq -r '.open // 0')"
    FIND_TOTAL="$(printf '%s' "$FCOUNT_JSON" | jq -r '[.[]] | add // 0')"
  fi
fi

FINDINGS_BLOCK=""
if [ "$FINDINGS_AVAILABLE" = 1 ] && [ "$FIND_TOTAL" -gt 0 ]; then
  SEV_CHIPS_HTML=""
  for sev in critical high medium low; do
    SJSON="$(bash "$FINDINGS_BIN_RESOLVED" count --run "$RUN" --repo "$REPO" --severity "$sev" 2>/dev/null)"
    n=0
    if [ -n "$SJSON" ] && printf '%s' "$SJSON" | jq -e . >/dev/null 2>&1; then
      n="$(printf '%s' "$SJSON" | jq -r '.open // 0')"
    fi
    case "$sev" in
      critical|high) bg="var(--bg-danger)"; fg="var(--text-danger)" ;;
      medium) bg="var(--bg-warning)"; fg="var(--text-warning)" ;;
      *) bg="var(--surface-1)"; fg="var(--text-secondary)" ;;
    esac
    SEV_CHIPS_HTML="$SEV_CHIPS_HTML<span class=\"ffw-chip\" style=\"background:$bg;color:$fg;\">$sev $n</span>"
  done
  FINDINGS_BLOCK="<div class=\"ffw-findings\">$SEV_CHIPS_HTML</div>"
fi

# --- footer: sendPrompt buttons + the one permitted external link ------------
REFRESH_JS="$(js_call_attr sendPrompt "Refresh fleetflow status for run $RUN")"
TRIAGE_JS="$(js_call_attr sendPrompt "Triage failed lanes for fleetflow run $RUN")"
REFRESH_BTN="<button class=\"ffw-btn\" onclick=\"$REFRESH_JS\"><i class=\"ti ti-refresh\" aria-hidden=\"true\"></i> Refresh</button>"
TRIAGE_BTN="<button class=\"ffw-btn\" onclick=\"$TRIAGE_JS\"><i class=\"ti ti-bug\" aria-hidden=\"true\"></i> Triage failed</button>"
GATE_BTN=""
if [ -n "$GATED_WAVE" ]; then
  GATE_JS="$(js_call_attr sendPrompt "Review the gated $GATED_WAVE wave for fleetflow run $RUN")"
  GATE_BTN="<button class=\"ffw-btn\" onclick=\"$GATE_JS\"><i class=\"ti ti-eye-check\" aria-hidden=\"true\"></i> Review gate</button>"
fi
REPO_ENC="$(jq -nr --arg r "$REPO" '$r|@uri')"
RUN_ENC="$(jq -nr --arg r "$RUN" '$r|@uri')"
DASHBOARD_URL="https://fleetflow.lab/?repo=${REPO_ENC}&run=${RUN_ENC}"

# --- emit: ffrc-host + style + marker-delimited module + beneath-card controls
cat <<HTMLEOF
<div class="ffrc-host"></div>
<style>
/* chat-surface mapping: the module's --ffc-* custom properties (ADR-019 §1)
   fall back onto claude.ai's own vars here, so the SAME module renders
   correctly in both light and dark without any chat-specific code inside it. */
.ffrc[data-surface="chat"]{
  --ffc-surface-1:var(--surface-1);
  --ffc-surface-2:var(--surface-2,var(--surface-1));
  --ffc-text-primary:var(--text-primary);
  --ffc-text-secondary:var(--text-secondary);
  --ffc-text-muted:var(--text-muted);
  --ffc-border:var(--border);
  --ffc-radius:var(--radius);
  --ffc-font-mono:var(--font-mono);
  --ffc-label-size:11px;
  --ffc-xlabel-size:11px;
}
.ffw-wavebar{display:flex;gap:1px;border-radius:var(--radius);overflow:hidden;height:26px;margin-top:12px;}
.ffw-seg{display:flex;align-items:center;justify-content:center;min-width:0;flex:1 1 0;padding:0 4px;}
.ffw-seg-label{font-size:12px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.ffw-findings{display:flex;gap:6px;flex-wrap:wrap;margin-top:10px;}
.ffw-chip{font-size:11px;font-weight:500;padding:3px 8px;border-radius:var(--radius);}
.ffw-footer{display:flex;align-items:center;gap:8px;margin-top:12px;flex-wrap:wrap;}
.ffw-btn{font-size:12px;font-weight:500;padding:5px 10px;border-radius:var(--radius);border:1px solid var(--border);background:var(--surface-1);color:var(--text-secondary);cursor:pointer;}
.ffw-link{margin-left:auto;font-size:11px;color:var(--text-muted);text-decoration:none;}
</style>
<script>
/* ff-runcard:begin */
HTMLEOF
cat "$RUNCARD_JS"
cat <<HTMLEOF
/* ff-runcard:end */
(function(){
  var s = document.createElement('style');
  s.textContent = FF_RUNCARD_CSS;
  document.currentScript.insertAdjacentElement('beforebegin', s);
  var DATA = $DATA_JS;
  document.querySelector('.ffrc-host').innerHTML = ffRunCard(DATA, {surface:"chat"});
})();
</script>
<div class="ffw-wavebar" role="list" aria-label="wave pipeline">$SEGMENTS_HTML</div>
$FINDINGS_BLOCK
<div class="ffw-footer">
$REFRESH_BTN
$TRIAGE_BTN
$GATE_BTN
<a class="ffw-link" href="$DASHBOARD_URL">full dashboard <i class="ti ti-external-link" aria-hidden="true"></i></a>
</div>
HTMLEOF

exit 0

}

main "$@"
