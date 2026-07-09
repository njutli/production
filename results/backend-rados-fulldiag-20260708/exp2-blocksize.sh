#!/bin/bash
# Exp 2: Block size matrix — EC 4+2 pool, t64, write + randread
# Block sizes: 4K 64K 256K 1M 4M
# Each: 3 write rounds (120s) + prefill + 3 rand read rounds (120s)

set -euo pipefail

RESULT_DIR=/home/turboai/production/results/backend-rados-fulldiag-20260708
EXP_DIR=$RESULT_DIR/exp2-blocksize
OPS_LOG=$RESULT_DIR/ops.log
POOL=juicefs-data
CONCURRENCY=64
DURATION=120
PREFILL_DURATION=120
SIZES=("4K" "64K" "256K" "1M" "4M")
SIZES_BYTES=("4096" "65536" "262144" "1048576" "4194304")

mkdir -p $EXP_DIR

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }
compact_all() {
    for osd_id in 0 1 2 3 4 5; do sudo ceph tell osd.$osd_id compact >> $OPS_LOG 2>&1 || true; done
    sleep 10
}
health_check() {
    local state=$(sudo ceph health 2>/dev/null)
    log "Health: $state"
    if [ "$state" != "HEALTH_OK" ]; then
        for i in $(seq 1 30); do sleep 10; state=$(sudo ceph health 2>/dev/null); log "  retry $i: $state"; [ "$state" = "HEALTH_OK" ] && break; done
        [ "$state" != "HEALTH_OK" ] && { log "ABORT"; exit 1; }
    fi
}
clean_pool() { sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1; }

log "=============================================="
log "Exp 2: Block size matrix START (t$CONCURRENCY, ${DURATION}s)"
log "Sizes: ${SIZES[@]}"
log "=============================================="

for idx in 0 1 2 3 4; do
    BS=${SIZES[$idx]}
    BS_BYTES=${SIZES_BYTES[$idx]}

    log "========== BLOCK SIZE: $BS =========="

    # ---- Write tests ----
    for round in 1 2 3; do
        log "---- write $BS round $round ----"
        clean_pool
        compact_all
        health_check
        sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

        OUT_FILE=$EXP_DIR/write-${BS}-t64-r${round}.txt
        log "START: rados bench -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup"
        sudo rados bench -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup 2>&1 | tee $OUT_FILE
        log "END: write $BS r$round"
        clean_pool
        compact_all
    done

    # ---- Rand read tests ----
    log "---- prefill for rand read ($BS, ${PREFILL_DURATION}s) ----"
    clean_pool
    compact_all
    health_check
    sudo rados bench -p $POOL $PREFILL_DURATION write -b $BS -t 16 --no-cleanup >> $OPS_LOG 2>&1
    objs=$(sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print $3}')
    log "Prefill done. Objects: $objs"

    for round in 1 2 3; do
        log "---- rand read $BS round $round ----"
        compact_all
        health_check
        sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

        OUT_FILE=$EXP_DIR/randread-${BS}-t64-r${round}.txt
        log "START: rados bench -p $POOL $DURATION rand -t $CONCURRENCY"
        sudo rados bench -p $POOL $DURATION rand -t $CONCURRENCY 2>&1 | tee $OUT_FILE
        log "END: rand read $BS r$round"
    done

    clean_pool
    compact_all
    health_check
    log "Block size $BS done."
done

log "=============================================="
log "Exp 2: BLOCK SIZE MATRIX COMPLETE"
log "=============================================="
