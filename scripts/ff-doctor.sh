#!/usr/bin/env bash
# ff-doctor.sh - fleetflow preflight: prove the heterogeneous fleet can run.
#
# --offline (default): structural checks only - binaries, sibling launchers,
#   script syntax. CI-safe, no network.
# --live: additionally probe each provider - GLM endpoint (via fleet-doctor),
#   Codex auth, Anthropic model availability - plus the codex windows.sandbox
#   tripwire (config-only, no sandbox provisioned) - and report which
#   orchestrator tier is available (fable > opus).
# stdout: one TSV line per check: name<TAB>status<TAB>detail. stderr: chatter.
#
# Exit codes: 0 all required checks ok | 2 usage | 7 live probe unreachable
#             10 structural failure
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.2.0"

usage() {
  cat <<'EOF'
Usage: ff-doctor.sh [--offline | --live | --env] [--for MODEL[,MODEL...]]

  --offline   structural checks only (default; CI-safe)
  --live      also probe GLM endpoint, Codex auth, Anthropic models;
              reports orchestrator tier (fable|opus)
  --env       print every FLEETFLOW_* tunable: name, current value, default,
              and what it does (TSV; the live source docs/REFERENCE.md cites)
  --for       scope the verdict to the models this run will spawn: a missing
              harness for a REQUESTED model escalates advisory->fail, and
              `claude` is required only when a claude-family/glm model (or no
              --for at all) is in play - an orchestrator on another harness
              can bless a claude-less codex/grok/pi fleet

EXAMPLES
  ff-doctor.sh --offline
  ff-doctor.sh --live
  ff-doctor.sh --env | column -t -s "$(printf '	')"
  ff-doctor.sh --offline --for codex,glm
EOF
}

MODE="offline"; FOR_MODELS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --offline) MODE="offline"; shift ;;
    --live) MODE="live"; shift ;;
    --env) MODE="env"; shift ;;
    --for) FOR_MODELS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ff-doctor: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
# wants M -> is model M named in the --for set? With NO --for the historic
# behaviour holds: claude is hard (the common Claude-orchestrated case), every
# per-model harness is advisory. wants() is therefore only consulted when a
# --for set exists; each check site guards on that.
wants() { case ",$FOR_MODELS," in *",$1,"*) return 0;; *) return 1;; esac; }
# req NAME OK DETAIL_OK MISSING_DETAIL WANTED -> fail when wanted, advisory when not
req_bin() {
  _name="$1"; _ok="$2"; _okd="$3"; _missd="$4"; _wanted="$5"
  if [ "$_ok" = 1 ]; then say "$_name" ok "$_okd"
  elif [ "$_wanted" = 1 ]; then say "$_name" fail "$_missd"; FAIL=1
  else say "$_name" advisory "$_missd"
  fi
}

FAIL=0; UNREACH=0

