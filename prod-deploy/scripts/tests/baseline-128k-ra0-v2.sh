#!/bin/bash
set -e

# Full baseline test - Group B (ra0, 128K default max_fuse_io)
# Strictly follows 01-2d task book §3.2 execution sequence
# cluster_network reverted to public (10.3.1.0/24) to match pre-fix state

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS_DIR="/tmp/opencode-baseline-128k-ra0-v2"
FSID="4f4e3ca0-8297-11f1-a671-97520597268c"
NIC_IF="enp139s0f0np0"
# Group B: ra0 (max-readahead=0), NO --max-fuse-io (default 128K)
MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-readahead 0"

mkdir -p "${RESULTS_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/test.log"; }

# === Helper: health check ===
check_health() {
    local label="$1"
    local health=$(ssh_local "sudo ceph health 2>/dev/null")
    log "Health check (${label}): ${health}"
    [ "$health" = "HEALTH_OK" ] || { log "WARN: health not OK, waiting 60s..."; sleep 60; }
}

# === Helper: compact cooldown ===
compact_cooldown() {
    log "Compact cooldown..."
    for osd in 0 1 2 3 4 5; do
        sudo ceph tell osd.${osd} compact 2>/dev/null || true
    done
    # Wait for compaction to complete
    for i in $(seq 1 30); do
        local all_done=true
        for osd in 0 1 2 3 4 5; do
            local running=$(sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('rocksdb',{}).get('compact_running',0))" 2>/dev/null || echo "1")
            [ "$running" != "0" ] && all_done=false
        done
        $all_done && break
        sleep 5
    done
    log "Compact cooldown done"
}

