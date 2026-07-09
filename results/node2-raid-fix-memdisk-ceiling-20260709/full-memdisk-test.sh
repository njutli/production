#!/bin/bash
# Full memdisk (DATA+WAL/DB all tmpfs) — full backend capability test
# Checklist: client NIC byte differential + OSD CPU + perf delta + iostat
set -uo pipefail

RESULT_DIR=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/full-memdisk
OPS_LOG=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/ops.log
POOL=juicefs-data
PW="TurboAi@303"
FSID=073f28e0-5fe0-11f1-8ce6-7369ee2be5a1

mkdir -p $RESULT_DIR
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }
compact_all() { for osd_id in 0 1 2 3 4 5; do sudo ceph tell osd.$osd_id compact >> $OPS_LOG 2>&1 || true; done; sleep 5; }
clean_pool() { sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1; }

# Client NIC monitor (byte differential, method A from checklist)
start_nic_monitor() {
  local outfile=$1
  local runtime=$2
  ( while true; do
      ts=$(date +%s)
      tx=$(awk '/eno1:/ {print $10}' /proc/net/dev)
      echo "$ts $tx"
      sleep 1
    done ) > $outfile 2>&1 &
  echo $!
}

stop_nic_monitor() {
  local pid=$1
  kill $pid 2>/dev/null
}

# OSD CPU monitor on 3 nodes
start_cpu_monitor() {
  local runtime=$1
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@192.168.11.11 "top -b -d1 -n $((runtime+5)) 2>/dev/null | grep --line-buffered ceph-osd" > $RESULT_DIR/cpu-node1.txt 2>&1 &
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@192.168.11.13 "top -b -d1 -n $((runtime+5)) 2>/dev/null | grep --line-buffered ceph-osd" > $RESULT_DIR/cpu-node2.txt 2>&1 &
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@192.168.11.14 "top -b -d1 -n $((runtime+5)) 2>/dev/null | grep --line-buffered ceph-osd" > $RESULT_DIR/cpu-node3.txt 2>&1 &
}

# iostat monitor
start_iostat() {
  local runtime=$1
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@192.168.11.11 "iostat -x 1 $((runtime+5))" > $RESULT_DIR/iostat-node1.txt 2>&1 &
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@192.168.11.13 "iostat -x 1 $((runtime+5))" > $RESULT_DIR/iostat-node2.txt 2>&1 &
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@192.168.11.14 "iostat -x 1 $((runtime+5))" > $RESULT_DIR/iostat-node3.txt 2>&1 &
}

# Collect perf for all 6 OSDs
collect_perf() {
  local suffix=$1
  for osd_id in 0 1 2 3 4 5; do
    sudo ceph tell osd.$osd_id perf dump 2>/dev/null > $RESULT_DIR/osd${osd_id}-perf-${suffix}.txt
  done
  log "  perf $suffix collected"
}

log "=============================================="
log "Full memdisk test START (DATA+WAL/DB all tmpfs)"
log "=============================================="

# Verify client NIC field
log "=== NIC self-check ==="
grep eno1 /proc/net/dev | head -1 | tee -a $OPS_LOG

# ============================================================
# TEST 1: write 256K t64 300s ×3 (with full monitoring on r1)
# ============================================================
log "==== WRITE 256K t64 300s ×3 ===="

# Round 1 with full monitoring
log "-- r1 (full monitoring) --"
clean_pool; compact_all
collect_perf t0-r1
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
NIC_PID=$(start_nic_monitor $RESULT_DIR/client-nic-r1.txt 300)
start_cpu_monitor 300
start_iostat 300
sleep 3
log "  monitoring started"

sudo rados bench -p $POOL 300 write -b 256K -t 64 --no-cleanup 2>&1 | tee $RESULT_DIR/write-256k-t64-r1.txt
log "  r1 done"
stop_nic_monitor $NIC_PID
collect_perf tend-r1
clean_pool; compact_all

# Round 2
log "-- r2 --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo rados bench -p $POOL 300 write -b 256K -t 64 --no-cleanup 2>&1 | tee $RESULT_DIR/write-256k-t64-r2.txt
clean_pool; compact_all

# Round 3
log "-- r3 --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo rados bench -p $POOL 300 write -b 256K -t 64 --no-cleanup 2>&1 | tee $RESULT_DIR/write-256k-t64-r3.txt
clean_pool; compact_all

# ============================================================
# TEST 2: Concurrency scan t16/t128
# ============================================================
log "==== CONCURRENCY SCAN ===="
for t in 16 128; do
  log "-- t${t} --"
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  sudo rados bench -p $POOL 300 write -b 256K -t $t --no-cleanup 2>&1 | tee $RESULT_DIR/conc-256k-t${t}.txt
  clean_pool; compact_all
done

# ============================================================
# TEST 3: Block size matrix 4K/64K/1M/4M ×3
# ============================================================
log "==== BLOCK SIZE MATRIX ===="
for bs in 4K 64K 1M 4M; do
  for r in 1 2 3; do
    log "-- write ${bs} r${r} --"
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sudo rados bench -p $POOL 120 write -b $bs -t 64 --no-cleanup 2>&1 | tee $RESULT_DIR/bs-write-${bs}-r${r}.txt
    clean_pool; compact_all
  done
done

# ============================================================
# TEST 4: Read tests seq/rand 256K ×3
# ============================================================
log "==== READ TESTS ===="
for r in 1 2 3; do
  log "-- seq read r${r} --"
  if [ $r -eq 1 ]; then
    clean_pool; compact_all; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sudo rados bench -p $POOL 600 write -b 256K -t 16 --no-cleanup >> $OPS_LOG 2>&1
  else
    compact_all; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  fi
  sudo rados bench -p $POOL 300 seq -t 64 2>&1 | tee $RESULT_DIR/seq-read-256k-r${r}.txt
done
clean_pool; compact_all

for r in 1 2 3; do
  log "-- rand read r${r} --"
  if [ $r -eq 1 ]; then
    clean_pool; compact_all; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sudo rados bench -p $POOL 120 write -b 256K -t 16 --no-cleanup >> $OPS_LOG 2>&1
  else
    compact_all; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  fi
  sudo rados bench -p $POOL 300 rand -t 64 2>&1 | tee $RESULT_DIR/rand-read-256k-r${r}.txt
done
clean_pool; compact_all

log "=============================================="
log "Full memdisk test COMPLETE"
log "=============================================="
