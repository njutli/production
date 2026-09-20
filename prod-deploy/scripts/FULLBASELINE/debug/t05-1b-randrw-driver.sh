#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 05-1b preparation driver: offline plan/Gate 0 plus separately ACK-gated
# online execution stages.  Gate 0 invokes only the offline paths; every
# environment-changing stage requires its own exact authorization token.
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ANALYZER="$SELF_DIR/t05-1b-randrw-analyze.py"
BASE_ANALYZER="$SELF_DIR/t05-1-randrw-analyze.py"
GATE0="$SELF_DIR/t05-1b-gate0-offline.sh"
TASKBOOK="$SELF_DIR/../../../doc/perf-tasks/05-1b-randrw-blocksize-and-bs-coupled-parameter-closure.md"
SCRUB_CONTROL="$SELF_DIR/u141d-scrub-control.sh"
RUN_ID=${2:-${1:-}}
OUT=${T051B_PLAN_OUT:-/tmp/t05-1b-plan-${RUN_ID}}
META_BASE=${T051B_META_BASE:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379}
META=${T051B_META:-$META_BASE/juicefs-prod}
POOL=juicefs-data
REMOTE_PARENT=/tmp/production
ROOT="$REMOTE_PARENT/opencode-05-1b-$RUN_ID"
JFS=${T051B_JFS:-/tmp/juicefs-1.4.1-patched}
FIO=${T051B_FIO:-fio}
REF=${T051B_REF:-/mnt/juicefs}
METRICS_C=${T051B_METRICS_C:-127.0.0.1:19658}
METRICS_T=${T051B_METRICS_T:-127.0.0.1:19659}
JFS_MD5=24fae0852051c80ca571cb2f20275d46
CEPH_CONF=
SCOPE=${T051B_SCOPE:-FULL}
L_T_BLOCK=${T051B_L_T_BLOCK:-4M}
L_T_BUFFER=${T051B_L_T_BUFFER:-300}
SCRUB_LEASE=${T051B_SCRUB_LEASE:-}
ACTIVE_SAMPLER_PID=
ACTIVE_SAMPLER_STOP=
sampler_exit_trap() {
  if [[ -n "$ACTIVE_SAMPLER_STOP" ]]; then printf 'STOP\n' >"$ACTIVE_SAMPLER_STOP"; fi
  if [[ -n "$ACTIVE_SAMPLER_PID" ]]; then wait "$ACTIVE_SAMPLER_PID" 2>/dev/null || :; fi
}
sampler_signal_trap() { sampler_exit_trap; exit 130; }
trap sampler_exit_trap EXIT
trap sampler_signal_trap INT TERM

die() { printf 'T051B_DRIVER_FAIL\t%s\n' "$*" >&2; exit 42; }
valid_run() {
  [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ "$ROOT" == "$REMOTE_PARENT/opencode-05-1b-$RUN_ID" && "$ROOT" != / && ! -L "$ROOT" ]] || die unsafe_root
}
valid_plan_output() {
  [[ "$OUT" == /tmp/t05-1b-plan-${RUN_ID} || "$OUT" == /tmp/t05-1b-plan-${RUN_ID}/* || "$OUT" == /tmp/t05-1b-gate0-*/* ]] || die unsafe_output
  [[ "$OUT" != / && ! -L "$OUT" ]] || die unsafe_output
}
group_meta() { printf '%s/jfs-05-1b-%s-%s-%s' "$META_BASE" "$RUN_ID" "$1" "$2"; }
group_name() { printf 'jfs-05-1b-%s-%s-%s' "$RUN_ID" "${1,,}" "$2"; }
group_mnt() { printf '/tmp/jfs-05-1b-%s-%s-%s' "$RUN_ID" "$1" "$2"; }

write_matrix() {
  local target=${1:-$OUT}
  mkdir -m 0700 -p "$target"
  printf 'stage\tgroup\tposition\tarm\tfio_bs\tvolume_bs\tfuse\n' >"$target/matrix.tsv"
  # A: representative FUSE64 screen on the fixed B256 asset.
  printf 'A\tA\t1\tC1\t64K\t256K\t256K\nA\tA\t2\tT1\t64K\t256K\t64K\nA\tA\t3\tT2\t64K\t256K\t64K\nA\tA\t4\tC2\t64K\t256K\t256K\n' >>"$target/matrix.tsv"
  # M/L are fresh-volume CTTC pairs with the same FUSE value in both arms.
  printf 'B\tM\t1\tC1\t1M\t256K\t1M\nB\tM\t2\tT1\t1M\t1M\t1M\nB\tM\t3\tT2\t1M\t1M\t1M\nB\tM\t4\tC2\t1M\t256K\t1M\n' >>"$target/matrix.tsv"
  printf 'B\tL\t1\tC1\t4M\t256K\t1M\nB\tL\t2\tT1\t4M\t%s\t1M\nB\tL\t3\tT2\t4M\t%s\t1M\nB\tL\t4\tC2\t4M\t256K\t1M\n' "$L_T_BLOCK" "$L_T_BLOCK" >>"$target/matrix.tsv"
  # S is fixed and balanced; it is deliberately last because B64 layout is
  # the largest object-count change.
  printf 'B\tS\t1\tC-4K\t4K\t256K\tFUSE64_OR_256\nB\tS\t2\tC-16K\t16K\t256K\tFUSE64_OR_256\nB\tS\t3\tC-64K\t64K\t256K\tFUSE64_OR_256\nB\tS\t4\tT-4K\t4K\t64K\tFUSE64_OR_256\nB\tS\t5\tT-16K\t16K\t64K\tFUSE64_OR_256\nB\tS\t6\tT-64K\t64K\t64K\tFUSE64_OR_256\nB\tS\t7\tT-64K\t64K\t64K\tFUSE64_OR_256\nB\tS\t8\tT-16K\t16K\t64K\tFUSE64_OR_256\nB\tS\t9\tT-4K\t4K\t64K\tFUSE64_OR_256\nB\tS\t10\tC-64K\t64K\t256K\tFUSE64_OR_256\nB\tS\t11\tC-16K\t16K\t256K\tFUSE64_OR_256\nB\tS\t12\tC-4K\t4K\t256K\tFUSE64_OR_256\n' >>"$target/matrix.tsv"
}

write_volume_plan() {
  printf 'stage\tgroup\tarm\tmeta\tname\tblock_size\taction\tstatus\tprecise_command\n' >"$OUT/format-layout-destroy-plan.tsv"
  local group arm block meta name mnt
  for group in M L S; do
    for arm in c t; do
      block=256K
      [[ "$group:$arm" == M:t ]] && block=1M
      [[ "$group:$arm" == L:t ]] && block=$L_T_BLOCK
      [[ "$group:$arm" == S:t ]] && block=64K
      meta=$(group_meta "$group" "$arm"); name=$(group_name "$group" "$arm"); mnt=$(group_mnt "$group" "$arm")
      printf 'B\t%s\t%s\t%s\t%s\t%s\tformat\tPLAN_ONLY\tjuicefs format --no-update --storage ceph --bucket ceph://%s --access-key REDACTED --secret-key REDACTED --block-size %s --compress none --trash-days 0 %s %s\n' \
        "$group" "$arm" "$meta" "$name" "$block" "$POOL" "$block" "$meta" "$name" >>"$OUT/format-layout-destroy-plan.tsv"
      printf 'B\t%s\t%s\t%s\t%s\t%s\tlayout\tPLAN_ONLY\tfio template: 128 real-write jobs, filename=%s/test_dir/rw_test.$jobnum.0, rw=write, bs=16M, size=1G, direct=1, allow_file_create=1, end_fsync=1\n' \
        "$group" "$arm" "$meta" "$name" "$block" "$mnt" >>"$OUT/format-layout-destroy-plan.tsv"
      printf 'B\t%s\t%s\t%s\t%s\t%s\tdestroy\tPLAN_ONLY\tjuicefs destroy %s <UUID-from-status-%s> --yes\n' \
        "$group" "$arm" "$meta" "$name" "$block" "$meta" "$group" >>"$OUT/format-layout-destroy-plan.tsv"
    done
  done
  printf 'A\tA\tc/t\tREFERENCE\tjuicefs-prod\t256K\tformat-layout-destroy\tNOT_USED\treuse existing fixed 128x1GiB asset\n' >>"$OUT/format-layout-destroy-plan.tsv"
}

