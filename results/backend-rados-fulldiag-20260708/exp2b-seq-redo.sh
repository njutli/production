#!/bin/bash
# Redo seq read with larger prefill (600s) to sustain 300s read
set -euo pipefail

RESULT_DIR=/home/turboai/production/results/backend-rados-fulldiag-20260708
EXP_DIR=$RESULT_DIR/exp1-fullset
OPS_LOG=$RESULT_DIR/ops.log
POOL=juicefs-data
BS=256K
DURATION=300
CONCURRENCY=64
PREFILL_DURATION=600

mkdir -p $EXP_DIR

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }
compact_all() {
    log "Compacting all OSDs..."
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
clean_pool() { log "Cleaning pool..."; sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1; log "Cleanup done."; }

log "==== SEQ READ REDO (prefill=${PREFILL_DURATION}s) ===="

# Clean + prefill once
clean_pool
compact_all
health_check
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

log "Prefilling ${PREFILL_DURATION}s write -b $BS -t 16 --no-cleanup..."
sudo rados bench -p $POOL $PREFILL_DURATION write -b $BS -t 16 --no-cleanup >> $OPS_LOG 2>&1
objs=$(sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print $3}')
log "Prefill done. Objects: $objs"

for round in 1 2 3; do
    log "---- seq read redo round $round ----"
    compact_all
    health_check
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

    OUT_FILE=$EXP_DIR/seq-read-256k-t64-r${round}.txt
    log "START: rados bench -p $POOL $DURATION seq -t $CONCURRENCY"
    sudo rados bench -p $POOL $DURATION seq -t $CONCURRENCY 2>&1 | tee $OUT_FILE
    log "END: seq read redo r$round"
done

clean_pool
compact_all
health_check
log "==== SEQ READ REDO COMPLETE ===="
