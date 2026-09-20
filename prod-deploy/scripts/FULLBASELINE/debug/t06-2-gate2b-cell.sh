#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

RUN_ID=${1:-}
CELL=${2:-}
if [[ $RUN_ID == --self-test ]]; then
  grep -Fq 'RUNTIME=180' "$0"
  grep -Fq 'WARMUP_RUNTIME=60' "$0"
  grep -Fq 'CACHE_MIB=98304' "$0"
  grep -Fq 'rw=randrw' "$0"
  grep -Fq 'debug/flush-instrumentation' "$0"
  grep -Fq '50533485977e187146c53b2cf2497b929df70b590a8a6b655a32c9e8c8d94dc9' "$0"
  grep -Fq 'a83343bc62e023f090a99d37872665516429765055968349de6eaefb2a81fc76' "$0"
  grep -Fq 'CELL == C1 || $CELL == C2' "$0"
  grep -Fq 'CELL == T1' "$0"
  ! grep -Eq 'juicefs[[:space:]]+gc|fusermount[[:space:]]+-u[z]|umount[[:space:]]+-l|rm[[:space:]]+-rf|pkill|killall|fuser[[:space:]]+-k' "$0"
  printf 'T062_GATE2B_CELL_SELF_TEST_PASS\n'
  exit 0
fi

[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo 'invalid RUN_ID' >&2; exit 42; }
[[ $CELL == B || $CELL == I || $CELL == C1 || $CELL == T1 || $CELL == T2 || $CELL == C2 ]] || {
  echo 'CELL must be B, I, C1, T1, T2, or C2' >&2; exit 42;
}

ROOT=/tmp/production/opencode-06-2-${RUN_ID}
if [[ $CELL == B || $CELL == I ]]; then
  OUT=${ROOT}/profile/gate2b/cells/${CELL}
else
  OUT=${ROOT}/phase-a/cells/${CELL}
fi
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
CEPH_CONF=/etc/ceph/ceph.conf
CACHE_PARENT=/mnt/jfs-cache/04tmp3
if [[ $CELL == B || $CELL == I ]]; then scope=gate2b; else scope=phase-a; fi
CACHE_DIR=${CACHE_PARENT}/jfs-06-2-${RUN_ID}-${scope}-${CELL}
MNT=/tmp/jfs-06-2-${RUN_ID}-${scope}-${CELL}
VERIFY_MNT=/tmp/jfs-06-2-${RUN_ID}-${scope}-${CELL}-verify
CACHE_MIB=98304
RUNTIME=180
WARMUP_RUNTIME=60
DRAIN_TIMEOUT=900
sampler_pid=
iostat_pid=
sampler_stop=

if [[ $CELL == B ]]; then
  JFS=${ROOT}/bin/juicefs-v1.4.1-b-catchup-baseline
  JFS_MD5=1eb79575f654c77c14aa212c2b6c478d
  JFS_SHA256=cdfd364e72d41d6da1aa45c9e3cfc0952451c2d3f5dbc263ab1fdf89ba9c3b4b
  JFS_BUILD_ID=ab49d56c6ceca27d363a80e24ccb7c4b61983942
  METRICS=127.0.0.1:19643
  VERIFY_METRICS=127.0.0.1:19645
elif [[ $CELL == I ]]; then
  JFS=${ROOT}/bin/juicefs-v1.4.1-b-catchup-instrumented
  JFS_MD5=be67049f6db88d382b657bb7fecf1bd8
  JFS_SHA256=d4e5689001082d993ebb25c8c8ea4900f8fa99459bfc6d62eaa92e57fc0e63f6
  JFS_BUILD_ID=1de897df7b8a88467f52c94798bc33af0f9d9800
  METRICS=127.0.0.1:19644
  VERIFY_METRICS=127.0.0.1:19646
