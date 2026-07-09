#!/bin/bash
# Full backend capability test with all 6 OSDs on tmpfs DB
# Tests: concurrency scan + block size matrix + read tests
set -uo pipefail

RESULT_DIR=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/memdisk-ceiling
OPS_LOG=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/ops.log
POOL=juicefs-data
PW="TurboAi@303"

mkdir -p $RESULT_DIR
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }
compact_all() { for osd_id in 0 1 2 3 4 5; do sudo ceph tell osd.$osd_id compact >> $OPS_LOG 2>&1 || true; done; sleep 10; }
clean_pool() { sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1; }

log "=============================================="
log "Full backend capability test (tmpfs DB) START"
log "=============================================="

# ============================================================
# TEST 1: Concurrency scan (t16/t128, 300s each, 1 round)
# t64 already have from write test
# ============================================================
log "==== CONCURRENCY SCAN ===="
for t in 16 128; do
  log "-- t${t} --"
  clean_pool; compact_all
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  sudo rados bench -p $POOL 300 write -b 256K -t $t --no-cleanup 2>&1 | tee $RESULT_DIR/conc-256k-t${t}.txt
  clean_pool; compact_all
done

# ============================================================
# TEST 2: Block size matrix (4K/64K/1M/4M write, 120s ×3)
# 256K already have from write test
# ============================================================
log "==== BLOCK SIZE MATRIX ===="
for bs in 4K 64K 1M 4M; do
  log "-- write ${bs} --"
  for r in 1 2 3; do
    clean_pool; compact_all
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sudo rados bench -p $POOL 120 write -b $bs -t 64 --no-cleanup 2>&1 | tee $RESULT_DIR/bs-write-${bs}-r${r}.txt
    clean_pool; compact_all
  done
done

# ============================================================
# TEST 3: Read tests (seq + rand, 256K, 300s ×3)
# ============================================================
log "==== READ TESTS ===="

# Sequential read
for r in 1 2 3; do
  log "-- seq read r${r} --"
  if [ $r -eq 1 ]; then
    clean_pool; compact_all; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    log "  prefilling 600s..."
    sudo rados bench -p $POOL 600 write -b 256K -t 16 --no-cleanup >> $OPS_LOG 2>&1
  else
    compact_all; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  fi
  sudo rados bench -p $POOL 300 seq -t 64 2>&1 | tee $RESULT_DIR/seq-read-256k-r${r}.txt
done
clean_pool; compact_all

# Random read
for r in 1 2 3; do
  log "-- rand read r${r} --"
  if [ $r -eq 1 ]; then
    clean_pool; compact_all; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    log "  prefilling 120s..."
    sudo rados bench -p $POOL 120 write -b 256K -t 16 --no-cleanup >> $OPS_LOG 2>&1
  else
    compact_all; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  fi
  sudo rados bench -p $POOL 300 rand -t 64 2>&1 | tee $RESULT_DIR/rand-read-256k-r${r}.txt
done
clean_pool; compact_all

log "=============================================="
log "Full backend capability test COMPLETE"
log "=============================================="
