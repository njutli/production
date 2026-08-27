#!/usr/bin/env bash
# t54-tikv-meta-latency-attribution.sh — 03-18：TiKV meta Write 延迟服务端归因
#
# 本脚本只做三件事：
#   1) 在交付配置下固定一个 JuiceFS 挂载实例；
#   2) 先采 120s idle，再由原版 FULLBASELINE_V4.sh 连跑 randwrite ×3；
#   3) 连续采客户端、TiKV/PD、TiKV 主机和对象数原始证据。
#
# 不改 TiKV/PD/Ceph 配置，不重启任何服务，不创建 layout，不做写前压力探针。
# GLM 只执行、监控、回传；统计与归因由分析方完成。
set -euo pipefail
export LC_ALL=C

RUN_ID="${1:-}"
if [[ ! "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
  echo "用法: $0 YYYYMMDD-HHMMSS" >&2
  exit 2
fi

OUT="/tmp/opencode-t3.18-${RUN_ID}"
V4=/tmp/FULLBASELINE_V4.sh
INSTR=/tmp/instrument.sh
SNAP=/tmp/env-snapshot.sh
TASKBOOK=/tmp/03-18-tikv-meta-latency-attribution.md
BIN=/tmp/juicefs-03-8
BIN_MD5_WANT=de93563f11a5ff3bd94dd25a4e0283b1
SYS_CONF=/etc/ceph/ceph.conf
SYS_CONF_MD5_WANT=5b6be34179a64e0a5f9c6d3a9690041f
PRIVATE_CONF="/tmp/t54-ceph-msgr8-${RUN_ID}.conf"
BIN_DIR="/tmp/t54-bin-${RUN_ID}"
V4_RESULTS=/tmp/opencode-fullbaseline-v4
V4_BACKUP="/tmp/opencode-fullbaseline-v4.pre-t54-${RUN_ID}"
ARCHIVE_DIR=/tmp/production
META='tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod'
MNT=/mnt/juicefs
TEST_DIR=/mnt/juicefs/test_dir
MOUNT_OPTS='--max-uploads 150 --cache-size 0 --max-fuse-io 256K'
TIKV_IPS=(10.20.1.150 10.20.1.151 10.20.1.152)
TIKV_EPS=(10.20.1.150:20180/metrics 10.20.1.151:20180/metrics 10.20.1.152:20180/metrics)
PD_EPS=(10.20.1.150:2379/metrics 10.20.1.151:2379/metrics 10.20.1.152:2379/metrics)
SSH=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1)
OBJ_START_MAX=3110000
OBJ_HARD_MAX=8000000
IDLE_SEC=120

TIKV_RE='^(tikv_storage_engine_async_request_duration_seconds_(sum|count)|tikv_storage_command_total|tikv_engine_cache_efficiency|tikv_scheduler_(command|latch_wait|processing_read)_duration_seconds_(sum|count)|tikv_raftstore_(append|commit|apply)_log_duration_seconds_(sum|count)|tikv_raftstore_apply_wait_time_duration_seconds_(sum|count)|tikv_engine_pending_compaction_bytes)(\{|[[:space:]])'
PD_RE='^(pd_server_tso_handle_duration_seconds_(sum|count)|pd_scheduler_[A-Za-z0-9_:]+|etcd_server_has_leader|etcd_server_leader_changes_seen_total|grpc_server_handling_seconds_(sum|count))(\{|[[:space:]])'
CLIENT_RE='^(juicefs_meta_ops_duration_seconds_Write|juicefs_meta_ops_total_Write|juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_transaction_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_write|juicefs_fuse_write_size_bytes_sum|juicefs_object_request_durations_histogram_seconds_PUT_(sum|total)|juicefs_object_request_data_bytes_PUT|juicefs_object_request_uploading|juicefs_process_cpu_seconds_total|juicefs_used_buffer_size_bytes|juicefs_staging_blocks) '

if [[ -e "$OUT" ]]; then
  echo "STOP: 唯一结果目录已存在，禁止混包: $OUT" >&2
  exit 3
fi
mkdir -p "$OUT" "$OUT/metrics-full" "$OUT/metrics-series" "$OUT/pd-api" "$OUT/tikv-host" "$OUT/client" "$ARCHIVE_DIR"
exec 3>&1
exec > >(tee -a "$OUT/wrapper.log") 2>&1
exec 9>/tmp/t54-stage03.lock
flock -n 9 || { echo "STOP: another T54 batch holds /tmp/t54-stage03.lock"; exit 3; }

log() { echo "[$(date '+%F %T %z')] $*"; }
stop_file="$OUT/STOP.txt"
sampler_pids=()
instr_started=0
load_pid=""

safety_dir() {
  local p="$1"
  [[ -n "$p" && "$p" == /tmp/* && "$p" != /tmp && "$p" != / ]] || {
    log "REFUSE unsafe path: $p"; exit 4;
  }
}

jfs_pid() {
  pgrep -af juicefs 2>/dev/null \
    | awk -v m="$MNT" '$0 ~ ("mount.*" m "([[:space:]]|$)") {print $1; exit}'
}

proc_starttime() {
  awk '{line=$0; sub(/^[0-9]+ \(/,"",line); if (!match(line,/\) [^)]*$/)) exit 1;
        rest=substr(line,RSTART+2); n=split(rest,f,/[[:space:]]+/); if(n<20) exit 1; print f[20]}' \
      "/proc/$1/stat" 2>/dev/null
}

pool_sample() {
  sudo ceph df --format=json 2>/dev/null | python3 -c '
import json,sys
p=[x for x in json.load(sys.stdin)["pools"] if x["name"]=="juicefs-data"][0]["stats"]
print(p["objects"],p["stored"],p["max_avail"])
'
}

health_ok() {
  local h
  h=$(sudo ceph health 2>&1 | head -1)
  printf '%s\t%s\n' "$(date +%s)" "$h" >> "$OUT/health-series.tsv"
  [[ "$h" == HEALTH_OK* ]]
}

metric_safe_name() { printf '%s' "$1" | tr '/:' '__'; }

validate_tikv_snapshot() {
  local f="$1" ep="$2" base plain s c sf cf total
  total=$(grep -Ec "$TIKV_RE" "$f" || true)
  printf 'snapshot\t%s\tFILTERED_TOTAL\t%s\tNA\n' "$ep" "$total" >> "$OUT/metrics-manifest.tsv"
  [[ "$total" -gt 0 ]] || { log "STOP TiKV $ep 精确过滤结果为空"; return 1; }
  for base in \
    tikv_storage_engine_async_request_duration_seconds \
    tikv_scheduler_command_duration_seconds \
    tikv_scheduler_latch_wait_duration_seconds \
    tikv_scheduler_processing_read_duration_seconds \
    tikv_raftstore_append_log_duration_seconds \
    tikv_raftstore_commit_log_duration_seconds \
    tikv_raftstore_apply_log_duration_seconds; do
    s=$(grep -Ec "^${base}_sum(\\{|[[:space:]])" "$f" || true)
    c=$(grep -Ec "^${base}_count(\\{|[[:space:]])" "$f" || true)
    printf 'snapshot\t%s\t%s\t%s\t%s\n' "$ep" "$base" "$s" "$c" >> "$OUT/metrics-manifest.tsv"
    [[ "$s" -gt 0 && "$c" -gt 0 ]] || {
      log "STOP TiKV $ep 缺 histogram pair: $base sum=$s count=$c"; return 1;
    }
    sf="${f}.sumlabels"; cf="${f}.countlabels"
    grep -E "^${base}_sum(\\{|[[:space:]])" "$f" \
      | sed -E "s/^${base}_sum//; s/[[:space:]][^[:space:]]+$//" | sort > "$sf"
    grep -E "^${base}_count(\\{|[[:space:]])" "$f" \
      | sed -E "s/^${base}_count//; s/[[:space:]][^[:space:]]+$//" | sort > "$cf"
    cmp -s "$sf" "$cf" || { log "STOP TiKV $ep histogram labels 不配对: $base"; return 1; }
  done
  for plain in tikv_storage_command_total tikv_engine_cache_efficiency tikv_engine_pending_compaction_bytes; do
    c=$(grep -Ec "^${plain}(\\{|[[:space:]])" "$f" || true)
    printf 'snapshot\t%s\t%s\t%s\tNA\n' "$ep" "$plain" "$c" >> "$OUT/metrics-manifest.tsv"
    [[ "$c" -gt 0 ]] || { log "STOP TiKV $ep 缺 plain metric: $plain"; return 1; }
  done
}

capture_full_metrics() {
  local tag="$1" ep safe tmp
  for ep in "${TIKV_EPS[@]}"; do
    safe=$(metric_safe_name "$ep")
    tmp=$(mktemp "$OUT/metrics-full/.tikv.XXXXXX")
    timeout 12 curl -fsS --max-time 10 "http://$ep" > "$tmp" 2>> "$OUT/metrics-errors.log" || {
      log "STOP TiKV endpoint 不可读: $ep"; return 1;
    }
    validate_tikv_snapshot "$tmp" "$ep" || return 1
    gzip -c "$tmp" > "$OUT/metrics-full/tikv-${safe}-${tag}.prom.gz"
    awk '/^[A-Za-z_:][A-Za-z0-9_:]*(\{|[[:space:]])/{n=$1;sub(/\{.*/,"",n);print n}' "$tmp" \
      | sort -u > "$OUT/metrics-full/tikv-${safe}-${tag}.names.txt"
    rm -f "$tmp" "${tmp}.sumlabels" "${tmp}.countlabels"
  done
  for ep in "${PD_EPS[@]}"; do
    safe=$(metric_safe_name "$ep")
    tmp=$(mktemp "$OUT/metrics-full/.pd.XXXXXX")
    timeout 12 curl -fsS --max-time 10 "http://$ep" > "$tmp" 2>> "$OUT/metrics-errors.log" || {
      log "STOP PD endpoint 不可读: $ep"; return 1;
    }
    gzip -c "$tmp" > "$OUT/metrics-full/pd-${safe}-${tag}.prom.gz"
    rm -f "$tmp"
  done
}

metric_loop() {
  local kind="$1" ep="$2" regex="$3" safe out
  safe=$(metric_safe_name "$ep")
  out="$OUT/metrics-series/${kind}-${safe}.prom.txt"
  while [[ ! -e "$OUT/.stop-samplers" ]]; do
    printf '=== ts=%s endpoint=%s ===\n' "$(date +%s)" "$ep" >> "$out"
    timeout 5 curl -fsS --max-time 3 "http://$ep" 2>> "$OUT/metrics-errors.log" \
      | grep -E "$regex" >> "$out" || true
    sleep 1
  done
}

client_write_loop() {
  local local_t
  while [[ ! -e "$OUT/.stop-samplers" ]]; do
    local_t=$(date +%s)
    timeout 3 cat "$MNT/.stats" 2>/dev/null \
      | grep -E "$CLIENT_RE" \
      | awk -v t="$local_t" '{print t"\t"$1"\t"$2}' >> "$OUT/client/write-meta-series.tsv" || true
    sleep 1
  done
}

pd_api_loop() {
  local base=http://10.20.1.150:2379/pd/api/v1 path tag
  while [[ ! -e "$OUT/.stop-samplers" ]]; do
    for path in hotspot/regions/write hotspot/regions/read hotspot/stores stores; do
      tag=$(printf '%s' "$path" | tr '/' '_')
      printf '=== ts=%s path=%s ===\n' "$(date +%s)" "$path" >> "$OUT/pd-api/${tag}.jsonl"
      timeout 5 curl -fsS --max-time 3 "$base/$path" >> "$OUT/pd-api/${tag}.jsonl" 2>> "$OUT/pd-api/errors.log" \
        || echo '{"capture_error":true}' >> "$OUT/pd-api/${tag}.jsonl"
      printf '\n' >> "$OUT/pd-api/${tag}.jsonl"
    done
    sleep 10
  done
}

host_loop() {
  local ip="$1" out="$OUT/tikv-host/${ip}.txt"
  while [[ ! -e "$OUT/.stop-samplers" ]]; do
    printf '=== local_ts=%s host=%s ===\n' "$(date +%s)" "$ip" >> "$out"
    timeout 15 "${SSH[@]}" "sunrise@$ip" '
      echo remote_ts=$(date +%s)
      p=$(pgrep -xo tikv-server 2>/dev/null || true)
      echo tikv_pid=${p:-NA}
      if [ -n "${p:-}" ]; then
        ps -p "$p" -o pid,etimes,pcpu,pmem,rss,vsz,nlwp --no-headers 2>/dev/null || true
        awk "/VmRSS|VmSize|Threads|voluntary_ctxt_switches|nonvoluntary_ctxt_switches/{print}" "/proc/$p/status" 2>/dev/null || true
      fi
      iostat -x -d 1 1 2>/dev/null | tail -n +4 || true
    ' >> "$out" 2>&1 || true
    sleep 5
  done
}

start_samplers() {
  local ep
  : > "$OUT/client/write-meta-series.tsv"
  printf 'ts\thealth\n' > "$OUT/health-series.tsv"
  printf 'scope\tendpoint_or_tag\tmetric\tsum_or_rows\tcount\n' > "$OUT/metrics-manifest.tsv"
  bash "$INSTR" start "$OUT/client" T54
  instr_started=1
  for ep in "${TIKV_EPS[@]}"; do metric_loop tikv "$ep" "$TIKV_RE" & sampler_pids+=("$!"); done
  for ep in "${PD_EPS[@]}"; do metric_loop pd "$ep" "$PD_RE" & sampler_pids+=("$!"); done
  client_write_loop & sampler_pids+=("$!")
  pd_api_loop & sampler_pids+=("$!")
  for ep in "${TIKV_IPS[@]}"; do host_loop "$ep" & sampler_pids+=("$!"); done
}

stop_samplers() {
  touch "$OUT/.stop-samplers"
  local p
  for p in "${sampler_pids[@]:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  for p in "${sampler_pids[@]:-}"; do
    [[ -n "$p" ]] && wait "$p" 2>/dev/null || true
  done
  sampler_pids=()
  if [[ "$instr_started" == 1 ]]; then
    bash "$INSTR" stop "$OUT/client" T54 || true
    instr_started=0
  fi
}

graceful_umount() {
  local p i
  p=$(jfs_pid || true)
  if ! mountpoint -q "$MNT" 2>/dev/null && [[ -z "$p" ]]; then return 0; fi
  "$BIN" umount --flush "$MNT" >> "$OUT/umount.log" 2>&1 || true
  for i in $(seq 1 30); do
    p=$(jfs_pid || true)
    if ! mountpoint -q "$MNT" 2>/dev/null && [[ -z "$p" ]]; then return 0; fi
    sleep 1
  done
  log "STOP: 优雅卸载 30s 后仍有本挂载；不做 TERM/KILL"
  return 1
}

collect_remote_tail() {
  local end_epoch="$1" ip
  for ip in "${TIKV_IPS[@]}"; do
    timeout 60 "${SSH[@]}" "sunrise@$ip" "journalctl -u tikv --since=@${START_EPOCH} --until=@${end_epoch} --no-pager 2>&1" \
      > "$OUT/tikv-host/${ip}-tikv-journal.txt" 2>&1 || true
    timeout 15 "${SSH[@]}" "sunrise@$ip" '
      date +"%s %F %T %z"
      /opt/tikv/bin/tikv-server --version 2>&1 | head -3
      md5sum /opt/tikv/conf/tikv.toml 2>/dev/null || true
      systemctl is-active tikv pd 2>/dev/null || true
    ' > "$OUT/tikv-host/${ip}-identity-post.txt" 2>&1 || true
  done
}

terminate_load() {
  local why="$1"
  [[ -e "$stop_file" ]] || printf '%s\t%s\n' "$(date '+%F %T %z')" "$why" > "$stop_file"
  if [[ -n "$load_pid" ]] && kill -0 "$load_pid" 2>/dev/null; then
    log "STOP load: $why (process-group=$load_pid)"
    kill -TERM -- "-$load_pid" 2>/dev/null || true
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  stop_samplers || true
  if [[ "$rc" -ne 0 ]]; then log "T54 exit rc=$rc；保留全部现场，不自动清理/重跑"; fi
  exit "$rc"
}
trap on_exit EXIT
trap 'terminate_load "wrapper received signal"; exit 130' INT TERM

log "=== T54 03-18 start run_id=$RUN_ID ==="
safety_dir "$OUT"
safety_dir "$V4_RESULTS"
safety_dir "$V4_BACKUP"

for f in "$V4" "$INSTR" "$SNAP" "$BIN" "$SYS_CONF"; do
  [[ -f "$f" ]] || { log "STOP missing file: $f"; exit 5; }
done
if pgrep -x fio >/dev/null 2>&1 || pgrep -af '[F]ULLBASELINE_V4.sh' >/dev/null 2>&1; then
  log "STOP pre-existing fio/FULLBASELINE_V4 process detected"
  pgrep -ax fio || true
  pgrep -af '[F]ULLBASELINE_V4.sh' || true
  exit 5
fi
{
  hostname
  date '+%s %F %T %z'
  md5sum "$V4" "$INSTR" "$SNAP" "$BIN" "$SYS_CONF"
  bash -n "$V4"
  bash -n "$INSTR"
  fio --version
  df -h /
  sudo ceph health detail
  sudo ceph osd stat
  sudo ceph pg stat
} > "$OUT/env-check.txt" 2>&1

[[ "$(md5sum "$BIN" | awk '{print $1}')" == "$BIN_MD5_WANT" ]] || { log "STOP binary md5 mismatch"; exit 5; }
[[ "$(md5sum "$SYS_CONF" | awk '{print $1}')" == "$SYS_CONF_MD5_WANT" ]] || { log "STOP system ceph.conf md5 mismatch"; exit 5; }
health_ok || { log "STOP initial ceph health is not HEALTH_OK"; exit 5; }
[[ "$(sudo ceph osd ls 2>/dev/null | wc -l)" -eq 6 ]] || { log "STOP OSD count != 6"; exit 5; }
pg_line=$(sudo ceph pg stat 2>&1)
echo "$pg_line" | grep -qE 'unknown|inactive|peering|degraded|recovering|backfill|misplaced|incomplete' \
  && { log "STOP PG not clean: $pg_line"; exit 5; }

avail_k=$(df -Pk / | awk 'NR==2{print $4}')
[[ "$avail_k" =~ ^[0-9]+$ && "$avail_k" -ge 5242880 ]] || { log "STOP root free space < 5 GiB"; exit 5; }

if [[ -e "$V4_BACKUP" ]]; then
  log "STOP backup target already exists: $V4_BACKUP"; exit 5
fi
if [[ -e "$V4_RESULTS" ]]; then
  mv "$V4_RESULTS" "$V4_BACKUP"
  log "旧 V4 目录已无损移至 $V4_BACKUP（禁止删除）"
fi

mkdir -p "$BIN_DIR"
ln -s "$BIN" "$BIN_DIR/juicefs"
export PATH="$BIN_DIR:$PATH"
cp "$SYS_CONF" "$PRIVATE_CONF"
printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
export CEPH_CONF="$PRIVATE_CONF"
cp "$SYS_CONF" "$OUT/ceph.conf.system-before"
cp "$PRIVATE_CONF" "$OUT/ceph.conf.private-msgr8"
[[ -f "$TASKBOOK" ]] && cp "$TASKBOOK" "$OUT/taskbook.md"

{
  echo '#!/usr/bin/env bash'
  echo '# T54 actual command record'
  printf 'export PATH=%q:$PATH\n' "$BIN_DIR"
  printf 'export CEPH_CONF=%q\n' "$PRIVATE_CONF"
  printf '%q mount -d %s %q %q\n' "$BIN" "$MOUNT_OPTS" "$META" "$MNT"
  printf 'ITEMS=randwrite SKIP_REMOUNT=1 OBJ_GATE=1 OBJ_GC_PASSES=0 OBJ_START_MAX=%s OBJ_WARN=%s OBJ_MAX=%s JUICEFS_MOUNT_OPTS=%q bash %q T54 180 3\n' \
    "$OBJ_START_MAX" "$OBJ_START_MAX" "$OBJ_HARD_MAX" "$MOUNT_OPTS" "$V4"
} > "$OUT/commands.sh"

graceful_umount || exit 6
"$BIN" mount -d $MOUNT_OPTS "$META" "$MNT" >> "$OUT/mount.log" 2>&1
sleep 10
mountpoint -q "$MNT" || { log "STOP mount failed"; exit 6; }
PID=$(jfs_pid || true)
[[ "$PID" =~ ^[0-9]+$ ]] || { log "STOP cannot resolve mount pid"; exit 6; }
PSTART=$(proc_starttime "$PID")
{
  echo "pid=$PID starttime_ticks=$PSTART"
  echo "exe=$(readlink -f "/proc/$PID/exe")"
  md5sum "/proc/$PID/exe"
  grep " $MNT " /proc/mounts
  _proc_ceph_conf=$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | awk -F= '$1=="CEPH_CONF"{print $2}')
  _msgr_ok=$(grep -c 'ms_async_op_threads = 8' "$_proc_ceph_conf" 2>/dev/null || echo 0)
  echo "proc_ceph_conf=$_proc_ceph_conf"
  echo "ms_async_op_threads_8=$_msgr_ok"
} > "$OUT/mount-verify.txt"
[[ "$(md5sum "/proc/$PID/exe" | awk '{print $1}')" == "$BIN_MD5_WANT" ]] || { log "STOP running exe md5 mismatch"; exit 6; }
grep " $MNT " /proc/mounts | grep -q 'max_read=262144' || { log "STOP max_read != 262144"; exit 6; }
_proc_ceph_conf=$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | awk -F= '$1=="CEPH_CONF"{print $2}')
[[ -n "$_proc_ceph_conf" && "$(grep -c 'ms_async_op_threads = 8' "$_proc_ceph_conf" 2>/dev/null || echo 0)" -eq 1 ]] || { log "STOP ms_async_op_threads=8 not found in proc CEPH_CONF"; exit 6; }
for stem in storage_test read_test rw_test; do
  [[ "$(find "$TEST_DIR" -maxdepth 1 -type f -name "${stem}.*.0" 2>/dev/null | wc -l)" -eq 128 ]] \
    || { log "STOP ${stem} layout != 128 files; 禁止现场 --layout"; exit 6; }