elif [[ $CELL == C1 || $CELL == C2 ]]; then
  JFS=${ROOT}/bin/juicefs-gate3-baseline
  JFS_MD5=25d8581301a6e599d320839d391e4de9
  JFS_SHA256=50533485977e187146c53b2cf2497b929df70b590a8a6b655a32c9e8c8d94dc9
  JFS_BUILD_ID=c8f4ba0cbd0b2e8a555bc2c55366a88409fa4371
  if [[ $CELL == C1 ]]; then METRICS=127.0.0.1:19651; VERIFY_METRICS=127.0.0.1:19661; else METRICS=127.0.0.1:19654; VERIFY_METRICS=127.0.0.1:19664; fi
else
  JFS=${ROOT}/bin/juicefs-gate3-patched
  JFS_MD5=862da80736e17d604b44c28c1b921c30
  JFS_SHA256=a83343bc62e023f090a99d37872665516429765055968349de6eaefb2a81fc76
  JFS_BUILD_ID=c165d294839fd49ec31d4e2d2c999bc08db25939
  if [[ $CELL == T1 ]]; then METRICS=127.0.0.1:19652; VERIFY_METRICS=127.0.0.1:19662; else METRICS=127.0.0.1:19653; VERIFY_METRICS=127.0.0.1:19663; fi
fi

die() {
  if [[ -n ${OUT:-} && -d ${OUT:-} ]]; then
    printf '%s\tPRESERVE_SCENE\treason=%s\n' "$(date +%s%N)" "$*" >>"$OUT/incidents.tsv" 2>/dev/null || true
  fi
  printf 'T062_GATE2B_CELL_FAIL\tcell=%s\treason=%s\n' "$CELL" "$*" >&2
  exit 42
}
event() { printf '%s\t%s\t%s\n' "$(date +%s%N)" "$1" "$2" >>"$OUT/incidents.tsv"; }
log_cmd() { printf '%q ' "$@" >>"$OUT/commands.sh"; printf '\n' >>"$OUT/commands.sh"; }
preserve_on_error() {
  rc=$?
  if [[ -n ${sampler_stop:-} ]]; then : >"$sampler_stop" 2>/dev/null || true; fi
  if [[ -n ${sampler_pid:-} ]]; then wait "$sampler_pid" 2>/dev/null || true; fi
  if [[ -n ${iostat_pid:-} ]]; then kill -TERM "$iostat_pid" 2>/dev/null || true; wait "$iostat_pid" 2>/dev/null || true; fi
  printf '%s\tPRESERVE_SCENE\trc=%s\n' "$(date +%s%N)" "$rc" >>"$OUT/incidents.tsv" 2>/dev/null || true
  exit "$rc"
}

