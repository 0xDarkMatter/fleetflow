#!/usr/bin/env bash
# ff-widget.sh - renders an inline chat-card HTML FRAGMENT for a fleetflow run,
# for the claude.ai chat sandbox's `show_widget` (ADR-018 §5).
#
# Self-containment (mirrors ADR-003's zero-external-references doctrine): the
# ONLY external reference this fragment ever emits is the literal
# "https://fleetflow.lab" anchor href in the footer. Tabler icon classes
# (`ti ti-...`) are NOT a fetch here - the host page loads the Tabler font,
# this fragment only references its CSS classes. `tests/run.sh` greps this
# script's output for http(s) occurrences and expects exactly that one hit.
#
# Data sources, all optional-degrading per the ADR:
#   ff-status.sh --run   (required - no run, no fragment)
#   manifest.json .waves + .posture (sibling key, ADR-018 §2; absent/empty ->
#     wave bar falls back to manifest.phases, all segments neutral)
#   ff-findings.sh count (absent script, or a failed/empty call -> findings
#     metric shows "-" and the findings strip is omitted entirely)
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
  --max-lanes N    lane cells to render before a "+N more" cell (default: 10)

Renders an HTML fragment (no doctype/html/head/body) on stdout, for the
claude.ai chat sandbox's `show_widget`. Reads ff-status.sh for lane data,
the run's manifest.json for wave/posture state, and ff-findings.sh (if
present) for open-findings counts - every data source degrades gracefully
when absent rather than failing the render.

EXAMPLES
  ff-widget.sh --run currency
  ff-widget.sh --run currency --repo /path/to/repo --max-lanes 6
  ff-widget.sh --run currency > fragment.html
EOF
}

err() { echo "ff-widget: $*" >&2; }

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

metric_cell() {
  # $1 icon suffix (ti-...), $2 label, $3 value - label/value are our own
  # literal strings or pre-formatted numbers, never raw run data, so no
  # per-call escaping here.
  printf '<div class="ffw-cell"><div class="ffw-cell-head"><i class="ti %s" aria-hidden="true"></i><span>%s</span></div><div class="ffw-cell-value">%s</div></div>' \
    "$1" "$2" "$3"
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

RUN="" REPO="" MAX_LANES=10
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --max-lanes) MAX_LANES="${2:-}"; shift 2 ;;
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
# status; a legacy manifest (no .waves) falls back to .manifest.phases with
# every segment neutral ("pending" - no status data exists to colour it).
WAVE_ROWS="$(printf '%s' "$STATUS_JSON" | jq -c --argjson w "$WAVES_JSON" '
  (.manifest.phases // []) as $ph
  | if ($w != null and ($w|length) > 0) then
      [$w[] | {name: (.name // "?"), status: (.status // "pending")}]
    else
      [$ph[] | {name: ., status: "pending"}]
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

# --- metric cell grid -------------------------------------------------------
LANES_TOTAL="$(printf '%s' "$STATUS_JSON" | jq -r '.lanes | length')"
LANES_DONE="$(printf '%s' "$STATUS_JSON" | jq -r '[.lanes[] | select(.state=="done")] | length')"
TOKENS_TOTAL="$(printf '%s' "$STATUS_JSON" | jq -r '[.lanes[].tokens_total] | add // 0')"
ELAPSED_MAX="$(printf '%s' "$STATUS_JSON" | jq -r '[.lanes[].elapsed_s] | if length>0 then max else 0 end')"
COST_SUM="$(printf '%s' "$STATUS_JSON" | jq -r '[.lanes[].cost_usd | select(. != null)] | add // 0')"
COST_REPORTED="$(printf '%s' "$STATUS_JSON" | jq -r '[.lanes[] | select(.cost_usd != null)] | length')"
COST_UNCOSTED=$((LANES_TOTAL - COST_REPORTED))

if [ "$COST_REPORTED" -eq 0 ]; then
  COST_H="-"
else
  COST_FMT="$(jq -nr --argjson a "$COST_SUM" '($a*100|round)/100|tostring')"
  if [ "$COST_UNCOSTED" -gt 0 ]; then COST_H="≈\$${COST_FMT}*"; else COST_H="\$${COST_FMT}"; fi
fi

FINDINGS_AVAILABLE=0
FIND_OPEN=0 FIND_TOTAL=0
if [ -f "$FINDINGS_BIN" ]; then
  FCOUNT_JSON="$(bash "$FINDINGS_BIN" count --run "$RUN" --repo "$REPO" 2>/dev/null)"
  if [ -n "$FCOUNT_JSON" ] && printf '%s' "$FCOUNT_JSON" | jq -e . >/dev/null 2>&1; then
    FINDINGS_AVAILABLE=1
    FIND_OPEN="$(printf '%s' "$FCOUNT_JSON" | jq -r '.open // 0')"
    FIND_TOTAL="$(printf '%s' "$FCOUNT_JSON" | jq -r '[.[]] | add // 0')"
  fi
fi
if [ "$FINDINGS_AVAILABLE" = 1 ]; then FINDINGS_H="$FIND_OPEN/$FIND_TOTAL"; else FINDINGS_H="-"; fi

TOKENS_H="$(humanize_tokens "$TOKENS_TOTAL")"
ELAPSED_H="$(humanize_secs "$ELAPSED_MAX")"

METRICS_HTML="$(metric_cell ti-layout-grid lanes "$LANES_DONE/$LANES_TOTAL")"
METRICS_HTML="$METRICS_HTML$(metric_cell ti-coins tokens "$TOKENS_H")"
METRICS_HTML="$METRICS_HTML$(metric_cell ti-report-money cost "$COST_H")"
METRICS_HTML="$METRICS_HTML$(metric_cell ti-bug findings "$FINDINGS_H")"
METRICS_HTML="$METRICS_HTML$(metric_cell ti-clock elapsed "$ELAPSED_H")"

# --- lane cell grid ----------------------------------------------------------
LANES_EXTRA="$(printf '%s' "$STATUS_JSON" | jq -r --argjson max "$MAX_LANES" '((.lanes|length) - $max) as $n | if $n > 0 then $n else 0 end')"

LANE_CELLS_HTML=""
while IFS=$'\t' read -r lid lstate lmodel lphase ltok lelapsed; do
  [ -n "$lid" ] || continue
  case "$lstate" in
    done) icon="ti-check"; fg="var(--text-success)" ;;
    running) icon="ti-loader-2"; fg="var(--text-accent)" ;;
    failed) icon="ti-x"; fg="var(--text-danger)" ;;
    stalled) icon="ti-alert-triangle"; fg="var(--text-warning)" ;;
    *) icon="ti-loader-2"; fg="var(--text-muted)" ;;
  esac
  id_esc="$(html_esc "$lid")"
  meta_esc="$(html_esc "${lmodel:-?} · ${lphase:-build}")"
  sub_esc="$(html_esc "$(humanize_tokens "$ltok") tok · $(humanize_secs "$lelapsed")")"
  LANE_CELLS_HTML="$LANE_CELLS_HTML<div class=\"ffw-lane\"><div class=\"ffw-lane-top\"><i class=\"ti $icon\" aria-hidden=\"true\" style=\"color:$fg;\"></i><span class=\"ffw-lane-id\">$id_esc</span></div><div class=\"ffw-lane-meta\">$meta_esc</div><div class=\"ffw-lane-sub\">$sub_esc</div></div>"
