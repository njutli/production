#!/usr/bin/env bash
# 04-2/A1 Phase 0 local-only contracts. No SSH, sudo, fio, mount, or service actions.
set -euo pipefail
export LC_ALL=C

s04a1_die() { printf 'E_S04A1\t%s\n' "$*" >&2; return 42; }
s04a1_check_run_id() { [[ ${1:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] || s04a1_die 'RUN_ID must be YYYYMMDD-HHMMSS'; }
s04a1_check_node() { [[ ${1:-} =~ ^10\.20\.1\.(150|151|152)$ ]] || s04a1_die 'node outside frozen A1 set'; }
s04a1_check_arm() { [[ ${1:-} == C || ${1:-} == L ]] || s04a1_die 'arm must be C or L'; }
s04a1_check_instance() { [[ ${1:-} =~ ^(H0|H1|SEED-FORMAL|RESTORE-PREFLIGHT-(C|L)|ARM-CANARY-(C|L)|GC-(PREFLIGHT|ARM-CANARY-(C|L))|G0[1-8]|R0[1-8])$ ]] || s04a1_die 'instance outside frozen 04-2 lifecycle'; }
s04a1_expected_arm() {
  case ${1:-} in
    SEED-FORMAL|RESTORE-PREFLIGHT-C|ARM-CANARY-C|GC-PREFLIGHT|GC-ARM-CANARY-C|G01|G04|G06|G07|R01|R04|R06|R07) printf C;;
    RESTORE-PREFLIGHT-L|ARM-CANARY-L|GC-ARM-CANARY-L|G02|G03|G05|G08|R02|R03|R05|R08) printf L;;
    *) s04a1_die "no C/L mapping for ${1:-EMPTY}";;
  esac
}
s04a1_check_matrix() {
  local got=${1:-}
  [[ "$got" == 'C,L,L,C,L,C,C,L' ]] || s04a1_die 'matrix must be C,L,L,C,L,C,C,L'
  local i a; IFS=',' read -ra a <<< "$got"; (( ${#a[@]} == 8 )) || s04a1_die 'matrix length is not 8'
  local c=0 l=0; for i in "${a[@]}"; do
    if [[ $i == C ]]; then ((c+=1)); elif [[ $i == L ]]; then ((l+=1)); else s04a1_die 'invalid matrix arm'; fi
  done
  (( c == 4 && l == 4 )) || s04a1_die 'matrix is not balanced'
}
s04a1_abs_path() { [[ ${1:-} == /* && ${1:-} != *'..'* ]] || s04a1_die 'path must be absolute and contain no ..'; }
s04a1_phase0_root() { local run=$1; s04a1_check_run_id "$run"; printf '/mnt/c/SunRise/test/04-2/%s\n' "$run"; }
