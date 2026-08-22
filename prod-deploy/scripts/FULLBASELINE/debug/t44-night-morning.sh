#!/usr/bin/env bash
# t44-night-morning.sh — 03-14：段A 读写共享性（今晚）+ 段B seqread 转正 3 实例（明早日间窗口）
# 段A（RUN_A=1）：/tmp/juicefs-03-8（v1.3.1+eaf3d21f+flushfix）256K 挂载，randread+randwrite 并行
#   预登记：A2a 独立（读≈[3906,4219] 且写≈[2817,3397]，合计≈7 GiB/s）｜A2b 共享（合计≈4.1）｜A2c 部分共享
# 段B（RUN_B=1）：stock 128K 默认挂载（与签收基线同口径），3 实例 ×（判档门 + seqread 2 轮）
#   判据：3 实例中位与 week3 平台 [1234,1324] 对照（计划书 §3.4 转正条件：≥3 实例含日间窗口）
set -uo pipefail
OUT=/tmp/opencode-t3.14
GATE=/tmp/t39-nsbgate.sh
SNAP=/tmp/env-snapshot.sh
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
TD=/mnt/juicefs/test_dir
RUN_A="${RUN_A:-1}"; RUN_B="${RUN_B:-1}"
mkdir -p "$OUT" "$OUT/bwlog"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }
[ -f "$SNAP" ] || { log "STOP 缺 $SNAP（先 scp scripts/FULLBASELINE/probe/env-snapshot.sh）"; exit 2; }

umount_jfs() {
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { log "STOP umount 失败"; return 2; }
  return 0
}

gate_i1() {   # $1=label（I1 直连 mseqread 探针）→ 0=过
  local lab="$1"
  ( printf 'ts\tkey\tvalue\n'
    while :; do t=$(date +%s); timeout 3 cat /mnt/juicefs/.stats 2>/dev/null \
      | grep -E '^(juicefs_fuse_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_read_size_bytes_sum|juicefs_fuse_ops_total_read) ' \
      | awk -v t="$t" '{print t"\t"$1"\t"$2}'; sleep 1; done ) > "$OUT/i1-probe-$lab.tsv" &
  SAMP=$!
  fio --name=mseqread --directory="$TD/mseqread/" --rw=read --refill_buffers --bs=256k \
      --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
      --time_based --runtime=180 --write_bw_log="$OUT/bwlog/probe-$lab" --log_avg_msec=1000 \
      > "$OUT/fio-probe-$lab.txt" 2>&1
  kill "$SAMP" 2>/dev/null; wait "$SAMP" 2>/dev/null
  bash "$GATE" --i1 "$OUT/i1-probe-$lab.tsv" 2>&1 | tee -a "$OUT/probe-gate.log" | grep -q "verdict=PASS"
}

# ================= 段A：读写共享性（今晚）=================
if [ "$RUN_A" = "1" ]; then
  log "=== 段A 读写共享性（/tmp/juicefs-03-8 + 256K）==="
  BIN=/tmp/juicefs-03-8
  OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
  ok=0
  for t in 1 2 3; do
    LAB="T44A"; [ $t -gt 1 ] && LAB="T44A-t${t}"
    umount_jfs || continue
    "$BIN" mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
    mount | grep -q juice || { log "$LAB mount failed"; continue; }
    mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
    [ "${mr:-0}" = "262144" ] || { log "$LAB max_read=$mr FAIL"; continue; }
    q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
    echo "$LAB bin=$BIN max_read=$mr pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" | tee -a "$OUT/instances.txt"
    gate_i1 "$LAB" && { ok=1; break; }
    echo "$LAB try=$t 判档 FAIL ⇒ remount" | tee -a "$OUT/remount-retry.log"
  done
  [ "$ok" = 1 ] || { log "STOP 段A 三次判档 FAIL"; exit 3; }
  log "段A gate PASS: $LAB"
  # 快照必须在已过门的候选挂载生效后采，才能证明真正的效应实例配置。
  bash "$SNAP" "$OUT" "segA-pre" "$META"
  tag="$LAB-rwcon"
  ( printf 'ts\tkey\tvalue\n'
    while :; do t=$(date +%s); timeout 3 cat /mnt/juicefs/.stats 2>/dev/null \
      | grep -E '^(juicefs_fuse_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_(read|write)|juicefs_fuse_(read|write)_size_bytes_sum|juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_object_request_durations_histogram_seconds_(GET|PUT)_(sum|total)|juicefs_object_request_data_bytes_(GET|PUT)|juicefs_used_(read_)?buffer_size_bytes) ' \
      | awk -v t="$t" '{print t"\t"$1"\t"$2}'; sleep 1; done ) > "$OUT/i1-$tag.tsv" &
  SAMP=$!
  fio --directory="$TD" --name=read_test --filesize=1G --size=1G --bs=256k --rw=randread \
      --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
      --readonly --group_reporting --time_based --runtime=180 \
      --write_bw_log="$OUT/bwlog/$tag-read" --log_avg_msec=1000 > "$OUT/fio-$tag-read.txt" 2>&1 &
  FR=$!
  fio --directory="$TD" --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite \
      --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
      --group_reporting --time_based --runtime=180 \
      --write_bw_log="$OUT/bwlog/$tag-write" --log_avg_msec=1000 > "$OUT/fio-$tag-write.txt" 2>&1 &
  FW=$!
  wait "$FR"; rc1=$?; wait "$FW"; rc2=$?
  kill "$SAMP" 2>/dev/null; wait "$SAMP" 2>/dev/null
  printf '%s\trc_read=%s\trc_write=%s\t%s\t%s\n' "$tag" "$rc1" "$rc2" \
    "$(grep -E '^\s+READ: bw=' "$OUT/fio-$tag-read.txt" | head -1 | grep -oE '[0-9.]+MiB/s' | head -1)" \
    "$(grep -E '^\s+WRITE: bw=' "$OUT/fio-$tag-write.txt" | head -1 | grep -oE '[0-9.]+MiB/s' | head -1)" \
    | tee -a "$OUT/summary.tsv" "$OUT/wrapper.log"
  bash "$SNAP" "$OUT" "segA-post" "$META"
  umount_jfs