[[ $ROOT == /tmp/production/opencode-06-2-${RUN_ID} && -d $ROOT && ! -L $ROOT ]] || die invalid_root
[[ -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die binary_identity
[[ ! -e $OUT && ! -L $OUT ]] || die output_exists
[[ ! -e $CACHE_DIR && ! -L $CACHE_DIR ]] || die cache_child_exists
[[ ! -e $MNT && ! -L $MNT && ! -e $VERIFY_MNT && ! -L $VERIFY_MNT ]] || die mount_path_exists
mkdir -m 0700 -p "$OUT/formal/bw"
printf 'epoch_ns\tevent\tdetail\n' >"$OUT/incidents.tsv"
trap preserve_on_error ERR

[[ $(id -u) == 1002 && $(id -g) == 1002 ]] || die unexpected_executor_identity
read -r parent_source parent_major parent_fstype parent_target parent_opts \
  < <(findmnt -bnr -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,TARGET,OPTIONS) || die cache_parent_findmnt
read -r parent_uid parent_gid parent_mode < <(stat -Lc '%u %g %a' "$CACHE_PARENT")
parent_uuid=$(lsblk -dnro UUID "${parent_source%%[*}" 2>/dev/null || true)
read -r parent_bytes parent_avail_bytes < <(df -B1 --output=size,avail "$CACHE_PARENT" | awk 'NR==2{print $1,$2}')
min_avail_bytes=$((700*1024*1024*1024))
[[ $(realpath -e "$CACHE_PARENT") == "$CACHE_PARENT" && $parent_source == /dev/nvme1n1 &&
   $parent_major == 259:2 && $parent_fstype == ext4 && $parent_target == /mnt/jfs-cache &&
   $parent_opts == rw,noatime,stripe=32 && $parent_uuid == 1b691709-e347-452c-96c4-5f37052bc203 &&
   $parent_uid == 1002 && $parent_gid == 1002 && $parent_mode == 700 && -w $CACHE_PARENT ]] \
  || die cache_parent_identity_drift
[[ $parent_avail_bytes =~ ^[0-9]+$ && $parent_avail_bytes -ge $min_avail_bytes ]] || die cache_parent_headroom_below_700GiB
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CACHE_PARENT" "$parent_source" "$parent_major" \
  "$parent_fstype" "$parent_uuid" "$parent_target" "$parent_opts" "$parent_uid:$parent_gid" "$parent_mode" \
  >"$OUT/cache-parent-live.tsv"
printf 'total_bytes\tavailable_bytes\tminimum_available_bytes\n%s\t%s\t%s\n' \
  "$parent_bytes" "$parent_avail_bytes" "$min_avail_bytes" >"$OUT/cache-headroom.tsv"

[[ -z $(pgrep -x fio || true) ]] || die foreign_fio
! ss -ltnH | awk -v a="${METRICS##*:}" -v b="${VERIFY_METRICS##*:}" '$4 ~ (":" a "$") || $4 ~ (":" b "$") {found=1} END{exit found?0:1}' || die metrics_port_occupied
ceph --conf "$CEPH_CONF" -s -f json >"$OUT/ceph.before.json"
ceph --conf "$CEPH_CONF" health detail -f json >"$OUT/health-detail.before.json"
python3 - "$OUT/health-detail.before.json" <<'PY' || die ceph_not_healthy
import json,sys
d=json.load(open(sys.argv[1])); status=d.get('status'); checks=set(d.get('checks',{}))
assert (status == 'HEALTH_OK' and not checks) or (status == 'HEALTH_WARN' and checks == {'OSDMAP_FLAGS'}), (status,checks)
PY
ceph --conf "$CEPH_CONF" osd stat -f json >"$OUT/osd.before.json"
python3 - "$OUT/osd.before.json" <<'PY' || die osd_not_all_up_in
import json,sys
d=json.load(open(sys.argv[1])); n=d.get('num_osds',0)
assert n > 0 and d.get('num_up_osds') == n and d.get('num_in_osds') == n, d
PY
ceph --conf "$CEPH_CONF" pg dump pgs_brief >"$OUT/pg.before.txt"
awk '$1 ~ /^[0-9]+\.[0-9a-fA-F]+$/ {n++; if ($2 != "active+clean") bad++} END {exit (n>0 && bad==0)?0:1}' \
  "$OUT/pg.before.txt" || die pg_not_active_clean
ceph --conf "$CEPH_CONF" osd dump -f json >"$OUT/osd-dump.before.json"
python3 - "$OUT/osd-dump.before.json" <<'PY' || die scrub_flags_not_controlled
import json,sys
v=json.load(open(sys.argv[1])).get('flags',[])
if isinstance(v,str): flags=set(x.replace('nodeep_scrub','nodeep-scrub') for x in v.split(',') if x)
else: flags=set(str(x).replace('nodeep_scrub','nodeep-scrub') for x in v)
assert {'noscrub','nodeep-scrub'} <= flags, sorted(flags)
PY
findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference-mount.before.tsv"
mkdir -m 0700 "$CACHE_DIR" "$MNT"
event CACHE_CREATE "$CACHE_DIR"

capture_pids() {
  local output=$1 proc
  : >"$output"
  for proc in /proc/[0-9]*; do
    [[ -e $proc/exe ]] || continue
    [[ $(readlink -f "$proc/exe" 2>/dev/null || true) == "$JFS" ]] && basename "$proc" >>"$output"
  done
  sort -n -o "$output" "$output"
}

mount_pid_gate() {
  local before=$1 marker=$2 output=$3
  python3 - "$JFS" "$before" "$marker" >"$output" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]); old={int(x) for x in open(sys.argv[2]) if x.strip().isdigit()}; marker=sys.argv[3]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if int(p.name) in old or os.path.realpath(p/'exe') != exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace').strip()
        if marker not in cmd: continue
        st=(p/'stat').read_text().split()
        rows.append((int(p.name),int(st[3]),int(st[21]),hashlib.md5((p/'exe').read_bytes()).hexdigest(),cmd))
    except (OSError,ValueError,IndexError): pass
pids={x[0] for x in rows}; workers=[x[0] for x in rows if x[1] in pids]
if len(rows)!=2 or len(workers)!=1: raise SystemExit(f'non_unique_parent_worker:{rows}')
print('pid\tppid\tstarttime_ticks\texe_md5\tis_worker\tcmdline')
for row in sorted(rows): print(*row[:4], 'yes' if row[0] in workers else 'no', row[4], sep='\t')
PY
}

