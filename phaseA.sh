#!/bin/bash
# ============================================================
# Task 12.1 Phase A: 基线（cache=0 mu=150，无 max-readahead）
#   重现上轮 + 补采集（NIC RX/TX + juicefs stats + pidstat CPU）
#   单变量锚点：与 Phase B（+max-readahead 0）对比
# ============================================================
set -uo pipefail

MNT=/mnt/juicefs
SEQ_DIR=$MNT/seq_dir
TEST_DIR=$MNT/test_dir
META="tikv://192.168.11.12:2379/juicefs-memdisk"
OUT=/home/turboai/production/results/randread-readahead-recheck-20260709
mkdir -p $OUT
LOG=$OUT/ops.log

log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

drop_client(){ sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true; sleep 1; }
get_jfs_pid(){ pgrep -f 'juicefs.v1.3.1 mount' | head -1; }
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }

# ---- 采集：NIC + juicefs stats + pidstat CPU，同步起停 ----
# 用法: collect <tag> <runtime_sec>
collect(){
  local tag=$1 rt=$2
  local nic=$OUT/nic-$tag.txt st=$OUT/jfs-stats-$tag.txt cp=$OUT/jfs-proc-$tag.txt
  local pid; pid=$(get_jfs_pid)
  echo "[$(date '+%H:%M:%S')] 采集 $tag start (jfs_pid=$pid, rt=${rt}s)" >> "$LOG"
  # NIC sampler: 每秒记 eno1 RX(bytes col2) TX(bytes col10) + 时间戳
  ( for i in $(seq 1 $((rt+10))); do
      echo "$(date +%s) $(awk '/eno1/{print $2, $10}' /proc/net/dev)"
      sleep 1
    done ) > "$nic" 2>&1 &
  local n=$!
  # juicefs stats: 1s 间隔，count=rt+5
  juicefs stats "$MNT" -l 1 --interval 1 --count $((rt+5)) > "$st" 2>&1 &
  local s=$!
  # pidstat CPU: 每秒，跑 rt+5 秒
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

# ============================================================
log "============================================================"
log "Phase A: 基线（cache=0 mu=150，无 max-readahead）start $(date)"
log "============================================================"

# ---- 版本确认 ----
juicefs --version > "$OUT/version.txt" 2>&1
log "juicefs version: $(cat "$OUT/version.txt")"
log "mount: $(mount | grep juicefs)"
log "jfs proc: $(ps -eo pid,cmd | grep '[j]uicefs.v1.3.1 mount')"

# ---- 清理 ----
log "cleaning test dirs"
sudo rm -rf "$SEQ_DIR" "$TEST_DIR" 2>/dev/null || true
mkdir -p "$SEQ_DIR" "$TEST_DIR"

# ---- layout L_A (128x512M=64G, bs=4M) ----
log "writing layout L_A (128x512M=64G, bs=4M, end_fsync=1)"
drop_client
fio --directory="$TEST_DIR" --name=storage_test --filesize=512M --size=512M \
    --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 \
    > "$OUT/fio-A-layout.txt" 2>&1
wait_fio
lw=$(grep -oP 'WRITE: bw=\K[0-9.]+MiB/s' "$OUT/fio-A-layout.txt" | head -1)
log "layout L_A done: WRITE=${lw:-NA}"

# ---- randread r1-r3 ----
for r in 1 2 3; do
  log "A randread r$r start"
  drop_client
  collect "A-randread-r$r" 60
  fio --directory="$TEST_DIR" --name=storage_test --filesize=512M --size=512M \
      --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s \
      > "$OUT/fio-A-randread-r$r.txt" 2>&1
  stop_collect
  rd=$(grep -oP 'READ: bw=\K[0-9.]+MiB/s' "$OUT/fio-A-randread-r$r.txt" | head -1)
  log "A randread r$r done: READ=${rd:-NA}"
  sleep 5
done

# ---- randrw r1-r3 ----
for r in 1 2 3; do
  log "A randrw r$r start"
  drop_client
  collect "A-randrw-r$r" 60
  fio --directory="$TEST_DIR" --name=storage_test --filesize=512M --size=512M \
      --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s \
      > "$OUT/fio-A-randrw-r$r.txt" 2>&1
  stop_collect
  rrd=$(grep -oP 'READ: bw=\K[0-9.]+MiB/s' "$OUT/fio-A-randrw-r$r.txt" | head -1)
  rwr=$(grep -oP 'WRITE: bw=\K[0-9.]+MiB/s' "$OUT/fio-A-randrw-r$r.txt" | head -1)
  log "A randrw r$r done: READ=${rrd:-NA} WRITE=${rwr:-NA}"
  sleep 5
done

# ---- seqread (4G, refill_buffers, 1 job) ----
log "A seqread prep (write 4G)"
drop_client
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=4G \
    > "$OUT/fio-A-seqread-prep.txt" 2>&1
wait_fio
log "A seqread start"
drop_client
collect "A-seqread" 45
fio --name=seqread --directory="$SEQ_DIR" --rw=read --refill_buffers --bs=256K --size=4G \
    > "$OUT/fio-A-seqread.txt" 2>&1
stop_collect
sr=$(grep -oP 'READ: bw=\K[0-9.]+MiB/s' "$OUT/fio-A-seqread.txt" | head -1)
log "A seqread done: READ=${sr:-NA}"

log "============================================================"
log "Phase A COMPLETE $(date)"
log "============================================================"
