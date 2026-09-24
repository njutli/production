#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

RUN_ID=${1:-}
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || { printf 'T062C_WRAPPER_FAIL\tinvalid_RUN_ID\n' >&2; exit 42; }
PREP=/tmp/production/opencode-06-2c-prep-$RUN_ID
ROOT=/tmp/production/opencode-06-2c-$RUN_ID
DRIVER=$PREP/prod-deploy/scripts/FULLBASELINE/debug/t06-2c-eager-freeze-driver.sh
PORTAL=/tmp/production/opencode-06-2c-prep-$RUN_ID/scripts/t06-5-portal-maintenance.sh
RESTORE_DONE=0

[[ ${T062C_WRAPPER_SHA256:-} =~ ^[0-9a-f]{64}$ && $(sha256sum "$0" | awk '{print $1}') == "$T062C_WRAPPER_SHA256" ]] \
  || { printf 'T062C_WRAPPER_FAIL\twrapper_identity\n' >&2; exit 42; }
[[ ${T062C_MAINTENANCE_ACK:-} == I_ACK_06_2C_PORTAL_PAUSED_$RUN_ID ]] \
  || { printf 'T062C_WRAPPER_FAIL\tmaintenance_ack_missing\n' >&2; exit 42; }
"$DRIVER" preflight-online "$RUN_ID"
remote_portal_sha=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/sunrise/.ssh/known_hosts 10.20.1.152 sha256sum "$PORTAL" | awk '{print $1}')
[[ $remote_portal_sha == "${T062C_PORTAL_SHA256:?}" ]] \
  || { printf 'T062C_WRAPPER_FAIL\tremote_portal_identity\n' >&2; exit 42; }

restore_portal() {
  (( RESTORE_DONE == 0 )) || return 0
  RESTORE_DONE=1
  local attempt
  for attempt in 1 2 3; do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/sunrise/.ssh/known_hosts \
      10.20.1.152 sudo "$PORTAL" restore "$RUN_ID" \
      >>"$PREP/portal-restore.stdout" 2>>"$PREP/portal-restore.stderr"; then return 0; fi
    sleep 5
  done
  return 1
}
finish() {
  local rc=$?
  trap - EXIT INT TERM
  if ! restore_portal; then
    rc=47
    printf 'PORTAL_RESTORE_FAIL\n' >"$PREP/PORTAL_RESTORE_FAIL"
    [[ ! -d $ROOT ]] || printf 'PORTAL_RESTORE_FAIL\n' >"$ROOT/PORTAL_RESTORE_FAIL"
  fi
  printf '%s\n' "$rc" >"$PREP/wrapper.rc"
  if [[ -d $ROOT ]]; then
    printf '%s\n' "$rc" >"$ROOT/wrapper.rc"
    if (( rc == 0 )); then
      printf 'PORTAL_RESTORE_PASS\n' >"$ROOT/PORTAL_RESTORE_PASS"
      printf 'WRAPPER_PASS\n' >"$ROOT/WRAPPER_PASS"
    fi
  fi
  exit "$rc"
}
trap finish EXIT INT TERM

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/sunrise/.ssh/known_hosts \
  10.20.1.152 sudo "$PORTAL" pause "$RUN_ID" \
  >"$PREP/portal-pause.stdout" 2>"$PREP/portal-pause.stderr"
T062C_WRAPPER_ACTIVE=I_ACK_06_2C_WRAPPER_$RUN_ID "$DRIVER" phase "$RUN_ID"
printf 'DRIVER_PASS\t%s\n' "$(date -Is)"