processes_gone() {
  local file=$1
  python3 - "$JFS" "$file" <<'PY'
import csv,os,sys
exe=os.path.realpath(sys.argv[1])
for row in csv.DictReader(open(sys.argv[2]),delimiter='\t'):
    try:
        if os.path.realpath('/proc/'+row['pid']+'/exe') == exe and open('/proc/'+row['pid']+'/stat').read().split()[21] == row['starttime_ticks']:
            raise SystemExit(1)
    except OSError: pass
PY
}

require_metrics_identity() {
  local addr=$1 mnt=$2 output=$3 text
  text=$(curl -fsS --max-time 5 "http://${addr}/metrics") || die metrics_unavailable
  grep -Fq 'vol_name="juicefs-prod"' <<<"$text" || die metrics_volume_identity
  grep -Fq "mp=\"$mnt\"" <<<"$text" || die metrics_mount_identity
  printf '%s' "$text" >"$output"
}

capture_pids "$OUT/pids.before"
log_cmd env CEPH_CONF="$CEPH_CONF" "$JFS" mount -d --max-fuse-io 256K --buffer-size 300 \
  --max-uploads 150 --max-downloads 200 --metrics "$METRICS" --log "$OUT/juicefs.log" \
  --cache-dir "$CACHE_DIR" --cache-size "$CACHE_MIB" --free-space-ratio 0.20 --writeback "$META" "$MNT"
env CEPH_CONF="$CEPH_CONF" "$JFS" mount -d --max-fuse-io 256K --buffer-size 300 \
  --max-uploads 150 --max-downloads 200 --metrics "$METRICS" --log "$OUT/juicefs.log" \
  --cache-dir "$CACHE_DIR" --cache-size "$CACHE_MIB" --free-space-ratio 0.20 --writeback "$META" "$MNT" \
  >"$OUT/mount.stdout" 2>"$OUT/mount.stderr"
for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
mountpoint -q "$MNT" || die mount_timeout
findmnt -rn -M "$MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/findmnt.tsv"
grep -Fq "JuiceFS:juicefs-prod $MNT fuse.juicefs" "$OUT/findmnt.tsv" || die mount_identity
mount_pid_gate "$OUT/pids.before" "--metrics $METRICS" "$OUT/mount-process.tsv" || die mount_process_identity
require_metrics_identity "$METRICS" "$MNT" "$OUT/metrics.mount.prom"
worker_pid=$(awk -F '\t' '$5=="yes"{print $1}' "$OUT/mount-process.tsv")
[[ $worker_pid =~ ^[0-9]+$ ]] || die worker_pid_missing
worker_exe=$(readlink -f "/proc/$worker_pid/exe")
worker_sha=$(sha256sum "/proc/$worker_pid/exe" | awk '{print $1}')
worker_build_id=$(readelf -n "/proc/$worker_pid/exe" | awk '/Build ID:/{print $3;exit}')
worker_version=$($JFS version)
[[ $worker_exe == "$JFS" && $worker_sha == "$JFS_SHA256" && $worker_build_id == "$JFS_BUILD_ID" &&
   $worker_version == 'juicefs version 1.4.1+2026-07-30.0b90c7d' ]] || die worker_binary_identity
