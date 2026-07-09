#!/bin/bash
# Stage F test: write 256K t64 300s ×3 + full monitoring
# Key question: with all 6 OSDs on tmpfs DB, can steady-state write pass 59?
set -uo pipefail

RESULT_DIR=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/memdisk-ceiling
OPS_LOG=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/ops.log
POOL=juicefs-data
BS=256K
DURATION=300
CONCURRENCY=64
PW="TurboAi@303"

mkdir -p $RESULT_DIR

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }
compact_all() { for osd_id in 0 1 2 3 4 5; do sudo ceph tell osd.$osd_id compact >> $OPS_LOG 2>&1 || true; done; sleep 10; }
clean_pool() { sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1; }
health_check() { local s=$(sudo ceph health 2>/dev/null); log "  health: $s"; }

log "=============================================="
log "Stage F test: write 256K t64 300s ×3 START"
log "All 6 OSDs on tmpfs DB (BlueFS spillover expected)"
log "=============================================="

# Collect perf t0 for all 6 OSDs
log "=== Collecting perf t0 ==="
for osd_id in 0 1 2 3 4 5; do
  sudo ceph tell osd.$osd_id perf dump 2>/dev/null > $RESULT_DIR/osd${osd_id}-perf-t0.txt
  log "  osd.$osd_id t0 saved"
done

# Round 1: with full monitoring (NIC + iostat)
log "==== Round 1 (with full monitoring) ===="
clean_pool; compact_all; health_check
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

# Start monitoring
sar -n DEV 1 310 > $RESULT_DIR/client-nic-r1.txt 2>&1 &
sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@192.168.11.11 "iostat -x 1 310 > /tmp/ceph11-iostat-r1.txt 2>&1 &" 2>/dev/null
sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@192.168.11.13 "iostat -x 1 310 > /tmp/ceph13-iostat-r1.txt 2>&1 &" 2>/dev/null
sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@192.168.11.14 "iostat -x 1 310 > /tmp/ceph14-iostat-r1.txt 2>&1 &" 2>/dev/null
log "  monitoring started"
sleep 3

log "  START rados bench r1"
sudo rados bench -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup 2>&1 | tee $RESULT_DIR/write-256k-t64-r1.txt
log "  END rados bench r1"

# Collect perf tend for round 1
for osd_id in 0 1 2 3 4 5; do
  sudo ceph tell osd.$osd_id perf dump 2>/dev/null > $RESULT_DIR/osd${osd_id}-perf-tend-r1.txt
done
log "  perf tend r1 saved"

# Collect iostat
sleep 5
sshpass -p "$PW" scp -o StrictHostKeyChecking=no turboai@192.168.11.11:/tmp/ceph11-iostat-r1.txt $RESULT_DIR/ceph11-iostat-r1.txt 2>/dev/null
sshpass -p "$PW" scp -o StrictHostKeyChecking=no turboai@192.168.11.13:/tmp/ceph13-iostat-r1.txt $RESULT_DIR/ceph13-iostat-r1.txt 2>/dev/null
sshpass -p "$PW" scp -o StrictHostKeyChecking=no turboai@192.168.11.14:/tmp/ceph14-iostat-r1.txt $RESULT_DIR/ceph14-iostat-r1.txt 2>/dev/null
log "  iostat r1 collected"

clean_pool; compact_all

# Round 2
log "==== Round 2 ===="
health_check
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
log "  START rados bench r2"
sudo rados bench -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup 2>&1 | tee $RESULT_DIR/write-256k-t64-r2.txt
log "  END rados bench r2"
clean_pool; compact_all

# Round 3
log "==== Round 3 ===="
health_check
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
log "  START rados bench r3"
sudo rados bench -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup 2>&1 | tee $RESULT_DIR/write-256k-t64-r3.txt
log "  END rados bench r3"
clean_pool; compact_all

# Final perf tend
for osd_id in 0 1 2 3 4 5; do
  sudo ceph tell osd.$osd_id perf dump 2>/dev/null > $RESULT_DIR/osd${osd_id}-perf-tend-final.txt
done
log "perf tend final saved"

log "=============================================="
log "Stage F write test COMPLETE"
log "=============================================="
