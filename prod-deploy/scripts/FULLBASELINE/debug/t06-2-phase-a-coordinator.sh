#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

RUN_ID=${1:-}
ATTEMPT=${2:-r1}
if [[ $RUN_ID == --self-test ]]; then
  grep -Fq 'for cell in C1 T1 T2 C2' "$0"
  grep -Fq 'passive_settle "$cell"' "$0"
  ! grep -Eq 'juicefs[[:space:]]+gc|rm[[:space:]]+-rf|umount[[:space:]]+-l|fusermount[[:space:]]+-u[z]|pkill|killall' "$0"
  printf 'T062_PHASE_A_COORDINATOR_SELF_TEST_PASS\torder=C1,T1,T2,C2\tshared_gc=ABSENT\n'
  exit 0
fi
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo 'invalid RUN_ID' >&2; exit 42; }
[[ $ATTEMPT =~ ^r[0-9]+$ ]] || { echo 'invalid attempt' >&2; exit 42; }
ROOT=/tmp/production/opencode-06-2-${RUN_ID}
SCRIPT_DIR=${ROOT}/scripts
SCRUB=${SCRIPT_DIR}/u141d-scrub-control.sh
CELL=${SCRIPT_DIR}/t06-2-gate2b-cell.sh
STATE_DIR=${ROOT}/scrub-phase-a
# u141d-scrub-control intentionally accepts only the frozen lease suffixes
# `<RUN_ID>-phase-a|b`; ATTEMPT remains scoped by OUT/STATE_DIR, not the lease.
LEASE=${RUN_ID}-phase-a
CEPH_CONF=/etc/ceph/ceph.conf
OUT=${ROOT}/phase-a/coordinator-${ATTEMPT}
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
    set -e
    (( restore_rc == 0 && verify_rc == 0 )) || exit 44
  fi
  exit "$rc"
}
trap restore_on_exit EXIT

health_gate() {
  local tag=$1
  ceph -c "$CEPH_CONF" -s -f json >"$OUT/ceph-${tag}.json"
  ceph -c "$CEPH_CONF" osd stat -f json >"$OUT/osd-${tag}.json"
  ceph -c "$CEPH_CONF" pg dump pgs_brief >"$OUT/pg-${tag}.txt"
  python3 - "$OUT/ceph-${tag}.json" "$OUT/osd-${tag}.json" "$OUT/pg-${tag}.txt" <<'PY'
import json,sys
h=json.load(open(sys.argv[1])).get('health',{})
checks=set(h.get('checks') or {})
assert (h.get('status')=='HEALTH_OK' and not checks) or (h.get('status')=='HEALTH_WARN' and checks=={'OSDMAP_FLAGS'}), h
o=json.load(open(sys.argv[2])); n=o.get('num_osds',0)
assert n==6 and o.get('num_up_osds')==n and o.get('num_in_osds')==n, o
states=[]
for line in open(sys.argv[3]):
    f=line.split()
    if f and '.' in f[0] and f[0][0].isdigit(): states.append(f[1])
assert len(states)==97 and all(x=='active+clean' for x in states), (len(states),set(states))
PY
}

passive_settle() {
  local tag=$1 stable=0 previous= current=
  for sample in $(seq 1 18); do
    current=$(ceph -c "$CEPH_CONF" df -f json | python3 -c 'import json,sys; d=json.load(sys.stdin); p=[x for x in d.get("pools",[]) if x.get("name")=="juicefs-data"]; assert len(p)==1; s=p[0]["stats"]; print(str(int(s["objects"]))+":"+str(int(s["stored"])))')
    printf '%s\t%s\n' "$(date +%s%N)" "$current" >>"$OUT/passive-settle-${tag}.tsv"
    if [[ -n $previous && $current == "$previous" ]]; then stable=$((stable+1)); else stable=0; fi
    previous=$current
    (( stable >= 2 )) && return 0
    sleep 10
  done
  echo "passive settle timeout: $tag" >&2
  return 42
}

scrub inspect "$LEASE" >"$OUT/inspect-before.txt" 2>"$OUT/inspect-before.stderr"
scrub plan-pause "$LEASE" >"$OUT/plan-pause.txt" 2>"$OUT/plan-pause.stderr"
FSID=$(ceph -c "$CEPH_CONF" fsid | tr -d '[:space:]')
[[ $FSID =~ ^[0-9a-f-]{36}$ ]] || { echo 'invalid FSID' >&2; exit 42; }
scrub pause "$LEASE" "$FSID" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$OUT/pause.txt" 2>"$OUT/pause.stderr"
PAUSED=1
health_gate start

for cell in C1 T1 T2 C2; do
  scrub verify-paused "$LEASE" >"$OUT/verify-paused-before-${cell}.txt" 2>"$OUT/verify-paused-before-${cell}.stderr"
  set +e
  bash "$CELL" "$RUN_ID" "$cell" >"$OUT/cell-${cell}.stdout" 2>"$OUT/cell-${cell}.stderr"
  cell_rc=$?
  set -e
  printf '%s\n' "$cell_rc" >"$OUT/cell-${cell}.rc"
  (( cell_rc == 0 )) || exit "$cell_rc"
  health_gate "after-${cell}"
  passive_settle "$cell"
done

scrub plan-restore "$LEASE" >"$OUT/plan-restore.txt" 2>"$OUT/plan-restore.stderr"
scrub restore "$LEASE" >"$OUT/restore.txt" 2>"$OUT/restore.stderr"
scrub verify-restored "$LEASE" >"$OUT/verify-restored.txt" 2>"$OUT/verify-restored.stderr"
PAUSED=0
health_gate final
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
trap - EXIT
printf 'T062_PHASE_A_COORDINATOR_PASS\torder=C1,T1,T2,C2\n'