# --- --env: the FLEETFLOW_* tunables registry -----------------------------------
# One row per variable: name<TAB>current<TAB>default<TAB>what it tunes.
# This list is the SOURCE OF TRUTH for docs/REFERENCE.md, and a test asserts every
# FLEETFLOW_* variable referenced by any script appears here - add the row in the
# same commit as the variable or the gate fails.
env_rows() {
  cat <<'ROWS'
FLEETFLOW_HOME	$HOME/.fleetflow	machine-level store root: history.jsonl, dashboard cache (ff-archive/clean/sweep/serve)
FLEETFLOW_ROOTS	(unset)	path-separator-joined roots for machine-wide discovery; overrides ~/.fleetflow/roots.txt (ff-serve, ff-aggregate, ff-sweep)
FLEETFLOW_STALL_SECONDS	600	live-stream silence before a running lane reads stalled (ff-status, ADR-008)
FLEETFLOW_ABANDON_SECONDS	21600	silence before a running/stalled lane is demoted to final abandoned (ff-status, ADR-025)
FLEETFLOW_CACHE_ROOT	$HOME/.fleet-worker/cache	per-lane tmp + uv cache root, redirected OUT of worktrees (ff-spawn, ff-clean)
FLEETFLOW_CFG_BASE	$HOME/.fleet-worker	fleet-worker config-dir base ff-status scans for glm lane transcripts
FLEETFLOW_DASHBOARD_URL	http://127.0.0.1:8161	dashboard origin for the widget anchor and the SKILL.md pane ritual
FLEETFLOW_BUS	0	=1 opts lanes into raven bus heartbeats (ff-spawn, ADR-022)
FLEETFLOW_ORCHESTRATOR	(unset)	orchestrator label recorded in the journal; falls back to $FLEETFLOW_HOME/orchestrator
FLEETFLOW_PERMISSION_MODE	acceptEdits (acp) / bypassPermissions (headless)	permission mode for claude-family lanes; default differs by lane kind
FLEETFLOW_FLEET_WORKER	$HOME/.claude/skills/fleet-worker/scripts/fleet-worker	glm launcher path (ff-spawn hard-requires it for --model glm)
FLEETFLOW_CODEX_MODEL	(harness default)	codex -m override for codex lanes
FLEETFLOW_CODEX_WINDOWS_SANDBOX	unelevated	Windows sandbox-mode pin for codex lanes (ADR-007); set EMPTY to disarm the override (set-vs-unset is meaningful)
FLEETFLOW_GROK_BIN	grok	grok binary or launcher path
FLEETFLOW_GROK_MODEL	(harness default)	grok -m override for grok lanes
FLEETFLOW_PI_BIN	pi	pi binary or launcher path
FLEETFLOW_PI_PROVIDER	(pi config default)	pi --provider override; recorded in the lane alias
FLEETFLOW_PI_MODEL	(provider default)	pi --model override
FLEETFLOW_ACP_AGENT_JS	(auto-resolved)	path to the claude-code-acp agent JS for --acp lanes
FLEETFLOW_WAVE_ROOT	(repo root)	asset root for the wave pipeline (ff-run wave)
FLEETFLOW_WAVE_CATALOGUE	$WAVE_ROOT/assets/wave-catalogue.json	wave catalogue override
FLEETFLOW_WAVE_SCHEMA	$WAVE_ROOT/assets/findings.schema.json	findings schema override
FLEETFLOW_FINDINGS_BIN	scripts/ff-findings.sh	findings CLI override (ff-run, ff-widget)
FLEETFLOW_REPAIR_DRYRUN	(unset)	non-empty = ff-collect --repair respawns with --dry-run (test the loop without spending)
FLEETFLOW_PATH_PREPEND	(unset)	colon-separated dirs _env.sh prepends to PATH before tool discovery
ROWS
}
if [ "$MODE" = "env" ]; then
  env_rows | while IFS=$(printf '	') read -r name dflt desc; do
    eval "cur=\${$name-__FF_UNSET__}"
    [ "$cur" = "__FF_UNSET__" ] && cur="(unset)"
    printf '%s	%s	%s	%s
' "$name" "$cur" "$dflt" "$desc"
  done
  exit 0
fi

say() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- structural ---------------------------------------------------------------
for bin in git jq; do
  if command -v "$bin" >/dev/null; then say "bin-$bin" ok "found"; else say "bin-$bin" fail "missing"; FAIL=1; fi
done
# sha256: any of coreutils/shasum/openssl satisfies ff_sha256 (see scripts/_env.sh).
# Reported by IMPLEMENTATION, not by the coreutils name, so macOS reads ok not fail.
if ff_have_sha256; then
  for _impl in sha256sum shasum openssl; do command -v "$_impl" >/dev/null 2>&1 && break; done
  say "bin-sha256" ok "$_impl"
