# _env.sh - PATH self-heal sourced by every fleetflow entry script.
#
# WHY: GUI-launched hosts (Claude Desktop et al.) snapshot their environment
# at app start, so User-PATH entries added later by installers (winget, npm,
# scoop, pipx, uv) are invisible to child shells until the host restarts.
# Sessions then fail with "claude/jq/keyring not found" despite correct
# installs. This block re-adds the canonical per-user tool dirs when present.
# Extend via FLEETFLOW_PATH_PREPEND (colon-separated) for exotic locations.
for _ffd in ${FLEETFLOW_PATH_PREPEND:+$(echo "$FLEETFLOW_PATH_PREPEND" | tr ':' ' ')} \
            "$HOME/.local/bin" \
            "$HOME/AppData/Local/Microsoft/WinGet/Links" \
            "$HOME/AppData/Roaming/npm" \
            "$HOME/scoop/shims" \
            "$HOME/AppData/Local/Programs/Python/Python313/Scripts" \
            "$HOME/AppData/Roaming/Python/Python313/Scripts" \
            "$HOME/.local/share/uv/tools" ; do
  [ -d "$_ffd" ] && case ":$PATH:" in *":$_ffd:"*) ;; *) PATH="$_ffd:$PATH" ;; esac
done
unset _ffd
export PATH

# --- portable helpers ---------------------------------------------------------
# WHY: fleetflow's hard deps are POSIX-ish but two of them are NOT universal, and
# both failed OPEN rather than loud on non-Linux hosts:
#
#   ff_sha256  - `sha256sum` is coreutils; macOS ships `shasum` instead. This is
#                load-bearing: ff-spawn keys the journal resume cache on it
#                (ADR-012). An empty hash collapses EVERY lane in a run onto the
#                same key `v2:`, so lane 2+ cache-hit lane 1 and silently never
#                run while the run still reports success. Never inline a bare
#                `| sha256sum` again - route through here.
#   ff_python  - `python` is not on PATH on default macOS / most Linux, where the
#                interpreter is `python3`. Used for the adr-ops bridge and the
#                suite's HTML assertions. Prefers python3, falls back to python.
#
# Both echo nothing and return non-zero when no implementation exists, so callers
# can guard with `command -v` semantics via the ff_have_* checks.
ff_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 "$@"
  elif command -v openssl  >/dev/null 2>&1; then openssl dgst -sha256 -r "$@"
  else return 127
  fi
}
ff_have_sha256() { command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1; }

# FF_PYTHON is resolved once and EXPORTED because `xargs`/`bash -c` subprocesses
# cannot see a shell function - ff-run's ADR sweep needs the binary name, not ff_python.
#
# The probe EXECUTES each candidate instead of trusting `command -v`. Windows
# installs App Execution Alias stubs for `python3`/`python` that resolve on PATH,
# print a Microsoft Store advert to stderr, and exit non-zero - so a PATH-only
# check picks a interpreter that cannot run anything. Verified on this box
# 2026-08-23: `command -v python3` succeeds while `python3 -c pass` fails.
FF_PYTHON=""
for _ffpy in python3 python py; do
  if command -v "$_ffpy" >/dev/null 2>&1 && "$_ffpy" -c "" >/dev/null 2>&1; then
    FF_PYTHON="$_ffpy"; break
  fi
done
unset _ffpy
export FF_PYTHON
ff_python() { [ -n "$FF_PYTHON" ] || return 127; "$FF_PYTHON" "$@"; }
ff_have_python() { [ -n "$FF_PYTHON" ]; }

# Does this fleet-worker launcher declare the claude-bin-override capability?
# ONE implementation consumed by ff-doctor (parity check) and ff-spawn (glm
# preflight) so the two can never diverge. This is a machine-readable
# handshake (`--capabilities`, exit 0, exact token line) - the previous
# textual grep was spoofable by a comment containing the variable name
# (codex review round 5). Auth env vars are STRIPPED for the probe so a
# pre-handshake launcher deterministically stops at its own key-resolution
# guard (exit 5) instead of ever exec'ing claude with an unknown flag.
ff_fw_has_claude_bin_override() {
  _ffcap="$(env -u ANTHROPIC_AUTH_TOKEN -u ZHIPU_API_KEY -u GLM_API_KEY \
                -u FLEET_WORKER_KEYRING_SERVICE -u FLEET_WORKER_KEYRING_KEY \
            timeout 15 bash "$1" --capabilities 2>/dev/null)" || return 1
  printf '%s\n' "$_ffcap" | tr -d '\r' | grep -qx "claude-bin-override"
}

