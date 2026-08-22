#!/usr/bin/env bash
# t42-segD.sh — 03-12 段D：TiKV/PD 服务端指标抓取（F44 归属闭环）
# 生产构建（v1.3.1 + eaf3d21f + flushfix = /tmp/juicefs-03-8）下：
#   0) 只读环境/对象数前置（取消会污染状态的 randwrite “静置探针”）
#   1) TiKV/PD metrics 端点可达性
#   2) ns/B 判档门（I1 直连探针）
#   3) randwrite（打 meta 墙）× 2 轮 + randrw（不打墙，对照）× 1 轮，各配 1Hz TiKV/PD 抓取 + I1
# 判据见任务书 §三；🔴 统计与归属分析由 DeepSeek/分析侧做，本脚本只采集。
set -uo pipefail
OUT=/tmp/opencode-t3.12
GATE=/tmp/t39-nsbgate.sh
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
TD=/mnt/juicefs/test_dir
BIN=/tmp/juicefs-03-8
OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
OBJ_START_MAX=3110000
TIKV_EPS="10.20.1.150:20180/metrics 10.20.1.151:20180/metrics 10.20.1.152:20180/metrics"
PD_EPS="10.20.1.150:2379/metrics 10.20.1.151:2379/metrics 10.20.1.152:2379/metrics"
TIKV_RE='^(tikv_storage_engine_async_request_duration_seconds_(sum|count)|tikv_storage_command_total|tikv_engine_cache_efficiency|tikv_scheduler_(command|latch_wait|processing_read)_duration_seconds_(sum|count)|tikv_raftstore_(append|commit|apply)_log_duration_seconds_(sum|count)|tikv_raftstore_apply_wait_time_duration_seconds_(sum|count)|tikv_engine_pending_compaction_bytes)(\{|[[:space:]])'
PD_RE='^(pd_server_tso_handle_duration_seconds_(sum|count)|pd_scheduler_[A-Za-z0-9_:]+|etcd_server_has_leader|etcd_server_leader_changes_seen_total|grpc_server_handling_seconds_(sum|count))(\{|[[:space:]])'
mkdir -p "$OUT" "$OUT/bwlog" "$OUT/metrics-full"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }

proc_starttime() {
  awk '{line=$0; sub(/^[0-9]+ \(/,"",line); if (!match(line,/\) [^)]*$/)) exit 1;
        rest=substr(line,RSTART+2); n=split(rest,f,/[[:space:]]+/); if(n<20) exit 1; print f[20]}' \
      "/proc/$1/stat" 2>/dev/null
}