else say "bin-sha256" fail "need one of sha256sum, shasum, or openssl"; FAIL=1; fi
# python: probed by execution - a PATH-resolvable Windows Store alias is not an interpreter.
if ff_have_python; then say "bin-python" ok "$FF_PYTHON"
else say "bin-python" advisory "missing - ADR constraint checks and some tests degrade"; fi
# claude serves sonnet/haiku/opus/fable lanes AND glm (fleet-worker rides claude -p).
# Scoped runs that want none of those may be claude-less (ADR-033).
CLAUDE_WANTED=0
if [ -z "$FOR_MODELS" ]; then CLAUDE_WANTED=1
else for _m in sonnet haiku opus fable glm chip; do wants "$_m" && CLAUDE_WANTED=1; done
fi
_cok=0; command -v claude >/dev/null && _cok=1
req_bin "bin-claude" "$_cok" "found" "missing - claude-family and glm lanes unavailable" "$CLAUDE_WANTED"
_cxok=0; command -v codex >/dev/null && _cxok=1
_cxw=0; [ -n "$FOR_MODELS" ] && wants codex && _cxw=1
req_bin "bin-codex" "$_cxok" "$(codex --version 2>/dev/null | head -1)" "missing - --model codex exits 5; install: https://github.com/openai/codex" "$_cxw"
GROK="${FLEETFLOW_GROK_BIN:-grok}"
_gkok=0; command -v "$GROK" >/dev/null && _gkok=1
_gkw=0; [ -n "$FOR_MODELS" ] && wants grok && _gkw=1
req_bin "bin-grok" "$_gkok" "$("$GROK" --version 2>/dev/null | head -1)" "missing - --model grok exits 5; set FLEETFLOW_GROK_BIN or install the xAI grok CLI" "$_gkw"
PIBIN="${FLEETFLOW_PI_BIN:-pi}"
# -f fallback matches ff-spawn: bash runs a .cmd shim but command -v rejects it
_piok=0; { command -v "$PIBIN" >/dev/null || [ -f "$PIBIN" ]; } && _piok=1
_piw=0; [ -n "$FOR_MODELS" ] && wants pi && _piw=1
req_bin "bin-pi" "$_piok" "pi $("$PIBIN" --version 2>/dev/null | head -1)" "missing - --model pi exits 5; set FLEETFLOW_PI_BIN or install https://github.com/earendil-works/pi" "$_piw"

FW="${FLEETFLOW_FLEET_WORKER:-$HOME/.claude/skills/fleet-worker/scripts/fleet-worker}"
_fwok=0; [ -f "$FW" ] && _fwok=1
_fww=0; [ -n "$FOR_MODELS" ] && wants glm && _fww=1
req_bin "fleet-worker" "$_fwok" "$FW" "not installed - --model glm exits 5; mount claude-mods skills/fleet-worker or set FLEETFLOW_FLEET_WORKER" "$_fww"

# --- which windows.sandbox mode will codex lanes actually get? -----------------
# Config read only (no execution) - the behavioural tripwire is in --live below.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    WSB_EFF="${FLEETFLOW_CODEX_WINDOWS_SANDBOX-unelevated}"
    WSB_HOST="$(sed -n '/^\[windows\]/,/^\[/p' "$HOME/.codex/config.toml" 2>/dev/null \
                | sed -n 's/^[[:space:]]*sandbox[[:space:]]*=[[:space:]]*"\{0,1\}\([a-z]*\)"\{0,1\}.*/\1/p' | head -1)"
    if [ -z "$WSB_EFF" ]; then
      say "codex-winsandbox-mode" advisory "override disabled - lanes defer to config.toml (${WSB_HOST:-unset}); elevated there = headless hang"
    elif [ "$WSB_EFF" = "elevated" ]; then
      say "codex-winsandbox-mode" advisory "FLEETFLOW_CODEX_WINDOWS_SANDBOX=elevated re-arms the headless UAC trap"
    else
      say "codex-winsandbox-mode" ok "lanes pinned $WSB_EFF (host config: ${WSB_HOST:-unset})"
    fi
    ;;
esac

for s in ff-spawn.sh ff-collect.sh ff-status.sh; do
  if bash -n "$HERE/$s" 2>/dev/null; then say "syntax-$s" ok "parses"; else say "syntax-$s" fail "syntax error"; FAIL=1; fi
done
[ -f "$HERE/../assets/guard-preamble.txt" ] && say "guard-preamble" ok "present" || { say "guard-preamble" fail "missing"; FAIL=1; }
# raven-bus (P4 wiring, ADR-022): advisory only - the bus heartbeat clause
# is opt-in via FLEETFLOW_BUS=1 and degrades silently without the binary.
if command -v raven >/dev/null 2>&1; then
  say "raven-bus" ok "$(raven version 2>/dev/null | head -1) (FLEETFLOW_BUS=1 adds worker bus heartbeats)"
else
  say "raven-bus" advisory "raven not on PATH - bus heartbeats unavailable"
fi

