#!/bin/bash
# Orchestration: start all monitoring, run rados bench 300s, collect perf tend
set -uo pipefail

RESULT_DIR=/home/turboai/production/results/iops-wall-locate-20260708
OPS_LOG=$RESULT_DIR/ops.log
POOL=juicefs-data
DURATION=300
MON_DUR=310
CONCURRENCY=64
BS=256K
PW11="TurboAi@303"
PW13="TurboAi@303"
PW14="TurboAi@303"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }

log "=== STARTING ORCHESTRATION ==="

# ---- 1. Start monitoring on all nodes ----
log "Starting monitoring (duration=${MON_DUR}s)..."

# Client (.12) - sar for NIC
sar -n DEV 1 $MON_DUR > $RESULT_DIR/client-nic-eno1.txt 2>&1 &
log "  client sar started (PID=$!)"

# Node1 (.11) - iostat + sar
sshpass -p "$PW11" ssh -o StrictHostKeyChecking=no turboai@192.168.11.11 \
    "iostat -x 1 $MON_DUR > /tmp/ceph11-iostat-sdb.txt 2>&1 & sar -n DEV 1 $MON_DUR > /tmp/ceph11-nic.txt 2>&1 &" &
log "  node1 monitoring started"

# Node2 (.13) - diskstats script
sshpass -p "$PW13" ssh -o StrictHostKeyChecking=no turboai@192.168.11.13 \
    "bash /tmp/diskstats-monitor.sh > /tmp/ceph13-iostat-sdb.txt 2>&1 &" &
log "  node2 monitoring started"

# Node3 (.14) - diskstats script
sshpass -p "$PW14" ssh -o StrictHostKeyChecking=no turboai@192.168.11.14 \
    "bash /tmp/diskstats-monitor.sh > /tmp/ceph14-iostat-sdb.txt 2>&1 &" &
log "  node3 monitoring started"

# Wait for monitoring to initialize
sleep 3
log "Monitoring initialized."

# ---- 2. perf t0 (already collected, verify exists) ----
for osd_id in 0 1 2 3 4 5; do
    [ ! -f "$RESULT_DIR/osd${osd_id}-perf-t0.txt" ] && { log "ABORT: osd${osd_id}-perf-t0.txt missing"; exit 1; }
done
log "perf t0 files verified."

# ---- 3. Start rados bench ----
log "START rados bench: -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup"
sudo rados bench -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup 2>&1 | tee $RESULT_DIR/rados-write-256k-t64-300s.txt
log "END rados bench"

# ---- 4. Collect perf tend ----
for osd_id in 0 1 2 3 4 5; do
    sudo ceph tell osd.$osd_id perf dump 2>/dev/null > $RESULT_DIR/osd${osd_id}-perf-tend.txt
    log "  osd.$osd_id perf tend saved ($(wc -c < $RESULT_DIR/osd${osd_id}-perf-tend.txt) bytes)"
done

# ---- 5. Cleanup pool ----
log "Cleaning pool..."
sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1
log "Pool cleanup done."

# ---- 6. Wait for monitoring to finish ----
log "Waiting for monitoring to finish (max 20s)..."
sleep 15

# ---- 7. Collect monitoring files from ceph nodes ----
log "Collecting monitoring files..."
sshpass -p "$PW11" scp -o StrictHostKeyChecking=no turboai@192.168.11.11:/tmp/ceph11-iostat-sdb.txt $RESULT_DIR/ceph11-iostat-sdb.txt 2>&1 | tee -a $OPS_LOG
sshpass -p "$PW11" scp -o StrictHostKeyChecking=no turboai@192.168.11.11:/tmp/ceph11-nic.txt $RESULT_DIR/ceph11-nic.txt 2>&1 | tee -a $OPS_LOG
sshpass -p "$PW13" scp -o StrictHostKeyChecking=no turboai@192.168.11.13:/tmp/ceph13-iostat-sdb.txt $RESULT_DIR/ceph13-iostat-sdb.txt 2>&1 | tee -a $OPS_LOG
sshpass -p "$PW14" scp -o StrictHostKeyChecking=no turboai@192.168.11.14:/tmp/ceph14-iostat-sdb.txt $RESULT_DIR/ceph14-iostat-sdb.txt 2>&1 | tee -a $OPS_LOG

log "=== ORCHESTRATION COMPLETE ==="
log "Files:"
ls -la $RESULT_DIR/*.txt $RESULT_DIR/*.md 2>/dev/null | tee -a $OPS_LOG
