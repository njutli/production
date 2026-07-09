#!/bin/bash
# Full cold baseline on full memdisk — matching cold-mu150-full-20260703 exactly
# Mount: --cache-size 0 --max-uploads 150
# Tests: seqread, seqwrite, multi-seqread(16j), multi-seqwrite(16j), layout(128j×512M=64G), randread/randwrite/randrw (128j×128, 3 rounds)
set -uo pipefail

DIR=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/full-memdisk/jfs-cold-mu150
OPS=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/ops.log
MNT=/mnt/juicefs
SEQ_DIR=$MNT/seq_dir
TEST_DIR=$MNT/test_dir
META=tikv://192.168.11.12:2379/juicefs-memdisk

mkdir -p $DIR
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS; }

log "=============================================="
log "Full cold baseline mu=150 on memdisk START"
log "=============================================="

# Remount with --max-uploads 150
log "=== remount with mu=150 ==="
sudo umount $MNT 2>/dev/null; sleep 2
sudo juicefs mount -d --cache-size 0 --max-uploads 150 $META $MNT 2>&1 | tee -a $OPS | tail -3
sleep 3

# Cleanup
sudo rm -rf $SEQ_DIR $TEST_DIR 2>/dev/null
sudo rados -p juicefs-data cleanup >> $OPS 2>&1
sleep 2

# ============================================================
# Sequential tests (bs=256K, --refill_buffers, NO --direct=1)
# ============================================================
log "==== SEQUENTIAL TESTS (bs=256K) ===="

# seqread prep
log "-- seqread prep --"
sudo mkdir -p $SEQ_DIR
sudo fio --name=prep --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G 2>&1 | tee $DIR/fio-seqread-prep.txt | tail -3

# seqread
log "-- seqread --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --name=seqread --directory=$SEQ_DIR --rw=read --refill_buffers --bs=256K --size=4G 2>&1 | tee $DIR/fio-seqread.txt | tail -3

# seqwrite
log "-- seqwrite --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --name=seqwrite --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1 2>&1 | tee $DIR/fio-seqwrite.txt | tail -3

# multi-seqread (16 jobs)
log "-- multi-seqread (16j) --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --name=multi-seqread --directory=$SEQ_DIR --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting 2>&1 | tee $DIR/fio-multi-seqread.txt | tail -3

# multi-seqwrite (16 jobs)
log "-- multi-seqwrite (16j) --"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo fio --name=multi-seqwrite --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1 2>&1 | tee $DIR/fio-multi-seqwrite.txt | tail -3

# Cleanup seq dir before layout (tmpfs space constraint)
log "-- cleanup seq_dir --"
sudo rm -rf $SEQ_DIR 2>/dev/null
sudo rados -p juicefs-data cleanup >> $OPS 2>&1
sleep 2

# ============================================================
# Layout (128 jobs × 512M = 64G, bs=4M) — reduced from 128G to fit tmpfs
# ============================================================
log "==== LAYOUT (128j × 512M = 64G, bs=4M) ===="
sudo mkdir -p $TEST_DIR
sudo fio --directory=$TEST_DIR --name=storage_test --filesize=512M --size=512M \
    --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 2>&1 | tee $DIR/fio-layout.txt | tail -3

# Layout cooldown
log "-- layout cooldown (compact + wait) --"
for osd_id in 0 1 2 3 4 5; do sudo ceph tell osd.$osd_id compact >> $OPS 2>&1 || true; done
sleep 120
log "  cooldown done"

# ============================================================
# Random tests (bs=256k, 128 jobs × 128 iodepth, 60s, 3 rounds)
# ============================================================
log "==== RANDOM TESTS (bs=256k, 128j×128, 3 rounds) ===="

for round in 1 2 3; do
  log "-- Round $round --"

  # randread
  log "  randread r$round"
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  sudo fio --directory=$TEST_DIR --name=storage_test --filesize=512M --size=512M \
      --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s 2>&1 | tee $DIR/fio-randread-r${round}.txt | tail -5

  # randwrite
  log "  randwrite r$round"
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  sudo fio --directory=$TEST_DIR --name=storage_test --filesize=512M --size=512M \
      --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s 2>&1 | tee $DIR/fio-randwrite-r${round}.txt | tail -5

  # randrw
  log "  randrw r$round"
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  sudo fio --directory=$TEST_DIR --name=storage_test --filesize=512M --size=512M \
      --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s 2>&1 | tee $DIR/fio-randrw-r${round}.txt | tail -5
done

# Cleanup
sudo rm -rf $TEST_DIR 2>/dev/null
sudo rados -p juicefs-data cleanup >> $OPS 2>&1

log "=============================================="
log "Full cold baseline mu=150 on memdisk COMPLETE"
log "=============================================="
