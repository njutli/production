#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

RUN_ID=${1:-}
if [[ $RUN_ID == --self-test ]]; then
  grep -Fq 'RUNTIME=180' "$0"
  grep -Fq 'CACHE_MIB=98304' "$0"
  grep -Fq 'rw=randrw' "$0"
  grep -Fq 'debug/pprof/trace?seconds=30' "$0"
  grep -Fq 'debug/pprof/goroutine?debug=2' "$0"
  grep -Fq 'drain_writeback' "$0"
  test_ts=$(date '+%Y.%m.%d %H:%M:%S.%N' | cut -c1-26)
  [[ ${#test_ts} -eq 26 && $test_ts =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$ ]]
  ! grep -Eq 'fusermount[[:space:]]+-u[z]|umount[[:space:]]+-l|rm[[:space:]]+-rf|pkill|killall|fuser[[:space:]]+-k' "$0"
  printf 'T062_GATE2A_SELF_TEST_PASS\n'
  exit 0
fi

ROOT=/tmp/production/opencode-06-2-${RUN_ID}
OUT=${ROOT}/profile/gate2a
JFS=${ROOT}/bin/juicefs-v1.4.1-b-catchup-baseline
JFS_MD5=1eb79575f654c77c14aa212c2b6c478d
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
CEPH_CONF=/etc/ceph/ceph.conf
CACHE_PARENT=/mnt/jfs-cache/04tmp3
CACHE_DIR=${CACHE_PARENT}/jfs-06-2-${RUN_ID}-gate2a
MNT=/tmp/jfs-06-2-${RUN_ID}-gate2a
VERIFY_MNT=/tmp/jfs-06-2-${RUN_ID}-gate2a-verify
METRICS=127.0.0.1:19641
PPROF_BASE=
CACHE_MIB=98304
RUNTIME=180
DRAIN_TIMEOUT=900

die() {
  if [[ -n ${OUT:-} && -d ${OUT:-} ]]; then
    printf '%s\tPRESERVE_SCENE\treason=%s\n' "$(date +%s%N)" "$*" >>"$OUT/phase.tsv" 2>/dev/null || true
  fi
  printf 'T062_GATE2A_FAIL\t%s\n' "$*" >&2
  exit 42
}
event() { printf '%s\t%s\t%s\n' "$(date +%s%N)" "$1" "$2" >>"$OUT/incidents.tsv"; }
log_cmd() { printf '%q ' "$@" >>"$OUT/commands.sh"; printf '\n' >>"$OUT/commands.sh"; }
phase() { printf '%s\t%s\n' "$(date +%s%N)" "$1" >>"$OUT/phase.tsv"; }
preserve_on_error() {
  rc=$?
  printf '%s\tPRESERVE_SCENE\trc=%s\n' "$(date +%s%N)" "$rc" >>"$OUT/phase.tsv" 2>/dev/null || true
  exit "$rc"
}

[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_run_id
[[ $ROOT == /tmp/production/opencode-06-2-${RUN_ID} && -d $ROOT && ! -L $ROOT ]] || die invalid_root
[[ -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die binary_identity
[[ ! -e $OUT && ! -L $OUT ]] || die output_exists
[[ ! -e $CACHE_DIR && ! -L $CACHE_DIR ]] || die cache_child_exists
[[ ! -e $MNT && ! -L $MNT && ! -e $VERIFY_MNT && ! -L $VERIFY_MNT ]] || die mount_path_exists
mkdir -m 0700 -p "$OUT/formal/bw" "$OUT/goroutine-dumps"
printf 'epoch_ns\tevent\tdetail\n' >"$OUT/incidents.tsv"
printf 'epoch_ns\tphase\n' >"$OUT/phase.tsv"
printf 'type\tpid\tstarttime_ticks\tstart_epoch_ns\toutput\n' >"$OUT/samplers.pid.tsv"
printf 'type\tpid\trc\tend_epoch_ns\n' >"$OUT/samplers.rc.tsv"
trap preserve_on_error ERR

[[ $(id -u) == 1002 && $(id -g) == 1002 ]] || die unexpected_executor_identity
read -r parent_source parent_major parent_fstype parent_target parent_opts \
  < <(findmnt -bnr -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,TARGET,OPTIONS) || die cache_parent_findmnt
read -r parent_uid parent_gid parent_mode < <(stat -Lc '%u %g %a' "$CACHE_PARENT")
parent_uuid=$(lsblk -dnro UUID "${parent_source%%[*}" 2>/dev/null || true)
[[ $(realpath -e "$CACHE_PARENT") == "$CACHE_PARENT" && $parent_source == /dev/nvme1n1 &&
   $parent_major == 259:2 && $parent_fstype == ext4 && $parent_target == /mnt/jfs-cache &&
   $parent_opts == rw,noatime,stripe=32 && $parent_uuid == 1b691709-e347-452c-96c4-5f37052bc203 &&
   $parent_uid == 1002 && $parent_gid == 1002 && $parent_mode == 700 && -w $CACHE_PARENT ]] \
  || die cache_parent_identity_drift
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CACHE_PARENT" "$parent_source" "$parent_major" \
  "$parent_fstype" "$parent_uuid" "$parent_target" "$parent_opts" "$parent_uid:$parent_gid" "$parent_mode" \
  >"$OUT/cache-parent-live.tsv"

[[ -z $(pgrep -x fio || true) ]] || die foreign_fio
! ss -ltnH | awk '$4 ~ /:19641$/ || $4 ~ /:19642$/ {found=1} END{exit found?0:1}' || die metrics_port_occupied
ceph --conf "$CEPH_CONF" -s -f json >"$OUT/ceph.before.json"
ceph --conf "$CEPH_CONF" osd stat -f json >"$OUT/osd.before.json"
findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference-mount.before.tsv"
mkdir -m 0700 "$CACHE_DIR" "$MNT"
event CACHE_CREATE "$CACHE_DIR"

capture_pids() {
  local out=$1 proc
  : >"$out"
  for proc in /proc/[0-9]*; do
    [[ -e $proc/exe ]] || continue
    [[ $(readlink -f "$proc/exe" 2>/dev/null || true) == "$JFS" ]] && basename "$proc" >>"$out"
  done
  sort -n -o "$out" "$out"
}

mount_pid_gate() {
  local before=$1 launch_marker=$2 out=$3
  python3 - "$JFS" "$before" "$launch_marker" >"$out" <<'PY'
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
  local addr=$1 mnt=$2 out=$3 text
  text=$(curl -fsS --max-time 5 "http://${addr}/metrics") || die metrics_unavailable
  grep -Fq 'vol_name="juicefs-prod"' <<<"$text" || die metrics_volume_identity
  grep -Fq "mp=\"$mnt\"" <<<"$text" || die metrics_mount_identity
  printf '%s' "$text" >"$out"
}

record_sampler() {
  local type=$1 pid=$2 output=$3 starttime
  starttime=$(awk '{print $22}' "/proc/$pid/stat") || die sampler_identity
  printf '%s\t%s\t%s\t%s\t%s\n' "$type" "$pid" "$starttime" "$(date +%s%N)" "$output" >>"$OUT/samplers.pid.tsv"
}

capture_pids "$OUT/pids.before"
phase MOUNT_START
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
for _ in $(seq 1 30); do
  listeners=$(ss -ltnp) || die listener_inventory
  for port in $(seq 6060 6099); do
    grep -Eq ":${port}[[:space:]].*pid=${worker_pid}," <<<"$listeners" || continue
    candidate=http://127.0.0.1:${port}
    cmdline=$(curl -fsS --max-time 1 "${candidate}/debug/pprof/cmdline" 2>/dev/null | tr '\0' ' ' || true)
    if [[ $cmdline == *"$JFS"* && $cmdline == *"$META"* && $cmdline == *"$MNT"* && $cmdline == *"$OUT/juicefs.log"* ]]; then
      PPROF_BASE=$candidate
      printf '%s\t%s\n' "$PPROF_BASE" "$cmdline" >"$OUT/pprof-endpoint.tsv"
      break 2
    fi
  done
  sleep 1
done
[[ -n $PPROF_BASE ]] || die pprof_unavailable
curl -fsS --max-time 5 "${PPROF_BASE}/debug/pprof/cmdline" >"$OUT/pprof-cmdline.bin" || die pprof_unavailable
phase MOUNT_IDENTITY_PASS
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
runtime=60
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
log_cmd timeout 120 fio "$OUT/warmup.fio" --output="$OUT/warmup.json" --output-format=json
timeout 120 fio "$OUT/warmup.fio" --output="$OUT/warmup.json" --output-format=json
curl -fsS --max-time 5 "http://${METRICS}/metrics" >"$OUT/metrics.pre.prom"

[[ -r $MNT/.accesslog ]] || die accesslog_unreadable
phase PROFILE_SAMPLERS_START
cat "$MNT/.accesslog" >"$OUT/accesslog.raw" 2>"$OUT/accesslog.stderr" &
access_pid=$!
record_sampler accesslog "$access_pid" "$OUT/accesslog.raw"
(
  for i in $(seq -w 1 36); do
    epoch=$(date +%s%N)
    curl -fsS --max-time 10 "${PPROF_BASE}/debug/pprof/goroutine?debug=2" \
      >"$OUT/goroutine-dumps/${i}-${epoch}.txt" || exit 42
    sleep 5
  done
) >"$OUT/goroutine-sampler.stdout" 2>"$OUT/goroutine-sampler.stderr" &
dump_pid=$!
record_sampler goroutine "$dump_pid" "$OUT/goroutine-dumps"
(
  sleep 15
  curl -fsS --max-time 45 "${PPROF_BASE}/debug/pprof/trace?seconds=30" >"$OUT/runtime-trace.out"
) >"$OUT/trace.stdout" 2>"$OUT/trace.stderr" &
trace_pid=$!
record_sampler runtime_trace "$trace_pid" "$OUT/runtime-trace.out"

log_cmd timeout 300 fio "$OUT/formal.fio" --write_bw_log="$OUT/formal/bw/randrw" --log_avg_msec=1000 \
  --output="$OUT/formal/fio.json" --output-format=json
date +%s%N >"$OUT/formal/fio-start-epoch-ns.txt"
date '+%Y.%m.%d %H:%M:%S.%N' | cut -c1-26 >"$OUT/formal/fio-start-local.txt"
phase FORMAL_START
set +e
timeout 300 fio "$OUT/formal.fio" --write_bw_log="$OUT/formal/bw/randrw" --log_avg_msec=1000 \
  --output="$OUT/formal/fio.json" --output-format=json
fio_rc=$?
set -e
date +%s%N >"$OUT/formal/fio-end-epoch-ns.txt"
date '+%Y.%m.%d %H:%M:%S.%N' | cut -c1-26 >"$OUT/formal/fio-end-local.txt"
printf '%s\n' "$fio_rc" >"$OUT/formal/fio.rc"
phase FORMAL_END
(( fio_rc == 0 )) || die formal_fio_failed
kill -TERM "$access_pid" 2>/dev/null || true
trap - ERR
set +e
wait "$access_pid" 2>/dev/null
access_rc=$?
set -e
printf '%s\n' "$access_rc" >"$OUT/accesslog.rc"
printf 'accesslog\t%s\t%s\t%s\n' "$access_pid" "$access_rc" "$(date +%s%N)" >>"$OUT/samplers.rc.tsv"
[[ $access_rc == 0 || $access_rc == 143 ]] || die accesslog_reader_failed
set +e
wait "$dump_pid"; dump_rc=$?
wait "$trace_pid"; trace_rc=$?
set -e
printf 'goroutine\t%s\t%s\t%s\n' "$dump_pid" "$dump_rc" "$(date +%s%N)" >>"$OUT/samplers.rc.tsv"
printf 'runtime_trace\t%s\t%s\t%s\n' "$trace_pid" "$trace_rc" "$(date +%s%N)" >>"$OUT/samplers.rc.tsv"
(( dump_rc == 0 )) || die goroutine_sampler_failed
(( trace_rc == 0 )) || die runtime_trace_failed
trap preserve_on_error ERR
[[ $(find "$OUT/formal/bw" -maxdepth 1 -type f -name 'randrw_bw.*.log' | wc -l) -eq 128 ]] || die bw_log_count
[[ -s $OUT/runtime-trace.out && $(find "$OUT/goroutine-dumps" -type f -name '*.txt' | wc -l) -eq 36 ]] || die profile_completeness
[[ -s $OUT/accesslog.raw ]] || die accesslog_empty
access_start=$(<"$OUT/formal/fio-start-local.txt")
access_end=$(<"$OUT/formal/fio-end-local.txt")
awk -v s="$access_start" -v e="$access_end" 'substr($0,1,26)>=s && substr($0,1,26)<=e && $0 ~ / (read|write) \(/ {found=1} END{exit found?0:1}' \
  "$OUT/accesslog.raw" || die accesslog_formal_window_missing
curl -fsS --max-time 5 "http://${METRICS}/metrics" >"$OUT/metrics.post.prom"

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

log_cmd timeout 300 "$JFS" umount "$MNT"
timeout 300 "$JFS" umount "$MNT" >"$OUT/umount.stdout" 2>"$OUT/umount.stderr"
for _ in $(seq 1 120); do mountpoint -q "$MNT" || break; sleep 1; done
mountpoint -q "$MNT" && die mount_remains
for _ in $(seq 1 60); do processes_gone "$OUT/mount-process.tsv" && break; sleep 1; done
processes_gone "$OUT/mount-process.tsv" || die mount_process_remains
rmdir "$MNT"
capture_pids "$OUT/pids.after-formal"
cmp -s "$OUT/pids.before" "$OUT/pids.after-formal" || die formal_process_leak

mkdir -m 0700 "$VERIFY_MNT"
capture_pids "$OUT/verify-pids.before"
env CEPH_CONF="$CEPH_CONF" "$JFS" mount -d --max-fuse-io 256K --buffer-size 300 --max-uploads 150 --max-downloads 200 \
  --metrics 127.0.0.1:19642 --log "$OUT/verify-mount.log" --cache-size 0 "$META" "$VERIFY_MNT" \
  >"$OUT/verify-mount.stdout" 2>"$OUT/verify-mount.stderr"
for _ in $(seq 1 90); do mountpoint -q "$VERIFY_MNT" && break; sleep 1; done
mountpoint -q "$VERIFY_MNT" || die verify_mount_timeout
findmnt -rn -M "$VERIFY_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/verify-findmnt.tsv"
grep -Fq "JuiceFS:juicefs-prod $VERIFY_MNT fuse.juicefs" "$OUT/verify-findmnt.tsv" || die verify_mount_identity
mount_pid_gate "$OUT/verify-pids.before" "--metrics 127.0.0.1:19642" "$OUT/verify-mount-process.tsv" || die verify_process_identity
require_metrics_identity 127.0.0.1:19642 "$VERIFY_MNT" "$OUT/verify-metrics.prom"
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
capture_pids "$OUT/pids.after-verify"
cmp -s "$OUT/pids.before" "$OUT/pids.after-verify" || die verify_process_leak

timeout 1800 env CEPH_CONF="$CEPH_CONF" "$JFS" gc --compact --delete --threads 32 "$META" \
  >"$OUT/gc.stdout" 2>"$OUT/gc.stderr" || die gc_failed
findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference-mount.after.tsv"
cmp -s "$OUT/reference-mount.before.tsv" "$OUT/reference-mount.after.tsv" || die reference_mount_changed
[[ -z $(findmnt -rn -R "$CACHE_DIR" -o TARGET 2>/dev/null) ]] || die cache_dir_is_mount
[[ $(realpath -e "$CACHE_DIR") == "$CACHE_DIR" && ${CACHE_DIR%/*} == "$CACHE_PARENT" ]] || die cache_child_identity_drift
event CACHE_CLEAN_PRE "$CACHE_DIR"
find "$CACHE_DIR" -ignore_readdir_race -xdev -depth -mindepth 1 -delete
rmdir "$CACHE_DIR"
event CACHE_CLEAN_POST "$CACHE_DIR"
ceph --conf "$CEPH_CONF" -s -f json >"$OUT/ceph.after.json"
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
printf 'T062_GATE2A_RAW_PASS\tdumps=36\ttrace=30s\truntime=180s\n'