write_recovery_plan() {
  cat >"$OUT/recovery-plan.tsv" <<'EOF'
action	status	precise_plan	owner
health-pre/post	PLAN_ONLY	ceph health JSON; six OSD up/in; PG active+clean	operator after G0
gc	PLAN_ONLY	juicefs gc --compact --delete <META>	operator after G0
ceph-cooldown	PLAN_ONLY	passively wait for stable pool objects/stored and TiKV pending=0; no automatic OSD compact	operator after G0
scrub-pause	PLAN_ONLY	u141d-scrub-control.sh plan-pause; setting noscrub/nodeep-scrub is a separate user-authorized action before S run	operator after G0
scrub-restore	PLAN_ONLY	u141d-scrub-control.sh plan-restore; restore and verify exact pre-test flags immediately after S run	operator after G0
mount	PLAN_ONLY	graceful mount with cache-size=0, writeback disabled, exact RUN paths	operator after G0
destroy	PLAN_ONLY	status UUID, compare META+Name+UUID, then exact destroy only	operator after G0
EOF
  printf '%s\n' $'identity\tPLAN_ONLY\tcapture every mount parent/worker PID, starttime_ticks and exe_md5; stop on drift\toperator after G0' >>"$OUT/recovery-plan.tsv"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die missing_tool_$1; }
