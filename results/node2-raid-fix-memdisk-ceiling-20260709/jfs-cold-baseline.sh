#!/bin/bash
# JuiceFS cold baseline on full memdisk — with full checklist monitoring
set -uo pipefail

RESULT_DIR=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/full-memdisk/jfs-cold
OPS_LOG=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709/ops.log
MOUNT=/mnt/juicefs
META=tikv://192.168.11.12:2379/juicefs-memdisk
POOL=juicefs-data

mkdir -p $RESULT_DIR
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }

# Client NIC monitor
start_nic() {
  local f=$1
  ( while true; do
      echo "$(date +%s) $(awk '/eno1:/ {print $10}' /proc/net/dev)"
      sleep 1
    done ) > $f 2>&1 &
  echo $!
}

log "=============================================="
log "JuiceFS cold baseline on full memdisk START"
log "=============================================="

# 1. Mount JuiceFS with --cache-size 0
log "=== mount JuiceFS ==="
sudo umount $MOUNT 2>/dev/null
sleep 2
sudo juicefs mount $META $MOUNT --cache-size 0 --max-readahead 0 -d 2>&1 | tee -a $OPS_LOG
sleep 5
JFS_PID=$(pgrep -f "juicefs.*juicefs-memdisk" | head -1)
log "  JuiceFS PID: $JFS_PID"
mount | grep juicefs | tee -a $OPS_LOG

# 2. Sequential write (4G, 256K, 1 job)
log "==== SEQWRITE 4G 256K 1job ===="
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
# rados df before
sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print "before: objects="$3, "used="$4}' | tee -a $OPS_LOG
NIC_PID=$(start_nic $RESULT_DIR/nic-seqwrite.txt)
sudo juicefs stats $MOUNT -l 1 --interval 1 --count 60 > $RESULT_DIR/jfs-stats-seqwrite.txt 2>&1 &
sudo pidstat -p $JFS_PID 1 60 > $RESULT_DIR/jfs-cpu-seqwrite.txt 2>&1 &
sleep 2
sudo fio --name=seqwrite --rw=write --bs=256K --size=4G --ioengine=libaio --iodepth=64 --direct=1 --numjobs=1 --group_reporting --filename=$MOUNT/seqwrite-test 2>&1 | tee $RESULT_DIR/fio-seqwrite.txt
kill $NIC_PID 2>/dev/null
sleep 2
# rados df after
sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print "after: objects="$3, "used="$4}' | tee -a $OPS_LOG
sudo rm -f $MOUNT/seqwrite-test
sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1

# 3. Multi-sequential write (2G × 4 jobs = 8G total)
log "==== MULTI-SEQWRITE 2G×4 256K ===="
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print "before: objects="$3, "used="$4}' | tee -a $OPS_LOG
NIC_PID=$(start_nic $RESULT_DIR/nic-multi-seqwrite.txt)
sudo juicefs stats $MOUNT -l 1 --interval 1 --count 120 > $RESULT_DIR/jfs-stats-multi-seqwrite.txt 2>&1 &
sudo pidstat -p $JFS_PID 1 120 > $RESULT_DIR/jfs-cpu-multi-seqwrite.txt 2>&1 &
sleep 2
sudo fio --name=multi-seqwrite --rw=write --bs=256K --size=2G --ioengine=libaio --iodepth=64 --direct=1 --numjobs=4 --group_reporting --filename=$MOUNT/multi-seqwrite-test 2>&1 | tee $RESULT_DIR/fio-multi-seqwrite.txt
kill $NIC_PID 2>/dev/null
sleep 2
sudo rados df -p $POOL 2>/dev/null | grep $POOL | awk '{print "after: objects="$3, "used="$4}' | tee -a $OPS_LOG
sudo rm -f $MOUNT/multi-seqwrite-test
sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1

# 4. Random read (prefill 4G + read 4G)
log "==== RANDREAD 4G 256K ===="
log "  prefilling..."
sudo fio --name=prefill --rw=write --bs=256K --size=4G --ioengine=libaio --iodepth=64 --direct=1 --numjobs=1 --group_reporting --filename=$MOUNT/randread-test 2>&1 | tail -5 | tee -a $OPS_LOG
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
NIC_PID=$(start_nic $RESULT_DIR/nic-randread.txt)
sudo juicefs stats $MOUNT -l 1 --interval 1 --count 60 > $RESULT_DIR/jfs-stats-randread.txt 2>&1 &
sudo pidstat -p $JFS_PID 1 60 > $RESULT_DIR/jfs-cpu-randread.txt 2>&1 &
sleep 2
sudo fio --name=randread --rw=randread --bs=256K --size=4G --ioengine=libaio --iodepth=64 --direct=1 --numjobs=1 --group_reporting --filename=$MOUNT/randread-test 2>&1 | tee $RESULT_DIR/fio-randread.txt
kill $NIC_PID 2>/dev/null
sudo rm -f $MOUNT/randread-test
sudo rados -p $POOL cleanup >> $OPS_LOG 2>&1

log "=============================================="
log "JuiceFS cold baseline COMPLETE"
log "=============================================="