done
[[ -f "$TEST_DIR/seqread/seqread.0.0" ]] \
  || { log "STOP seqread prep missing（V4 硬前置）；禁止现场 --layout"; exit 6; }

read -r START_OBJ START_STORED _ < <(pool_sample)
printf 'ts\tphase\tobjects\tstored\tmax_avail\n%s\tstart\t%s\t%s\tNA\n' \
  "$(date +%s)" "$START_OBJ" "$START_STORED" > "$OUT/object-series.tsv"
[[ "$START_OBJ" -le "$OBJ_START_MAX" ]] || { log "STOP start objects=$START_OBJ > $OBJ_START_MAX; 禁止自动 gc"; exit 7; }

bash "$SNAP" "$OUT" pre "$META"
capture_full_metrics preflight
START_EPOCH=$(date +%s)
for ip in "${TIKV_IPS[@]}"; do
  timeout 15 "${SSH[@]}" "sunrise@$ip" '
    date +"%s %F %T %z"
    /opt/tikv/bin/tikv-server --version 2>&1 | head -3
    md5sum /opt/tikv/conf/tikv.toml 2>/dev/null || true
    systemctl is-active tikv pd 2>/dev/null || true
  ' > "$OUT/tikv-host/${ip}-identity-pre.txt" 2>&1 || true