# ff_host_watchers REPO -> one line per registered Process Compose service whose
# working_dir IS this repo and whose command looks like a file watcher:
#     name<TAB>command<TAB>ignored        ignored: yes | no | unknown
# `ignored` says whether the repo's bundler/watcher config mentions `.fleetflow`
# (unknown = no recognised config file found). Exit 3 when the services file
# is absent - that is the normal case on any machine but this author's stack,
# and callers must treat it as "not applicable", never as "clean".
# ONE implementation consumed by ff-doctor (machine-wide row) and ff-plan lint
# (per-repo finding) so the two never disagree about what a watcher is.
# WHY THIS EXISTS (2026-09-10, ADR-038): lane worktrees live INSIDE the host
# repo under .fleetflow/<run>/wt-<id>, so any dev server watching that repo
# crawls every new lane, node_modules included, and never releases the module
# graph. A Vite service reached 87.9 GB of private commit and 0.2 GB free
# machine-wide before anyone looked; a restart freed it instantly. The fix in
# the victim is one line (server.watch.ignored: ['**/.fleetflow/**']); this
# helper is how fleetflow says so BEFORE the next victim.
ff_host_watchers() {
  _ffhw_repo="$1"
  _ffhw_yaml="${FLEETFLOW_HOST_SERVICES:-X:/00_Orchestration/compose-portless/process-compose.yaml}"
  [ -f "$_ffhw_yaml" ] || return 3
  _ffhw_want="$(printf '%s' "$_ffhw_repo" | tr '\\' '/' | sed 's:/*$::' | tr 'A-Z' 'a-z')"
  # services are 2-space keys; command/working_dir are their 4-space children.
  # Quoted or bare values both occur in the file.
  awk -v want="$_ffhw_want" '
    function strip(s) { gsub(/^[ \t]*["'"'"']?|["'"'"']?[ \t]*$/, "", s); return s }
    function norm(s)  { s = strip(s); gsub(/\\/, "/", s); sub(/\/+$/, "", s); return tolower(s) }
    function flush() {
      if (name != "" && wd == want &&
          cmd ~ /(vite|webpack|next|nuxt|astro|remix|parcel|turbo|nodemon|tsx watch|--watch|--reload)/)
        print name "\t" cmd
      name = ""; wd = ""; cmd = ""
    }
    /^  [A-Za-z0-9_.-]+:[ \t]*$/ { flush(); name = $1; sub(/:$/, "", name); next }
    /^    command:/     { sub(/^    command:/, "");     cmd = strip($0); next }
    /^    working_dir:/ { sub(/^    working_dir:/, ""); wd  = norm($0);  next }
    END { flush() }
  ' "$_ffhw_yaml" | tr -d '\r' | while IFS="$(printf '\t')" read -r _ffhw_n _ffhw_c; do
    [ -n "$_ffhw_n" ] || continue
    _ffhw_ign=unknown
    for _ffhw_f in "$_ffhw_repo"/vite.config.* "$_ffhw_repo"/webpack.config.* \
                   "$_ffhw_repo"/next.config.* "$_ffhw_repo"/nuxt.config.* \
                   "$_ffhw_repo"/astro.config.* "$_ffhw_repo"/nodemon.json; do
      [ -f "$_ffhw_f" ] || continue
      if grep -q '\.fleetflow' "$_ffhw_f"; then _ffhw_ign=yes; break; else _ffhw_ign=no; fi
    done
    printf '%s\t%s\t%s\n' "$_ffhw_n" "$_ffhw_c" "$_ffhw_ign"
  done
}
