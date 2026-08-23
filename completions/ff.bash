# ff.bash - bash tab-completion for the fleetflow `ff` dispatcher.
#
# Install:  source this file from ~/.bashrc, or drop it in
#           /usr/share/bash-completion/completions/ff (or ~/.local/share/...).
# zsh:      autoload -U +X bashcompinit && bashcompinit; source completions/ff.bash
#
# Run names complete from <git toplevel>/.fleetflow/*/ of the CURRENT repo, so
# completion follows whichever repo you are standing in. Model aliases mirror the
# spawnable set in SKILL.md / the dashboard HARNESS register - keep in the same
# commit as any contract change there.

_ff_complete() {
  local cur prev subcmds models
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  subcmds="plan doctor spawn collect status run clean sweep chip archive findings widget import serve aggregate env open logs watch help"
  models="glm codex grok pi sonnet haiku opus fable chip"

  _ff_runs() {
    local top
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
    [ -d "$top/.fleetflow" ] || return 0
    ( cd "$top/.fleetflow" 2>/dev/null && ls -d */ 2>/dev/null | tr -d '/' )
  }

  # first word: the subcommand
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$subcmds" -- "$cur") )
    return 0
  fi

  case "$prev" in
    --model)      COMPREPLY=( $(compgen -W "$models" -- "$cur") ); return 0 ;;
    --run)        COMPREPLY=( $(compgen -W "$(_ff_runs)" -- "$cur") ); return 0 ;;
    --posture)    COMPREPLY=( $(compgen -W "baseline tested hardened complete" -- "$cur") ); return 0 ;;
    --attend)     COMPREPLY=( $(compgen -W "none land each" -- "$cur") ); return 0 ;;
    --shape)      COMPREPLY=( $(compgen -W "feature review research migrate app" -- "$cur") ); return 0 ;;
    --repo|--spec|--prompt-file|--out|--vars) COMPREPLY=( $(compgen -f -- "$cur") ); return 0 ;;
  esac

  case "${COMP_WORDS[1]}" in
    plan)   [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=( $(compgen -W "draft expand lint refute estimate" -- "$cur") ) ;;
    run)    [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=( $(compgen -W "wave resume" -- "$cur") ) ;;
    chip)   [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=( $(compgen -W "open close" -- "$cur") ) ;;
    doctor) COMPREPLY=( $(compgen -W "--offline --live --env" -- "$cur") ) ;;
    logs|watch) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=( $(compgen -W "$(_ff_runs)" -- "$cur") ) ;;
  esac
  return 0
}
complete -F _ff_complete ff
