#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

MODE=${1:-}
RUN_ID=${2:-}
STATE=/tmp/jfs-06-5-$RUN_ID-portal-state.tsv
MOUNT_UNIT=juicefs-namespace-mount.service
COLLECTOR_UNIT=juicefs-namespace-collector.service
TIMER_UNIT=juicefs-namespace-collector.timer
PORTAL_UNIT=juicefs-portal.service
MOUNTPOINT=/var/lib/juicefs-portal/namespace-mount

die() { printf 'T065_PORTAL_FAIL\t%s\n' "$*" >&2; exit 42; }
guard() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $(hostname -s) == ceph-node3 ]] || die wrong_host
  [[ $EUID -eq 0 ]] || die must_run_as_root
  [[ $STATE == /tmp/jfs-06-5-$RUN_ID-portal-state.tsv && $STATE != / ]] || die unsafe_state
}
unit_state() { systemctl is-active "$1" 2>/dev/null || true; }
write_plan() {
  printf '%s\n' \
    "sudo systemctl stop $TIMER_UNIT" \
    "sudo systemctl stop $COLLECTOR_UNIT  # only if active" \
    "sudo systemctl stop $MOUNT_UNIT" \
    "# run 06-5 on 157 while this mount stays absent" \
    "sudo systemctl start $MOUNT_UNIT" \
    "sudo systemctl start $COLLECTOR_UNIT  # only if it was active before pause" \
    "sudo systemctl start $TIMER_UNIT"
}
pause() {
  guard
  [[ ! -e $STATE ]] || die state_exists
  printf 'run_id\t%s\ntimer\t%s\ncollector\t%s\nmount\t%s\nportal\t%s\n' \
    "$RUN_ID" "$(unit_state "$TIMER_UNIT")" "$(unit_state "$COLLECTOR_UNIT")" \
    "$(unit_state "$MOUNT_UNIT")" "$(unit_state "$PORTAL_UNIT")" >"$STATE"
  [[ $(awk -F '\t' '$1=="portal"{print $2}' "$STATE") == active ]] || die portal_not_active
  rollback_pause() {
    local rc=$?
    trap - EXIT INT TERM
    restore || printf 'T065_PORTAL_ROLLBACK_FAILED\tpreserve_state=%s\n' "$STATE" >&2
    exit "$rc"
  }
  trap rollback_pause EXIT INT TERM
  systemctl stop "$TIMER_UNIT"
  systemctl stop "$COLLECTOR_UNIT"
  systemctl stop "$MOUNT_UNIT"
  [[ $(unit_state "$TIMER_UNIT") == inactive && $(unit_state "$COLLECTOR_UNIT") == inactive && $(unit_state "$MOUNT_UNIT") == inactive ]] || die unit_not_stopped
  [[ -z $(findmnt -rn -M "$MOUNTPOINT" 2>/dev/null || true) ]] || die mount_remains
  [[ $(unit_state "$PORTAL_UNIT") == active ]] || die portal_was_impacted
  trap - EXIT INT TERM
  printf 'T065_PORTAL_PAUSE_PASS\tstate=%s\n' "$STATE"
}
restore() {
  guard
  [[ -s $STATE && ! -L $STATE ]] || die state_missing
  [[ $(awk -F '\t' '$1=="run_id"{print $2}' "$STATE") == "$RUN_ID" ]] || die state_run_mismatch
  if [[ $(awk -F '\t' '$1=="mount"{print $2}' "$STATE") == active ]]; then systemctl start "$MOUNT_UNIT"; fi
  for _ in $(seq 1 60); do findmnt -rn -M "$MOUNTPOINT" >/dev/null 2>&1 && break; sleep 1; done
  [[ $(awk -F '\t' '$1=="mount"{print $2}' "$STATE") != active || -n $(findmnt -rn -M "$MOUNTPOINT" 2>/dev/null || true) ]] || die mount_restore_failed
  if [[ $(awk -F '\t' '$1=="collector"{print $2}' "$STATE") == active ]]; then systemctl start "$COLLECTOR_UNIT"; fi
  if [[ $(awk -F '\t' '$1=="timer"{print $2}' "$STATE") == active ]]; then systemctl start "$TIMER_UNIT"; fi
  [[ $(unit_state "$PORTAL_UNIT") == "$(awk -F '\t' '$1=="portal"{print $2}' "$STATE")" ]] || die portal_state_not_restored
  [[ $(unit_state "$MOUNT_UNIT") == "$(awk -F '\t' '$1=="mount"{print $2}' "$STATE")" ]] || die mount_state_not_restored
  [[ $(unit_state "$COLLECTOR_UNIT") == "$(awk -F '\t' '$1=="collector"{print $2}' "$STATE")" ]] || die collector_state_not_restored
  [[ $(unit_state "$TIMER_UNIT") == "$(awk -F '\t' '$1=="timer"{print $2}' "$STATE")" ]] || die timer_state_not_restored
  printf 'T065_PORTAL_RESTORE_PASS\tstate=%s\n' "$STATE"
}

case $MODE in
  plan) write_plan;;
  pause) pause;;
  restore) restore;;
  *) printf 'usage: %s plan|pause|restore RUN_ID\n' "$0" >&2; exit 2;;
esac