done < <(printf '%s' "$STATUS_JSON" | jq -r --argjson max "$MAX_LANES" '
  .lanes[0:$max][] | [.id, .state, ((.model_id // .model) // ""), (.phase // ""), (.tokens_total // 0), (.elapsed_s // 0)] | @tsv' | tr -d '\r')

if [ "$LANES_EXTRA" -gt 0 ]; then
  LANE_CELLS_HTML="$LANE_CELLS_HTML<div class=\"ffw-lane ffw-lane-more\">+$LANES_EXTRA more</div>"
fi

# --- findings strip (only when findings exist at all) ------------------------
FINDINGS_BLOCK=""
if [ "$FINDINGS_AVAILABLE" = 1 ] && [ "$FIND_TOTAL" -gt 0 ]; then
  SEV_CHIPS_HTML=""
  for sev in critical high medium low; do
    SJSON="$(bash "$FINDINGS_BIN" count --run "$RUN" --repo "$REPO" --severity "$sev" 2>/dev/null)"
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

cat <<HTMLEOF
<div class="ffw">
<style>
.ffw-wavebar{display:flex;gap:1px;border-radius:var(--radius);overflow:hidden;height:26px;}
.ffw-seg{display:flex;align-items:center;justify-content:center;min-width:0;flex:1 1 0;padding:0 4px;}
.ffw-seg-label{font-size:12px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.ffw-metrics,.ffw-lanes{display:grid;grid-template-columns:repeat(auto-fit,minmax(110px,1fr));gap:8px;margin-top:10px;}
.ffw-cell,.ffw-lane{background:var(--surface-1);border-radius:var(--radius);padding:10px;display:flex;flex-direction:column;gap:4px;}
.ffw-cell-head{display:flex;align-items:center;gap:6px;color:var(--text-muted);font-size:11px;}
.ffw-cell-head i{font-size:16px;}
.ffw-cell-value{font-size:16px;font-weight:500;color:var(--text-primary);font-family:var(--font-mono);}
.ffw-lane-top{display:flex;align-items:center;gap:6px;}
.ffw-lane-id{font-family:var(--font-mono);font-size:12px;color:var(--text-primary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.ffw-lane-meta{font-size:11px;color:var(--text-secondary);}
.ffw-lane-sub{font-size:11px;color:var(--text-muted);font-family:var(--font-mono);}
.ffw-lane-more{align-items:center;justify-content:center;color:var(--text-muted);font-size:12px;}
.ffw-findings{display:flex;gap:6px;flex-wrap:wrap;margin-top:10px;}
.ffw-chip{font-size:11px;font-weight:500;padding:3px 8px;border-radius:var(--radius);}
.ffw-footer{display:flex;align-items:center;gap:8px;margin-top:12px;flex-wrap:wrap;}
.ffw-btn{font-size:12px;font-weight:500;padding:5px 10px;border-radius:var(--radius);border:1px solid var(--border);background:var(--surface-1);color:var(--text-secondary);cursor:pointer;}
.ffw-link{margin-left:auto;font-size:11px;color:var(--text-muted);text-decoration:none;}
</style>
<div class="ffw-wavebar" role="list" aria-label="wave pipeline">$SEGMENTS_HTML</div>
<div class="ffw-metrics">$METRICS_HTML</div>
<div class="ffw-lanes">$LANE_CELLS_HTML</div>
$FINDINGS_BLOCK
<div class="ffw-footer">
$REFRESH_BTN
$TRIAGE_BTN
$GATE_BTN
<a class="ffw-link" href="$DASHBOARD_URL">full dashboard <i class="ti ti-external-link" aria-hidden="true"></i></a>
</div>
</div>
HTMLEOF

exit 0

}

main "$@"
