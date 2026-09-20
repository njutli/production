#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

RUN_ID=${1:-}
ATTEMPT=${2:-r1}
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo 'invalid RUN_ID' >&2; exit 42; }
[[ $ATTEMPT =~ ^r[0-9]+$ ]] || { echo 'invalid attempt' >&2; exit 42; }
ROOT=/tmp/production/opencode-06-2-${RUN_ID}
SCRIPT_DIR=${ROOT}/scripts
SCRUB=${SCRIPT_DIR}/u141d-scrub-control.sh
CELL=${SCRIPT_DIR}/t06-2-gate2b-cell.sh
STATE_DIR=${ROOT}/scrub-gate2b
LEASE=${RUN_ID}-gate2b-${ATTEMPT}-phase-a
CEPH_CONF=/etc/ceph/ceph.conf
OUT=${ROOT}/profile/gate2b/coordinator-${ATTEMPT}
PAUSED=0

[[ -d $ROOT && ! -L $ROOT && -x $SCRUB && -x $CELL ]] || { echo 'invalid root/scripts' >&2; exit 42; }
[[ ! -e $OUT && ! -L $OUT ]] || { echo 'coordinator output exists' >&2; exit 42; }
mkdir -m 0700 -p "$OUT" "$STATE_DIR"

scrub() {
  env U141D_SCRUB_STATE_DIR="$STATE_DIR" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" "$@"
}
restore_on_exit() {
  rc=$?
  if (( PAUSED == 1 )); then
    set +e
    scrub plan-restore "$LEASE" >"$OUT/plan-restore-on-exit.txt" 2>"$OUT/plan-restore-on-exit.stderr"
    scrub restore "$LEASE" >"$OUT/restore-on-exit.txt" 2>"$OUT/restore-on-exit.stderr"
    restore_rc=$?
    scrub verify-restored "$LEASE" >"$OUT/verify-restored-on-exit.txt" 2>"$OUT/verify-restored-on-exit.stderr"
    verify_rc=$?
    printf '%s\n' "$restore_rc" >"$OUT/restore-on-exit.rc"
    printf '%s\n' "$verify_rc" >"$OUT/verify-restored-on-exit.rc"
    set -e
    (( restore_rc == 0 && verify_rc == 0 )) || exit 44
  fi
  exit "$rc"
}
trap restore_on_exit EXIT

scrub inspect "$LEASE" >"$OUT/inspect-before.txt" 2>"$OUT/inspect-before.stderr"
scrub plan-pause "$LEASE" >"$OUT/plan-pause.txt" 2>"$OUT/plan-pause.stderr"
FSID=$(ceph -c "$CEPH_CONF" fsid | tr -d '[:space:]')
[[ $FSID =~ ^[0-9a-f-]{36}$ ]] || { echo 'invalid FSID' >&2; exit 42; }
scrub pause "$LEASE" "$FSID" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$OUT/pause.txt" 2>"$OUT/pause.stderr"
PAUSED=1
scrub verify-paused "$LEASE" >"$OUT/verify-paused-before-B.txt" 2>"$OUT/verify-paused-before-B.stderr"

set +e
bash "$CELL" "$RUN_ID" B >"$OUT/cell-B.stdout" 2>"$OUT/cell-B.stderr"
B_RC=$?
set -e
printf '%s\n' "$B_RC" >"$OUT/cell-B.rc"
(( B_RC == 0 )) || exit "$B_RC"
scrub verify-paused "$LEASE" >"$OUT/verify-paused-before-I.txt" 2>"$OUT/verify-paused-before-I.stderr"

set +e
bash "$CELL" "$RUN_ID" I >"$OUT/cell-I.stdout" 2>"$OUT/cell-I.stderr"
I_RC=$?
set -e
printf '%s\n' "$I_RC" >"$OUT/cell-I.rc"
(( I_RC == 0 )) || exit "$I_RC"
scrub verify-paused "$LEASE" >"$OUT/verify-paused-after-I.txt" 2>"$OUT/verify-paused-after-I.stderr"

scrub plan-restore "$LEASE" >"$OUT/plan-restore.txt" 2>"$OUT/plan-restore.stderr"
scrub restore "$LEASE" >"$OUT/restore.txt" 2>"$OUT/restore.stderr"
PAUSED=0
scrub verify-restored "$LEASE" >"$OUT/verify-restored.txt" 2>"$OUT/verify-restored.stderr"
ceph -c "$CEPH_CONF" -s -f json >"$OUT/ceph.final.json"
python3 - "$OUT/ceph.final.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d.get('health',{}).get('status') == 'HEALTH_OK', d.get('health')
o=d.get('osdmap',{}); assert o.get('num_osds') == o.get('num_up_osds') == o.get('num_in_osds'), o
PY
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
trap - EXIT
printf 'T062_GATE2B_COORDINATOR_PASS\tB=0\tI=0\n'
