#!/usr/bin/env bash
# Offline mock of the state machine; no environment or network operations.
set -euo pipefail
export LC_ALL=C
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); source "$DIR/s04a1-common.sh"
RUN=${1:-20260902-120000}; s04a1_check_run_id "$RUN"; s04a1_check_matrix C,L,L,C,L,C,C,L
state=H0
for step in STOP_PROD C L L C L C C L RESTORE_PROD H1; do
  case "$step" in STOP_PROD) state=PROD_STOPPED;; C|L) [[ $state == PROD_STOPPED || $state == ARM_DONE ]] || s04a1_die "bad state before $step"; state=ARM_DONE;; RESTORE_PROD) state=PROD_RESTORED;; H1) [[ $state == PROD_RESTORED ]] || s04a1_die 'H1 before restore'; state=H1;; esac
done
[[ $state == H1 ]] || s04a1_die 'normal closure failed'
printf 'MOCK_PASS\tH0-stop-C/Lx8-restore-H1\tfailure-branch=restore-first\n'
