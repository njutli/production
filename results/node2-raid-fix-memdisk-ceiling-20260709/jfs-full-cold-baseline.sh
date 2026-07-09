#!/bin/bash
# Full cold baseline on full memdisk — matching cold-baseline-recheck-20260706 parameters
# Tests: seqread, seqwrite, multi-seqread(16j), multi-seqwrite(16j), randread(16j), randwrite(16j), randrw(16j)
# Layout: 16G (16 jobs × 1G) to fit tmpfs 152GB
set -uo pipefail

DIR=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/full-memdisk/jfs-cold
OPS=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/ops.log
MNT=/mnt/juicefs
SEQ_DIR=$MNT/seq_dir
TEST_DIR=$MNT/test_dir

mkdir -p $DIR
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS; }

log "=============================================="
log "Full cold baseline on memdisk START (7 items)"
log "=============================================="

# Cleanup
sudo rm -rf $SEQ_DIR $TEST_DIR 2>/dev/null
sudo rados -p juicefs-data cleanup >> $OPS 2>&1
sleep 2

# ============================================================
# Sequential tests (bs=256K, --refill_buffers, NO --direct=1)
# ============================================================
log "==== SEQUENTIAL TESTS (bs=256K) ===="

# seqread prep (write 4G)
log "-- seqread prep --"
sudo mkdir -p $SEQ_DIR
sudo fio --name=prep --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G 2>&1 | tee $DIR/fio-seqread-prep.txt | tail -3

# seqread (buffered, no --direct)
log "-- seqread --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --name=seqread --directory=$SEQ_DIR --rw=read --refill_buffers --bs=256K --size=4G 2>&1 | tee $DIR/fio-seqread.txt | tail -3

# seqwrite
log "-- seqwrite --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --name=seqwrite --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1 2>&1 | tee $DIR/fio-seqwrite-v2.txt | tail -3

# multi-seqread (16 jobs)
log "-- multi-seqread (16j) --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --name=multi-seqread --directory=$SEQ_DIR --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting 2>&1 | tee $DIR/fio-multi-seqread.txt | tail -3

# multi-seqwrite (16 jobs)
log "-- multi-seqwrite (16j) --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --name=multi-seqwrite --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1 2>&1 | tee $DIR/fio-multi-seqwrite-v2.txt | tail -3

# Cleanup seq dir
sudo rm -rf $SEQ_DIR 2>/dev/null
sudo rados -p juicefs-data cleanup >> $OPS 2>&1
sleep 2

# ============================================================
# Layout (16 jobs × 1G = 16G, bs=4M)
# ============================================================
log "==== LAYOUT (16G, bs=4M) ===="
sudo mkdir -p $TEST_DIR
sudo fio --directory=$TEST_DIR --name=storage_test --filesize=1G --size=1G \
    --bs=4M --rw=write --numjobs=16 --fallocate=none --group_reporting --end_fsync=1 2>&1 | tee $DIR/fio-layout.txt | tail -3

# ============================================================
# Random tests (bs=256k, 16 jobs × 128 iodepth, 60s time_based)
# ============================================================
log "==== RANDOM TESTS (bs=256k, 16j×128, 60s) ===="

# randread
log "-- randread --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --directory=$TEST_DIR --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=16 \
    --direct=1 --fallocate=none --openfiles=20 --group_reporting --time_based --runtime=60s 2>&1 | tee $DIR/fio-randread-v3.txt | tail -5

# randwrite
log "-- randwrite --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --directory=$TEST_DIR --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=16 \
    --direct=1 --fallocate=none --openfiles=20 --group_reporting --time_based --runtime=60s 2>&1 | tee $DIR/fio-randwrite.txt | tail -5

# randrw
log "-- randrw --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --directory=$TEST_DIR --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=16 \
    --direct=1 --fallocate=none --openfiles=20 --group_reporting --time_based --runtime=60s 2>&1 | tee $DIR/fio-randrw.txt | tail -5

# Cleanup
sudo rm -rf $TEST_DIR 2>/dev/null
sudo rados -p juicefs-data cleanup >> $OPS 2>&1

log "=============================================="
log "Full cold baseline on memdisk COMPLETE"
log "=============================================="
