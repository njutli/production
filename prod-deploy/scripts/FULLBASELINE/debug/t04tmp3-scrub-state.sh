#!/usr/bin/env bash
# State-driven scrub lease plan.  It renders commands for a separately
# authorised operator; it never invokes a cluster command itself.
# DEFECT-D25 DEFECT-D26 DEFECT-D27 DEFECT-D28 DEFECT-D31
set -euo pipefail
export LC_ALL=C

usage() { printf 'usage: %s plan|restore PHASE FSID STATE_FILE\n' "$0" >&2; exit 2; }
valid() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'invalid identifier' >&2; exit 2; }; }
plan() {
  local phase=$1 fsid=$2 state=$3
  valid "$phase"; valid "$fsid"
  [[ $state != / && $state == /* && ${state##*/} == *.* ]] || { echo 'unsafe state path' >&2; exit 2; }
  [[ ! -e $state ]] || { echo 'state already exists; append-only lease required' >&2; exit 2; }
  mkdir -p "$(dirname -- "$state")"
  printf 'epoch_iso\taction\tphase\tfsid\towned_flags\trc\n' >"$state"
  printf '%s\tPLAN_SET\t%s\t%s\tnoscrub,nodeep-scrub\tPENDING\n' "$(date -Is)" "$phase" "$fsid" >>"$state"
  printf '# INSPECT current flags/health/PG before this lease.\n'
  printf '# SET (operator, after explicit ACK): ceph osd set noscrub; ceph osd set nodeep-scrub\n'
  printf '# VERIFY only the authorised OSDMAP_FLAGS exception; PG active+clean; no scrub running.\n'
  printf 'T04TMP3_SCRUB_PLAN_PASS\tphase=%s\tfsid=%s\tstate=%s\n' "$phase" "$fsid" "$state"
}
restore() {
  local phase=$1 fsid=$2 state=$3
  valid "$phase"; valid "$fsid"; [[ -f $state ]] || { echo 'missing lease state' >&2; exit 2; }
  grep -Fq $'PLAN_SET\t' "$state" || { echo 'state is not owned by this controller' >&2; exit 2; }
  grep -Fq $'\t'"$phase"$'\t' "$state" || { echo 'phase mismatch' >&2; exit 2; }
  printf '%s\tPLAN_RESTORE\t%s\t%s\tnoscrub,nodeep-scrub\tPENDING\n' "$(date -Is)" "$phase" "$fsid" >>"$state"
  printf '# RESTORE only flags recorded as owned by this lease; verify exact pre-state after each action.\n'
  printf '# UNSET (operator, after phase success/failure): ceph osd unset noscrub; ceph osd unset nodeep-scrub\n'
  printf 'T04TMP3_SCRUB_RESTORE_PLAN\tphase=%s\tfsid=%s\tstate=%s\n' "$phase" "$fsid" "$state"
}
[[ $# -eq 4 ]] || usage
case $1 in plan) plan "$2" "$3" "$4";; restore) restore "$2" "$3" "$4";; *) usage;; esac
