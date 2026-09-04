#!/usr/bin/env bash
# ff-plan — author, lint, refute, and estimate a fleet run plan BEFORE spawn.
#
# Contract: stdout is data, chatter on stderr; exit 0 ok, 2 usage/refused
# overwrite, 3 missing/unimplemented, 10 findings. ff-plan authors the plan
# sibling in the manifest without changing the frozen phases[] string array
# (ADR-026); lint gates spawn and reports every check armed/disarmed (ADR-030).

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
RS=$'\036'

usage() {
  cat <<'EOF' >&2
ff-plan — plan a fleet run: draft, expand, lint, refute, estimate

USAGE
  ff-plan.sh draft    --run NAME --spec FILE [--shape feature|review|research|migrate|app]
                      [--packets "id=Role/class/model,..."] [--force] [--repo P]
  ff-plan.sh expand   --run NAME --generator NAME --vars FILE [--repo P]
  ff-plan.sh lint     --run NAME [--json] [--repo P]
  ff-plan.sh refute   --run NAME [--model codex|grok|glm|pi] [--repo P]
  ff-plan.sh estimate --run NAME [--repo P]

EXAMPLES
  bash scripts/ff-plan.sh draft --run shopfront --spec spec/shopfront.md --shape app \
    --packets "api=Builder/build/codex,verify=Adversary/verify/grok"
  bash scripts/ff-plan.sh lint --run shopfront

EXIT CODES
  0 ok · 2 usage/refused overwrite · 3 missing/unimplemented · 10 findings
EOF
}