done

start_samplers
printf '%s\tidle-start\n' "$(date +%s)" >> "$OUT/phase-markers.tsv"
log "idle capture ${IDLE_SEC}s（无 fio、无 preprobe）"
for _ in $(seq 1 $((IDLE_SEC / 10))); do
  read -r o s m < <(pool_sample)
  printf '%s\tidle\t%s\t%s\t%s\n' "$(date +%s)" "$o" "$s" "$m" >> "$OUT/object-series.tsv"
  [[ "$o" -le "$OBJ_HARD_MAX" ]] || { log "STOP idle objects=$o > $OBJ_HARD_MAX"; exit 7; }
  [[ "$(jfs_pid || true)" == "$PID" && "$(proc_starttime "$PID")" == "$PSTART" ]] \
    || { log "STOP mount drift during idle"; exit 7; }
  sleep 10
done
printf '%s\tidle-end\n' "$(date +%s)" >> "$OUT/phase-markers.tsv"
capture_full_metrics idle-post

printf '%s\tv4-start\n' "$(date +%s)" >> "$OUT/phase-markers.tsv"
setsid env \
  ITEMS=randwrite SKIP_REMOUNT=1 \
  OBJ_GATE=1 OBJ_GC_PASSES=0 OBJ_START_MAX="$OBJ_START_MAX" OBJ_WARN="$OBJ_START_MAX" OBJ_MAX="$OBJ_HARD_MAX" \
  JUICEFS_MOUNT_OPTS="$MOUNT_OPTS" \
  bash "$V4" T54 180 3 > "$OUT/v4.stdout.log" 2>&1 &