# === Helper: drop caches (client + slaves) ===
drop_caches() {
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    rm -f ${BW_LOG_DIR}/* 2>/dev/null || true
}

# === Helper: clean volume (juicefs destroy + format + mount) ===
# Follows 01-2d task book §4.2.1 exactly
clean_volume() {
    log "=== 清卷 (juicefs destroy) ==="
    # 1. Unmount
    fusermount -u "${MNT}" 2>/dev/null || true
    fusermount -uz "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5

    # 2. Wait for session TTL
    log "Waiting 65s for session TTL..."
    sleep 65

    # 3. Extract UUID
    local UUID=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    log "Volume UUID: ${UUID}"

    # 4. Destroy
    if [ -n "${UUID}" ]; then
        juicefs destroy "${META}" "${UUID}" --yes 2>&1 | tee -a "${RESULTS_DIR}/destroy.log"
        log "Destroy done"
    else
        log "WARN: No UUID found, skipping destroy"
    fi

    # 5. Compact cooldown (destroy produces tombstones)
    compact_cooldown

    # 6. Format
    juicefs format --storage ceph --bucket ceph://juicefs-data \
        --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
        "${META}" juicefs-prod 2>&1 | tee -a "${RESULTS_DIR}/format.log"

    # 7. Mount (Group B: ra0)
    juicefs mount -d ${MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tee -a "${RESULTS_DIR}/mount.log"
    sleep 3
    mount | grep juice | grep -q max_read=131072 || { log "ERROR: max_read not 128K!"; exit 1; }
    mkdir -p "${TEST_DIR}"
    log "清卷 complete (max_read=128K, ra0)"
}

# === Helper: run fio + collect data ===
run_fio() {
    local label="$1"
    local subdir="${RESULTS_DIR}/${label}"
    mkdir -p "${subdir}"

    log "Starting ${label}..."
    drop_caches
    check_health "${label}"

    # NIC monitor
    ( while true; do
        echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"
        sleep 1
    done ) > "${subdir}/nic.txt" &
    local nic_pid=$!

    # juicefs stats
    local jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1)
    ( while true; do
        echo "------ $(date +%H:%M:%S) ------"
        juicefs stats "${MNT}" 2>/dev/null || true
        sleep 1
    done ) > "${subdir}/jfs-stats.txt" &
    local stats_pid=$!

    # Run fio
    shift
    eval "$*" 2>&1 | tee "${subdir}/fio.txt"

    kill ${nic_pid} ${stats_pid} 2>/dev/null || true
    wait ${nic_pid} ${stats_pid} 2>/dev/null || true

    # Copy bw logs
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true

    # Verify per-job file count
    local bw_count=$(ls "${subdir}"/*_bw.*.log 2>/dev/null | wc -l)
    log "${label} done (bw_log files: ${bw_count})"
}

# === Helper: remount (for write test rounds) ===
remount_jfs() {
    log "Remounting JuiceFS..."
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    juicefs mount -d ${MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -2
    sleep 3
    mount | grep juice | grep -q max_read=131072 || { log "ERROR: max_read not 128K!"; exit 1; }
    log "Remounted OK (max_read=128K, ra0)"
}

# ============================================================
# === PRE-TEST: Ensure clean cluster state ===
# ============================================================
check_health "pre-test"

# === Clean up any existing volume ===
log "=== Pre-test cleanup ==="
fusermount -u "${MNT}" 2>/dev/null || true
pkill -f 'juicefs.*mount' 2>/dev/null || true
sleep 5

# Delete pool to ensure clean state
sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it 2>/dev/null || true
sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
sudo ceph osd pool application enable juicefs-data juicefs 2>/dev/null
sleep 10
compact_cooldown

# Format + Mount
juicefs format --storage ceph --bucket ceph://juicefs-data \
    --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
    "${META}" juicefs-prod 2>&1 | tee -a "${RESULTS_DIR}/format.log"
juicefs mount -d ${MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tee -a "${RESULTS_DIR}/mount.log"
sleep 3
mount | grep juice | grep -q max_read=131072 || { log "ERROR: max_read not 128K!"; exit 1; }
mkdir -p "${TEST_DIR}"
log "=== Pre-test setup complete (max_read=128K, ra0, cluster_network=10.3.1.0/24) ==="

# ============================================================
# === STEP 1: Sequential tests (REPEAT=1) ===
# ============================================================

# 1a. seqread (prep + 180s)
log "=== STEP 1: seqread ==="
mkdir -p "${TEST_DIR}/seqread/"
fio --name=prep --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=4G >/dev/null 2>&1
run_fio "seqread" "fio --name=seqread --directory='${TEST_DIR}/seqread/' --rw=read --refill_buffers --bs=256k --size=4G --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/seqread' --log_avg_msec=1000"

# 1b. seqwrite (4G, end_fsync=1)
rm -rf "${TEST_DIR}/seqwrite"; mkdir -p "${TEST_DIR}/seqwrite"
run_fio "seqwrite" "fio --name=seqwrite --directory='${TEST_DIR}/seqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/seqwrite' --log_avg_msec=1000"

# 1c. mseqread (prep + 180s, 16 jobs)
rm -rf "${TEST_DIR}/mseqread"; mkdir -p "${TEST_DIR}/mseqread"
fio --name=prep --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
run_fio "mseqread" "fio --name=mseqread --directory='${TEST_DIR}/mseqread/' --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/mseqread' --log_avg_msec=1000"

# 1d. mseqwrite (64G, 16 jobs, end_fsync=1)
rm -rf "${TEST_DIR}/mseqwrite"; mkdir -p "${TEST_DIR}/mseqwrite"
run_fio "mseqwrite" "fio --name=mseqwrite --directory='${TEST_DIR}/mseqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/mseqwrite' --log_avg_msec=1000"

# ============================================================
# === STEP 2: 清卷 → randwrite-真写 (fresh, REPEAT=3) ===
# ============================================================
clean_volume

for round in 1 2 3; do
    run_fio "randwrite-true-r${round}" "fio --directory='${TEST_DIR}' --name=storage_test --nrfiles=100 --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randwrite-true-r${round}' --log_avg_msec=1000"
    compact_cooldown
done

# ============================================================
# === STEP 3: 清卷 → layout → compact → randread → randrw → randwrite-ow ===
# ============================================================
clean_volume

# 3a. Layout 128G
log "=== STEP 3a: Layout 128G ==="
run_fio "layout" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 --write_bw_log='${BW_LOG_DIR}/layout' --log_avg_msec=1000"
compact_cooldown

# 3b. randread ×3 (reuse layout, drop_caches between rounds)
for round in 1 2 3; do
    run_fio "randread-r${round}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randread-r${round}' --log_avg_msec=1000"
done

# 3c. randrw ×3 (reuse layout, compact between rounds)
for round in 1 2 3; do
    run_fio "randrw-r${round}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randrw-r${round}' --log_avg_msec=1000"
    compact_cooldown
done

# 3d. randwrite-ow ×3 (reuse layout, compact between rounds)
for round in 1 2 3; do
    run_fio "randwrite-ow-r${round}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randwrite-ow-r${round}' --log_avg_msec=1000"
    compact_cooldown
done

# ============================================================
# === DONE ===
# ============================================================
log "=== ALL TESTS DONE ==="
log "Results in ${RESULTS_DIR}"
log "cluster_network: 10.3.1.0/24 (reverted to public)"
log "mount: max_read=128K (default), ra0 (--max-readahead 0)"

# Verify per-job file counts
log "=== Per-job file verification ==="
for prefix in seqread seqwrite mseqread mseqwrite layout \
              randwrite-true-r1 randwrite-true-r2 randwrite-true-r3 \
              randread-r1 randread-r2 randread-r3 \
              randrw-r1 randrw-r2 randrw-r3 \
              randwrite-ow-r1 randwrite-ow-r2 randwrite-ow-r3; do
    count=$(ls "${RESULTS_DIR}/${prefix}/"*_bw.*.log 2>/dev/null | wc -l)
    case $prefix in
        seqread|seqwrite) expected=1;;
        mseqread|mseqwrite) expected=16;;
        *) expected=128;;
    esac
    log "${prefix}: ${count}/${expected} $([ "$count" = "$expected" ] && echo OK || echo MISSING)"
done

log "Script completed"