require_ack() {
  local stage=$1 supplied=$2
  [[ "$supplied" == "I_ACK_05_1B_${stage}_$RUN_ID" ]] || die invalid_ack_$stage
}
online_scope() {
  valid_run
  [[ "$SCOPE" == FULL || "$SCOPE" == LS_RETEST ]] || die invalid_scope
  [[ "$L_T_BLOCK" == 4M || "$L_T_BLOCK" == 1M ]] || die invalid_L_treatment_block
  [[ "$L_T_BUFFER" == 300 || "$L_T_BUFFER" == 1024 ]] || die invalid_L_treatment_buffer
  [[ "$ROOT" == "$REMOTE_PARENT/opencode-05-1b-$RUN_ID" ]] || die unsafe_root
  if [[ -e "$ROOT" ]]; then
    [[ -d "$ROOT" && "$(stat -Lc %a "$ROOT")" == 700 && "$(stat -Lc %u "$ROOT")" == "$(id -u)" ]] || die root_identity
  fi
}
record_cmd() {
  mkdir -m 0700 -p "$ROOT"
  [[ -f "$ROOT/commands.sh" ]] || printf '# actual commands; credentials are redacted\n' >"$ROOT/commands.sh"
  printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"
}
ceph_read() { timeout 30 env CEPH_CONF="$CEPH_CONF" ceph "$@"; }
prepare_ceph_conf() {
  CEPH_CONF="$ROOT/inventory/ceph.conf"
  if [[ ! -f "$CEPH_CONF" ]]; then
    [[ -r /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die ceph_conf_missing
    cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
    printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
    chmod 0600 "$CEPH_CONF"; sha256sum "$CEPH_CONF" >"$ROOT/inventory/ceph.conf.sha256"
  else
    sha256sum -c "$ROOT/inventory/ceph.conf.sha256" >/dev/null || die ceph_conf_drift
  fi
  grep -Fqx $'\tms_async_op_threads = 8' "$CEPH_CONF" || die ceph_msgr_threads
  export CEPH_CONF
}
health_gate() {
  local tag=$1 out="$ROOT/health-$1"
  mkdir -m 0700 -p "$out"
  ceph_read -s --format json >"$out/status.json" || die health_status_$tag
  ceph_read osd stat --format json >"$out/osd-stat.json" || die health_osd_$tag
  ceph_read pg dump pgs_brief >"$out/pgs.txt" || die health_pg_$tag
  if [[ -n "$SCRUB_LEASE" ]]; then
    [[ "$SCRUB_LEASE" == "05-1b-${RUN_ID}-phase-b" || "$SCRUB_LEASE" == "05-1b-${RUN_ID}-s4k-phase-b" ]] || die scrub_lease_scope_$tag
    U141D_CEPH_CONF="$CEPH_CONF" "$SCRUB_CONTROL" verify-paused "$SCRUB_LEASE" >"$out/scrub-lease.tsv" || die scrub_lease_invalid_$tag
  fi
  python3 - "$out/status.json" "$out/osd-stat.json" "$out/pgs.txt" "${SCRUB_LEASE:+paused}" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); o=json.load(open(sys.argv[2]))
health=s.get('health') or {}; status=health.get('status'); paused=sys.argv[4]=='paused'
checks=health.get('checks') or {}
if paused:
    if not (status == 'HEALTH_OK' and not checks) and not (status == 'HEALTH_WARN' and set(checks) == {'OSDMAP_FLAGS'}):
        raise SystemExit('paused Ceph health has unexpected checks')
elif status != 'HEALTH_OK':
    raise SystemExit('Ceph health is not HEALTH_OK')
if any(o.get(k) != o.get('num_osds') for k in ('num_up_osds','num_in_osds')): raise SystemExit('OSDs not all up/in')
states=[]
for line in open(sys.argv[3]):
    f=line.split()
    if f and f[0][:1].isdigit() and len(f)>1: states.append(f[1])
if not states or any(x != 'active+clean' for x in states): raise SystemExit('PGs not active+clean')
PY
}
status_identity() {
  local meta=$1 expected=$2 out=$3
  env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$out.json" || die status_failed
  python3 - "$out.json" "$expected" >"$out.tsv" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('Setting') or {}
if s.get('Name') != sys.argv[2] or not isinstance(s.get('UUID'),str) or not s['UUID']:
    raise SystemExit('volume identity mismatch')
print('name\t'+s['Name']); print('uuid\t'+s['UUID']); print('block_size\t'+str(s.get('BlockSize')))
PY
}
expected_block_size() {
  local group=$1 arm=$2
  case "$group:$arm" in
    M:c|L:c|S:c) printf '256K' ;;
    M:t) printf '1M' ;;
    L:t) printf '%s' "$L_T_BLOCK" ;;
    S:t) printf '64K' ;;
    *) die invalid_block_size_arm ;;
  esac
}
block_size_matches() {
  local expected=$1 actual=$2
  case "$expected:$actual" in
    256K:256K|256K:256|1M:1M|1M:1024|4M:4M|4M:4096|64K:64K|64K:64) return 0 ;;
    *) return 1 ;;
  esac
}
metrics_for_arm() {
  case "$1" in
    c|C|C1|C2) printf '%s' "$METRICS_C" ;;
    t|T|T1|T2) printf '%s' "$METRICS_T" ;;
    *) die invalid_metrics_arm ;;
  esac
}
metrics_port() { printf '%s' "${1##*:}"; }
metrics_ports_distinct() { [[ "$(metrics_port "$METRICS_C")" != "$(metrics_port "$METRICS_T")" ]]; }
pid_starttime_gone() {
  local pid=$1 expected=$2 current
  [[ ! -r "/proc/$pid/stat" ]] && return 0
  current=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
  [[ -z "$current" || "$current" != "$expected" ]]
}
metrics_port_released() {
  local port=$1
  ! ss -ltnH 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" {found=1} END{exit found ? 0 : 1}'
}
verify_assets() {
  local path=$1 output=$2
  find "$path/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$output"
  [[ $(wc -l <"$output") -eq 128 ]] || die asset_count_$(basename "$output")
  awk -F '\t' '$3 != 1073741824 {bad=1} END{exit bad}' "$output" || die asset_size_$(basename "$output")
}
recovery_gate() {
  local tag=$1
  local out="$ROOT/recovery-$tag"
  local pending host metric_file
  mkdir -m 0700 -p "$out"
  ceph_read df -f json >"$out/pool.json" || die pool_read_$tag
  python3 - "$out/pool.json" >"$out/pool.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
p=[p for p in d.get('pools',[]) if p.get('name')=='juicefs-data']
if len(p)!=1: raise SystemExit('juicefs-data pool missing')
q=p[0].get('stats',{})
if any(not isinstance(q.get(k),(int,float)) or q[k] < 0 for k in ('objects','stored')):
    raise SystemExit('juicefs-data objects/stored missing or invalid')
print(int(q['objects']), int(q['stored']), sep='\t')
PY
  : >"$out/pending.tsv"
  for host in 10.20.1.150 10.20.1.151 10.20.1.152; do
    metric_file="$out/tikv-$host.pending"
    curl --fail --silent --show-error --connect-timeout 3 --max-time 10 "http://$host:20180/metrics" |
      awk '$1 ~ /^tikv_engine_pending_compaction_bytes(\{|$)/ {print}' >"$metric_file" || die tikv_pending_read_$tag
    [[ -s "$metric_file" ]] || die tikv_pending_metric_missing_$tag
    pending=$(awk '{v=$2; if (v !~ /^[-+]?[0-9]+([.][0-9]*)?$/ || v+0 < 0) bad=1; else {s+=v; n++}} END{if(bad || !n) exit 1; printf "%.0f",s}' "$metric_file") || die tikv_pending_invalid_$tag
    printf '%s\t%s\n' "$host" "$pending" >>"$out/pending.tsv"
  done
  printf 'RECOVERY_SNAPSHOT\ttag=%s\tobjects_stored_recorded=true\tpending_recorded=true\n' "$tag" >"$out/snapshot.tsv"
}
quiet_wait() {
  local tag=$1 reference=${2:-} out="$ROOT/recovery-quiet-$1" stable=0 i objects stored prev_objects prev_stored ref_objects ref_stored
  mkdir -m 0700 -p "$out"; : >"$out/quiet.tsv"
  if [[ -n "$reference" ]]; then read -r ref_objects ref_stored <"$reference" || die recovery_reference_invalid; fi
  for i in $(seq 1 60); do
    recovery_gate "quiet-${tag}-${i}"
    read -r objects stored <"$ROOT/recovery-quiet-${tag}-${i}/pool.tsv" || die recovery_pool_snapshot_invalid
    if awk '$2 != 0 {bad=1} END{exit bad+0}' "$ROOT/recovery-quiet-${tag}-${i}/pending.tsv" &&
       [[ -n "${prev_objects:-}" ]] && [[ "$objects" == "$prev_objects" ]] &&
       awk -v a="$stored" -v b="$prev_stored" 'BEGIN{d=a-b;if(d<0)d=-d;exit d<=16777216?0:1}' &&
       { [[ -z "$reference" ]] || { [[ "$objects" == "$ref_objects" ]] && awk -v a="$stored" -v b="$ref_stored" 'BEGIN{d=a-b;if(d<0)d=-d;exit d<=16777216?0:1}'; }; }; then
      stable=$((stable+1))
    else
      stable=0
    fi
    printf '%s\t%s\t%s\t%s\n' "$i" "$objects" "$stored" "$stable" >>"$out/quiet.tsv"
    prev_objects=$objects; prev_stored=$stored
    if (( stable >= 3 )); then
      printf 'QUIET_WAIT_PASS\tobjects=%s\tstored=%s\tconsecutive=%s\n' "$objects" "$stored" "$stable" >"$out/PASS"
      printf '%s\t%s\n' "$objects" "$stored" >"$out/pool.tsv"
      return 0
    fi
    sleep 10
  done
  die recovery_state_not_quiet_$tag
}
volume_gc() {
  local group=$1 arm=$2 tag=$3 reference=$4 meta
  if [[ "$group" == A ]]; then meta="$META"; else meta=$(group_meta "$group" "$arm"); fi
  record_cmd env "CEPH_CONF=$CEPH_CONF" "$JFS" gc --compact --delete --threads 32 "$meta"
  timeout 1800 env CEPH_CONF="$CEPH_CONF" "$JFS" gc --compact --delete --threads 32 "$meta" >"$ROOT/recovery-gc-$tag.stdout" 2>"$ROOT/recovery-gc-$tag.stderr" || die volume_gc_failed_$tag
  quiet_wait "$tag" "$reference"
}
sample_window() {
  local cell=$1 metrics=$2 pidfile=$3 stopfile=$4
  local out="$ROOT/cells/$cell/formal"
  local ts pid st rss rx tx
  printf 'epoch_ns\tmetric_source\tpayload\n' >"$out/juicefs-metrics.tsv"
  printf 'epoch_ns\tpid\tstarttime_ticks\tutime\tstime\trss_bytes\trx_bytes\ttx_bytes\n' >"$out/client-sidecar.tsv"
  while [[ ! -f "$out/fio-start-epoch-ns.txt" && "$(cat "$stopfile" 2>/dev/null || true)" != STOP ]]; do sleep 1; done
  while [[ ! -f "$out/fio-end-epoch-ns.txt" && "$(cat "$stopfile" 2>/dev/null || true)" != STOP ]]; do
    ts=$(date +%s%N)
    curl --fail --silent --max-time 5 "http://$metrics/metrics" |
      awk -v t="$ts" 'BEGIN{ORS=""} /^juicefs_/ {print t "\tjuicefs\t" $0 "\n"}' >>"$out/juicefs-metrics.tsv" || true
    while IFS=$'\t' read -r pid _ st _ _; do
      [[ "$pid" == pid || ! -r "/proc/$pid/stat" ]] && continue
      read -r utime stime < <(awk '{print $14,$15}' "/proc/$pid/stat") || continue
      rss=$(awk '/^VmRSS:/{print $2*1024; exit}' "/proc/$pid/status" 2>/dev/null || printf '0')
      rx=$(awk '{s+=$1} END{print s+0}' /sys/class/net/*/statistics/rx_bytes 2>/dev/null || printf '0')
      tx=$(awk '{s+=$1} END{print s+0}' /sys/class/net/*/statistics/tx_bytes 2>/dev/null || printf '0')
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$pid" "$st" "$utime" "$stime" "$rss" "$rx" "$tx" >>"$out/client-sidecar.tsv"
    done <"$pidfile"
    sleep 1
  done
}
validate_sampling() {
  local cell=$1
  local out="$ROOT/cells/$cell/formal"
  local start end metric_rows client_rows stopfile evidence
  start=$(cat "$out/fio-start-epoch-ns.txt"); end=$(cat "$out/fio-end-epoch-ns.txt")
  start=$(python3 - "$out/fio.json" "$end" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); jobs=d.get('jobs') or []
r=[float(j.get(k,{}).get('runtime',0)) for j in jobs for k in ('read','write') if float(j.get(k,{}).get('runtime',0)) > 0]
if not r: raise SystemExit('directional runtime missing')
print(int(sys.argv[2])-int(max(r)*1000000))
PY
  ) || die actual_io_start_missing_$cell
  printf '%s\n' "$start" >"$out/actual-io-start-epoch-ns.txt"
  stopfile="$out/STOP_SAMPLER"; [[ -e "$stopfile" ]] || die sampler_stop_missing_$cell
  metric_rows=$(awk 'NR>1 && $1 ~ /^[0-9]+$/ {n++} END{print n+0}' "$out/juicefs-metrics.tsv")
  client_rows=$(awk 'NR>1 && $1 ~ /^[0-9]+$/ {n++} END{print n+0}' "$out/client-sidecar.tsv")
  (( metric_rows >= 30 )) || die metrics_formal_window_missing_$cell
  (( client_rows >= 30 )) || die client_formal_window_missing_$cell
  for evidence in "$out/juicefs-metrics.tsv" "$out/client-sidecar.tsv"; do
    awk -F '\t' -v s="$start" 'BEGIN{lo=s+15000000000;hi=s+175000000000} NR>1 && $1 ~ /^[0-9]+$/ && $1>=lo && $1<hi {if(!seen){first=$1;seen=1} if(prev && $1!=prev && $1-prev>3000000000)bad=1; if($1!=prev)n++;prev=$1;last=$1} END{if(!seen || first>lo+3000000000 || last<hi-3000000000 || n<30 || bad)exit 1}' "$evidence" || die sampler_window_gap_$(basename "$evidence")_$cell
  done
  printf 'SAMPLER_COVERAGE_PASS\tmetrics_rows=%s\tclient_rows=%s\n' "$metric_rows" "$client_rows" >"$out/sampler-status.tsv"
}
mount_pid_guard() {
  local mnt=$1 log=$2 out=$3
  python3 - "$JFS" "$mnt" "$log" >"$out" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]); marker=sys.argv[3]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(p/'exe') != exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        if marker not in cmd: continue
        st=(p/'stat').read_text().split()
        rows.append((int(p.name),int(st[3]),int(st[21]),hashlib.md5(open(p/'exe','rb').read()).hexdigest(),cmd))
    except (OSError,ValueError,IndexError): pass