err() { echo "ff-plan: $*" >&2; }
jqr() { jq -r "$@" | tr -d '\r'; }
need_value() { [ "$1" -ge 2 ] || { err "$2 requires a value"; usage; exit 2; }; }
valid_run() { [[ "$1" =~ ^[a-z0-9-]+$ ]]; }
default_repo() {
  local prefix repo="." part
  prefix="$(git rev-parse --show-prefix 2>/dev/null | tr -d '\r')" || return 1
  prefix="${prefix%/}"
  if [ -n "$prefix" ]; then
    IFS='/' read -r -a _ff_parts <<< "$prefix"
    for part in "${_ff_parts[@]}"; do repo="../$repo"; done
  fi
  printf '%s\n' "$repo"
}
resolve_repo() { if [ -n "$1" ]; then printf '%s\n' "$1"; else default_repo; fi; }
require_repo() {
  [ -d "$1" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || {
    err "not in a git repo (or --repo invalid)"; exit 2;
  }
}
require_run() {
  [ -n "$1" ] || { err "--run is required"; usage; exit 2; }
  valid_run "$1" || { err "invalid run name '$1' (expected [a-z0-9-]+)"; exit 2; }
}
repo_file() { if [ "$1" = "." ]; then printf '%s\n' "$2"; else printf '%s/%s\n' "${1%/}" "$2"; fi; }

# Restricted YAML subset: flat scalars plus two-space list items between the
# first two delimiter lines. Inline [] is the template's empty-list spelling.
has_frontmatter() { awk '{sub(/\r$/,"")} $0=="---"{n++;if(n==2)exit} END{exit !(n>=2)}' "$1"; }
fm_scalar() {
  local file="$1" wanted="$2"
  awk -v wanted="$wanted" '
    {sub(/\r$/,"")} $0=="---"{marks++;if(marks==2)exit;next}
    marks==1 && $0~"^"wanted":[[:space:]]*"{
      v=$0;sub("^[^:]+:[[:space:]]*","",v)
      # A blank scalar whose line carries only a trailing comment must read
      # as empty, not as the comment text (the packet template writes every
      # placeholder line in exactly that style).
      if(v~/^#/){v=""}else{sub(/[[:space:]]+#.*$/, "",v)}
      gsub(/^[[:space:]]+|[[:space:]]+$/, "",v);if(v!="[]"&&v!="null")print v;exit
    }' "$file" | tr -d '\r'
}
fm_list() {
  local file="$1" wanted="$2"
  awk -v wanted="$wanted" '
    {sub(/\r$/,"")} $0=="---"{marks++;if(marks==2)exit;current="";next} marks!=1{next}
    /^[a-z_]+:[[:space:]]*/{
      key=$0;sub(/:.*/,"",key);v=$0;sub("^[^:]+:[[:space:]]*","",v)
      sub(/[[:space:]]+#.*$/, "",v);gsub(/^[[:space:]]+|[[:space:]]+$/, "",v)
      current=(key==wanted&&v=="")?wanted:"";next
    }
    current==wanted&&/^  -[[:space:]]+/{
      v=$0;sub(/^  -[[:space:]]+/,"",v);sub(/[[:space:]]+#.*$/, "",v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "",v);if(v!="")print v
    }' "$file" | tr -d '\r'
}
packet_id() {
  local v; v="$(fm_scalar "$1" id)"
  if [ -n "$v" ]; then printf '%s\n' "$v"; else v="${1##*/}"; printf '%s\n' "${v%.task.md}"; fi
}
json_array() { if [ "$#" -eq 0 ]; then printf '[]\n'; else printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]' | tr -d '\r'; fi; }

render_plan_template() {
  local template="$1" target="$2" run="$3" date="$4" spec="$5" line
  : > "$target"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//'{{RUN}}'/$run}"; line="${line//'{{DATE}}'/$date}"; line="${line//'{{SPEC_PATH}}'/$spec}"
    printf '%s\n' "$line" >> "$target"
  done < "$template"
}
render_packet_template() {
  local template="$1" target="$2" id="$3" role="$4" class="$5" model="$6" card="$7" line
  : > "$target"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//'{{ID}}'/$id}"; line="${line//'{{ROLE}}'/$role}"
    line="${line//'{{CLASS}}'/$class}"; line="${line//'{{MODEL}}'/$model}"
    if [[ "$line" == *"role card prepended here by ff-plan draft"* ]] && [ -f "$card" ]; then
      cat "$card" >> "$target"; printf '\n' >> "$target"
    else printf '%s\n' "$line" >> "$target"; fi
  done < "$template"
}

draft_cmd() {
  local run="" spec="" shape="feature" packets_arg="" force=0 repo_arg="" repo
  local plan_template packet_template plan_dir plan_file run_dir packet_dir manifest base today month upper
  local entry id rhs role class model packet_file card prompt existing='{}' packet_json='[]' tmp
  local -a entries=() ids=() roles=() classes=() models=() blockers=()
  while [ "$#" -gt 0 ]; do case "$1" in
    --run) need_value "$#" "$1"; run="$2"; shift 2;; --spec) need_value "$#" "$1"; spec="$2"; shift 2;;
    --shape) need_value "$#" "$1"; shape="$2"; shift 2;; --packets) need_value "$#" "$1"; packets_arg="$2"; shift 2;;
    --force) force=1; shift;; --repo) need_value "$#" "$1"; repo_arg="$2"; shift 2;;
    -h|--help) usage; return 0;; *) err "unknown draft argument: $1"; usage; return 2;; esac; done
  require_run "$run"; [ -n "$spec" ] || { err "draft requires --spec"; usage; return 2; }
  case "$shape" in feature|review|research|migrate|app);; *) err "invalid shape '$shape'"; return 2;; esac
  repo="$(resolve_repo "$repo_arg")" || { err "not in a git repo"; return 2; }; require_repo "$repo"
  # --spec accepts a path as given (absolute or cwd-relative) or repo-relative.
  [ -f "$spec" ] || [ -f "$(repo_file "$repo" "$spec")" ] || { err "spec file missing: $spec"; return 3; }
  if [ -n "$packets_arg" ]; then
    IFS=',' read -r -a entries <<< "$packets_arg"
    for entry in "${entries[@]}"; do
      id="${entry%%=*}"; rhs="${entry#*=}"
      if [ "$id" = "$entry" ] || [[ "$rhs" != */*/* ]]; then err "invalid --packets entry '$entry'"; return 2; fi
      role="${rhs%%/*}"; rhs="${rhs#*/}"; class="${rhs%%/*}"; model="${rhs#*/}"
      # Each field must be individually non-empty; concatenation hides a blank.
      if ! valid_run "$id" || [ -z "$role" ] || [ -z "$class" ] || [ -z "$model" ] || [[ "$model" == */* ]]; then err "invalid --packets entry '$entry'"; return 2; fi
      for value in "${ids[@]}"; do [ "$value" != "$id" ] || { err "duplicate packet id '$id' in --packets"; return 2; }; done
      ids+=("$id"); roles+=("$role"); classes+=("$class"); models+=("$model")
    done
  fi
  # Templates ship with the SKILL, not the target repo — a planning tool must
  # work against arbitrary repos (same pattern as assets/wave-packets).
  plan_template="$SCRIPT_DIR/../assets/plan.tmpl.md"; packet_template="$SCRIPT_DIR/../assets/packet.tmpl.md"
  [ -f "$plan_template" ] && [ -f "$packet_template" ] || { err "draft templates are missing"; return 3; }
  today="$(date +%F | tr -d '\r')"; month="$(date +%Y-%m | tr -d '\r')"; upper="${run^^}"
  plan_dir="$(repo_file "$repo" docs/plans)"; plan_file="$plan_dir/$upper-$month.md"
  run_dir="$(repo_file "$repo" ".fleetflow/$run")"; packet_dir="$run_dir/packets"; manifest="$run_dir/manifest.json"
  [ ! -e "$plan_file" ] || blockers+=("$plan_file")
  for id in "${ids[@]}"; do packet_file="$packet_dir/$id.task.md"; [ ! -e "$packet_file" ] || blockers+=("$packet_file"); done
  if [ "$force" -eq 0 ] && [ "${#blockers[@]}" -gt 0 ]; then
    err "refusing to overwrite existing files (use --force):"; printf '  %s\n' "${blockers[@]}" >&2; return 2
  fi
  mkdir -p "$plan_dir" "$packet_dir"; render_plan_template "$plan_template" "$plan_file" "$run" "$today" "$spec"; err "created plan: $plan_file"
  for ((i=0;i<${#ids[@]};i++)); do
    id="${ids[$i]}"; role="${roles[$i]}"; class="${classes[$i]}"; model="${models[$i]}"; packet_file="$packet_dir/$id.task.md"
    card="$SCRIPT_DIR/../assets/roles/${role,,}.role.md"; [ -f "$card" ] || err "warning: role card missing for $role ($card); marker left in packet"
    render_packet_template "$packet_template" "$packet_file" "$id" "$role" "$class" "$model" "$card"; err "created packet: $packet_file"
    prompt=".fleetflow/$run/packets/$id.task.md"
    packet_json="$(jq -c --arg id "$id" --arg role "$role" --arg class "$class" --arg model "$model" --arg prompt "$prompt" \
      '.+[{id:$id,role:$role,class:$class,model:$model,phase:"build",prompt_file:$prompt,depends_on:[],locus:"process",gate:"auto"}]' <<< "$packet_json" | tr -d '\r')"
  done
  # Unborn HEAD (fresh repo, no commits yet) is a legal draft target — base
  # is simply unknown until the first commit.
  base="$(git -C "$repo" rev-parse HEAD 2>/dev/null | tr -d '\r' || true)"; tmp="$manifest.ff-plan.tmp"
  if [ -f "$manifest" ]; then jq -e 'type=="object"' "$manifest" >/dev/null 2>&1 || { err "manifest is malformed: $manifest"; return 3; }; existing="$(jq -c . "$manifest"|tr -d '\r')"; fi
  jq -n --argjson old "$existing" --arg run "$run" --arg base "$base" --arg shape "$shape" --argjson incoming "$packet_json" '
    ($old+{run:$run,base:($old.base//$base),created_by:"ff-plan",phases:($old.phases//[]),packets:($old.packets//[]),
      plan:(($old.plan//{})+{shape:$shape,bounds:($old.plan.bounds//"none"),barriers:($old.plan.barriers//[])})})
    | reduce $incoming[] as $p (.;if any(.packets[]?;.id==$p.id) then . else .packets+=[$p] end)' > "$tmp"
  mv "$tmp" "$manifest"; err "created or updated manifest: $manifest"; printf '%s\n' "$plan_file"
}

registry_rows() {
  awk -F'|' '/^\|/&&NF>=4{g=$2;s=$4;gsub(/`/,"",g);gsub(/^[[:space:]]+|[[:space:]]+$/, "",g);gsub(/^[[:space:]]+|[[:space:]]+$/, "",s);if(tolower(g)!="generator"&&g!~/^-+$/&&g!="")print g"\t"s}' "$1" | tr -d '\r'
}
expand_cmd() {
  local run="" generator="" vars="" repo_arg="" repo registry status="" known="" name row_status
  while [ "$#" -gt 0 ]; do case "$1" in
    --run) need_value "$#" "$1"; run="$2"; shift 2;; --generator) need_value "$#" "$1"; generator="$2"; shift 2;;
    --vars) need_value "$#" "$1"; vars="$2"; shift 2;; --repo) need_value "$#" "$1"; repo_arg="$2"; shift 2;;
    -h|--help) usage; return 0;; *) err "unknown expand argument: $1"; usage; return 2;; esac; done
  require_run "$run"; [ -n "$generator" ] && [ -n "$vars" ] || { err "expand requires --generator and --vars"; return 2; }
  repo="$(resolve_repo "$repo_arg")" || return 2; require_repo "$repo"
  # --vars accepts a path as given (absolute or cwd-relative) or repo-relative.
  [ -f "$vars" ] || [ -f "$(repo_file "$repo" "$vars")" ] || { err "vars file missing: $vars"; return 3; }
  [ -f "$(repo_file "$repo" ".fleetflow/$run/manifest.json")" ] || { err "manifest missing for run $run"; return 3; }
  registry="$SCRIPT_DIR/../references/generator-registry.md"; [ -f "$registry" ] || { err "generator registry missing"; return 3; }
  while IFS=$'\t' read -r name row_status; do known="${known:+$known, }$name"; [ "$name" = "$generator" ] && status="$row_status"; done < <(registry_rows "$registry")
  [ -n "$status" ] || { err "unknown generator '$generator' (known: ${known:-none})"; return 3; }
  if [[ "${status,,}" == *pending* ]]; then err "generator $generator is registered but has no expansion tables yet"; return 3; fi
  err "generator $generator is registered but its Status is not an expansion table: $status"; return 3
}
FINDINGS='[]'
CHECKS='[]'
add_finding() {
  FINDINGS="$(jq -c --arg check "$1" --arg severity "$2" --argjson packets "$3" --argjson files "$4" --arg detail "$5" \
    '.+[{check:$check,severity:$severity,packets:$packets,files:$files,detail:$detail}]' <<< "$FINDINGS" | tr -d '\r')"
}
add_check() {
  CHECKS="$(jq -c --arg name "$1" --argjson armed "$2" --arg reason "$3" \
    '.+[{name:$name,armed:$armed,reason:$reason}]' <<< "$CHECKS" | tr -d '\r')"
}
scope_overlap() {
  local a="$1" b="$2" ap bp ag=0 bg=0
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [[ "$a" == */ ]] && a="${a}**"; [[ "$b" == */ ]] && b="${b}**"
  [[ "$a" == *'*'* || "$a" == *'?'* || "$a" == *'['* ]] && ag=1
  [[ "$b" == *'*'* || "$b" == *'?'* || "$b" == *'['* ]] && bg=1
  if [ "$ag" -eq 0 ] && [ "$bg" -eq 0 ]; then [ "$a" = "$b" ]; return; fi
  ap="$(printf '%s' "$a" | sed 's/[?*\[].*$//')"; bp="$(printf '%s' "$b" | sed 's/[?*\[].*$//')"
  [[ "$ap" == "$bp"* || "$bp" == "$ap"* ]]
}
scope_pair_findings() {
  local fa="$1" ia="$2" ka="$3" fb="$4" ib="$5" kb="$6" severity="$7" label="$8" a b
  local -a av=() bv=(); mapfile -t av < <(fm_list "$fa" "$ka"); mapfile -t bv < <(fm_list "$fb" "$kb")
  for a in "${av[@]}"; do for b in "${bv[@]}"; do
    if scope_overlap "$a" "$b"; then
      add_finding scope-conflict "$severity" "$(json_array "$ia" "$ib")" "$(json_array "$a" "$b")" "$label: '$a' overlaps '$b'"
    fi
  done; done
}