printf 'cell\tpid\texe\tmd5\tsha256\tgnu_build_id\tversion\n%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$CELL" "$worker_pid" "$worker_exe" "$JFS_MD5" "$worker_sha" "$worker_build_id" "$worker_version" \
  >"$OUT/binary-live.tsv"
printf '%s\n' "$worker_exe" >"$OUT/worker.exe"
awk '{print $22}' "/proc/$worker_pid/stat" >"$OUT/worker.starttime"
cat "/proc/$worker_pid/status" >"$OUT/worker-status.pre"

PPROF_BASE=
if [[ $CELL != B ]]; then
  for _ in $(seq 1 30); do
    listeners=$(ss -ltnp) || die listener_inventory
    for port in $(seq 6060 6099); do
      grep -Eq ":${port}[[:space:]].*pid=${worker_pid}," <<<"$listeners" || continue
      candidate=http://127.0.0.1:${port}
      if curl -fsS --max-time 2 "${candidate}/debug/flush-instrumentation" >"$OUT/instrumentation-probe.tsv" 2>/dev/null &&
         sed -n '1p' "$OUT/instrumentation-probe.tsv" | grep -Fq 'read_start_ns'; then
        PPROF_BASE=$candidate
        break 2
      fi
    done
    sleep 1
  done
  [[ -n $PPROF_BASE ]] || die instrumentation_endpoint_missing
  printf '%s\n' "$PPROF_BASE" >"$OUT/instrumentation-endpoint.txt"
fi

find -P "$MNT/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%s\n' | sort -V >"$OUT/assets.tsv"
[[ $(wc -l <"$OUT/assets.tsv") -eq 128 ]] || die asset_count
awk -F '\t' '$2 != 1073741824 {bad++} END {exit bad ? 1 : 0}' "$OUT/assets.tsv" || die asset_size