if len(rows) != 2 or not any(a[1] == b[0] or b[1] == a[0] for a in rows for b in rows if a != b):
    raise SystemExit('mount parent/worker identity is not a unique pair')
print('pid\tppid\tstarttime_ticks\texe_md5\tcmdline')
for row in sorted(rows): print(*row,sep='\t')
PY
}
mount_one() {
  local group=$1 arm=$2 cell=$3 mode=$4 fuse=$5
  local buffer=${6:-300}
  local meta mnt out log expected_name metrics
  [[ "$buffer" == 300 || "$buffer" == 1024 ]] || die invalid_mount_buffer_$cell
  if [[ "$group" == A ]]; then meta="$META"; expected_name=juicefs-prod; else meta=$(group_meta "$group" "$arm"); expected_name=$(group_name "$group" "$arm"); fi
  metrics=$(metrics_for_arm "$arm"); metrics_port_released "$(metrics_port "$metrics")" || die metrics_port_busy_$arm; mnt=$(group_mnt "$group" "$arm"); out="$ROOT/cells/$cell"; log="$out/mount-$arm.log"
  mkdir -m 0700 -p "$out"; [[ ! -e "$mnt" && ! -L "$mnt" ]] || die mount_path_exists
  mkdir -m 0700 "$mnt"
  local -a cmd=(env "CEPH_CONF=$CEPH_CONF" "$JFS" mount -d --log "$log" --metrics "$metrics" --max-fuse-io "$fuse" --max-downloads 200 --max-uploads 150 --buffer-size "$buffer" --cache-size 0)
  [[ "$mode" == ro ]] && cmd+=(--read-only)
  cmd+=("$meta" "$mnt")
  record_cmd "${cmd[@]}"
  timeout 180 "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr" || die mount_failed_$cell
  for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout_$cell
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/findmnt.tsv"
  grep -Fq "JuiceFS:$expected_name $mnt fuse.juicefs" "$out/findmnt.tsv" || die mount_identity_$cell
  mount_pid_guard "$mnt" "$log" "$out/mount-processes.tsv" || die mount_process_identity_$cell
  printf 'group\t%s\narm\t%s\nfuse\t%s\nbuffer_mib\t%s\nmetrics\t%s\nmount\t%s\n' "$group" "$arm" "$fuse" "$buffer" "$metrics" "$mnt" >"$out/mount-state.tsv"
}
graceful_umount() {
  local cell=$1
  local out="$ROOT/cells/$cell"
  local mnt metrics port pid st
  mnt=$(awk -F '\t' '$1=="mount"{print $2}' "$out/mount-state.tsv")
  metrics=$(awk -F '\t' '$1=="metrics"{print $2}' "$out/mount-state.tsv")
  record_cmd env "CEPH_CONF=$CEPH_CONF" "$JFS" umount "$mnt"
  timeout 180 env CEPH_CONF="$CEPH_CONF" "$JFS" umount "$mnt" >"$out/umount.stdout" 2>"$out/umount.stderr" || die umount_failed_$cell
  for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done
  mountpoint -q "$mnt" && die mount_remains_$cell
  rmdir -- "$mnt" || die mount_dir_not_empty_$cell
  while IFS=$'\t' read -r pid _ st _ _; do
    [[ "$pid" == pid ]] && continue
    for _ in $(seq 1 30); do pid_starttime_gone "$pid" "$st" && break; sleep 1; done
    pid_starttime_gone "$pid" "$st" || die mount_pid_remains_$cell
  done <"$out/mount-processes.tsv"
  port=$(metrics_port "$metrics")
  for _ in $(seq 1 30); do metrics_port_released "$port" && break; sleep 1; done
  metrics_port_released "$port" || die metrics_port_remains_$cell
  printf 'GRACEFUL_UMOUNT_PASS\n' >"$out/umount.pass"
}
saved_mount_identity() {
  local group=$1 arm=$2 cell=$3 mnt expected_name pid st md5 current
  mnt=$(group_mnt "$group" "$arm"); expected_name=$(group_name "$group" "$arm")
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/cells/$cell/recover-findmnt.tsv"
  grep -Fq "JuiceFS:$expected_name $mnt fuse.juicefs" "$ROOT/cells/$cell/recover-findmnt.tsv" || die recover_mount_identity_${group}_${arm}
  while IFS=$'\t' read -r pid _ st md5 _; do
    [[ "$pid" == pid ]] && continue
    [[ -r "/proc/$pid/stat" ]] || die recover_pid_missing_${group}_${arm}
    current=$(awk '{print $22}' "/proc/$pid/stat")
    [[ "$current" == "$st" ]] || die recover_pid_starttime_drift_${group}_${arm}
    [[ "$(md5sum "/proc/$pid/exe" | awk '{print $1}')" == "$md5" ]] || die recover_pid_exe_drift_${group}_${arm}
  done <"$ROOT/cells/$cell/mount-processes.tsv"
}
group_recover_mounts() {
  online_scope; local group=$1; require_ack "RECOVER_MOUNTS_$group" "${2:-}"
  [[ "$group" =~ ^(M|L|S)$ ]] || die invalid_group; prepare_ceph_conf
  local arm cell mnt candidate
  for arm in c t; do
    mnt=$(group_mnt "$group" "$arm"); cell=
    for candidate in "L-B4M-buffer-1024-r2" "L-B4M-buffer-300-r2" \
      "L-B4M-buffer-1024" "L-B4M-buffer-300" "$group-mount-$arm" "LAYOUT-$group-$arm"; do
      if [[ -f "$ROOT/cells/$candidate/mount-state.tsv" && -f "$ROOT/cells/$candidate/mount-processes.tsv" ]]; then
        cell=$candidate
        break
      fi
    done
    if mountpoint -q "$mnt"; then
      [[ -n "$cell" ]] || die recover_identity_evidence_missing_${group}_${arm}
      saved_mount_identity "$group" "$arm" "$cell"; graceful_umount "$cell"
    fi
  done
  printf 'T051B_GROUP_RECOVER_MOUNTS_PASS\tgroup=%s\n' "$group"
}
phase_a_fuse() {
  local signed=${T051B_PHASE_A_SIGNED_FILE:-}
  [[ "$SCOPE" != LS_RETEST ]] || signed="$ROOT/inventory/phase-a-decision.tsv"
  [[ -n "$signed" && -f "$signed" && ! -L "$signed" ]] || die phase_a_signed_file_required
  local value
  value=$(awk -F '\t' '$1=="selected_fuse" || $1=="fuse" {print $2; exit}' "$signed")
  [[ "$value" == 64K || "$value" == 256K ]] || die phase_a_signed_fuse_invalid
  grep -Eq $'^(status|verdict)\t(PASS|SIGNED|ACCEPTED)$' "$signed" || die phase_a_decision_unsigned
  printf '%s\n' "$value"
}
capture_retest_decision() {
  [[ "$SCOPE" == LS_RETEST ]] || return 0
  local source=${T051B_PHASE_A_SIGNED_FILE:-} expected_sha=${T051B_PHASE_A_SIGNED_SHA256:-} actual_sha source_run
  [[ -n "$source" && -f "$source" && ! -L "$source" ]] || die retest_phase_a_source_required
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die retest_phase_a_sha_required
  actual_sha=$(sha256sum "$source" | awk '{print $1}')
  [[ "$actual_sha" == "$expected_sha" ]] || die retest_phase_a_source_sha_drift
  source_run=$(awk -F '\t' '$1=="run_id"{print $2; exit}' "$source")
  [[ "$source_run" =~ ^[0-9]{8}-[0-9]{6}$ && "$source_run" != "$RUN_ID" ]] || die retest_phase_a_source_run_invalid
  grep -Fqx $'selected_fuse\t256K' "$source" || die retest_phase_a_must_be_256K
  cp -- "$source" "$ROOT/inventory/phase-a-decision.tsv"
  printf 'source_run\t%s\nsource_path\t%s\nsha256\t%s\n' "$source_run" "$source" "$actual_sha" >"$ROOT/inventory/phase-a-decision-source.tsv"
}
run_fio_cell() {
  local cell=$1 path=$2 bs=$3 fuse=$4
  local mount_cell=${5:-$cell}
  local log_mode=${6:-per-job} per_job_logs=1 log_avg_msec=1000
  local out="$ROOT/cells/$cell/formal" job rc sampler_pid metrics pidfile stopfile sampler_rc
  [[ "$log_mode" == per-job || "$log_mode" == aggregate || "$log_mode" == completion ]] || die invalid_bw_log_mode_$cell
  [[ "$log_mode" == per-job ]] || per_job_logs=0
  [[ "$log_mode" != completion ]] || log_avg_msec=0
  mkdir -m 0700 -p "$ROOT/cells/$cell"
  [[ ! -e "$out" && ! -L "$out" ]] || die formal_dir_exists_$cell
  mkdir -m 0700 "$out"; mkdir -m 0700 "$out/bw"; job="$out/fio.job"
  metrics=$(awk -F '\t' '$1=="metrics"{print $2}' "$ROOT/cells/$mount_cell/mount-state.tsv")
  pidfile="$ROOT/cells/$mount_cell/mount-processes.tsv"
  [[ -s "$pidfile" ]] || die mount_pid_evidence_missing_$cell
  printf '%s\n' '[global]' 'ioengine=libaio' 'iodepth=128' 'numjobs=128' 'rw=randrw' 'rwmixread=50' "bs=$bs" 'filesize=1G' 'size=1G' 'direct=1' 'fallocate=none' 'allow_file_create=0' 'openfiles=128' 'time_based=1' 'runtime=180' 'group_reporting=1' 'randrepeat=1' >"$job"
  if [[ "$log_mode" == completion ]]; then
    printf 'write_lat_log=%s\n' "$out/bw/randrw" >>"$job"
  else
    printf 'write_bw_log=%s\n' "$out/bw/randrw" >>"$job"
  fi
  printf '%s\n' "log_avg_msec=$log_avg_msec" "per_job_logs=$per_job_logs" "filename_format=$path/test_dir/rw_test.\$jobnum.0" '[job]' >>"$job"
  printf '%s\n' "$log_mode" >"$out/bw-log-mode.txt"
  printf '%s\n' "$bs" >"$ROOT/cells/$cell/bs.txt"; printf 'fuse\t%s\nmount_source\t%s\n' "$fuse" "$mount_cell" >>"$ROOT/cells/$cell/mount-state.tsv"
  verify_assets "$path" "$out/assets-before.tsv"
  stopfile="$out/STOP_SAMPLER"; printf 'RUNNING\n' >"$stopfile"
  record_cmd timeout 240 "$FIO" "$job" --output="$out/fio.json" --output-format=json+
  sample_window "$cell" "$metrics" "$pidfile" "$stopfile" & sampler_pid=$!
  ACTIVE_SAMPLER_PID=$sampler_pid; ACTIVE_SAMPLER_STOP=$stopfile
  date +%s%N >"$out/fio-start-epoch-ns.txt"
  set +e; timeout 240 "$FIO" "$job" --output="$out/fio.json" --output-format=json+ >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; set -e
  date +%s%N >"$out/fio-end-epoch-ns.txt"; printf 'STOP\n' >"$stopfile"; set +e; wait "$sampler_pid"; sampler_rc=$?; set -e; ACTIVE_SAMPLER_PID=; ACTIVE_SAMPLER_STOP=
  printf '%s\n' "$rc" >"$out/fio.rc"; (( rc == 0 )) || die fio_failed_$cell
  (( sampler_rc == 0 )) || die sampler_failed_$cell
  verify_assets "$path" "$out/assets-after.tsv"; cmp -s "$out/assets-before.tsv" "$out/assets-after.tsv" || die asset_drift_$cell
  validate_sampling "$cell"
  if [[ "$log_mode" == per-job ]]; then
    [[ $(find "$out/bw" -maxdepth 1 -type f -name 'randrw_bw.*.log' | wc -l) -eq 128 ]] || die bw_log_count_$cell
  elif [[ "$log_mode" == aggregate ]]; then
    [[ -s "$out/bw/randrw_bw.log" ]] || die aggregate_bw_log_missing_$cell
    [[ $(find "$out/bw" -maxdepth 1 -type f -name 'randrw_bw*.log' | wc -l) -eq 1 ]] || die aggregate_bw_log_count_$cell
  else
    [[ -s "$out/bw/randrw_clat.log" ]] || die completion_log_missing_$cell
    [[ $(find "$out/bw" -maxdepth 1 -type f -name 'randrw_*lat.log' | wc -l) -eq 3 ]] || die completion_log_count_$cell
  fi
  python3 "$ANALYZER" cell --root "$ROOT" --name "$cell" --output "$ROOT/cells/$cell/analysis.json" >/dev/null || die analyzer_failed_$cell
}
layout_one() {
  local group=$1 arm=$2
  local cell="LAYOUT-$group-$arm"
  local out="$ROOT/cells/$cell"
  local mnt job rc
  mkdir -m 0700 -p "$out"; health_gate "layout_${group}_${arm}_pre"; mount_one "$group" "$arm" "$cell" rw 1M; mnt=$(group_mnt "$group" "$arm"); mkdir -m 0700 -p "$mnt/test_dir"; job="$out/layout.fio"
  printf '%s\n' '[global]' 'rw=write' 'ioengine=psync' 'bs=16M' 'size=1G' 'filesize=1G' 'numjobs=128' 'direct=1' 'allow_file_create=1' 'end_fsync=1' "filename_format=$mnt/test_dir/rw_test.\$jobnum.0" '[job]' >"$job"
  record_cmd timeout 1800 "$FIO" "$job" --output="$out/fio.json" --output-format=json+
  set +e; timeout 1800 "$FIO" "$job" --output="$out/fio.json" --output-format=json+ >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; set -e; printf '%s\n' "$rc" >"$out/fio.rc"; (( rc == 0 )) || die layout_fio_failed_${group}_${arm}
  find "$mnt/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%s\n' | sort -V >"$out/layout-manifest.tsv"; [[ $(wc -l <"$out/layout-manifest.tsv") -eq 128 ]] || die layout_file_count_${group}_${arm}
  awk -F '\t' '$2 != 1073741824 {bad=1} END{exit bad}' "$out/layout-manifest.tsv" || die layout_file_size_${group}_${arm}; graceful_umount "$cell"
}
online_inventory() {
  online_scope; require_ack INVENTORY "${3:-}"
  [[ ! -e "$ROOT" ]] || die root_exists
  metrics_ports_distinct || die metrics_port_collision
  for tool in ceph curl fio find findmnt mountpoint pgrep python3 sha256sum sort ss stat timeout; do need_cmd "$tool"; done
  [[ -x "$JFS" && ! -L "$JFS" ]] || die binary_missing; [[ "$(md5sum "$JFS" | awk '{print $1}')" == "$JFS_MD5" ]] || die binary_md5_drift
  mkdir -p "$ROOT"
  chmod 0700 "$ROOT"
  mkdir -m 0700 -p "$ROOT/inventory" "$ROOT/plans" "$ROOT/plans/scripts" "$ROOT/cells" "$ROOT/closure"; printf 'epoch_iso\tevent\tdetail\n' >"$ROOT/incidents.tsv"; printf '# actual commands; credentials are redacted\n' >"$ROOT/commands.sh"
  for source in "$0" "$ANALYZER" "$BASE_ANALYZER" "$GATE0" "$TASKBOOK" "$SCRUB_CONTROL"; do
    [[ -f "$source" && ! -L "$source" ]] || die evidence_source_missing
    cp -- "$source" "$ROOT/plans/scripts/"
  done
  sha256sum "$ROOT/plans/scripts/"* >"$ROOT/plans/scripts.sha256"
  prepare_ceph_conf; capture_retest_decision; write_matrix "$ROOT/plans"; md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"; "$JFS" version >"$ROOT/inventory/juicefs-version.txt"; ceph_read fsid >"$ROOT/inventory/ceph-fsid.txt"; ceph_read df -f json >"$ROOT/inventory/ceph-df.json"
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/reference-mount.tsv"; grep -Fq "JuiceFS:juicefs-prod $REF fuse.juicefs" "$ROOT/inventory/reference-mount.tsv" || die reference_mount_identity
  env CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" >"$ROOT/inventory/reference-status.json" || die reference_status
  status_identity "$META" juicefs-prod "$ROOT/inventory/reference-identity"; block_size_matches 256K "$(awk -F '\t' '$1=="block_size"{print $2}' "$ROOT/inventory/reference-identity.tsv")" || die reference_block_size_identity
  health_gate inventory
  if pgrep -x fio >"$ROOT/inventory/foreign-fio.tsv"; then die foreign_fio; fi
  find "$REF/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$ROOT/inventory/assets.tsv"; [[ $(wc -l <"$ROOT/inventory/assets.tsv") -eq 128 ]] || die reference_asset_count; awk -F '\t' '$3 != 1073741824 {bad=1} END{exit bad}' "$ROOT/inventory/assets.tsv" || die reference_asset_size
  : >"$ROOT/ONLINE_INVENTORY_PASS.tmp"; mv -T -- "$ROOT/ONLINE_INVENTORY_PASS.tmp" "$ROOT/ONLINE_INVENTORY_PASS"
  printf 'T051B_ONLINE_INVENTORY_PASS\troot=%s\n' "$ROOT"
}
phase_a() {
  [[ "$SCOPE" == FULL ]] || die phase_a_forbidden_in_retest_scope
  online_scope; require_ack PHASE_A "${3:-}"; [[ -f "$ROOT/ONLINE_INVENTORY_PASS" && -f "$ROOT/plans/matrix.tsv" ]] || die inventory_required; prepare_ceph_conf; health_gate phase_a_pre
  local position arm bs fuse cell baseline
  quiet_wait phase-a-baseline
  baseline="$ROOT/recovery-quiet-phase-a-baseline/pool.tsv"
  while IFS=$'\t' read -r position arm bs fuse; do
    [[ "$position" == position ]] && continue; cell="A-${position}-${arm}"; [[ "$arm" == C1 || "$arm" == C2 ]] && fuse=256K || fuse=64K; mkdir -m 0700 -p "$ROOT/cells/$cell"; printf 'group\tA\narm\t%s\n' "$arm" >"$ROOT/cells/$cell/mount-state.tsv"
    health_gate "phase_a_${cell}_pre"; mount_one A "$arm" "$cell" rw "$fuse"; run_fio_cell "$cell" "$(group_mnt A "$arm")" "$bs" "$fuse" "$cell"; graceful_umount "$cell"; health_gate "phase_a_${cell}_post"; volume_gc A "$arm" "phase-a-${cell}" ""
  done < <(awk -F '\t' '$1=="A" {print $3"\t"$4"\t"$5"\t"$7}' "$ROOT/plans/matrix.tsv")
  health_gate phase_a_post
  quiet_wait phase-a-return "$baseline"
  sleep 60
  quiet_wait phase-a-post-idle "$baseline"
  printf 'PHASE_A_RESULTS_READY\tUNSIGNED\tsecond-party-must-write-signed-fuse-decision\n' >"$ROOT/phase-a-results.tsv"; : >"$ROOT/PHASE_A_PASS"; printf 'T051B_PHASE_A_PASS\troot=%s\tdecision=UNSIGNED\n' "$ROOT"
}
group_create_layout() {
  online_scope; require_ack "CREATE_LAYOUT_$1" "${2:-}"; [[ "$1" =~ ^(M|L|S)$ ]] || die invalid_group; [[ -f "$ROOT/ONLINE_INVENTORY_PASS" ]] || die inventory_required
  local group=$1
  if [[ "$SCOPE" == LS_RETEST ]]; then
    [[ "$group" == L || "$group" == S ]] || die group_forbidden_in_retest_scope
    [[ -f "$ROOT/inventory/phase-a-decision-source.tsv" ]] || die retest_phase_a_decision_required
    [[ "$group" != S || -f "$ROOT/GROUP_L_CLEANUP_PASS" ]] || die L_must_close_first
  else
    [[ "$group" != M || -f "$ROOT/PHASE_A_PASS" ]] || die phase_a_required
    [[ "$group" != L || -f "$ROOT/GROUP_M_CLEANUP_PASS" ]] || die M_must_close_first
    [[ "$group" != S || -f "$ROOT/GROUP_L_CLEANUP_PASS" ]] || die L_must_close_first
  fi
  [[ ! -e "$ROOT/GROUP_${group}_CREATE_LAYOUT_PASS" ]] || die group_already_created; prepare_ceph_conf; health_gate "${group}_create_pre"; quiet_wait "${group}_create_baseline"
  : >"$ROOT/GROUP_${group}_CREATE_LAYOUT_STARTED"
  local arm block expected meta name out
  for arm in c t; do
    block=256K; [[ "$group:$arm" == M:t ]] && block=1M; [[ "$group:$arm" == L:t ]] && block=$L_T_BLOCK; [[ "$group:$arm" == S:t ]] && block=64K
    meta=$(group_meta "$group" "$arm"); name=$(group_name "$group" "$arm"); out="$ROOT/cells/LAYOUT-$group-$arm"
    mkdir -m 0700 -p "$out"
    if env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$out/preexisting.json" 2>"$out/preexisting.stderr"; then die volume_preexists_${group}_${arm}; fi
    local -a cmd=(env "CEPH_CONF=$CEPH_CONF" "$JFS" format --no-update --storage ceph --bucket "ceph://$POOL" --access-key "${T051B_ACCESS_KEY:-}" --secret-key "${T051B_SECRET_KEY:-}" --block-size "$block" --compress none --trash-days 0 "$meta" "$name")
    [[ -n "${T051B_ACCESS_KEY:-}" && -n "${T051B_SECRET_KEY:-}" ]] || die format_credentials_required
    record_cmd env "CEPH_CONF=$CEPH_CONF" "$JFS" format --no-update --storage ceph --bucket "ceph://$POOL" --access-key REDACTED --secret-key REDACTED --block-size "$block" --compress none --trash-days 0 "$meta" "$name"; timeout 180 "${cmd[@]}" >"$out/format.stdout" 2>"$out/format.stderr" || die format_failed_${group}_${arm}
    status_identity "$meta" "$name" "$out/identity"; expected=$(expected_block_size "$group" "$arm"); actual=$(awk -F '\t' '$1=="block_size"{print $2}' "$out/identity.tsv"); block_size_matches "$expected" "$actual" || die block_size_identity_${group}_${arm}_expected_${expected}_got_${actual}
    layout_one "$group" "$arm"; volume_gc "$group" "$arm" "${group}-layout-${arm}" ""
  done
  health_gate "${group}_create_post"; recovery_gate "${group}_create_post"; printf '%s\n' "$(date -Ins)" >"$ROOT/GROUP_${group}_CREATE_LAYOUT_PASS"; printf 'T051B_GROUP_CREATE_LAYOUT_PASS\tgroup=%s\n' "$group"
}
group_run() {
  online_scope; require_ack "RUN_$1" "${2:-}"; local group=$1; [[ "$group" =~ ^(M|L|S)$ ]] || die invalid_group; [[ -f "$ROOT/GROUP_${group}_CREATE_LAYOUT_PASS" ]] || die group_create_required
  [[ "$SCOPE" != LS_RETEST || "$group" != M ]] || die group_forbidden_in_retest_scope
  [[ ! -f "$ROOT/B4M_BUFFER_PROBE_PASS" ]] || die diagnostic_run_cannot_be_formal_L
  if [[ "$SCOPE" == LS_RETEST && "$group" == S ]]; then
    [[ "$SCRUB_LEASE" == "05-1b-${RUN_ID}-phase-b" ]] || die S_retest_requires_scrub_lease
  fi
  prepare_ceph_conf; local fuse=1M; [[ "$group" == S ]] && fuse=$(phase_a_fuse)
  local pos matrix_arm bs vol planned_fuse cell arm mnt mount_c mount_t mount_cell expected actual baseline buffer=300 log_mode=per-job
  if [[ "$SCOPE" == LS_RETEST ]]; then log_mode=aggregate; fi
  if [[ "$group" == L ]]; then buffer=$L_T_BUFFER; [[ "$SCOPE" != LS_RETEST ]] || log_mode=completion; fi
  baseline="$ROOT/recovery-quiet-${group}_create_baseline/pool.tsv"; [[ -s "$baseline" ]] || die create_baseline_missing
  for arm in c t; do
    status_identity "$(group_meta "$group" "$arm")" "$(group_name "$group" "$arm")" "$ROOT/cells/RUN-$group-$arm-identity"
    expected=$(expected_block_size "$group" "$arm"); actual=$(awk -F '\t' '$1=="block_size"{print $2}' "$ROOT/cells/RUN-$group-$arm-identity.tsv"); block_size_matches "$expected" "$actual" || die run_block_size_identity_${group}_${arm}
  done
  mount_c="$group-mount-c"; mount_t="$group-mount-t"
  health_gate "${group}_run_pre"; mount_one "$group" c "$mount_c" rw "$fuse" "$buffer"; mount_one "$group" t "$mount_t" rw "$fuse" "$buffer"
  while IFS=$'\t' read -r pos matrix_arm bs vol planned_fuse; do
    [[ "$pos" == position ]] && continue
    [[ "$group" == S ]] && planned_fuse="$fuse"
    [[ "$matrix_arm" =~ ^C ]] && arm=c || arm=t
    [[ "$arm" == c ]] && mount_cell="$mount_c" || mount_cell="$mount_t"
    cell="${group}-${pos}-${matrix_arm}"; mnt=$(group_mnt "$group" "$arm")
    health_gate "${group}_${cell}_pre"; run_fio_cell "$cell" "$mnt" "$bs" "$planned_fuse" "$mount_cell" "$log_mode"; health_gate "${group}_${cell}_post"; volume_gc "$group" "$arm" "${group}-cell-${pos}-${matrix_arm}" ""
  done < <(awk -F '\t' -v g="$group" '$2==g {print $3"\t"$4"\t"$5"\t"$6"\t"$7}' "$ROOT/plans/matrix.tsv")
  graceful_umount "$mount_c"; graceful_umount "$mount_t"; health_gate "${group}_run_post"; printf '%s\n' "$(date -Ins)" >"$ROOT/GROUP_${group}_RUN_PASS"; printf 'T051B_GROUP_RUN_PASS\tgroup=%s\n' "$group"
}
b4m_buffer_probe() {
  online_scope; require_ack B4M_BUFFER_PROBE "${1:-}"
  [[ "$SCOPE" == LS_RETEST ]] || die probe_requires_retest_scope
  [[ "$L_T_BLOCK" == 4M ]] || die probe_requires_B4M
  [[ -f "$ROOT/GROUP_L_CREATE_LAYOUT_PASS" ]] || die L_create_required
  [[ ! -e "$ROOT/B4M_BUFFER_PROBE_PASS" ]] || die probe_already_completed
  prepare_ceph_conf
  local expected actual buffer cell mnt
  status_identity "$(group_meta L t)" "$(group_name L t)" "$ROOT/cells/PROBE-L-t-identity"
  expected=$(expected_block_size L t); actual=$(awk -F '\t' '$1=="block_size"{print $2}' "$ROOT/cells/PROBE-L-t-identity.tsv")
  block_size_matches "$expected" "$actual" || die probe_block_size_identity
  mnt=$(group_mnt L t)
  for buffer in 300 1024; do
    cell="L-B4M-buffer-${buffer}-r2"
    health_gate "probe_${buffer}_pre"
    mount_one L t "$cell" rw 1M "$buffer"
    run_fio_cell "$cell" "$mnt" 4M 1M "$cell" completion
    graceful_umount "$cell"
    health_gate "probe_${buffer}_post"
    volume_gc L t "probe-buffer-${buffer}" ""
  done
  printf 'status\tPASS\nvalues_mib\t300,1024\nlog_mode\taggregate-completion\nnext\tsecond-party review, cleanup this diagnostic RUN, then use a new formal RUN\n' >"$ROOT/B4M_BUFFER_PROBE_PASS"
  printf 'T051B_B4M_BUFFER_PROBE_PASS\troot=%s\tdecision=SECOND_PARTY_REQUIRED\n' "$ROOT"
}
s4k_closure() {
  online_scope; require_ack S4K_CLOSURE "${1:-}"
  [[ "$SCOPE" == LS_RETEST ]] || die S4K_closure_requires_retest_scope
  [[ -f "$ROOT/GROUP_S_RUN_PASS" ]] || die S_formal_run_required
  [[ ! -e "$ROOT/GROUP_S_4K_CLOSURE_PASS" ]] || die S4K_closure_already_completed
  [[ "$SCRUB_LEASE" == "05-1b-${RUN_ID}-s4k-phase-b" ]] || die S4K_closure_requires_scrub_lease
  prepare_ceph_conf
  local fuse expected actual arm cell mount_c=S4K-mount-c mount_t=S4K-mount-t mount_cell mnt pos label
  fuse=$(phase_a_fuse)
  [[ "$fuse" == 256K ]] || die S4K_closure_requires_fuse256
  for arm in c t; do
    status_identity "$(group_meta S "$arm")" "$(group_name S "$arm")" "$ROOT/cells/S4K-$arm-identity"
    expected=$(expected_block_size S "$arm"); actual=$(awk -F '\t' '$1=="block_size"{print $2}' "$ROOT/cells/S4K-$arm-identity.tsv")
    block_size_matches "$expected" "$actual" || die S4K_closure_block_size_identity_$arm
  done
  health_gate S4K_run_pre
  mount_one S c "$mount_c" rw "$fuse" 300
  mount_one S t "$mount_t" rw "$fuse" 300
  while IFS=$'\t' read -r pos arm label; do
    [[ "$arm" == c ]] && mount_cell=$mount_c || mount_cell=$mount_t
    cell="S4K-${pos}-${label}"; mnt=$(group_mnt S "$arm")
    health_gate "S4K_${cell}_pre"
    run_fio_cell "$cell" "$mnt" 4K "$fuse" "$mount_cell" aggregate
    health_gate "S4K_${cell}_post"
    volume_gc S "$arm" "S4K-cell-${pos}-${label}" ""
  done <<'EOF'
1	c	C1
2	t	T1
3	t	T2
4	c	C2
EOF
  graceful_umount "$mount_c"; graceful_umount "$mount_t"; health_gate S4K_run_post
  printf '%s\n' "$(date -Ins)" >"$ROOT/GROUP_S_4K_CLOSURE_PASS"
  printf 'T051B_S4K_CLOSURE_PASS\troot=%s\n' "$ROOT"
}
group_cleanup_plan() {
  online_scope; require_ack "CLEANUP_PLAN_$1" "${2:-}"; local group=$1
  [[ "$group" =~ ^(M|L|S)$ ]] || die invalid_group; [[ -f "$ROOT/GROUP_${group}_CREATE_LAYOUT_STARTED" ]] || die create_layout_not_started; prepare_ceph_conf
  mkdir -m 0700 -p "$ROOT/closure"; printf 'group\tarm\tmeta\tname\tuuid\n' >"$ROOT/closure/destroy-plan-$group.tsv"
  local arm meta name out uuid expected actual rows=0
  for arm in c t; do
    meta=$(group_meta "$group" "$arm"); name=$(group_name "$group" "$arm"); out="$ROOT/closure/status-$group-$arm"
    if ! env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$out.json" 2>"$out.stderr"; then continue; fi
    status_identity "$meta" "$name" "$out"; expected=$(expected_block_size "$group" "$arm"); actual=$(awk -F '\t' '$1=="block_size"{print $2}' "$out.tsv"); block_size_matches "$expected" "$actual" || die cleanup_block_size_identity_${group}_${arm}
    uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$out.tsv"); [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || die invalid_uuid_${group}_${arm}
    printf '%s\t%s\t%s\t%s\t%s\n' "$group" "$arm" "$meta" "$name" "$uuid" >>"$ROOT/closure/destroy-plan-$group.tsv"; rows=$((rows+1))
  done
  (( rows > 0 )) || die cleanup_no_matching_volumes
  printf 'T051B_GROUP_CLEANUP_PLAN_PASS\tgroup=%s\n' "$group"
}
cleanup_recovery_wait() {
  local group=$1
  local base="$ROOT/recovery-quiet-${group}_create_baseline/pool.tsv"
  [[ -s "$base" ]] || die cleanup_baseline_missing
  quiet_wait "${group}_cleanup" "$base"
  cp -- "$ROOT/recovery-quiet-${group}_cleanup/pool.tsv" "$ROOT/closure/recovery-$group.tsv"
}
group_cleanup() {
  online_scope; require_ack "CLEANUP_$1" "${2:-}"; local group=$1 plan="$ROOT/closure/destroy-plan-$1.tsv"
  [[ "$group" =~ ^(M|L|S)$ ]] || die invalid_group; [[ -f "$plan" ]] || die cleanup_plan_required; prepare_ceph_conf
  if findmnt -rn -o TARGET | awk -v r="$RUN_ID" -v g="$group" '$1 ~ ("^/tmp/jfs-05-1b-" r "-" g "-"){found=1} END{exit found?0:1}'; then die group_mount_remains; fi
  local row arm meta name uuid out now expected actual
  while IFS=$'\t' read -r row arm meta name uuid; do
    [[ "$row" == group ]] && continue; [[ "$row" == "$group" && "$arm" =~ ^(c|t)$ && "$meta" == "$(group_meta "$group" "$arm")" && "$name" == "$(group_name "$group" "$arm")" ]] || die cleanup_row_invalid
    out="$ROOT/closure/pre-destroy-$group-$arm"; status_identity "$meta" "$name" "$out"; expected=$(expected_block_size "$group" "$arm"); actual=$(awk -F '\t' '$1=="block_size"{print $2}' "$out.tsv"); block_size_matches "$expected" "$actual" || die cleanup_block_size_drift; now=$(awk -F '\t' '$1=="uuid"{print $2}' "$out.tsv"); [[ "$now" == "$uuid" ]] || die cleanup_uuid_drift
    record_cmd env "CEPH_CONF=$CEPH_CONF" "$JFS" destroy "$meta" "$uuid" --yes; timeout 1800 env CEPH_CONF="$CEPH_CONF" "$JFS" destroy "$meta" "$uuid" --yes >"$ROOT/closure/destroy-$group-$arm.stdout" 2>"$ROOT/closure/destroy-$group-$arm.stderr" || die destroy_failed_${group}_${arm}
    if env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$ROOT/closure/post-destroy-$group-$arm.json" 2>"$ROOT/closure/post-destroy-$group-$arm.stderr"; then die destroy_status_still_exists_${group}_${arm}; fi
  done <"$plan"
  health_gate "${group}_cleanup_post"; cleanup_recovery_wait "$group"
  sleep 60
  quiet_wait "${group}_cleanup_post_idle" "$ROOT/recovery-quiet-${group}_create_baseline/pool.tsv"
  printf '%s\n' "$(date -Ins)" >"$ROOT/GROUP_${group}_CLEANUP_PASS"; printf 'T051B_GROUP_CLEANUP_PASS\tgroup=%s\n' "$group"
}
bundle_online() {
  online_scope; require_ack BUNDLE "${3:-}"; [[ -d "$ROOT" ]] || die root_missing; mkdir -m 0700 -p "$ROOT/bundle"; find "$ROOT" -type f ! -path "$ROOT/bundle/*" -print0 | sort -z | xargs -0 sha256sum >"$ROOT/bundle/SHA256SUMS"; printf 'T051B_BUNDLE_PASS\troot=%s\n' "$ROOT"
}
plan() {
  valid_run; valid_plan_output; [[ ! -e "$OUT" ]] || die output_exists
  mkdir -m 0700 -p "$OUT"
  write_matrix; write_volume_plan; write_recovery_plan
  printf 'epoch_iso\tevent\tdetail\n' >"$OUT/incidents.tsv"
  printf '# Offline plan generation only; no environment command was executed.\n' >"$OUT/commands.sh"
  cat >"$OUT/status.tsv" <<EOF
RUN_ID	$RUN_ID
GATE	G0_OFFLINE
AUTHORIZATION	REQUIRED_BEFORE_ENVIRONMENT_CONTACT
FORMAT_LAYOUT_DESTROY	PLAN_ONLY
ONLINE_ACTIONS	UNREACHABLE_IN_THIS_PREPARATION_DRIVER
FORMAL_DECISION	SECOND_PARTY_REVIEW_REQUIRED
EOF
  sha256sum "$0" "$ANALYZER" "$TASKBOOK" >"$OUT/input-sha256.tsv"
  printf 'T051B_PLAN_ONLY_PASS\troot=%s\tformat_layout_destroy=PLAN_ONLY\tonline=UNREACHABLE\n' "$OUT"
}

