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

# --- lane placement (ADR-040) --------------------------------------------------
# THE ONE PLACE a lane worktree's path is decided. Before this section, ten
# scripts built `$REPO/.fleetflow/$RUN/wt-$ID` by hand at 27 sites, which is
# what made "put lanes somewhere a dev server cannot crawl" (ADR-038's
# non-goal) untouchable. Two resolvers, and the split between them is the
# safety property - do not merge them:
#
#   ff_lane_dir REPO RUN ID    CREATION resolver. Consults FLEETFLOW_LANES_ROOT.
#                              Unset (default): <repo>/.fleetflow/<run>/wt-<id>,
#                              byte-for-byte the path every script built before.
#                              Set: <root>/<repo-slug>/<run>/wt-<id> - outside
#                              the host repo, so no watcher serving it can
#                              ever see the lane. ONLY ff-spawn and ff-chip
#                              (the two lane creators) may call this.
#   ff_lane_path REPO RUN ID   READER resolver. NEVER consults the env var: the
#                              lane is wherever the journal's `started` record
#                              says it is (`worktree` field, written only when
#                              a lanes root was in use), else the in-repo path.
#                              A reader that consulted the env var would probe
#                              or RECLAIM a guessed location whenever the
#                              variable differed from spawn time - which is why
#                              ff-status/clean/sweep/collect/chip-close all go
#                              through here. An outside path that the journal
#                              does not name is not fleetflow's to touch.
#
# Run artifacts (journal, prompts, results, events, manifest) NEVER move: the
# run dir is always <repo>/.fleetflow/<run> (ff_run_dir), which is what keeps
# discovery (ff-sweep, ff-aggregate) and the info/exclude mechanism unchanged.
ff_run_dir() { printf '%s/.fleetflow/%s\n' "${1%/}" "$2"; }

# ff_repo_slug REPO -> <basename>-<8 hex>: readable AND collision-free. The
# hash is over the canonical path (absolute, forward slashes, no trailing
# slash, lowercased - NTFS is case-insensitive and Git Bash hands the same
# directory over as /x/forge/f, X:/Forge/f or X:\Forge\f depending on who
# asked). The claude-projects encoding ([:\/.] -> "-") was rejected for this
# job: `X:/a.b` and `X:/a-b` collide under it, and a collision here would
# make two repos' runs share one lane directory. Falls back to that encoding
# only when no sha256 implementation exists at all (ff_sha256 - never on a
# host that can run ff-spawn, which already hard-requires one).
ff_repo_slug() {
  _ffrs_abs="$(cd "$1" 2>/dev/null && { pwd -W 2>/dev/null || pwd -P; })" || _ffrs_abs="$1"
  _ffrs_key="$(printf '%s' "$_ffrs_abs" | tr '\\' '/' | sed 's:/*$::' | tr 'A-Z' 'a-z')"
  _ffrs_base="${_ffrs_key##*/}"; [ -n "$_ffrs_base" ] || _ffrs_base="repo"
  if ff_have_sha256; then
    printf '%s-%s\n' "$_ffrs_base" "$(printf '%s' "$_ffrs_key" | ff_sha256 | cut -c1-8)"
  else
    printf '%s\n' "$_ffrs_key" | sed 's#[:\\/.]#-#g'
  fi
}

ff_lane_dir() {
  if [ -n "${FLEETFLOW_LANES_ROOT:-}" ]; then
    # Canonicalised the same way ff-spawn canonicalises REPO (`pwd -W`, the
    # drive-letter flavour): the path lands in the journal and in the claude
    # transcript encoding (ADR-021), and a /c/Users POSIX spelling would
    # encode a project slug claude never writes. Only an existing root can be
    # canonicalised; the creators mkdir it first, readers never need to.
    _ffld_root="${FLEETFLOW_LANES_ROOT%/}"
    [ -d "$_ffld_root" ] && _ffld_root="$(cd "$_ffld_root" && { pwd -W 2>/dev/null || pwd -P; })"
    printf '%s/%s/%s/wt-%s\n' "$_ffld_root" "$(ff_repo_slug "$1")" "$2" "$3"
  else
    printf '%s/.fleetflow/%s/wt-%s\n' "${1%/}" "$2" "$3"
  fi
}

# ff_lane_journalled RUNDIR ID -> the `worktree` field of the LAST started
# record for ID, or nothing. Last wins because a --force respawn appends a
# fresh started record and the lane may have moved between them.
ff_lane_journalled() {
  [ -f "$1/journal.jsonl" ] || return 0
  jq -r --arg id "$2" 'select(.type=="started" and .id==$id) | .worktree // empty' \
    "$1/journal.jsonl" 2>/dev/null | tr -d '\r' | tail -1
}

ff_lane_path() {
  _fflp="$(ff_lane_journalled "$(ff_run_dir "$1" "$2")" "$3")"
  [ -n "$_fflp" ] && printf '%s\n' "$_fflp" || printf '%s/.fleetflow/%s/wt-%s\n' "${1%/}" "$2" "$3"
}

# ff_lanes_journalled RUNDIR -> every lane dir the journal names, one per
# line (id<TAB>path, last started record per id wins). The list ff-clean and
# ff-sweep add to their in-repo wt-* walk: an outside lane exists for them
# ONLY through this list (ADR-040 widens ADR-020's boundary by exactly this).
ff_lanes_journalled() {
  [ -f "$1/journal.jsonl" ] || return 0
  jq -sr '[.[] | select(.type=="started" and (.worktree // "") != "")]
          | group_by(.id) | map(last) | .[] | [.id, .worktree] | @tsv' \
    "$1/journal.jsonl" 2>/dev/null | tr -d '\r'
}