fi

# ================= 段B：seqread 转正 3 实例（明早日间窗口）=================
if [ "$RUN_B" = "1" ]; then
  log "=== 段B seqread 转正（stock 128K，3 实例，日间窗口）==="
  OPTS="--max-uploads 150 --cache-size 0"
  for idx in 1 2 3; do
    LAB="T44B-$idx"
    ok=0
    for t in 1 2 3; do
      LTRY="$LAB"; [ $t -gt 1 ] && LTRY="${LAB}-t${t}"
      umount_jfs || continue
      juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
      mount | grep -q juice || { log "$LTRY mount failed"; continue; }
      mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
      [ "${mr:-0}" = "131072" ] || { log "$LTRY max_read=$mr FAIL"; continue; }
      q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
      echo "$LTRY bin=stock max_read=$mr pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" | tee -a "$OUT/instances.txt"
      gate_i1 "$LTRY" && { ok=1; LAB="$LTRY"; break; }
      echo "$LTRY try=$t 判档 FAIL ⇒ remount" | tee -a "$OUT/remount-retry.log"
    done
    [ "$ok" = 1 ] || { log "STOP 段B $LAB 三次判档 FAIL"; exit 3; }
    [ "$idx" = 1 ] && bash "$SNAP" "$OUT" "segB-pre" "$META"
    for r in 1 2; do
      tag="$LAB-r$r"
      ( printf 'ts\tkey\tvalue\n'
        while :; do t=$(date +%s); timeout 3 cat /mnt/juicefs/.stats 2>/dev/null \
          | grep -E '^(juicefs_fuse_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_(read|write)|juicefs_fuse_(read|write)_size_bytes_sum|juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_object_request_durations_histogram_seconds_(GET|PUT)_(sum|total)|juicefs_object_request_data_bytes_(GET|PUT)|juicefs_used_(read_)?buffer_size_bytes) ' \
          | awk -v t="$t" '{print t"\t"$1"\t"$2}'; sleep 1; done ) > "$OUT/i1-$tag.tsv" &
      SAMP=$!
      fio --name=seqread --directory="$TD/seqread/" --rw=read --refill_buffers --bs=256k \
          --size=32G --direct=1 --ioengine=psync --iodepth=1 \
          --time_based --runtime=180 \
          --write_bw_log="$OUT/bwlog/$tag" --log_avg_msec=1000 > "$OUT/fio-$tag.txt" 2>&1
      rc=$?
      kill "$SAMP" 2>/dev/null; wait "$SAMP" 2>/dev/null
      printf '%s\t%s\trc=%s\t%s\n' "$LAB" "r$r" "$rc" \
        "$(grep -E '^\s+READ: bw=' "$OUT/fio-$tag.txt" | head -1 | grep -oE '[0-9.]+MiB/s' | head -1)" \
        | tee -a "$OUT/summary.tsv" "$OUT/wrapper.log"
    done
    [ "$idx" = 3 ] && bash "$SNAP" "$OUT" "segB-post" "$META"
    umount_jfs
  done
fi

# 收尾：恢复 128K
umount_jfs
juicefs mount -d --max-uploads 150 --cache-size 0 "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1
sleep 5
mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
echo "RESTORED max_read=$mr want=131072" | tee -a "$OUT/progress.txt"
{ echo "=== T44 end $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; } >> "$OUT/health.txt"
log "=== T44 DONE $(date) ==="