# --- install-sync: repo copy vs the installed copy at $HOME/.claude/skills ---
# version-skew guard. Only compares when an installed copy exists AND is a
# different directory from the one being run (running from the install itself
# trivially matches). Drift is advisory, never a hard fail.
INST="$HOME/.claude/skills/fleetflow/scripts"
if [ -d "$INST" ]; then
  INST_ABS="$(cd "$INST" 2>/dev/null && pwd)"
  if [ -n "$INST_ABS" ] && [ "$INST_ABS" != "$HERE" ]; then
    DIFF=0
    for s in ff-spawn.sh ff-collect.sh ff-status.sh ff-doctor.sh ff-run.sh ff-clean.sh; do
      [ -f "$HERE/$s" ] || continue            # not shipped here; skip
      if [ ! -f "$INST/$s" ]; then DIFF=1; break; fi
      h1="$(ff_sha256 "$HERE/$s" | cut -d' ' -f1)"
      h2="$(ff_sha256 "$INST/$s" | cut -d' ' -f1)"
      [ "$h1" = "$h2" ] || { DIFF=1; break; }
    done
    if [ "$DIFF" = 0 ]; then say "install-sync" ok "repo and installed copies match"
    else say "install-sync" advisory "repo and installed copies differ - re-run install"; fi
  else
    say "install-sync" ok "running from the installed copy"
  fi
else
  say "install-sync" advisory "no installed copy at $INST"
fi

[ "$MODE" = "live" ] || { [ "$FAIL" = 0 ] && exit 0 || exit 10; }

# --- live probes ----------------------------------------------------------------
FD="$(dirname "$FW")/fleet-doctor.sh"
if [ -f "$FD" ]; then
  if bash "$FD" --live 2>/dev/null | grep -q "live-ping	ok"; then
    say "glm-endpoint" ok "model resolves"
  else
    say "glm-endpoint" unreachable "fleet-doctor --live did not confirm (key/endpoint)"; UNREACH=1
  fi
else
  say "glm-endpoint" advisory "fleet-doctor not installed"
fi

if command -v codex >/dev/null; then
  if timeout 30 codex login status 2>&1 | grep -qi "logged in"; then
    say "codex-auth" ok "$(timeout 30 codex login status 2>&1 | head -1)"
  else
    say "codex-auth" unreachable "not logged in (codex login)"; UNREACH=1
  fi
fi

# --- codex windows.sandbox tripwire (guards the 2026-07-27 elevation hang) -----
# ff-spawn pins `-c windows.sandbox=unelevated` so a headless lane never waits on
# a UAC prompt nobody can approve. That guard fails SILENTLY if codex renames or
# drops the key: `-c` accepts unknown dotted keys without complaint (verified -
# `-c nosuch.key=x` exits 0), so the flag would degrade to an inert no-op and
# lanes would hang again with no signal. We therefore probe the OPPOSITE: feed a
# deliberately invalid value and require codex to reject it, naming the key.
# Rejection proves the key still exists and is still typed; silent acceptance
# means the guard has gone inert and this check is the only thing that will say so.
#
# `codex debug prompt-input` is the probe carrier ON PURPOSE: it only loads and
# validates config (~1.2s, no network, no model call, no API tokens) and - unlike
# `codex sandbox` - it does NOT provision a Windows sandbox. Sandbox provisioning
# is machine-global (~/.codex/.sandbox*) and is the very thing that can trigger
# the elevation helper, so a preflight check must never invoke it. Do not
# "simplify" this to a sandbox or exec call.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v codex >/dev/null; then
      WSB_ERR="$(timeout 60 codex debug prompt-input -c windows.sandbox=ff-doctor-invalid 2>&1 >/dev/null)"
      WSB_RC=$?
      if [ "$WSB_RC" = 124 ]; then
        say "codex-winsandbox" unreachable "config probe timed out"; UNREACH=1
      elif [ "$WSB_RC" != 0 ] && printf '%s' "$WSB_ERR" | grep -q 'windows\.sandbox'; then
        say "codex-winsandbox" ok "key recognised - elevation guard live"
      elif [ "$WSB_RC" != 0 ]; then
        say "codex-winsandbox" advisory "probe failed for another reason: $(printf '%s' "$WSB_ERR" | head -1)"
      else
        say "codex-winsandbox" fail "codex accepts an invalid windows.sandbox - ff-spawn's elevation guard is INERT (key renamed/removed?)"
        FAIL=1
      fi
    fi
    ;;