umount_jfs() {
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { "$BIN" umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { log "STOP umount 失败"; return 2; }
  return 0
}

sample() {   # $1=tag —— 1Hz I1 子集（meta 延迟/率 + FUSE 读/写 + PUT + buffer）
  ( printf 'ts\tkey\tvalue\n'
    while :; do
      t=$(date +%s)
      timeout 3 cat /mnt/juicefs/.stats 2>/dev/null \
        | grep -E '^(juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_(read|write)|juicefs_fuse_(read|write)_size_bytes_sum|juicefs_object_request_durations_histogram_seconds_(GET|PUT)_(sum|total)|juicefs_object_request_data_bytes_(GET|PUT)|juicefs_object_request_uploading|juicefs_process_cpu_seconds_total|juicefs_used_(read_)?buffer_size_bytes|juicefs_staging_blocks|juicefs_fuse_open_handlers) ' \
        | awk -v t="$t" '{print t"\t"$1"\t"$2}'
      sleep 1
    done ) > "$OUT/i1-$1.tsv" &
  SAMPLER=$!
}

metric_safe_name() { printf '%s' "$1" | tr '/:' '__'; }

validate_tikv_snapshot() { # $1=完整 exposition 文件 $2=endpoint；严格校验关键族
  local f="$1" ep="$2" base plain s c sf cf total
  total=$(grep -Ec "$TIKV_RE" "$f" || true)
  printf 'snapshot\t%s\tFILTERED_TOTAL\t%s\tNA\n' "$ep" "$total" >> "$OUT/metrics-manifest.tsv"
  [ "$total" -gt 0 ] || { log "STOP TiKV $ep 精确过滤结果为空"; return 1; }
  if [ "$total" -lt 600 ] || [ "$total" -gt 3000 ]; then
    log "WARN TiKV $ep 精确过滤行数=$total 不在经验区间[600,3000]；保留全量、不截断"
  fi
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
    [ "$s" -gt 0 ] && [ "$c" -gt 0 ] || {
      log "STOP TiKV $ep 缺 histogram pair: $base sum=$s count=$c"; return 1;
    }
    sf="${f}.sumlabels"; cf="${f}.countlabels"
    grep -E "^${base}_sum(\\{|[[:space:]])" "$f" \
      | sed -E "s/^${base}_sum//; s/[[:space:]][^[:space:]]+$//" | sort > "$sf"
    grep -E "^${base}_count(\\{|[[:space:]])" "$f" \
      | sed -E "s/^${base}_count//; s/[[:space:]][^[:space:]]+$//" | sort > "$cf"
    cmp -s "$sf" "$cf" || {
      log "STOP TiKV $ep histogram labels 不配对: $base"; return 1;
    }
  done
  for plain in tikv_storage_command_total tikv_engine_cache_efficiency tikv_engine_pending_compaction_bytes; do
    c=$(grep -Ec "^${plain}(\\{|[[:space:]])" "$f" || true)
    printf 'snapshot\t%s\t%s\t%s\tNA\n' "$ep" "$plain" "$c" >> "$OUT/metrics-manifest.tsv"
    [ "$c" -gt 0 ] || {
      log "STOP TiKV $ep 缺 plain metric: $plain"; return 1;
    }
  done
  return 0
}

capture_full_metrics() { # $1=tag；完整原文 gzip，TiKV/PD 分端点保存
  local tag="$1" ep safe tmp
  for ep in $TIKV_EPS; do
    safe=$(metric_safe_name "$ep"); tmp=$(mktemp "$OUT/metrics-full/.tikv.XXXXXX") || return 1
    timeout 10 curl -fsS --max-time 8 "http://$ep" > "$tmp" 2>> "$OUT/metrics-errors.log" || {
      log "STOP TiKV endpoint 不可读: $ep"; rm -f "$tmp"; return 1;
    }
    validate_tikv_snapshot "$tmp" "$ep" || { rm -f "$tmp" "${tmp}.sumlabels" "${tmp}.countlabels"; return 1; }
    gzip -c "$tmp" > "$OUT/metrics-full/tikv-${safe}-${tag}.prom.gz"
    rm -f "$tmp" "${tmp}.sumlabels" "${tmp}.countlabels"
  done
  for ep in $PD_EPS; do
    safe=$(metric_safe_name "$ep"); tmp=$(mktemp "$OUT/metrics-full/.pd.XXXXXX") || return 1
    timeout 10 curl -fsS --max-time 8 "http://$ep" > "$tmp" 2>> "$OUT/metrics-errors.log" || {
      log "STOP PD endpoint 不可读: $ep"; rm -f "$tmp"; return 1;
    }
    gzip -c "$tmp" > "$OUT/metrics-full/pd-${safe}-${tag}.prom.gz"
    rm -f "$tmp"
  done
}

tikv_capture() {   # $1=tag —— 1Hz 精确 TiKV 子集；PD 单独落盘，绝不 head 截断
  local tag="$1"
  capture_full_metrics "$tag-pre" || return 1
  ( for i in $(seq 1 240); do
      for ep in $TIKV_EPS; do
        printf '=== t=%s ts=%s endpoint=%s ===\n' "$i" "$(date +%s)" "$ep" >> "$OUT/tikv-metrics-$tag.txt"
        timeout 5 curl -fsS --max-time 3 "http://$ep" 2>> "$OUT/metrics-errors.log" \
          | grep -E "$TIKV_RE" >> "$OUT/tikv-metrics-$tag.txt" || true
      done
      for ep in $PD_EPS; do
        printf '=== t=%s ts=%s endpoint=%s ===\n' "$i" "$(date +%s)" "$ep" >> "$OUT/pd-metrics-$tag.txt"
        timeout 5 curl -fsS --max-time 3 "http://$ep" 2>> "$OUT/metrics-errors.log" \
          | grep -E "$PD_RE" >> "$OUT/pd-metrics-$tag.txt" || true
      done
      sleep 1
    done ) &
  TIKV_PID=$!
}

manifest_filtered_capture() { # $1=tag；采样结束后记录每族实际行数，不作为裁剪条件
  local tag="$1" base n
  for base in \
    tikv_storage_engine_async_request_duration_seconds \
    tikv_storage_command_total tikv_engine_cache_efficiency \
    tikv_scheduler_command_duration_seconds tikv_scheduler_latch_wait_duration_seconds \
    tikv_scheduler_processing_read_duration_seconds tikv_raftstore_append_log_duration_seconds \
    tikv_raftstore_commit_log_duration_seconds tikv_raftstore_apply_log_duration_seconds \
    tikv_engine_pending_compaction_bytes; do
    n=$(grep -Ec "^${base}(_(sum|count))?(\\{|[[:space:]])" "$OUT/tikv-metrics-$tag.txt" || true)
    printf 'sample\t%s\t%s\t%s\tNA\n' "$tag" "$base" "$n" >> "$OUT/metrics-manifest.tsv"
  done
}

# ================= 0) 环境前置（只读；首个健康 randwrite 才是状态测量）=================
printf 'scope\tendpoint_or_tag\tmetric\tsum_or_rows\tcount\n' > "$OUT/metrics-manifest.tsv"
H=$(sudo ceph health 2>&1 | head -1)
echo "ceph_health_start: $H $(date '+%F %T')" | tee -a "$OUT/health.txt"
echo "$H" | grep -q HEALTH_OK || { log "STOP health 非 OK"; exit 2; }
log "compact cooldown（前置）..."
for osd in $(sudo ceph osd ls 2>/dev/null); do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
for i in $(seq 1 60); do
  all_done=1
  for osd in $(sudo ceph osd ls 2>/dev/null); do
    read -r running queued < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c \
      'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "1 1")
    { [ "$running" != "0" ] || [ "$queued" != "0" ]; } && all_done=0
  done
  $all_done && { log "  compact ✅ (~$((i*5))s)"; break; }
  sleep 5
done
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true

# 旧版在正式实验前跑 60s randwrite 判“静置”，它本身会新增对象/元数据并污染状态。
# 修订后前置只挂载、记对象数和验证指标；第一轮正式 randwrite 同时承担状态测量。
umount_jfs || exit 2
"$BIN" mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
mount | grep -q juice || { log "STOP 候选挂载失败"; exit 2; }
mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
echo "state mount max_read=$mr pid=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')" | tee -a "$OUT/quiesce.log"
OBJ=$(sudo ceph df --format=json 2>/dev/null | python3 -c \
  "import json,sys; p=[x for x in json.load(sys.stdin)['pools'] if x['name']=='juicefs-data'][0]['stats']; print(p['objects'])" \
  2>/dev/null || true)
echo "objects=${OBJ:-NA}" >> "$OUT/quiesce.log"
[[ "${OBJ:-}" =~ ^[0-9]+$ ]] && [ "$OBJ" -le "$OBJ_START_MAX" ] || {
  log "STOP 起点 objects=${OBJ:-NA} > $OBJ_START_MAX 或不可解析；禁止自动 gc"; exit 5;
}

# ================= 1) 可达性 =================
log "TiKV/PD 可达性侦察..."
for ep in $TIKV_EPS $PD_EPS; do
  code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://$ep" 2>/dev/null || echo ERR)
  echo "reach $ep http=$code $(date '+%F %T')" | tee -a "$OUT/tikv-reach.log"
done
capture_full_metrics "preflight" || { log "STOP 指标 preflight/manifest 校验失败"; exit 4; }

# ================= 2) 判档门（I1 直连 mseqread）=================
ok=0
for t in 1 2 3; do
  LAB="T42D"; [ $t -gt 1 ] && LAB="T42D-t${t}"
  sample "probe-$LAB"
  fio --name=mseqread --directory="$TD/mseqread/" --rw=read --refill_buffers --bs=256k \
      --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
      --time_based --runtime=180 --write_bw_log="$OUT/bwlog/probe-$LAB" --log_avg_msec=1000 \
      > "$OUT/fio-probe-$LAB.txt" 2>&1
  kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
  GATELOG=$(bash "$GATE" --i1 "$OUT/i1-probe-$LAB.tsv" 2>&1 | tee -a "$OUT/probe-gate.log")
  echo "$GATELOG" | grep -q "verdict=PASS" && { ok=1; break; }
  echo "$LAB try=$t 判档 FAIL" | tee -a "$OUT/remount-retry.log"
  umount_jfs; "$BIN" mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
done
[ "$ok" = 1 ] || { log "STOP 三次判档 FAIL ⇒ 停，回报"; exit 3; }
log "gate PASS: $LAB"
P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
PSTART=$(proc_starttime "$P")
echo "effect pid=$P starttime_ticks=$PSTART label=$LAB" | tee -a "$OUT/quiesce.log"

# ================= 3) 效应轮（randwrite×2 打墙 + randrw×1 对照）=================
for it in randwrite randwrite randrw; do
  tag="$LAB-${it}-$(date +%H%M%S)"
  log "=== $tag（$it）==="
  NOWP=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  NOWS=$(proc_starttime "$NOWP")
  [ "$NOWP" = "$P" ] && [ "$NOWS" = "$PSTART" ] || {
    log "STOP mount 实例漂移 got=$NOWP/$NOWS want=$P/$PSTART"; exit 8;
  }
  sample "$tag"
  tikv_capture "$tag" || { kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null; exit 4; }
  if [ "$it" = randrw ]; then
    fio --directory="$TD" --name=rw_test --filesize=1G --size=1G --bs=256k --rw=randrw \
        --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="$OUT/bwlog/$tag" --log_avg_msec=1000 > "$OUT/fio-$tag.txt" 2>&1
  else
    fio --directory="$TD" --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite \
        --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="$OUT/bwlog/$tag" --log_avg_msec=1000 > "$OUT/fio-$tag.txt" 2>&1
  fi
  rc=$?
  kill "$TIKV_PID" 2>/dev/null; wait "$TIKV_PID" 2>/dev/null
  manifest_filtered_capture "$tag"
  kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
  capture_full_metrics "$tag-post" || { log "STOP $tag post metrics/manifest 失败（本轮不得判读）"; exit 4; }
  echo "$tag rc=$rc $(grep -E '^\s+(READ|WRITE): bw=' "$OUT/fio-$tag.txt" | head -2 | tr '\n' ' ')" \
    | tee -a "$OUT/progress.txt" "$OUT/wrapper.log"
  sleep 20
done

{ echo "=== T42 end $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
log "=== T42 WRAPPER DONE $(date) ==="
