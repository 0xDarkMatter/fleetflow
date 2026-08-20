#!/usr/bin/env bash
# ff-plan — author, lint, refute, and estimate a fleet run plan BEFORE spawn.
#
# SEEDED SKELETON (2026-08-20): subcommand surface + protocol shell only.
# The `lint`/`estimate` paths are owned by the run `ffplan` lint lane; the
# `draft`/`expand` paths by its draft lane. Do not implement here outside
# those lanes — see docs/plans/FFPLAN-2026-08.md §12 and ADR-026..031.
#
# Contract: stdout is data, chatter on stderr; exit 0 ok, 2 usage,
# 3 missing/unimplemented, 10 findings. `ff-spawn` consumes the manifest
# this tool authors (ADR-026); `lint` gates the spawn (ADR-030).

set -euo pipefail

usage() {
  cat <<'EOF' >&2
ff-plan — plan a fleet run: draft, expand, lint, refute, estimate

USAGE
  ff-plan.sh draft    --run NAME --spec FILE [--shape feature|review|research|migrate|app] [--repo P]
  ff-plan.sh expand   --run NAME --generator NAME --vars FILE [--repo P]
  ff-plan.sh lint     --run NAME [--json] [--repo P]
  ff-plan.sh refute   --run NAME [--model codex|grok|glm|pi] [--repo P]
  ff-plan.sh estimate --run NAME [--repo P]

EXAMPLES
  # scaffold a plan doc + packet stubs + manifest for an app-scale run
  bash scripts/ff-plan.sh draft --run shopfront --spec spec/shopfront.md --shape app

  # gate the plan before ff-doctor blesses the fleet (exit 10 = findings)
  bash scripts/ff-plan.sh lint --run shopfront

EXIT CODES
  0 ok · 2 usage · 3 missing/unimplemented · 10 findings
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    draft|expand|lint|refute|estimate)
      echo "ff-plan: '$cmd' is not implemented yet — build in flight (docs/plans/FFPLAN-2026-08.md §12)" >&2
      exit 3
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
