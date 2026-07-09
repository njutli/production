#!/bin/bash
# Stage C retest: osd.2 with tmpfs DB — 120s rados bench + perf/iostat
set -uo pipefail

RESULT_DIR=/home/turboai/production/results/node2-raid-forensics-20260709/memdisk-bypass
OPS_LOG=/home/turboai/production/results/node2-raid-forensics-20260709/ops.log
POOL=juicefs-data
DURATION=120
CONCURRENCY=64
BS=256K

mkdir -p $RESULT_DIR

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }

log "=== Stage C retest START (osd.2 with tmpfs DB) ==="

# Cleanup + compact
sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1
for osd_id in 0 1 2 3 4 5; do sudo ceph tell osd.$osd_id compact >> $OPS_LOG 2>&1 || true; done
sleep 10
log "Cleanup + compact done."

# perf t0
sudo ceph tell osd.2 perf dump 2>/dev/null > $RESULT_DIR/osd2-perf-t0.txt
log "perf t0 saved ($(wc -c < $RESULT_DIR/osd2-perf-t0.txt) bytes)"

# Start iostat on node2
sshpass -p 'TurboAi@303' ssh -o StrictHostKeyChecking=no turboai@192.168.11.13 \
    "iostat -x 1 $((DURATION+10)) > /tmp/node2-iostat-memdisk.txt 2>&1 &"
log "iostat started on node2"

# rados bench
log "START rados bench ${DURATION}s"
sudo rados bench -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup 2>&1 | tee $RESULT_DIR/rados-${DURATION}s.txt
log "END rados bench"

# perf tend
sudo ceph tell osd.2 perf dump 2>/dev/null > $RESULT_DIR/osd2-perf-tend.txt
log "perf tend saved ($(wc -c < $RESULT_DIR/osd2-perf-tend.txt) bytes)"

# Cleanup
sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1
log "Pool cleanup done."

# Collect iostat
sleep 5
sshpass -p 'TurboAi@303' scp -o StrictHostKeyChecking=no turboai@192.168.11.13:/tmp/node2-iostat-memdisk.txt $RESULT_DIR/node2-iostat.txt 2>&1 >> $OPS_LOG
log "iostat collected."

log "=== Stage C retest COMPLETE ==="
