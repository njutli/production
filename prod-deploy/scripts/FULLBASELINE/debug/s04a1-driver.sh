#!/usr/bin/env bash
# Phase 0 state contract only. Online lifecycle is deliberately unavailable.
set -euo pipefail
export LC_ALL=C
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); source "$DIR/s04a1-common.sh"
ACTION=${1:-}; RUN_ID=${2:-}; s04a1_check_run_id "$RUN_ID"
case "$ACTION" in
  plan)
    printf 'DRIVER_STATE\tPHASE0_ONLY\nRUN_ID\t%s\n' "$RUN_ID"
    printf 'ALLOWED\tlocal plan and offline Gate\nFORBIDDEN\tremote mutation and performance execution\n'
    printf 'NEXT\tPhase I requires explicit review of inventory/capacity/maintenance plans\n'
    ;;
  transition)
    from=${3:-}; to=${4:-}
    [[ "$from:$to" == 'PHASE0_ONLY:PHASE1_READONLY_PENDING' ]] || s04a1_die 'invalid phase transition'
    printf 'TRANSITION_PASS\t%s\t%s\n' "$from" "$to"
    ;;
  run) s04a1_die 'online driver is NOT_READY; Phase 0 cannot run it';;
  *) s04a1_die 'usage: driver plan|transition|run RUN_ID ...';;
esac
