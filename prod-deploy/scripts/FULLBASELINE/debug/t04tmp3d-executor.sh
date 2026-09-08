#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 04-tmp3d direct RADOS object service curve.  No JuiceFS mount and no TiKV.
# DEFECT-D01 DEFECT-D02 DEFECT-D03 DEFECT-D06 DEFECT-D09 DEFECT-D12
# DEFECT-D16 DEFECT-D17 DEFECT-D18 DEFECT-D21 DEFECT-D22 DEFECT-D25
# DEFECT-D26 DEFECT-D27 DEFECT-D28 DEFECT-D31

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXECUTOR=$(readlink -f -- "${BASH_SOURCE[0]}")
ANALYZER="$SELF_DIR/t04tmp3d-analyze.py"
REMOTE_PARENT=/tmp/production
TASK_ROOT=/mnt/c/SunRise/test/04-tmp3d
POOL=juicefs-data
RADOS_USER=client.juicefs
ROUTE_TARGET=10.3.1.6
RUN_ID=${2:-}
ROOT="$REMOTE_PARENT/opencode-04tmp3d-$RUN_ID"
NAMESPACE="04tmp3d-$RUN_ID"
CEPH_CONF="$ROOT/common/ceph.conf"
SEED_SECONDS=900
READ_SECONDS=25
STABLE_SECONDS=15
SEED_THREADS=32
SIZES=(b256 b4)
QDS=(1 2 4 8 16 32 1)
SIZE_BYTES_b256=262144
SIZE_BYTES_b4=4194304
MAX_OBJECTS_b256=131072
MAX_OBJECTS_b4=8192
NIC=
STORAGE_HOSTS=(10.20.1.150 10.20.1.151 10.20.1.152)