esac

# grok auth is the GROK_DEPLOYMENT_KEY env var (no login-status subcommand exists,
# and OAuth on some accounts lacks chat entitlement). We probe key PRESENCE, not
# validity - a real chat call would burn quota. Only when the binary is installed.
if command -v "$GROK" >/dev/null; then
  if [ -n "${GROK_DEPLOYMENT_KEY:-}" ]; then
    say "grok-auth" ok "GROK_DEPLOYMENT_KEY set"
  else
    say "grok-auth" unreachable "GROK_DEPLOYMENT_KEY not set (deployment key required)"; UNREACH=1
  fi
fi

# pi lanes run with an ISOLATED PI_CODING_AGENT_DIR (ff-spawn), so the host's
# ~/.pi/agent/auth.json never applies - the provider's API key env var is the
# lane's ONLY auth. Probe key PRESENCE for the configured provider, not
# validity (a real call would burn quota, same doctrine as grok-auth).
if command -v "$PIBIN" >/dev/null || [ -f "$PIBIN" ]; then
  PIPROV="${FLEETFLOW_PI_PROVIDER:-}"
  if [ -z "$PIPROV" ]; then
    say "pi-auth" advisory "FLEETFLOW_PI_PROVIDER not set - pi lanes would use pi's default provider with no key check"
  else
    case "$PIPROV" in
      anthropic)  PIKEY="ANTHROPIC_API_KEY" ;;
      openai)     PIKEY="OPENAI_API_KEY" ;;
      google)     PIKEY="GEMINI_API_KEY" ;;
      zai)        PIKEY="ZAI_API_KEY" ;;
      groq)       PIKEY="GROQ_API_KEY" ;;
      xai)        PIKEY="XAI_API_KEY" ;;
      deepseek)   PIKEY="DEEPSEEK_API_KEY" ;;
      mistral)    PIKEY="MISTRAL_API_KEY" ;;
      openrouter) PIKEY="OPENROUTER_API_KEY" ;;
      cerebras)   PIKEY="CEREBRAS_API_KEY" ;;
      *)          PIKEY="" ;;
    esac
    if [ -z "$PIKEY" ]; then
      say "pi-auth" advisory "no env-key mapping for provider '$PIPROV' - lane auth unverified"
    elif [ -n "$(eval "printf '%s' \"\${$PIKEY:-}\"")" ]; then
      say "pi-auth" ok "$PIKEY set (provider $PIPROV)"
    else
      say "pi-auth" unreachable "$PIKEY not set (provider $PIPROV; host auth.json does not reach lanes)"; UNREACH=1
    fi
  fi
fi

ORCH="none"
if command -v claude >/dev/null; then
  for m in claude-fable-5 opus; do
    R="$(timeout 120 claude -p "reply with exactly: ok" --model "$m" --max-turns 1 --output-format json 2>/dev/null)"
    if [ -n "$R" ] && [ "$(printf '%s' "$R" | jq -r 'if has("is_error") then (.is_error|tostring) else "true" end' 2>/dev/null)" = "false" ]; then
      case "$m" in claude-fable-5) ORCH="fable" ;; *) ORCH="opus" ;; esac
      say "model-$m" ok "responds"
      break
    else
      say "model-$m" unavailable "no successful reply"
    fi
  done
fi
# Persist the probe so ff-spawn has a default when a session forgets to pass
# --orchestrator. A best guess recorded as such beats a null nobody can fill in
# later - but it IS a guess about availability, not proof of what is driving, so
# an explicit --orchestrator / $FLEETFLOW_ORCHESTRATOR always wins over this file.
if [ "$ORCH" != none ]; then
  mkdir -p "${FLEETFLOW_HOME:-$HOME/.fleetflow}" 2>/dev/null || true
  printf '%s\n' "$ORCH" > "${FLEETFLOW_HOME:-$HOME/.fleetflow}/orchestrator" 2>/dev/null || true
fi
say "orchestrator" "$([ "$ORCH" = none ] && echo unreachable || echo ok)" "$ORCH"
[ "$ORCH" = "none" ] && UNREACH=1

if [ "$FAIL" != 0 ]; then exit 10; fi
[ "$UNREACH" != 0 ] && exit 7
exit 0
