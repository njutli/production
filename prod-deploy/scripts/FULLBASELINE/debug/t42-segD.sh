#!/usr/bin/env bash
# t42-segD.sh — 03-12 段D：TiKV/PD 服务端指标抓取（F44 归属闭环）
# 生产构建（v1.3.1 + eaf3d21f + flushfix = /tmp/juicefs-03-8）下：
#   0) 环境静置检查（meta 提交率回白天态 ≥8K/s 才继续）
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
WAIT_MIN=30; MAX_WAITS=4
EPS="10.20.1.150:2379/metrics 10.20.1.150:9090/metrics 10.20.1.150:20180/metrics 10.20.1.150:20181/metrics 10.20.1.151:20180/metrics 10.20.1.152:20180/metrics"
mkdir -p "$OUT"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }

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
        | grep -E '^(juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_read|juicefs_fuse_ops_total_write|juicefs_fuse_read_size_bytes_sum|juicefs_fuse_write_size_bytes_sum|juicefs_object_request_durations_histogram_seconds_PUT_(sum|total)|juicefs_used_buffer_size_bytes) ' \
        | awk -v t="$t" '{print t"\t"$1"\t"$2}'
      sleep 1
    done ) > "$OUT/i1-$1.tsv" &
  SAMPLER=$!
}

tikv_capture() {   # $1=tag —— 1Hz TiKV/PD 指标子集
  ( for i in $(seq 1 240); do
      echo "=== t=$i $(date '+%F %T') ===" >> "$OUT/tikv-metrics-$1.txt"
      for ep in $EPS; do
        echo "--- $ep ---" >> "$OUT/tikv-metrics-$1.txt"
        timeout 2 curl -s "http://$ep" 2>/dev/null \
          | grep -E '^(tikv_storage_engine_async_request_duration_seconds|tikv_storage_command_total|tikv_scheduler_|tikv_engine_|tikv_raftstore_|tikv_server_report_failures|grpc_server_handling_seconds|etcd_server_|pd_server_)' \
          | head -200 >> "$OUT/tikv-metrics-$1.txt"
      done
      sleep 1
    done ) &
  TIKV_PID=$!
}

# ================= 0) 环境前置 + 静置检查 =================
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

# 静置检查：60s randwrite 探针 → meta 提交率（白天态 ≥8K/s）
umount_jfs || exit 2
"$BIN" mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
mount | grep -q juice || { log "STOP 静置探针挂载失败"; exit 2; }
mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
echo "quiesce mount max_read=$mr pid=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')" | tee -a "$OUT/quiesce.log"
QUIET=0
for w in $(seq 0 $MAX_WAITS); do
  [ $w -gt 0 ] && { log "静置等待 ${WAIT_MIN}min（第 $w/$MAX_WAITS 次）..."; sleep $((WAIT_MIN*60)); }
  sample "quiesce-$w"
  fio --directory="$TD" --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite \
      --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
      --group_reporting --time_based --runtime=60 > "$OUT/fio-quiesce-$w.txt" 2>&1
  kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
  LAT=$(awk -F'\t' '$2=="juicefs_meta_ops_durations_histogram_seconds_sum"{if(!("s" in lo))lo["s"]=$3; hi["s"]=$3}
    $2=="juicefs_meta_ops_durations_histogram_seconds_total"{if(!("t" in lo))lo["t"]=$3; hi["t"]=$3}
    END{ds=hi["s"]-lo["s"]; dt=hi["t"]-lo["t"]; printf "%.0f", (dt>0)?ds/dt*1000:0}' "$OUT/i1-quiesce-$w.tsv")
  RATE=$(awk -F'\t' '$1+0==$1{if(!t0)t0=$1; t1=$1}
    $2=="juicefs_meta_ops_durations_histogram_seconds_total"{if(!("t" in lo))lo["t"]=$3; hi["t"]=$3}
    END{dt=hi["t"]-lo["t"]; win=t1-t0; printf "%.0f", (win>0)?dt/win:0}' "$OUT/i1-quiesce-$w.tsv")
  BW=$(grep -E '^\s+WRITE: bw=' "$OUT/fio-quiesce-$w.txt" | head -1 | grep -oE '[0-9.]+MiB/s' | head -1)
  echo "quiesce-$w: meta延迟=${LAT}ms meta率=${RATE}/s $BW" | tee -a "$OUT/quiesce.log"
  if [ "${RATE:-0}" -ge 8000 ] 2>/dev/null; then QUIET=1; log "✅ 静置检查通过（meta 率 ${RATE}/s ≥ 8000 白天态）"; break; fi
done
[ "$QUIET" = 1 ] || log "⚑ 静置检查 ${MAX_WAITS} 次等待后仍未达标 ⇒ 继续执行但全部数据标注'退化态'（任务书 §六.2）"

# ================= 1) 可达性 =================
log "TiKV/PD 可达性侦察..."
for ep in $EPS; do
  code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://$ep" 2>/dev/null || echo ERR)
  echo "reach $ep http=$code $(date '+%F %T')" | tee -a "$OUT/tikv-reach.log"
done

# ================= 2) 判档门（I1 直连 mseqread）=================
ok=0
for t in 1 2 3; do
  LAB="T42D"; [ $t -gt 1 ] && LAB="T42D-t${t}"
  sample "probe-$LAB"
  fio --name=mseqread --directory="$TD/mseqread/" --rw=read --refill_buffers --bs=256k \
      --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
      --time_based --runtime=180 > "$OUT/fio-probe-$LAB.txt" 2>&1
  kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
  GATELOG=$(bash "$GATE" --i1 "$OUT/i1-probe-$LAB.tsv" 2>&1 | tee -a "$OUT/probe-gate.log")
  echo "$GATELOG" | grep -q "verdict=PASS" && { ok=1; break; }
  echo "$LAB try=$t 判档 FAIL" | tee -a "$OUT/remount-retry.log"
  umount_jfs; "$BIN" mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
done
[ "$ok" = 1 ] || { log "STOP 三次判档 FAIL ⇒ 停，回报"; exit 3; }
log "gate PASS: $LAB"
P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
echo "effect pid=$P starttime_ticks=$(awk '{print $22}' /proc/$P/stat) label=$LAB" | tee -a "$OUT/quiesce.log"

# ================= 3) 效应轮（randwrite×2 打墙 + randrw×1 对照）=================
for it in randwrite randwrite randrw; do
  tag="$LAB-${it}-$(date +%H%M%S)"
  log "=== $tag（$it）==="
  sample "$tag"
  tikv_capture "$tag"
  if [ "$it" = randrw ]; then
    fio --directory="$TD" --name=rw_test --filesize=1G --size=1G --bs=256k --rw=randrw \
        --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=180 > "$OUT/fio-$tag.txt" 2>&1
  else
    fio --directory="$TD" --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite \
        --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=180 > "$OUT/fio-$tag.txt" 2>&1
  fi
  rc=$?
  kill "$TIKV_PID" 2>/dev/null; wait "$TIKV_PID" 2>/dev/null
  kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
  echo "$tag rc=$rc $(grep -E '^\s+(READ|WRITE): bw=' "$OUT/fio-$tag.txt" | head -2 | tr '\n' ' ')" \
    | tee -a "$OUT/progress.txt" "$OUT/wrapper.log"
  sleep 20
done

{ echo "=== T42 end $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
log "=== T42 WRAPPER DONE $(date) ==="