load_pid=$!
log "V4 load pid/process-group=$load_pid"

load_stop=0
tick=0
while kill -0 "$load_pid" 2>/dev/null; do
  tick=$((tick + 1))
  if ! read -r o s m < <(pool_sample); then
    terminate_load "pool object sample failed"
    load_stop=1
    break
  fi
  printf '%s\tload\t%s\t%s\t%s\n' "$(date +%s)" "$o" "$s" "$m" >> "$OUT/object-series.tsv"
  if [[ "$o" -gt "$OBJ_HARD_MAX" ]]; then
    terminate_load "runtime objects=$o > hard max $OBJ_HARD_MAX"
    load_stop=1
    break
  fi
  now_pid=$(jfs_pid || true)
  now_start=$(proc_starttime "$PID" || true)
  if [[ "$now_pid" != "$PID" || "$now_start" != "$PSTART" ]]; then
    terminate_load "mount drift got=$now_pid/$now_start want=$PID/$PSTART"
    load_stop=1
    break
  fi
  if (( tick % 3 == 0 )) && ! health_ok; then
    terminate_load "ceph health became non-OK"
    load_stop=1
    break
  fi
  gate_file="$V4_RESULTS/obj-gate-T54.tsv"
  if [[ -s "$gate_file" ]] && awk -v lim="$OBJ_START_MAX" '
      {for(i=1;i<=NF;i++) if($i ~ /^objects=/){split($i,a,"="); if(a[2]+0>lim) bad=1}} END{exit bad?0:1}' "$gate_file"; then
    terminate_load "post-cleanup objects exceeded start limit $OBJ_START_MAX"
    load_stop=1
    break
  fi
  sleep 10