# ff_lanes_root_in_use -> 0 when lanes are being placed outside the repo.
# Creators use it to decide whether to journal the path; readers must not.
ff_lanes_root_in_use() { [ -n "${FLEETFLOW_LANES_ROOT:-}" ]; }

# --- machine headroom (ADR-041) ------------------------------------------------
# ff_commit_headroom -> "free_mb<TAB>total_mb<TAB>source", exit 3 when the
# platform cannot be measured (callers must read that as "not applicable",
# never as "plenty").
#
# COMMIT, NOT RAM, and the distinction is the whole point. Windows dies of
# commit exhaustion with RAM still free: on 2026-09-10 this box wedged at
# 0.2 GB commit free with 28 GB of RAM idle, and a "free RAM" reading would
# have said healthy every single time. Measured minutes apart on the same box:
# commit free 61.6 GB vs RAM free 33.1 GB - two different numbers, and only
# one of them is the one that kills the machine. Linux gets the analogous
# figure (MemAvailable + SwapFree), which is what its own overcommit accounting
# spends.
ff_commit_headroom() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      command -v powershell.exe >/dev/null 2>&1 || return 3
      # FreeVirtualMemory/TotalVirtualMemorySize are KB and are the COMMIT
      # figures (page file + physical), not the working set.
      MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -NonInteractive -Command \
        '$o = Get-CimInstance Win32_OperatingSystem; "{0} {1}" -f $o.FreeVirtualMemory, $o.TotalVirtualMemorySize' \
        2>/dev/null | tr -d '\r' \
        | awk 'NF==2 && $1+0>0 { printf "%d\t%d\twin32_operatingsystem\n", $1/1024, $2/1024; f=1 } END { exit !f }' \
        || return 3
      ;;
    Linux)
      [ -r /proc/meminfo ] || return 3
      awk '/^MemAvailable:/{a=$2} /^SwapFree:/{s=$2} /^MemTotal:/{mt=$2} /^SwapTotal:/{st=$2}
           END { if (a=="") exit 1; printf "%d\t%d\tproc_meminfo\n", (a+s)/1024, (mt+st)/1024 }' \
        /proc/meminfo || return 3
      ;;
    Darwin)
      command -v vm_stat >/dev/null 2>&1 || return 3
      # free + inactive pages are what a new process can actually get; swap is
      # dynamic on macOS, so this is an approximation and says so in `source`.
      _ffch_ps="$(vm_stat 2>/dev/null | awk -F'[ .]+' '/page size of/{print $8}')"
      [ -n "$_ffch_ps" ] || _ffch_ps=4096
      vm_stat 2>/dev/null | awk -F'[:.]+' -v ps="$_ffch_ps" -v tot="$(sysctl -n hw.memsize 2>/dev/null)" '
        /Pages free/{f=$2} /Pages inactive/{i=$2}
        END { if (tot=="") exit 1; printf "%d\t%d\tvm_stat_approx\n", (f+i)*ps/1048576, tot/1048576 }' || return 3
      ;;
    *) return 3 ;;
  esac
}

# ff_lane_capacity -> "lanes<TAB>free_mb<TAB>reserve_mb<TAB>per_lane_mb<TAB>source"
# How many CONCURRENT lanes this machine's headroom supports right now:
#   floor((free - reserve) / per_lane), clamped to [1, FLEETFLOW_MAX_CONCURRENT].
# Exit 3 (and no output) where headroom cannot be measured.
#
# Deliberately NOT calibrated from the running process table, though that was
# the obvious idea. Measured here 2026-09-10: 90 node processes averaging
# 262 MB with a single dev server at 11,943 MB, and 53 claude processes
# averaging 335 MB most of which are idle session hosts, not lane workers. A
# mean over that distribution is meaningless and a max is absurd. Honest
# calibration needs a per-lane peak the JOURNAL records (ff-spawn sampling its
# worker), which does not exist yet - see the ADR. Until it does, the estimate
# is a documented constant the operator can tune, not a fabricated measurement.
ff_lane_capacity() {
  _fflc_hr="$(ff_commit_headroom)" || return 3
  _fflc_free="${_fflc_hr%%	*}"
  _fflc_src="${_fflc_hr##*	}"
  _fflc_per="${FLEETFLOW_LANE_MEMORY_MB:-1500}"
  _fflc_res="${FLEETFLOW_MEMORY_RESERVE_MB:-16384}"
  _fflc_max="${FLEETFLOW_MAX_CONCURRENT:-16}"
  case "$_fflc_per$_fflc_res$_fflc_max" in *[!0-9]*) return 3 ;; esac
  [ "$_fflc_per" -gt 0 ] || return 3
  _fflc_n=$(( (_fflc_free - _fflc_res) / _fflc_per ))
  # Floor of 1, never 0: "spawn nothing" is not a verdict this may reach on its
  # own. A box with no headroom gets ONE lane and a loud row, because refusing
  # outright is what gets a check disabled (the ADR-038 reasoning).
  [ "$_fflc_n" -ge 1 ] || _fflc_n=1
  [ "$_fflc_n" -le "$_fflc_max" ] || _fflc_n="$_fflc_max"
  printf '%s\t%s\t%s\t%s\t%s\n' "$_fflc_n" "$_fflc_free" "$_fflc_res" "$_fflc_per" "$_fflc_src"
}
