#!/bin/bash
# Exp 3: EC vs Replica — create rep3-test pool, test 256K+4M write+randread, delete pool
# Compare with EC 4+2 data from exp2

set -euo pipefail

RESULT_DIR=/home/turboai/production/results/backend-rados-fulldiag-20260708
EXP_DIR=$RESULT_DIR/exp3-ec-vs-rep
OPS_LOG=$RESULT_DIR/ops.log
POOL=rep3-test
EC_POOL=juicefs-data
CONCURRENCY=64
DURATION=120
PREFILL_DURATION=120
SIZES=("256K" "4M")
SIZES_BYTES=("262144" "4194304")

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
log "Exp 3: EC vs Replica — START"
log "Pool: $POOL (replica size=3) vs $EC_POOL (EC 4+2)"
log "=============================================="

# ---- Create replica pool ----
log "Creating replica pool $POOL (size=3)..."
sudo ceph osd pool create $POOL 32 32 replicated 2>&1 | tee -a $OPS_LOG
sudo ceph osd pool set $POOL size 3 2>&1 | tee -a $OPS_LOG
sudo ceph osd pool set $POOL min_size 2 2>&1 | tee -a $OPS_LOG
sudo ceph osd pool application enable $POOL bench 2>&1 | tee -a $OPS_LOG
sleep 5
health_check
log "Pool $POOL created."

for idx in 0 1; do
    BS=${SIZES[$idx]}
    BS_BYTES=${SIZES_BYTES[$idx]}

    log "========== REPLICA $BS =========="

    # ---- Write tests ----
    for round in 1 2 3; do
        log "---- rep write $BS round $round ----"
        clean_pool
        compact_all
        health_check
        sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

        OUT_FILE=$EXP_DIR/rep-write-${BS}-t64-r${round}.txt
        log "START: rados bench -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup"
        sudo rados bench -p $POOL $DURATION write -b $BS -t $CONCURRENCY --no-cleanup 2>&1 | tee $OUT_FILE
        log "END: rep write $BS r$round"
        clean_pool
        compact_all
    done

    # ---- Rand read tests ----
    log "---- rep prefill for rand read ($BS, ${PREFILL_DURATION}s) ----"
    clean_pool
    compact_all
    health_check
    sudo rados bench -p $POOL $PREFILL_DURATION write -b $BS -t 16 --no-cleanup >> $OPS_LOG 2>&1
    objs=$(sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print $3}')
    log "Prefill done. Objects: $objs"

    for round in 1 2 3; do
        log "---- rep rand read $BS round $round ----"
        compact_all
        health_check
        sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

        OUT_FILE=$EXP_DIR/rep-randread-${BS}-t64-r${round}.txt
        log "START: rados bench -p $POOL $DURATION rand -t $CONCURRENCY"
        sudo rados bench -p $POOL $DURATION rand -t $CONCURRENCY 2>&1 | tee $OUT_FILE
        log "END: rep rand read $BS r$round"
    done

    clean_pool
    compact_all
    health_check
    log "Replica $BS done."
done

# ---- Delete replica pool ----
log "Deleting replica pool $POOL..."
sudo ceph config set mon mon_allow_pool_delete true 2>&1 | tee -a $OPS_LOG
sleep 2
sudo ceph osd pool delete $POOL $POOL --yes-i-really-really-mean-it 2>&1 | tee -a $OPS_LOG
sudo ceph config rm mon mon_allow_pool_delete 2>&1 | tee -a $OPS_LOG || true
sleep 5
health_check
log "Pool $POOL deleted."

# Final compact
compact_all
health_check

log "=============================================="
log "Exp 3: EC vs Replica — COMPLETE"
log "=============================================="