cat >"$OUT/warmup.fio" <<EOF
[global]
ioengine=libaio
iodepth=128
numjobs=128
rw=randread
bs=256K
filesize=1G
size=1G
direct=1
fallocate=none
allow_file_create=0
openfiles=128
time_based=1
runtime=${WARMUP_RUNTIME}
group_reporting=1
randrepeat=1
randseed=20260915
filename_format=${MNT}/test_dir/rw_test.\$jobnum.0
[job]
EOF
cat >"$OUT/formal.fio" <<EOF
[global]
ioengine=libaio
iodepth=128
numjobs=128
rw=randrw
rwmixread=50
bs=256K
filesize=1G
size=1G
direct=1
fallocate=none
allow_file_create=0
openfiles=128
time_based=1
runtime=${RUNTIME}
group_reporting=1
randrepeat=1
randseed=20260915
filename_format=${MNT}/test_dir/rw_test.\$jobnum.0
[job]
EOF
sha256sum "$OUT/warmup.fio" "$OUT/formal.fio" >"$OUT/fio-contract.sha256"
timeout 120 fio "$OUT/warmup.fio" --output="$OUT/warmup.json" --output-format=json
curl -fsS --max-time 5 "http://${METRICS}/metrics" >"$OUT/metrics.pre.prom"
cat "/proc/$worker_pid/stat" >"$OUT/worker-stat.pre"
sampler_stop=$OUT/formal/sampler.stop
nic=$(ip route get 10.3.1.6 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[[ -n $nic && -r /sys/class/net/$nic/statistics/rx_bytes && -r /sys/class/net/$nic/statistics/tx_bytes ]] || die sampler_nic_missing
(
  printf 'epoch_ns\tmetric_file\n' >"$OUT/formal/metrics-1hz.tsv"
  printf 'epoch_ns\tcache_dir\ttotal_bytes\tavailable_bytes\n' >"$OUT/formal/df-1hz.tsv"
  printf 'epoch_ns\tCached_kB\tDirty_kB\tWriteback_kB\trx_bytes\ttx_bytes\n' >"$OUT/formal/meminfo-1hz.tsv"
  while [[ ! -e $sampler_stop ]]; do
    epoch=$(date +%s%N)
    curl -fsS --max-time 5 "http://${METRICS}/metrics" >"$OUT/formal/metrics-${epoch}.prom" || exit 42
    printf '%s\tmetrics-%s.prom\n' "$epoch" "$epoch" >>"$OUT/formal/metrics-1hz.tsv"
    read -r total avail < <(df -B1 --output=size,avail "$CACHE_DIR" | awk 'NR==2{print $1,$2}')
    printf '%s\t%s\t%s\t%s\n' "$epoch" "$CACHE_DIR" "$total" "$avail" >>"$OUT/formal/df-1hz.tsv"
    read -r cached dirty writeback < <(awk '/^Cached:/{c=$2}/^Dirty:/{d=$2}/^Writeback:/{w=$2}END{print c+0,d+0,w+0}' /proc/meminfo)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$cached" "$dirty" "$writeback" \
      "$(cat /sys/class/net/$nic/statistics/rx_bytes)" "$(cat /sys/class/net/$nic/statistics/tx_bytes)" \
      >>"$OUT/formal/meminfo-1hz.tsv"
    sleep 0.8
  done
) >"$OUT/formal/sampler.stdout" 2>"$OUT/formal/sampler.stderr" &
sampler_pid=$!
iostat_pid=
if command -v iostat >/dev/null 2>&1; then
  iostat -dxk 1 >"$OUT/formal/iostat-1hz.tsv" 2>"$OUT/formal/iostat.stderr" &
  iostat_pid=$!
fi
date +%s%N >"$OUT/formal/fio-start-epoch-ns.txt"
set +e
timeout 300 fio "$OUT/formal.fio" --write_bw_log="$OUT/formal/bw/randrw" --log_avg_msec=1000 \
  --output="$OUT/formal/fio.json" --output-format=json
fio_rc=$?
set -e
date +%s%N >"$OUT/formal/fio-end-epoch-ns.txt"
: >"$sampler_stop"
sampler_rc=0
wait "$sampler_pid" || sampler_rc=$?
if [[ -n $iostat_pid ]]; then kill -TERM "$iostat_pid" 2>/dev/null || true; wait "$iostat_pid" 2>/dev/null || true; fi
printf '%s\n' "$sampler_rc" >"$OUT/formal/sampler.rc"
(( sampler_rc == 0 )) || die formal_sampler_failed
python3 - "$OUT/formal/fio-start-epoch-ns.txt" "$OUT/formal/fio-end-epoch-ns.txt" "$OUT/formal/metrics-1hz.tsv" <<'PY' \
  >"$OUT/formal/sampler-coverage.tsv" || die formal_sampler_coverage
import sys
start=int(open(sys.argv[1]).read()); end=int(open(sys.argv[2]).read())
rows=[int(x.split('\t',1)[0]) for x in open(sys.argv[3]).read().splitlines()[1:] if x]
assert len(rows) >= 170, len(rows)
gaps=[(b-a)/1e9 for a,b in zip(rows,rows[1:])]
max_gap=max(gaps,default=0.0)
start_lag=(rows[0]-start)/1e9; end_lag=(end-rows[-1])/1e9
assert start_lag <= 1.5 and end_lag <= 1.5 and max_gap <= 1.5, (start_lag,end_lag,max_gap)
print('samples\tstart_lag_s\tend_lag_s\tmax_gap_s')
print(f'{len(rows)}\t{start_lag:.6f}\t{end_lag:.6f}\t{max_gap:.6f}')
PY
printf '%s\n' "$fio_rc" >"$OUT/formal/fio.rc"
(( fio_rc == 0 )) || die formal_fio_failed
[[ $(find "$OUT/formal/bw" -maxdepth 1 -type f -name 'randrw_bw.*.log' | wc -l) -eq 128 ]] || die bw_log_count
curl -fsS --max-time 5 "http://${METRICS}/metrics" >"$OUT/metrics.post.prom"
cat "/proc/$worker_pid/stat" >"$OUT/worker-stat.post"
cat "/proc/$worker_pid/status" >"$OUT/worker-status.post"
df -B1 --output=size,used,avail,pcent,target "$CACHE_PARENT" >"$OUT/cache-df.post-formal.tsv"
grep -Eqi 'stageFull|not enough free space' "$OUT/juicefs.log" && die staging_space_guard_hit
if [[ $CELL != B ]]; then
  curl -fsS --max-time 600 "${PPROF_BASE}/debug/flush-instrumentation" | gzip -1 >"$OUT/read-intervals.tsv.gz" || die interval_dump_failed
  gzip -t "$OUT/read-intervals.tsv.gz" || die interval_gzip_invalid
fi

metric_sum() {
  local text=$1 name=$2
  awk -v n="$name" '$1 ~ ("^" n "($|\\{)") {s+=$(NF);f=1} END{if(f)printf "%.0f",s;else print "NA"}' <<<"$text"
}
drain_writeback() {
  local start now text blocks bytes writing files file_bytes zeros=0
  start=$(date +%s)
  printf 'epoch_ns\tstaging_blocks\tstaging_bytes\tstaging_writing_blocks\tstaging_files\tstaging_file_bytes\n' >"$OUT/drain.tsv"
  while :; do
    now=$(date +%s)
    text=$(curl -fsS --max-time 5 "http://${METRICS}/metrics") || die drain_metrics
    blocks=$(metric_sum "$text" juicefs_staging_blocks)
    bytes=$(metric_sum "$text" juicefs_staging_block_bytes)
    writing=$(metric_sum "$text" juicefs_staging_writing_blocks)
    [[ $blocks != NA && $bytes != NA && $writing != NA ]] || die staging_metrics_missing
    read -r files file_bytes < <(find "$CACHE_DIR" -ignore_readdir_race -xdev -type f -path '*/rawstaging/*' -printf '%s\n' 2>/dev/null | awk '{n++;s+=$1}END{print n+0,s+0}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$blocks" "$bytes" "$writing" "$files" "$file_bytes" >>"$OUT/drain.tsv"
    [[ $blocks == 0 && $bytes == 0 && $writing == 0 && $files == 0 && $file_bytes == 0 ]] && zeros=$((zeros+1)) || zeros=0
    if (( zeros >= 2 )); then printf '%s\n' "$((now-start))" >"$OUT/drain-seconds.txt"; return 0; fi
    (( now-start < DRAIN_TIMEOUT )) || { event DRAIN_TIMEOUT PRESERVE_MOUNT; return 43; }
    sleep 1
  done
}
drain_writeback || die drain_timeout_preserve_mount

timeout 300 "$JFS" umount "$MNT" >"$OUT/umount.stdout" 2>"$OUT/umount.stderr"
for _ in $(seq 1 120); do mountpoint -q "$MNT" || break; sleep 1; done
mountpoint -q "$MNT" && die mount_remains
for _ in $(seq 1 60); do processes_gone "$OUT/mount-process.tsv" && break; sleep 1; done
processes_gone "$OUT/mount-process.tsv" || die mount_process_remains
rmdir "$MNT"

mkdir -m 0700 "$VERIFY_MNT"
capture_pids "$OUT/verify-pids.before"
env CEPH_CONF="$CEPH_CONF" "$JFS" mount -d --max-fuse-io 256K --buffer-size 300 --max-uploads 150 --max-downloads 200 \
  --metrics "$VERIFY_METRICS" --log "$OUT/verify-mount.log" --cache-size 0 "$META" "$VERIFY_MNT" \
  >"$OUT/verify-mount.stdout" 2>"$OUT/verify-mount.stderr"
for _ in $(seq 1 90); do mountpoint -q "$VERIFY_MNT" && break; sleep 1; done
mountpoint -q "$VERIFY_MNT" || die verify_mount_timeout
mount_pid_gate "$OUT/verify-pids.before" "--metrics $VERIFY_METRICS" "$OUT/verify-mount-process.tsv" || die verify_process_identity
require_metrics_identity "$VERIFY_METRICS" "$VERIFY_MNT" "$OUT/verify-metrics.prom"
timeout 120 fio --name=readback \
  --filename="$VERIFY_MNT/test_dir/rw_test.0.0:$VERIFY_MNT/test_dir/rw_test.31.0:$VERIFY_MNT/test_dir/rw_test.63.0:$VERIFY_MNT/test_dir/rw_test.127.0" \
  --rw=read --bs=256K --size=4M --direct=1 --ioengine=libaio --iodepth=1 --numjobs=1 \
  --group_reporting --output="$OUT/readback.json" --output-format=json
"$JFS" umount "$VERIFY_MNT" >"$OUT/verify-umount.stdout" 2>"$OUT/verify-umount.stderr"
for _ in $(seq 1 120); do mountpoint -q "$VERIFY_MNT" || break; sleep 1; done
mountpoint -q "$VERIFY_MNT" && die verify_mount_remains
for _ in $(seq 1 60); do processes_gone "$OUT/verify-mount-process.tsv" && break; sleep 1; done
processes_gone "$OUT/verify-mount-process.tsv" || die verify_mount_process_remains
rmdir "$VERIFY_MNT"

findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference-mount.after.tsv"
cmp -s "$OUT/reference-mount.before.tsv" "$OUT/reference-mount.after.tsv" || die reference_mount_changed
[[ -z $(findmnt -rn -R "$CACHE_DIR" -o TARGET 2>/dev/null) ]] || die cache_dir_is_mount
[[ $(realpath -e "$CACHE_DIR") == "$CACHE_DIR" && ${CACHE_DIR%/*} == "$CACHE_PARENT" ]] || die cache_child_identity_drift
event CACHE_CLEAN_PRE "$CACHE_DIR"
find "$CACHE_DIR" -ignore_readdir_race -xdev -depth -mindepth 1 -delete
rmdir "$CACHE_DIR"
event CACHE_CLEAN_POST "$CACHE_DIR"
ceph --conf "$CEPH_CONF" -s -f json >"$OUT/ceph.after.json"
ceph --conf "$CEPH_CONF" health detail -f json >"$OUT/health-detail.after.json"
ceph --conf "$CEPH_CONF" osd stat -f json >"$OUT/osd.after.json"
ceph --conf "$CEPH_CONF" pg dump pgs_brief >"$OUT/pg.after.txt"
python3 - "$OUT/health-detail.after.json" "$OUT/osd.after.json" <<'PY' || die post_health_gate
import json,sys
h=json.load(open(sys.argv[1])); status=h.get('status'); checks=set(h.get('checks',{}))
assert (status == 'HEALTH_OK' and not checks) or (status == 'HEALTH_WARN' and checks == {'OSDMAP_FLAGS'}), (status,checks)
o=json.load(open(sys.argv[2])); n=o.get('num_osds',0)
assert n > 0 and o.get('num_up_osds') == n and o.get('num_in_osds') == n, o
PY
awk '$1 ~ /^[0-9]+\.[0-9a-fA-F]+$/ {n++; if ($2 != "active+clean") bad++} END {exit (n>0 && bad==0)?0:1}' \
  "$OUT/pg.after.txt" || die post_pg_gate
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
printf 'T062_GATE2B_CELL_PASS\tcell=%s\truntime=%ss\n' "$CELL" "$RUNTIME"