declare -A DEP_STATE=() DEP_MAP=() ID_FILE=() DEP_INCOMING=()
CYCLE_REPORTED=0
visit_dep() {
  local id="$1" dep raw="${DEP_MAP[$1]:-}"; local -a deps=()
  DEP_STATE["$id"]=1; [ -z "$raw" ] || IFS="$RS" read -r -a deps <<< "$raw"
  for dep in "${deps[@]}"; do
    [ -n "$dep" ] && [ -n "${ID_FILE[$dep]:-}" ] || continue
    if [ "${DEP_STATE[$dep]:-0}" -eq 1 ] && [ "$CYCLE_REPORTED" -eq 0 ]; then
      add_finding dep-edges hard "$(json_array "$dep" "$id")" '[]' "dependency cycle includes $dep and $id"; CYCLE_REPORTED=1
    elif [ "${DEP_STATE[$dep]:-0}" -eq 0 ]; then visit_dep "$dep"; fi
  done
  DEP_STATE["$id"]=2; return 0
}

lint_cmd() {
  local run="" json_mode=0 repo_arg="" repo run_dir manifest packet_dir file id role class model dep value reason
  local fm_count=0 legacy_count=0 legacy_reason="" adr_armed=0 adr_disarmed="" adr_script rc adr_output
  local -a files=() fm_files=() legacy_ids=() ids=() av=() bv=() deps=() owned=() replies=()
  FINDINGS='[]'; CHECKS='[]'; DEP_STATE=(); DEP_MAP=(); ID_FILE=(); DEP_INCOMING=(); CYCLE_REPORTED=0
  while [ "$#" -gt 0 ]; do case "$1" in
    --run) need_value "$#" "$1"; run="$2"; shift 2;; --json) json_mode=1; shift;;
    --repo) need_value "$#" "$1"; repo_arg="$2"; shift 2;; -h|--help) usage; return 0;;
    *) err "unknown lint argument: $1"; usage; return 2;; esac; done
  require_run "$run"; repo="$(resolve_repo "$repo_arg")" || return 2; require_repo "$repo"
  run_dir="$(repo_file "$repo" ".fleetflow/$run")"; manifest="$run_dir/manifest.json"; packet_dir="$run_dir/packets"
  # A missing manifest never blocks the packet checks (ADR-030: report
  # disarmed, don't refuse) — only the manifest-dependent checks (f)/(g)
  # degrade. A PRESENT but malformed manifest is still fatal.
  if [ -f "$manifest" ]; then
    jq -e 'type=="object"' "$manifest" >/dev/null 2>&1 || { err "manifest is malformed: $manifest"; return 3; }
  else manifest=""; fi
  shopt -s nullglob; files=("$packet_dir"/*.task.md); shopt -u nullglob
  for file in "${files[@]}"; do
    id="$(packet_id "$file")"
    if has_frontmatter "$file"; then fm_files+=("$file"); ids+=("$id"); ID_FILE["$id"]="$file"; fm_count=$((fm_count+1))
    else legacy_ids+=("$id"); legacy_count=$((legacy_count+1)); fi
  done
  [ "$legacy_count" -eq 0 ] || legacy_reason="; disarmed(no frontmatter): $(IFS=,; echo "${legacy_ids[*]}")"

  # (a) owns/modifies globs and registry single-writer.
  for ((i=0;i<${#fm_files[@]};i++)); do for ((j=i+1;j<${#fm_files[@]};j++)); do
    local fa="${fm_files[$i]}" fb="${fm_files[$j]}" ia="${ids[$i]}" ib="${ids[$j]}"
    scope_pair_findings "$fa" "$ia" owns "$fb" "$ib" owns hard "owns×owns"
    scope_pair_findings "$fa" "$ia" owns "$fb" "$ib" modifies warn "owns×modifies"
    scope_pair_findings "$fb" "$ib" owns "$fa" "$ia" modifies warn "owns×modifies"
    scope_pair_findings "$fa" "$ia" modifies "$fb" "$ib" modifies warn "modifies×modifies"
    mapfile -t av < <(fm_list "$fa" registries); mapfile -t bv < <(fm_list "$fb" registries)
    for value in "${av[@]}"; do for dep in "${bv[@]}"; do
      [ -z "$value" ] || [ "$value" != "$dep" ] || add_finding scope-conflict hard "$(json_array "$ia" "$ib")" "$(json_array "$value")" "registries single-writer conflict: $value"
    done; done
  done; done
  if [ "$fm_count" -gt 0 ]; then add_check scope-conflict true "checked $fm_count packet(s)$legacy_reason"; else add_check scope-conflict false "no frontmatter"; fi

  # (b) dependency membership, cycle, and orphan checks.
  for ((i=0;i<${#fm_files[@]};i++)); do
    file="${fm_files[$i]}"; id="${ids[$i]}"; mapfile -t deps < <(fm_list "$file" depends_on)
    DEP_MAP["$id"]="$(IFS="$RS"; echo "${deps[*]}")"
    for dep in "${deps[@]}"; do
      if [ -z "${ID_FILE[$dep]:-}" ]; then add_finding dep-edges hard "$(json_array "$id")" '[]' "depends_on id '$dep' is not in the packet set"
      else DEP_INCOMING["$dep"]=$(( ${DEP_INCOMING[$dep]:-0} + 1 )); fi
    done
  done
  for id in "${ids[@]}"; do [ "${DEP_STATE[$id]:-0}" -ne 0 ] || visit_dep "$id"; done
  if [ "$fm_count" -gt 3 ]; then for id in "${ids[@]}"; do
    if [ -z "${DEP_MAP[$id]:-}" ] && [ "${DEP_INCOMING[$id]:-0}" -eq 0 ]; then
      add_finding dep-edges warn "$(json_array "$id")" '[]' "orphan packet has no incoming or outgoing dependency edge"
    fi
  done; fi
  if [ "$fm_count" -gt 0 ]; then add_check dep-edges true "checked $fm_count packet(s)$legacy_reason"; else add_check dep-edges false "no frontmatter"; fi

  # (c) adr-touching exit 10 requires the standing-decisions heading.
  # adr-touching.py accepts EXACTLY ONE positional query and exits 2 (usage) on
  # more, so this MUST loop once per owned path. A single call carrying every
  # owned path returned rc=2, which reads as "tool unavailable" and disarmed the
  # whole check silently — governing ADR BLUFs went unverified for every packet
  # (observed 2026-09-04). ADR-030: disarmed must mean genuinely absent, never a
  # wrong invocation. --dir is pinned to the TARGET repo so the verdict comes
  # from the planned repo's decision record rather than ff-plan's cwd.
  adr_script="$HOME/.claude/skills/adr-ops/scripts/adr-touching.py"
  if [ ! -f "$adr_script" ]; then add_check adr-constraints false "adr-touching.py unavailable$legacy_reason"
  else
    local owned_path pkt_ok pkt_gov pkt_rc
    local -a governed=()
    for ((i=0;i<${#fm_files[@]};i++)); do
      file="${fm_files[$i]}"; id="${ids[$i]}"; mapfile -t owned < <(fm_list "$file" owns)
      if [ "${#owned[@]}" -eq 0 ]; then adr_disarmed="${adr_disarmed:+$adr_disarmed, }$id(no owned paths)"; continue; fi
      pkt_ok=1; pkt_gov=0; pkt_rc=""; governed=()
      for owned_path in "${owned[@]}"; do
        set +e
        adr_output="$(ff_python "$adr_script" --json --dir "$repo/docs/adr" "$owned_path" 2>&1)"; rc=$?
        set -e
        case "$rc" in
          0) ;;
          10) pkt_gov=1; governed+=("$owned_path");;
          # Any other rc is an unanswered query: the packet's verdict is
          # incomplete, so it reports disarmed WITH the rc rather than passing.
          *) pkt_ok=0; pkt_rc="$rc"; [ -z "$adr_output" ] || err "adr-touching $id $owned_path: $adr_output";;
        esac
      done
      if [ "$pkt_ok" -eq 0 ]; then
        adr_disarmed="${adr_disarmed:+$adr_disarmed, }$id(adr-touching rc=$pkt_rc)"; continue
      fi
      adr_armed=$((adr_armed+1))
      if [ "$pkt_gov" -eq 1 ] && ! grep -qi "constraints from standing decisions" "$file"; then
        add_finding adr-constraints hard "$(json_array "$id")" "$(json_array "${governed[@]}")" "governing ADRs found but packet lacks the Constraints from standing decisions heading"
      fi
    done
    if [ "$adr_armed" -gt 0 ]; then add_check adr-constraints true "checked $adr_armed packet(s)${adr_disarmed:+; disarmed: $adr_disarmed}$legacy_reason"
    else add_check adr-constraints false "${adr_disarmed:-no owned paths}$legacy_reason"; fi
  fi

  # (d) packet-contract enums and final_reply for mutators.
  local valid_roles=" Architect Oracle Scout Surveyor Scholar Builder Inspector Adversary Judge Critic Composer Warden "
  local valid_classes=" mechanical scout build verify judge generator interactive " valid_models=" glm codex grok pi sonnet haiku opus fable chip " scalar_reply
  for ((i=0;i<${#fm_files[@]};i++)); do
    file="${fm_files[$i]}"; id="${ids[$i]}"; role="$(fm_scalar "$file" role)"; class="$(fm_scalar "$file" class)"; model="$(fm_scalar "$file" model)"
    [[ "$valid_roles" == *" $role "* ]] || add_finding packet-contract hard "$(json_array "$id")" "$(json_array "$file")" "invalid role '$role'"
    [[ "$valid_classes" == *" $class "* ]] || add_finding packet-contract hard "$(json_array "$id")" "$(json_array "$file")" "invalid class '$class'"
    [[ "$valid_models" == *" $model "* ]] || add_finding packet-contract hard "$(json_array "$id")" "$(json_array "$file")" "invalid model '$model'"
    mapfile -t replies < <(fm_list "$file" final_reply); scalar_reply="$(fm_scalar "$file" final_reply)"
    if [[ " mechanical build generator " == *" $class "* ]] && [ "${#replies[@]}" -eq 0 ] && [ -z "$scalar_reply" ]; then
      add_finding packet-contract warn "$(json_array "$id")" "$(json_array "$file")" "file-mutating class '$class' has empty final_reply"
    fi
  done
  if [ "$fm_count" -gt 0 ]; then add_check packet-contract true "checked $fm_count packet(s)$legacy_reason"; else add_check packet-contract false "no frontmatter"; fi

  # (e) routing sanity.
  for ((i=0;i<${#fm_files[@]};i++)); do
    file="${fm_files[$i]}"; id="${ids[$i]}"; role="$(fm_scalar "$file" role)"; class="$(fm_scalar "$file" class)"; model="$(fm_scalar "$file" model)"
    if [[ " verify judge " == *" $class "* ]] && [[ " glm haiku " == *" $model "* ]]; then add_finding routing warn "$(json_array "$id")" "$(json_array "$file")" "under-powered judge"; fi
    if [ "$role" = Adversary ] && [ "$class" = mechanical ]; then add_finding routing warn "$(json_array "$id")" "$(json_array "$file")" "Adversary role cannot use mechanical class"; fi
  done
  if [ "$fm_count" -gt 0 ]; then add_check routing true "checked $fm_count packet(s)$legacy_reason"; else add_check routing false "no frontmatter"; fi

  # (f) every barrier under manifest.plan must name a non-empty string join.
  if [ -z "$manifest" ]; then add_check barriers false "no manifest"
  elif jq -e 'has("plan")' "$manifest" >/dev/null 2>&1; then
    while IFS= read -r value; do [ -z "$value" ] || add_finding barriers warn '[]' '[]' "$value"; done < <(
      jq -r '.plan.barriers//[]|to_entries[]|select((((.value.joins? //"")|type)!="string") or (((.value.joins? //"")|length)==0))|"barrier \(.key) has empty joins"' "$manifest" | tr -d '\r')
    add_check barriers true "manifest plan.barriers checked"
  else add_check barriers false "manifest has no plan key"; fi

  # (g) absent bounds is a finding; the value "none" is valid. No manifest at
  # all disarms the check rather than manufacturing a finding.
  if [ -z "$manifest" ]; then add_check bounds false "no manifest"
  elif jq -e '(.plan? | type)=="object" and (.plan|has("bounds"))' "$manifest" >/dev/null 2>&1; then add_check bounds true "manifest plan.bounds declared"
  else add_finding bounds warn '[]' '[]' "manifest plan.bounds is absent"; add_check bounds true "manifest checked; plan.bounds absent"; fi

  local result count
  result="$(jq -cn --argjson findings "$FINDINGS" --argjson checks "$CHECKS" '{findings:$findings,checks:$checks}' | tr -d '\r')"; count="$(jqr '.findings|length' <<< "$result")"
  if [ "$json_mode" -eq 1 ]; then printf '%s\n' "$result"
  else
    jq -r '.findings[]|"FINDING \(.check) \(.severity) \(if (.packets|length)>0 then (.packets|join(",")) else "-" end) — \(.detail)"' <<< "$result" | tr -d '\r'
    jq -r '.checks[]|"CHECK \(.name) \(if .armed then "armed" else "disarmed("+.reason+")" end)"' <<< "$result" | tr -d '\r'
  fi
  [ "$count" -eq 0 ] || return 10
}
choose_refute_model() {
  local manifest="$1" candidate used
  for candidate in codex grok pi glm; do
    used="$(jqr --arg model "$candidate" '[.packets[]? |select((.model//.brain)==$model)]|length' "$manifest")"
    if [ "$used" -eq 0 ]; then printf '%s\n' "$candidate"; return; fi
  done
  printf 'pi\n'
}
refute_cmd() {
  local run="" model="" repo_arg="" repo manifest packet_dir packet plan_dir plan_doc role_card spawn collect
  local spawn_output final rc findings=0 line severity claim finding_json append_output id file
  local -a plans=() packet_files=() owned=() deps=()
  while [ "$#" -gt 0 ]; do case "$1" in
    --run) need_value "$#" "$1"; run="$2"; shift 2;; --model) need_value "$#" "$1"; model="$2"; shift 2;;
    --repo) need_value "$#" "$1"; repo_arg="$2"; shift 2;; -h|--help) usage; return 0;;
    *) err "unknown refute argument: $1"; usage; return 2;; esac; done
  require_run "$run"; case "$model" in ""|codex|grok|glm|pi);; *) err "invalid refute model '$model'"; return 2;; esac
  repo="$(resolve_repo "$repo_arg")" || return 2; require_repo "$repo"
  manifest="$(repo_file "$repo" ".fleetflow/$run/manifest.json")"; [ -f "$manifest" ] || { err "manifest missing for run $run"; return 3; }
  jq -e 'type=="object"' "$manifest" >/dev/null 2>&1 || { err "manifest is malformed: $manifest"; return 3; }
  [ -n "$model" ] || model="$(choose_refute_model "$manifest")"
  packet_dir="$(repo_file "$repo" ".fleetflow/$run/packets")"; mkdir -p "$packet_dir"; packet="$packet_dir/plan-adversary.task.md"
  role_card="$SCRIPT_DIR/../assets/roles/adversary.role.md"; [ -f "$role_card" ] || { err "Adversary role card missing: $role_card"; return 3; }
  plan_dir="$(repo_file "$repo" docs/plans)"; shopt -s nullglob; plans=("$plan_dir/${run^^}-"*.md); packet_files=("$packet_dir"/*.task.md); shopt -u nullglob
  [ "${#plans[@]}" -gt 0 ] || { err "plan doc missing for run $run"; return 3; }; plan_doc="${plans[${#plans[@]}-1]}"
  {
    cat <<EOF
---
id: plan-adversary
role: Adversary
class: verify
model: $model
locus: process
owns: []
modifies: []
reads: []
registries: []
depends_on: []
generator: null
gate: auto
final_reply:
  - "FINDING: <severity> <claim>"
  - "VERDICT: stands"
---

EOF
    cat "$role_card"
    cat <<'EOF'

## Refutation target

Attack this plan's decomposition. Hunt hidden coupling, shared writers,
unfrozen contracts, unjustified or missing barriers, under-powered or
same-provider verification, and spec requirements no packet owns.

### Plan document

EOF
    cat "$plan_doc"; printf '\n\n### Packet summaries\n\n'
    for file in "${packet_files[@]}"; do
      [ "$file" = "$packet" ] && continue
      id="$(packet_id "$file")"; mapfile -t owned < <(fm_list "$file" owns); mapfile -t deps < <(fm_list "$file" depends_on)
      printf -- '- id: %s\n  owns: %s\n  depends_on: %s\n' "$id" "$(IFS=,; echo "${owned[*]:-}")" "$(IFS=,; echo "${deps[*]:-}")"
    done
  } > "$packet"
  spawn="${FFPLAN_SPAWN:-$SCRIPT_DIR/ff-spawn.sh}"; collect="${FFPLAN_COLLECT:-$SCRIPT_DIR/ff-collect.sh}"
  set +e
  spawn_output="$("$spawn" --run "$run" --id plan-adversary --model "$model" --prompt-file ".fleetflow/$run/packets/plan-adversary.task.md" --worktree --repo "$repo")"; rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then [ -z "$spawn_output" ] || err "$spawn_output"; return "$rc"; fi
  set +e; final="$("$collect" --run "$run" --id plan-adversary --repo "$repo")"; rc=$?; set -e
  [ "$rc" -eq 0 ] || return "$rc"; printf '%s\n' "$final"
  while IFS= read -r line; do
    [[ "$line" == FINDING:* ]] || continue
    findings=$((findings+1)); severity=medium
    if [[ "${line,,}" =~ severity[=:[:space:]]+(low|medium|high|critical) ]]; then severity="${BASH_REMATCH[1]}"
    elif [[ "${line,,}" =~ finding:[[:space:]]*(low|medium|high|critical) ]]; then severity="${BASH_REMATCH[1]}"; fi
    claim="${line#FINDING:}"; claim="${claim# }"
    finding_json="$(jq -cn --arg severity "$severity" --arg claim "$claim" --arg evidence "$line" \
      '{wave:"plan",severity:$severity,files:[],claim:$claim,evidence:$evidence}' | tr -d '\r')"
    append_output="$(bash "$SCRIPT_DIR/ff-findings.sh" append --run "$run" --repo "$repo" --json "$finding_json")"; [ -n "$append_output" ] || true
  done <<< "$final"
  [ "$findings" -eq 0 ] || return 10
}

pricing_record() {
  jq -c --arg model "$2" '
    def pick($key): if type=="object" then .[$key] else null end;
    def direct($key): (. | pick($key)) // (.models? | pick($key)) // (.pricing? | pick($key)) // (.rates? | pick($key));
    def aliased: (.aliases? | pick($model) // empty) as $a | if ($a|type)=="string" then direct($a) else empty end;
    # Spawn aliases (sonnet, opus, haiku, fable) resolve by prefix against the
    # pricing file'\''s full Claude ids (claude-sonnet-4-6, ...) so a model
    # version bump does not silently unprice the alias. Non-Anthropic aliases
    # (glm/codex/grok/pi) have no entries there and stay honestly unpriced.
    def prefixed: ((.models? // .pricing? // .rates? // {}) as $m
      | if ($m|type)=="object" then ($m | keys | map(select(startswith("claude-" + $model + "-") or .=="claude-"+$model)) | sort | last) as $k
        | if $k then $m[$k] else empty end else empty end);
    direct($model) // aliased // prefixed //
      ([.models?[]?,.pricing?[]?,.rates?[]?] | map(select(type=="object" and ((.alias? // .id? // .model? // .name? //"")==$model)))[0]) // empty
  ' "$1" 2>/dev/null | tr -d '\r'
}
estimate_value() {
  jq -nr --argjson rate "$1" --argjson packet "$2" '
    def nf($names): (first($names[] as $n | $rate[$n]? | select(type=="number")) // null);
    if ($rate|type)=="number" then ($rate|tostring)
    elif ($rate|type)=="string" then $rate
    elif ($rate|type)!="object" then "unpriced"
    else (nf(["estimate_usd","estimated_usd","cost_usd","estimate","per_run","per_call"])) as $flat
      |if $flat!=null then ($flat|tostring)
       else (nf(["input_per_million","input_per_mtok","input","prompt"])) as $ir
        |(nf(["output_per_million","output_per_mtok","output","completion"])) as $or
        |($packet.estimated_input_tokens//$packet.tokens_in//($packet.estimate? |if type=="object" then .input_tokens else null end)//null) as $it
        |($packet.estimated_output_tokens//$packet.tokens_out//($packet.estimate? |if type=="object" then .output_tokens else null end)//null) as $ot
        |if $ir!=null and $or!=null and $it!=null and $ot!=null then (((($it*$ir)+($ot*$or))/1000000)|tostring)
         # Rates known but no per-packet token estimate: print the rates
         # rather than invent a number (honest-costs, ADR-010/015) or lie
         # with "unpriced" when the model IS priced.
         elif $ir!=null and $or!=null then "in:\($ir)/M out:\($or)/M (no token estimate)"
         else "unpriced" end
       end
    end' | tr -d '\r'
}
estimate_cmd() {
  local run="" repo_arg="" repo manifest pricing bounds missing=0 packet_json id model record estimate
  while [ "$#" -gt 0 ]; do case "$1" in
    --run) need_value "$#" "$1"; run="$2"; shift 2;; --repo) need_value "$#" "$1"; repo_arg="$2"; shift 2;;
    -h|--help) usage; return 0;; *) err "unknown estimate argument: $1"; usage; return 2;; esac; done
  require_run "$run"; repo="$(resolve_repo "$repo_arg")" || return 2; require_repo "$repo"
  manifest="$(repo_file "$repo" ".fleetflow/$run/manifest.json")"; [ -f "$manifest" ] || { err "manifest missing for run $run"; return 3; }
  jq -e 'type=="object" and (.packets|type)=="array"' "$manifest" >/dev/null 2>&1 || { err "manifest is malformed: $manifest"; return 3; }
  pricing="${FFPLAN_PRICING:-$HOME/.claude/skills/loop-ops/assets/model-pricing.json}"
  if [ ! -f "$pricing" ]; then err "pricing file missing: $pricing; every lane is unpriced"; missing=1
  elif ! jq -e . "$pricing" >/dev/null 2>&1; then err "pricing file is malformed: $pricing; every lane is unpriced"; missing=1; fi
  while IFS= read -r packet_json; do
    id="$(jqr '.id//"unknown"' <<< "$packet_json")"; model="$(jqr '.model//.brain//"unknown"' <<< "$packet_json")"; estimate=unpriced
    if [ "$missing" -eq 0 ]; then record="$(pricing_record "$pricing" "$model")"; [ -z "$record" ] || estimate="$(estimate_value "$record" "$packet_json")"; fi
    printf '%s %s %s\n' "$id" "$model" "$estimate"
  done < <(jq -c '.packets[]' "$manifest" | tr -d '\r')
  bounds="$(jqr '.plan.bounds//"absent"' "$manifest")"; printf 'BOUNDS: %s\n' "$bounds"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    draft) shift; draft_cmd "$@";; expand) shift; expand_cmd "$@";; lint) shift; lint_cmd "$@";;
    refute) shift; refute_cmd "$@";; estimate) shift; estimate_cmd "$@";;
    -h|--help|help) usage; exit 0;; *) usage; exit 2;; esac
}
main "$@"