done

set +e
wait "$load_pid"
load_rc=$?
set -e
load_pid=""
printf '%s\tv4-end rc=%s\n' "$(date +%s)" "$load_rc" >> "$OUT/phase-markers.tsv"
[[ "$load_stop" -eq 0 && "$load_rc" -eq 0 ]] || { log "STOP V4 rc=$load_rc load_stop=$load_stop"; exit 8; }
gate_file="$V4_RESULTS/obj-gate-T54.tsv"
if [[ -s "$gate_file" ]] && awk -v lim="$OBJ_START_MAX" '
    {for(i=1;i<=NF;i++) if($i ~ /^objects=/){split($i,a,"="); if(a[2]+0>lim) bad=1}} END{exit bad?0:1}' "$gate_file"; then
  log "STOP one or more post-cleanup boundaries exceeded $OBJ_START_MAX"
  exit 8
fi

capture_full_metrics post-load
stop_samplers
END_EPOCH=$(date +%s)
collect_remote_tail "$END_EPOCH"
bash "$SNAP" "$OUT" post "$META"
cp "$SYS_CONF" "$OUT/ceph.conf.system-after"
[[ "$(md5sum "$SYS_CONF" | awk '{print $1}')" == "$SYS_CONF_MD5_WANT" ]] || { log "STOP system ceph.conf changed"; exit 9; }
health_ok || { log "STOP final ceph health is not HEALTH_OK"; exit 9; }