self_test() {
  RUN_ID=20260914-120000; OUT=/tmp/t05-1b-plan-$RUN_ID
  [[ "$(group_meta M c)" == "$META_BASE/jfs-05-1b-20260914-120000-M-c" ]] || die meta_render
  [[ "$(group_name L t)" == jfs-05-1b-20260914-120000-l-t ]] || die name_render
  [[ "$(group_mnt S t)" == /tmp/jfs-05-1b-20260914-120000-S-t ]] || die mount_render
  grep -Fq 'juicefs format' "$0" || die format_plan_source
  grep -Fq 'juicefs destroy' "$0" || die destroy_plan_source
  block_size_matches 256K 256 || die block_size_positive_fixture
  [[ "$(expected_block_size M c)" == 256K && "$(expected_block_size M t)" == 1M && "$(expected_block_size L t)" == 4M && "$(expected_block_size S t)" == 64K ]] || die block_size_arm_mapping_fixture
  if block_size_matches 256K 1M; then die block_size_negative_fixture; fi
  printf 'T051B_DRIVER_SELF_TEST_PASS\toffline_plan=true\tonline_ack_gated=true\tgroups=M,L,S\n'
}

case "${1:-}" in
  plan|inventory-plan) plan ;;
  online-inventory) RUN_ID=${2:-}; online_inventory "$@" ;;
  phase-a) RUN_ID=${2:-}; phase_a "$@" ;;
  group-create-layout) RUN_ID=${2:-}; group_create_layout "${3:-}" "${4:-}" ;;
  group-run) RUN_ID=${2:-}; group_run "${3:-}" "${4:-}" ;;
  b4m-buffer-probe) RUN_ID=${2:-}; b4m_buffer_probe "${3:-}" ;;
  s4k-closure) RUN_ID=${2:-}; s4k_closure "${3:-}" ;;
  group-cleanup-plan) RUN_ID=${2:-}; group_cleanup_plan "${3:-}" "${4:-}" ;;
  group-cleanup) RUN_ID=${2:-}; group_cleanup "${3:-}" "${4:-}" ;;
  group-recover-mounts) RUN_ID=${2:-}; group_recover_mounts "${3:-}" "${4:-}" ;;
  bundle) RUN_ID=${2:-}; bundle_online "$@" ;;
  --self-test) self_test ;;
  *) printf 'usage: %s plan RUN_ID | online-inventory RUN_ID ACK | phase-a RUN_ID ACK | group-{create-layout,run,cleanup-plan,cleanup,recover-mounts} RUN_ID GROUP ACK | b4m-buffer-probe RUN_ID ACK | s4k-closure RUN_ID ACK | bundle RUN_ID ACK | --self-test\n' "$0" >&2; exit 2 ;;
esac
