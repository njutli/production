#!/bin/bash
# ============================================================
# Task 12.1 Phase B: 变体（cache=0 mu=150 + max-readahead 0）
#   单变量：仅比 Phase A 多 --max-readahead 0
# ============================================================
set -uo pipefail

MNT=/mnt/juicefs
SEQ_DIR=$MNT/seq_dir
TEST_DIR=$MNT/test_dir
META="tikv://192.168.11.12:2379/juicefs-memdisk"
OUT=/home/turboai/production/results/randread-readahead-recheck-20260709
LOG=$OUT/ops.log

log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
drop_client(){ sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true; sleep 1; }
get_jfs_pid(){ pgrep -f 'juicefs.v1.3.1 mount' | head -1; }
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }

collect(){
  local tag=$1 rt=$2
  local nic=$OUT/nic-$tag.txt st=$OUT/jfs-stats-$tag.txt cp=$OUT/jfs-proc-$tag.txt
  local pid; pid=$(get_jfs_pid)
  echo "[$(date '+%H:%M:%S')] 采集 $tag start (jfs_pid=$pid, rt=${rt}s)" >> "$LOG"
  ( for i in $(seq 1 $((rt+10))); do
      echo "$(date +%s) $(awk '/eno1/{print $2, $10}' /proc/net/dev)"
      sleep 1
    done ) > "$nic" 2>&1 &
  local n=$!
  juicefs stats "$MNT" -l 1 --interval 1 --count $((rt+5)) > "$st" 2>&1 &
  local s=$!
  pidstat -p "$pid" 1 $((rt+5)) > "$cp" 2>&1 &
  local c=$!
  echo "$n $s $c" > "$OUT/.collect-pids"
}
stop_collect(){
  local pids; pids=$(cat "$OUT/.collect-pids" 2>/dev/null)
  for p in $pids; do kill "$p" 2>/dev/null; done
  wait $pids 2>/dev/null
  echo "[$(date '+%H:%M:%S')] 采集 stop" >> "$LOG"
}

log "============================================================"
log "Phase B: 变体（cache=0 mu=150 + max-readahead 0）start $(date)"
log "============================================================"

# ---- remount with +max-readahead 0 ----
log "umount old mount (Phase A baseline)"
sudo juicefs umount "$MNT" 2>&1 | tee -a "$LOG" || sudo fusermount -uz "$MNT" 2>/dev/null || true
sleep 3
log "mount with --cache-size 0 --max-uploads 150 --max-readahead 0"
sudo juicefs mount -d --cache-size 0 --max-uploads 150 --max-readahead 0 \
  "$META" "$MNT" 2>&1 | tee -a "$LOG"
sleep 5
mountpoint -q "$MNT" || { log "FATAL: remount failed"; exit 1; }
log "remount OK"
log "jfs proc: $(ps -eo pid,cmd | grep '[j]uicefs.v1.3.1 mount')"
log "mount line: $(mount | grep juicefs)"

# ---- 版本再确认 ----
juicefs --version >> "$OUT/version.txt" 2>&1

# ---- 清理 ----
log "cleaning test dirs"
sudo rm -rf "$SEQ_DIR" "$TEST_DIR" 2>/dev/null || true
mkdir -p "$SEQ_DIR" "$TEST_DIR"

# ---- layout L_B (fresh 64G) ----
log "writing layout L_B (128x512M=64G, bs=4M, end_fsync=1)"
drop_client
fio --directory="$TEST_DIR" --name=storage_test --filesize=512M --size=512M \
    --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 \
    > "$OUT/fio-B-layout.txt" 2>&1
wait_fio
lw=$(grep -oP 'WRITE: bw=\K[0-9.]+MiB/s' "$OUT/fio-B-layout.txt" | head -1)
log "layout L_B done: WRITE=${lw:-NA}"

# ---- randread r1-r3 ----
for r in 1 2 3; do
  log "B randread r$r start"
  drop_client
  collect "B-randread-r$r" 60
  fio --directory="$TEST_DIR" --name=storage_test --filesize=512M --size=512M \
      --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s \
      > "$OUT/fio-B-randread-r$r.txt" 2>&1
  stop_collect
  rd=$(grep -oP 'READ: bw=\K[0-9.]+MiB/s' "$OUT/fio-B-randread-r$r.txt" | head -1)
  log "B randread r$r done: READ=${rd:-NA}"
  sleep 5
done

# ---- randrw r1-r3 ----
for r in 1 2 3; do
  log "B randrw r$r start"
  drop_client
  collect "B-randrw-r$r" 60
  fio --directory="$TEST_DIR" --name=storage_test --filesize=512M --size=512M \
      --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s \
      > "$OUT/fio-B-randrw-r$r.txt" 2>&1
  stop_collect
  rrd=$(grep -oP 'READ: bw=\K[0-9.]+MiB/s' "$OUT/fio-B-randrw-r$r.txt" | head -1)
  rwr=$(grep -oP 'WRITE: bw=\K[0-9.]+MiB/s' "$OUT/fio-B-randrw-r$r.txt" | head -1)
  log "B randrw r$r done: READ=${rrd:-NA} WRITE=${rwr:-NA}"
  sleep 5
done

# ---- seqread ----
log "B seqread prep (write 4G)"
drop_client
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=4G \
    > "$OUT/fio-B-seqread-prep.txt" 2>&1
wait_fio
log "B seqread start"
drop_client
collect "B-seqread" 45
fio --name=seqread --directory="$SEQ_DIR" --rw=read --refill_buffers --bs=256K --size=4G \
    > "$OUT/fio-B-seqread.txt" 2>&1
stop_collect
sr=$(grep -oP 'READ: bw=\K[0-9.]+MiB/s' "$OUT/fio-B-seqread.txt" | head -1)
log "B seqread done: READ=${sr:-NA}"

log "============================================================"
log "Phase B COMPLETE $(date)"
log "============================================================"