read -r END_OBJ END_STORED END_MAX < <(pool_sample)
printf '%s\tend\t%s\t%s\t%s\n' "$(date +%s)" "$END_OBJ" "$END_STORED" "$END_MAX" >> "$OUT/object-series.tsv"
[[ "$END_OBJ" -le "$OBJ_START_MAX" ]] || { log "STOP final objects=$END_OBJ > $OBJ_START_MAX"; exit 9; }

graceful_umount || exit 9
[[ -d "$V4_RESULTS" ]] || { log "STOP V4 result directory missing"; exit 10; }
mv "$V4_RESULTS" "$OUT/v4"

rm -f "$OUT/.stop-samplers"
{
  printf 'file\tlines\tbytes\n'
  find "$OUT/metrics-series" "$OUT/client" "$OUT/pd-api" "$OUT/tikv-host" -type f -print0 \
    | sort -z | while IFS= read -r -d '' f; do
        printf '%s\t%s\t%s\n' "${f#$OUT/}" "$(wc -l < "$f")" "$(stat -c %s "$f")"
      done
} > "$OUT/series-manifest.tsv"
archive="$ARCHIVE_DIR/opencode-t3.18-${RUN_ID}.tar.gz"
log "T54 data collection complete; preparing immutable manifest/archive"
log "OUT=$OUT"
log "ARCHIVE=$archive"
log "OLD_V4_BACKUP=${V4_BACKUP} (若原目录存在；禁止删除)"
trap - EXIT INT TERM
( cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > MANIFEST.md5 )
tar -C /tmp -czf "$archive" "$(basename "$OUT")"
md5sum "$archive" > "${archive}.md5"
printf '=== T54 DONE ===\nOUT=%s\nARCHIVE=%s\n' "$OUT" "$archive" >&3
