#!/bin/bash
# Exp 2B: Full read suite — EC 4+2 pool, 256K, 300s, t64, 3 rounds
# write data reused from 2A (t64 r1/r2/r3)
# seq read: prefill then rados bench 300 seq
# rand read: prefill then rados bench 300 rand

set -euo pipefail

RESULT_DIR=/home/turboai/production/results/backend-rados-fulldiag-20260708
EXP_DIR=$RESULT_DIR/exp1-fullset
OPS_LOG=$RESULT_DIR/ops.log
POOL=juicefs-data
BS=256K
DURATION=300
CONCURRENCY=64
PREFILL_DURATION=120

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
        [ "$state" != "HEALTH_OK" ] && { log "ABORT: Health not OK"; exit 1; }
    fi
}

clean_pool() {
    log "Cleaning pool $POOL..."
    sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1
    log "Pool cleanup done."
}

prefill_pool() {
    log "Prefilling pool (${PREFILL_DURATION}s write, $BS, t16, --no-cleanup)..."
    sudo rados bench -p $POOL $PREFILL_DURATION write -b $BS -t 16 --no-cleanup >> $OPS_LOG 2>&1
    local objs=$(sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print $3}')
    log "Prefill done. Objects in pool: $objs"
}

# ================================================================
log "=============================================="
log "Exp 2B: Full read suite START (t$CONCURRENCY, $BS, ${DURATION}s)"
log "write data reused from 2A t64 r1/r2/r3"
log "=============================================="

# ---- Sequential Read ----
log "==== SEQUENTIAL READ ===="

for round in 1 2 3; do
    log "---- seq read round $round ----"

    if [ $round -eq 1 ]; then
        # First round: prefill
        clean_pool
        compact_all
        health_check
        prefill_pool
    else
        # Subsequent rounds: compact + health check (keep prefilled objects)
        compact_all
        health_check
    fi
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

    OUT_FILE=$EXP_DIR/seq-read-256k-t64-r${round}.txt
    log "START: rados bench -p $POOL $DURATION seq -t $CONCURRENCY (reads 256K objects from prefill)"
    log "Output -> $OUT_FILE"
    sudo rados bench -p $POOL $DURATION seq -t $CONCURRENCY 2>&1 | tee $OUT_FILE
    log "END: seq read r$round"
done

# Clean up after seq read
clean_pool

# ---- Random Read ----
log "==== RANDOM READ ===="

for round in 1 2 3; do
    log "---- rand read round $round ----"

    if [ $round -eq 1 ]; then
        clean_pool
        compact_all
        health_check
        prefill_pool
    else
        compact_all
        health_check
    fi
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

    OUT_FILE=$EXP_DIR/rand-read-256k-t64-r${round}.txt
    log "START: rados bench -p $POOL $DURATION rand -t $CONCURRENCY (reads 256K objects from prefill)"
    log "Output -> $OUT_FILE"
    sudo rados bench -p $POOL $DURATION rand -t $CONCURRENCY 2>&1 | tee $OUT_FILE
    log "END: rand read r$round"
done

# Final cleanup
clean_pool
compact_all
health_check

log "=============================================="
log "Exp 2B: ALL READ TESTS COMPLETE"
log "=============================================="