die() { printf 'T04TMP3D_EXECUTOR_FAIL\t%s\n' "$*" >&2; exit 42; }
usage() {
  printf '%s\n' \
    'usage: t04tmp3d-executor.sh plan RUN_ID' \
    '       t04tmp3d-executor.sh inventory RUN_ID' \
    '       t04tmp3d-executor.sh canary RUN_ID I_ACK_04TMP3D_CANARY_RUN_ID' \
    '       t04tmp3d-executor.sh formal RUN_ID I_ACK_04TMP3D_FORMAL_RUN_ID' \
    '       t04tmp3d-executor.sh cleanup-plan RUN_ID' \
    '       t04tmp3d-executor.sh cleanup RUN_ID I_ACK_04TMP3D_CLEANUP_RUN_ID' \
    '       t04tmp3d-executor.sh --self-test' >&2
  exit 2
}
valid_scope() {
  [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ "$ROOT" == "$REMOTE_PARENT/opencode-04tmp3d-$RUN_ID" && "$ROOT" != / && "$ROOT" != *..* ]] || die unsafe_root
  [[ "$NAMESPACE" == "04tmp3d-$RUN_ID" ]] || die unsafe_namespace
  [[ ! -L "$ROOT" ]] || die root_symlink
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing_tool_$1"; }
ack() { [[ "${3:-}" == "I_ACK_04TMP3D_${1}_$RUN_ID" ]] || die "invalid_ACK_$1"; }
record() { printf '#' >>"$ROOT/commands.sh"; printf ' %q' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"; }
incident() { printf '%s\t%s\t%s\n' "$(date -Ins)" "$1" "$2" >>"$ROOT/incidents.tsv"; }
state() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tLUNA\n' "$(date -Ins)" "$RUN_ID" "$1" "$2" "$3" "$4" "$5" "$6" "$TASK_ROOT/$RUN_ID" >>"$ROOT/run-state.tsv"; }
ceph_cmd() { timeout 30 env CEPH_CONF="$CEPH_CONF" ceph "$@"; }
rados_cmd() { timeout "$1" env CEPH_CONF="$CEPH_CONF" rados --name "$RADOS_USER" "${@:2}"; }
ns_ls() { rados_cmd 30 -p "$POOL" -N "$NAMESPACE" ls; }
run_name() { printf '%s-%s' "$NAMESPACE" "$1"; }
size_bytes() { eval "printf '%s' \"\${SIZE_BYTES_$1}\""; }
max_objects() { eval "printf '%s' \"\${MAX_OBJECTS_$1}\""; }
seed_name() { run_name "$1-seed"; }
snapshot() {
  local tag=$1
  local out="$ROOT/snapshots/$1"
  mkdir -m 0700 -p "$out"
  record env CEPH_CONF="$CEPH_CONF" ceph -s --format json
  ceph_cmd -s --format json >"$out/health.json"
  ceph_cmd osd stat --format json >"$out/osd-stat.json"
  ceph_cmd pg stat --format json >"$out/pg-stat.json"
  ceph_cmd osd tree --format json >"$out/osd-tree.json"
  ceph_cmd osd perf >"$out/osd-perf.txt"
  record env CEPH_CONF="$CEPH_CONF" ceph tell 'osd.*' perf dump
  local host
  for host in "${STORAGE_HOSTS[@]}"; do
    record ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" iostat -dx 1 2
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" iostat -dx 1 2 </dev/null >"$out/iostat-$host.txt" 2>&1 || die "osd_iostat_failed_$host"
  done
  if [[ -n "$NIC" && -r "/sys/class/net/$NIC/statistics/rx_bytes" ]]; then
    local rx
    local tx
    rx=$(<"/sys/class/net/$NIC/statistics/rx_bytes")
    tx=$(<"/sys/class/net/$NIC/statistics/tx_bytes")
    printf 'rx_bytes\t%s\ntx_bytes\t%s\n' "$rx" "$tx" >"$out/client-nic.tsv"
  fi
  python3 - "$out/health.json" "$out/osd-stat.json" "$out/pg-stat.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); o=json.load(open(sys.argv[2])); p=json.load(open(sys.argv[3]))
if (s.get('health') or {}).get('status') != 'HEALTH_OK': raise SystemExit('health_not_ok')
if len({o.get(k) for k in ('num_osds','num_up_osds','num_in_osds')}) != 1: raise SystemExit('osd_not_all_up_in')
summary=p.get('pg_summary') or {}
states=summary.get('num_pg_by_state') or []
if not states or sum(int(x.get('num',0)) for x in states) != int(summary.get('num_pgs',-1)):
    raise SystemExit('pg_state_missing')
if any('active+clean' != x.get('name') for x in states): raise SystemExit('pg_not_active_clean')
PY
}
prepare_conf() {
  if [[ ! -f "$CEPH_CONF" ]]; then
    [[ -r /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die ceph_conf_missing
    cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
    printf '\n[client.juicefs]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
    sha256sum "$CEPH_CONF" >"$ROOT/common/ceph.conf.sha256"
  else
    sha256sum -c "$ROOT/common/ceph.conf.sha256" >/dev/null || die ceph_conf_drift
  fi
  grep -Fqx $'\tms_async_op_threads = 8' "$CEPH_CONF" || die ceph_conf_threads
}
find_nic() {
  local route="$ROOT/inventory/route.txt"
  ip route get "$ROUTE_TARGET" >"$route"
  NIC=$(awk '{for(i=1;i<=NF;i++) if($i=="dev"&&i<NF){print $(i+1); exit}}' "$route")
  [[ "$NIC" =~ ^[A-Za-z0-9_.:-]+$ && -r "/sys/class/net/$NIC/statistics/rx_bytes" ]] || die nic_unavailable
  printf '%s\n' "$NIC" >"$ROOT/inventory/nic.txt"
}
plan() {
  valid_scope; [[ ! -e "$ROOT" ]] || die root_exists
  mkdir -m 0700 -p "$ROOT"/{common,inventory,snapshots,cells,incidents,closure}
  printf 'epoch_iso\trun_id\tvalidity_state\tlifecycle_state\tremote_status\tlocal_status\tincident_status\treason\tevidence_root\tactor\n' >"$ROOT/run-state.tsv"
  printf 'epoch_iso\ttype\tdetail\n' >"$ROOT/incidents.tsv"
  printf '#!/usr/bin/env bash\n# Actual commands; credentials are not recorded.\n' >"$ROOT/commands.sh"
  printf 'key\tvalue\nrun_id\t%s\nevidence_level\tL1_SCREEN\nevidence_root\t%s\nremote_result_root\t%s\nevidence_retention\tSCREEN\nremote_cleanup\tAFTER_REVIEW\nlocal_compaction\tAFTER_REVIEW\nenvironment_asset_cleanup\tprecise namespace manifest and ACK\npool\t%s\nnamespace\t%s\nclient\t%s\n' "$RUN_ID" "$TASK_ROOT/$RUN_ID" "$ROOT" "$POOL" "$NAMESPACE" "$RADOS_USER" >"$ROOT/common/contract.tsv"
  printf 'size\tbytes\tmax_objects\tseed_run_name\n' >"$ROOT/common/matrix.tsv"
  for size in "${SIZES[@]}"; do printf '%s\t%s\t%s\t%s\n' "$size" "$(size_bytes "$size")" "$(max_objects "$size")" "$(seed_name "$size")" >>"$ROOT/common/matrix.tsv"; done
  state ACTIVE ACTIVE NONE PRESERVED NONE L0_PLAN
  printf 'T04TMP3D_PLAN_PASS\troot=%s\tnamespace=%s\n' "$ROOT" "$NAMESPACE"
}
inventory() {
  valid_scope; [[ -f "$ROOT/common/contract.tsv" ]] || die plan_required
  for x in ceph rados ip iostat ssh python3 sha256sum stat timeout hostname; do need "$x"; done
  prepare_conf; mkdir -m 0700 -p "$ROOT/inventory"; find_nic
  hostname -f >"$ROOT/inventory/hostname.txt"; date -Ins >"$ROOT/inventory/time.txt"
  ceph_cmd --version >"$ROOT/inventory/ceph-version.txt" 2>&1
  rados_cmd 30 --version >"$ROOT/inventory/rados-version.txt" 2>&1
  ceph_cmd fsid >"$ROOT/inventory/ceph-fsid.txt"
  snapshot inventory
  ns_ls >"$ROOT/inventory/namespace.tsv"
  [[ ! -s "$ROOT/inventory/namespace.tsv" ]] || die namespace_not_empty
  sha256sum "$EXECUTOR" "$ANALYZER" >"$ROOT/common/runtime-sha256.tsv"
  state ACTIVE ACTIVE NONE PRESERVED NONE INVENTORY_PASS
  printf 'T04TMP3D_INVENTORY_PASS\troot=%s\n' "$ROOT"
}
canary() {
  valid_scope; ack CANARY "$RUN_ID" "${3:-}"; [[ -f "$ROOT/inventory/ceph-fsid.txt" ]] || die inventory_required; prepare_conf
  local name out; name=$(run_name canary); out="$ROOT/cells/CANARY"; mkdir -m 0700 -p "$out"
  [[ ! -s "$ROOT/inventory/namespace.tsv" ]] || die namespace_not_empty
  record env CEPH_CONF="$CEPH_CONF" rados --name "$RADOS_USER" -p "$POOL" -N "$NAMESPACE" bench 20 write -b 4096 -t 1 --max-objects 1 --run-name "$name" --no-cleanup
  rados_cmd 60 -p "$POOL" -N "$NAMESPACE" bench 20 write -b 4096 -t 1 --max-objects 1 --run-name "$name" --no-cleanup >"$out/stdout" 2>"$out/stderr"
  ns_ls >"$out/objects-before.tsv"; [[ -s "$out/objects-before.tsv" ]] || die canary_object_missing
  record env CEPH_CONF="$CEPH_CONF" rados --name "$RADOS_USER" -p "$POOL" -N "$NAMESPACE" cleanup --run-name "$name"
  rados_cmd 60 -p "$POOL" -N "$NAMESPACE" cleanup --run-name "$name" >"$out/cleanup.stdout" 2>"$out/cleanup.stderr"
  ns_ls >"$out/objects-after.tsv"; [[ ! -s "$out/objects-after.tsv" ]] || die canary_cleanup_not_empty
  printf '%s\n' "$(date -Ins)" >"$ROOT/CANARY_PASS"; state ACTIVE ACTIVE NONE PRESERVED NONE CANARY_PASS
  printf 'T04TMP3D_CANARY_PASS\tname=%s\n' "$name"
}
sample_client() {
  local out=$1
  local pid=$2
  printf 'epoch_ns\tpid\tstarttime_ticks\tutime_ticks\tstime_ticks\trss_pages\tthreads\trx_bytes\ttx_bytes\n' >"$out/client-sidecar.tsv"
  while [[ -e "$out/SAMPLER_ON" ]]; do
    if [[ ! -r "/proc/$pid/stat" ]]; then return 0; fi
    local epoch
    local st
    local ut stime rss threads rx
    local tx
    read -r ut stime threads rss st < <(awk '{print $14,$15,$20,$24,$22}' "/proc/$pid/stat")
    epoch=$(date +%s%N)
    rx=$(<"/sys/class/net/$NIC/statistics/rx_bytes")
    tx=$(<"/sys/class/net/$NIC/statistics/tx_bytes")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$pid" "$st" "$ut" "$stime" "$rss" "$threads" "$rx" "$tx" >>"$out/client-sidecar.tsv"
    sleep 1
  done
}
read_cell() {
  local size=$1
  local qd=$2
  local idx=$3
  local seed
  local out
  local name
  local bytes
  local max
  local pid
  local rc
  idx=$(printf '%02d' "$idx"); seed=$(seed_name "$size"); out="$ROOT/cells/${size}-QD${idx}-q${qd}"; mkdir -m 0700 -p "$out"
  bytes=$(size_bytes "$size"); max=$(max_objects "$size"); name="$seed"
  snapshot "pre-${size}-QD${idx}-q${qd}"
  : >"$out/SAMPLER_ON"
  record env CEPH_CONF="$CEPH_CONF" rados --name "$RADOS_USER" -p "$POOL" -N "$NAMESPACE" bench "$READ_SECONDS" rand -t "$qd" --run-name "$name" --no-verify
  set +e
  timeout $((READ_SECONDS + 60)) env CEPH_CONF="$CEPH_CONF" rados --name "$RADOS_USER" -p "$POOL" -N "$NAMESPACE" bench "$READ_SECONDS" rand -t "$qd" --run-name "$name" --no-verify >"$out/stdout" 2>"$out/stderr" &
  local wrapper=$!; sleep 0.2
  pid=$(pgrep -P "$wrapper" -x rados | head -n1 || true); [[ "$pid" =~ ^[0-9]+$ ]] || { kill "$wrapper" 2>/dev/null || true; die rados_pid_missing; }
  sample_client "$out" "$pid" & local sampler=$!
  wait "$wrapper"; rc=$?; : >"$out/SAMPLER_OFF"; rm -f -- "$out/SAMPLER_ON"; wait "$sampler" || rc=43
  set -e
  printf '%s\n' "$rc" >"$out/rc"; printf '%s\n' "$pid" >"$out/pid"; [[ "$rc" == 0 ]] || { incident READ_RC "$size QD=$qd rc=$rc"; die read_failed; }
  python3 "$ANALYZER" cell "$out/stdout" --runtime "$READ_SECONDS" --stable "$STABLE_SECONDS" --size "$bytes" --qd "$qd" >"$out/analysis.json"
  snapshot "post-${size}-QD${idx}-q${qd}"
}
seed_one() {
  local size=$1
  local out="$ROOT/cells/${size}-SEED"
  local bytes
  local max
  local name
  bytes=$(size_bytes "$size"); max=$(max_objects "$size"); name=$(seed_name "$size"); mkdir -m 0700 -p "$out"
  [[ ! -e "$out/PASS" ]] || return 0
  snapshot "pre-${size}-SEED"
  record env CEPH_CONF="$CEPH_CONF" rados --name "$RADOS_USER" -p "$POOL" -N "$NAMESPACE" bench "$SEED_SECONDS" write -b "$bytes" -t "$SEED_THREADS" --max-objects "$max" --run-name "$name" --no-cleanup
  rados_cmd 1200 -p "$POOL" -N "$NAMESPACE" bench "$SEED_SECONDS" write -b "$bytes" -t "$SEED_THREADS" --max-objects "$max" --run-name "$name" --no-cleanup >"$out/stdout" 2>"$out/stderr"
  local writes object_size
  writes=$(awk -F: '/Total writes made:/{gsub(/[[:space:]]/,"",$2); print $2}' "$out/stdout" | tail -n1)
  object_size=$(awk -F: '/Object size:/{gsub(/[[:space:]]/,"",$2); print $2}' "$out/stdout" | tail -n1)
  [[ "$writes" == "$max" && "$object_size" == "$bytes" ]] || die "seed_contract_failed_${size}_writes_${writes}_object_size_${object_size}"
  ns_ls >"$out/objects.tsv"; [[ -s "$out/objects.tsv" ]] || die seed_objects_missing
  printf '%s\n' "$(date -Ins)" >"$out/PASS"; snapshot "post-${size}-SEED"
}
formal() {
  valid_scope; ack FORMAL "$RUN_ID" "${3:-}"; [[ -f "$ROOT/CANARY_PASS" ]] || die canary_required; prepare_conf; find_nic
  local size
  local qd
  local i=0
  record env CEPH_CONF="$CEPH_CONF" ceph tell 'osd.*' perf dump
  ceph_cmd tell 'osd.*' perf dump >"$ROOT/snapshots/formal-pre-osd-perf-dump.txt"
  for size in "${SIZES[@]}"; do
    seed_one "$size"
    for qd in "${QDS[@]}"; do i=$((i+1)); read_cell "$size" "$qd" "$i"; done
  done
  record env CEPH_CONF="$CEPH_CONF" ceph tell 'osd.*' perf dump
  ceph_cmd tell 'osd.*' perf dump >"$ROOT/snapshots/formal-final-osd-perf-dump.txt"
  snapshot formal-final; printf '%s\n' "$(date -Ins)" >"$ROOT/FORMAL_PASS"; state ACTIVE ACTIVE NONE PRESERVED NONE FORMAL_PASS
  printf 'T04TMP3D_FORMAL_PASS\troot=%s\n' "$ROOT"
}
cleanup_plan() {
  valid_scope; [[ -f "$ROOT/FORMAL_PASS" ]] || die formal_required; prepare_conf; mkdir -m 0700 -p "$ROOT/closure"
  ns_ls >"$ROOT/closure/namespace-before.tsv"
  : >"$ROOT/closure/cleanup-manifest.tsv"
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *$'\t'* && "$line" != *$'\n'* ]] || die invalid_namespace_object_name
    printf '%s\tRUN_NAMESPACE_OWNED\n' "$line" >>"$ROOT/closure/cleanup-manifest.tsv"
  done <"$ROOT/closure/namespace-before.tsv"
  sha256sum "$ROOT/closure/cleanup-manifest.tsv" >"$ROOT/closure/cleanup-manifest.sha256"
  printf 'T04TMP3D_CLEANUP_PLAN_PASS\tmanifest=%s\n' "$ROOT/closure/cleanup-manifest.tsv"
}
cleanup() {
  valid_scope; ack CLEANUP "$RUN_ID" "${3:-}"; [[ -f "$ROOT/closure/cleanup-manifest.tsv" ]] || die cleanup_plan_required; prepare_conf
  sha256sum -c "$ROOT/closure/cleanup-manifest.sha256" >/dev/null
  ns_ls >"$ROOT/closure/namespace-cleanup-start.tsv"
  cmp -s "$ROOT/closure/namespace-before.tsv" "$ROOT/closure/namespace-cleanup-start.tsv" || die namespace_changed_after_plan
  local run size
  for size in "${SIZES[@]}"; do
    [[ -f "$ROOT/cells/${size}-SEED/PASS" ]] || die "seed_state_missing_$size"
    run=$(seed_name "$size")
    record env CEPH_CONF="$CEPH_CONF" rados --name "$RADOS_USER" -p "$POOL" -N "$NAMESPACE" cleanup --run-name "$run"
    rados_cmd 900 -p "$POOL" -N "$NAMESPACE" cleanup --run-name "$run" >"$ROOT/closure/cleanup-${run}.stdout" 2>"$ROOT/closure/cleanup-${run}.stderr"
  done
  ns_ls >"$ROOT/closure/namespace-after.tsv"; [[ ! -s "$ROOT/closure/namespace-after.tsv" ]] || die namespace_not_empty_after_cleanup
  sha256sum "$ROOT/closure/namespace-before.tsv" "$ROOT/closure/namespace-after.tsv" >"$ROOT/closure/cleanup-audit.sha256"
  printf '%s\n' "$(date -Ins)" >"$ROOT/closure/CLEANUP_PASS"; state VALID CLOSED PURGED PRESERVED NONE CLEANUP_PASS
  printf 'T04TMP3D_CLEANUP_PASS\troot=%s\n' "$ROOT"
}
self_test() {
  RUN_ID=20260904-000000; ROOT="$REMOTE_PARENT/opencode-04tmp3d-$RUN_ID"; NAMESPACE="04tmp3d-$RUN_ID"
  valid_scope; [[ "$(run_name canary)" == 04tmp3d-20260904-000000-canary ]]; [[ "$(size_bytes b4)" == 4194304 ]]; [[ "$(max_objects b256)" == 131072 ]]
  printf 'T04TMP3D_EXECUTOR_SELFTEST_PASS\n'
}
case ${1:-} in
  plan) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3d-$RUN_ID"; NAMESPACE="04tmp3d-$RUN_ID"; plan;;
  inventory) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3d-$RUN_ID"; NAMESPACE="04tmp3d-$RUN_ID"; inventory;;
  canary) [[ $# -eq 3 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3d-$RUN_ID"; NAMESPACE="04tmp3d-$RUN_ID"; canary "$@";;
  formal) [[ $# -eq 3 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3d-$RUN_ID"; NAMESPACE="04tmp3d-$RUN_ID"; formal "$@";;
  cleanup-plan) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3d-$RUN_ID"; NAMESPACE="04tmp3d-$RUN_ID"; cleanup_plan;;
  cleanup) [[ $# -eq 3 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3d-$RUN_ID"; NAMESPACE="04tmp3d-$RUN_ID"; cleanup "$@";;
  --self-test) self_test;;
  *) usage;;
esac
