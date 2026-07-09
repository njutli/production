#!/bin/bash
# Exp 2A: Concurrency scan — EC 4+2 pool, 256K, 300s, scan -t 16/32/64/128, 3 rounds each
# Net-state reset between rounds: cleanup pool + compact all OSDs + health check

set -euo pipefail

RESULT_DIR=/home/turboai/production/results/backend-rados-fulldiag-20260708
EXP_DIR=$RESULT_DIR/exp1-concurrency
OPS_LOG=$RESULT_DIR/ops.log
POOL=juicefs-data
BS=256K
DURATION=300

mkdir -p $EXP_DIR

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG
}

compact_all() {
    log "Compacting all OSDs..."
    for osd_id in 0 1 2 3 4 5; do
        sudo ceph tell osd.$osd_id compact >> $OPS_LOG 2>&1 || true
    done
    sleep 10
    log "Compaction triggered."
}

verify_compact_done() {
    for osd_id in 0 1 2 3 4 5; do
        local ql=$(sudo ceph tell osd.$osd_id perf dump 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('rocksdb',{}).get('compact_queue_len','?'))
" 2>/dev/null || echo "err")
        local cr=$(sudo ceph tell osd.$osd_id perf dump 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('rocksdb',{}).get('compact_running','?'))
" 2>/dev/null || echo "err")
        log "  osd.$osd_id: queue_len=$ql running=$cr"
    done
}

clean_pool() {
    local before=$(sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print $3}')
    log "Cleaning pool $POOL (before: $before objects)..."
    sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1
    local after=$(sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print $3}')
    log "Pool cleanup done (after: $after objects)."
}

health_check() {
    local state=$(sudo ceph health 2>/dev/null)
    log "Health: $state"
    if [ "$state" != "HEALTH_OK" ]; then
        log "WARNING: Health not OK, waiting up to 300s..."
        for i in $(seq 1 30); do
            sleep 10
            state=$(sudo ceph health 2>/dev/null)
            log "  retry $i: $state"
            [ "$state" = "HEALTH_OK" ] && break
        done
        if [ "$state" != "HEALTH_OK" ]; then
            log "ABORT: Health not OK after 300s wait"
            exit 1
        fi
    fi
}

log "=============================================="
log "Exp 2A: Concurrency scan START"
log "Pool=$POOL BS=$BS Duration=${DURATION}s Concurrency=16,32,64,128 Rounds=3"
log "=============================================="

for concurrency in 16 32 64 128; do
    log "=========================================="
    log "2A: concurrency=$concurrency"
    log "=========================================="

    for round in 1 2 3; do
        log "---- t$concurrency round $round ----"

        # Net-state reset
        clean_pool
        compact_all
        verify_compact_done
        health_check
        sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

        # Bench
        OUT_FILE=$EXP_DIR/256k-t${concurrency}-r${round}.txt
        log "START bench: rados bench -p $POOL $DURATION write -b $BS -t $concurrency --no-cleanup"
        log "Output -> $OUT_FILE"
        sudo rados bench -p $POOL $DURATION write -b $BS -t $concurrency --no-cleanup 2>&1 | tee $OUT_FILE
        log "END bench: t$concurrency r$round"

        # Post-bench cleanup
        clean_pool
        compact_all
        log "Round $round done."
    done
done

log "=============================================="
log "Exp 2A: ALL CONCURRENCY SCANS COMPLETE"
log "=============================================="
