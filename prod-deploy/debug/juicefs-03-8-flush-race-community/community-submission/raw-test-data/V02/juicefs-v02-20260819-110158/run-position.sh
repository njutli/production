#!/bin/bash
set -euo pipefail

# V02 Performance Matrix - One Position Runner
# Usage: run-position.sh <arm> <block> <position> <binary>
# Example: run-position.sh S 1 1 /tmp/juicefs-v02-20260819-110158-S

ARM=$1
BLOCK=$2
POS=$3
BIN=$4
RUN_ID=20260819-110158
OUT=/tmp/juicefs-v02-$RUN_ID
MNT=/mnt/juicefs-v02
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
LABEL="${ARM}${POS}"
POS_DIR=$OUT/runs/block${BLOCK}-${LABEL}
mkdir -p $POS_DIR

log() { echo "[$(date '+%F %T %z')] $*" >> $OUT/controller-state.tsv; }

# Mount
echo "=== Mount $LABEL ===" > $POS_DIR/mount.log
$BIN mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K "$META" "$MNT" >> $POS_DIR/mount.log 2>&1
sleep 3
MOUNT_PID=$(pgrep -f "juicefs-v02.*-${ARM}.*mount" | head -1)
echo "PID=$MOUNT_PID" >> $POS_DIR/mount.log
if [ -z "$MOUNT_PID" ]; then echo "MOUNT FAILED" >> $POS_DIR/STATUS; exit 1; fi

run_fio() {
    local item=$1 round=$2 rw=$3 name=$4 prefix=$5
    local run_dir=$POS_DIR/${item}-${round}
    mkdir -p $run_dir

    echo "=== $LABEL $item r$round ===" > $run_dir/status.txt
    date '+%F %T %z' >> $run_dir/status.txt

    # Health check
    local health=$(sudo -n ceph health 2>/dev/null)
    echo "health=$health" >> $run_dir/status.txt
    [ "$health" = "HEALTH_OK" ] || { echo "HEALTH FAIL - STOP" >> $run_dir/status.txt; exit 1; }

    # Objects pre
    local obj_pre=$(sudo -n ceph df --format=json 2>/dev/null | python3 -c "import json,sys;[print(p['stats']['objects']) for p in json.load(sys.stdin)['pools'] if p['name']=='juicefs-data']" 2>/dev/null)
    echo "objects_pre=$obj_pre" >> $run_dir/status.txt

    # drop_caches on 4 nodes
    sudo -n bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
    for ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
        timeout 10 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $ip 'sudo -n bash -c "echo 3 > /proc/sys/vm/drop_caches"' 2>/dev/null || true
    done
    echo "drop_caches done" >> $run_dir/status.txt

    # Mount identity
    grep '/mnt/juicefs-v02 ' /proc/self/mountinfo > $run_dir/mountinfo.txt 2>/dev/null
    echo "pid=$MOUNT_PID" > $run_dir/pid.txt

    # .stats pre
    curl -s http://127.0.0.1:9567/metrics > $run_dir/stats-pre.txt 2>/dev/null

    # fio
    fio --directory=$MNT/test_dir --name=$name --filesize=1G --size=1G --bs=256k --rw=$rw \
        --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log=$run_dir/$prefix --log_avg_msec=1000 --kb_base=1024 \
        > $run_dir/fio.txt 2>&1
    local rc=$?
    echo $rc > $run_dir/fio.rc
    echo "fio_rc=$rc" >> $run_dir/status.txt

    # .stats post
    curl -s http://127.0.0.1:9567/metrics > $run_dir/stats-post.txt 2>/dev/null

    # Objects post
    local obj_post=$(sudo -n ceph df --format=json 2>/dev/null | python3 -c "import json,sys;[print(p['stats']['objects']) for p in json.load(sys.stdin)['pools'] if p['name']=='juicefs-data']" 2>/dev/null)
    echo "objects_post=$obj_post" >> $run_dir/status.txt

    # bw log count
    local bw_count=$(ls $run_dir/${prefix}*.log 2>/dev/null | wc -l)
    echo "bw_logs=$bw_count" >> $run_dir/status.txt

    # PID stability
    kill -0 $MOUNT_PID 2>/dev/null && echo "pid_stable=YES" >> $run_dir/status.txt || echo "pid_stable=NO" >> $run_dir/status.txt

    # Cleanup: gc --compact
    echo "=== cleanup $item r$round ===" >> $run_dir/status.txt
    $BIN gc --compact "$META" > $run_dir/gc.log 2>&1
    local gc_rc=$?
    echo $gc_rc > $run_dir/gc.rc

    # OSD compact
    for osd_id in $(sudo -n ceph osd ls 2>/dev/null); do
        sudo -n ceph tell osd.$osd_id compact 2>/dev/null
    done
    sleep 10

    # Post-cleanup objects
    local obj_clean=$(sudo -n ceph df --format=json 2>/dev/null | python3 -c "import json,sys;[print(p['stats']['objects']) for p in json.load(sys.stdin)['pools'] if p['name']=='juicefs-data']" 2>/dev/null)
    echo "objects_after_cleanup=$obj_clean" >> $run_dir/status.txt
    local health_clean=$(sudo -n ceph health 2>/dev/null)
    echo "health_after_cleanup=$health_clean" >> $run_dir/status.txt

    echo "DONE $item r$round" >> $run_dir/status.txt
}

# 3 randwrite + 3 randrw
for round in 1 2 3; do
    run_fio randwrite $round randwrite storage_test "${LABEL}-rw${round}"
done
for round in 1 2 3; do
    run_fio randrw $round randrw rw_test "${LABEL}-rr${round}"
done

# Umount
echo "=== Umount $LABEL ===" > $POS_DIR/umount.log
$BIN umount "$MNT" >> $POS_DIR/umount.log 2>&1
echo "umount_rc=$?" >> $POS_DIR/umount.log
sleep 3
grep '/mnt/juicefs-v02 ' /proc/self/mountinfo 2>/dev/null && echo "STILL MOUNTED" >> $POS_DIR/umount.log || echo "MOUNT GONE" >> $POS_DIR/umount.log

# Final status
echo "POSITION $LABEL COMPLETE" > $POS_DIR/STATUS
date '+%F %T %z' >> $POS_DIR/STATUS
echo "DONE" >> $POS_DIR/STATUS
