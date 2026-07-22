#!/bin/bash
set -e

# Full baseline sweep: test 4 max-fuse-io values (128K, 256K, 512K, 1M)
# Each value runs full 9-item baseline following 01-2d task book §3.2
# Follows skills/TESTING-GUIDE.md + skills/test-commands-reference.md

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
NIC_IF="enp139s0f0np0"
FSID="4f4e3ca0-8297-11f1-a671-97520597268c"
BASE_RESULTS="/tmp/opencode-maxfuse-full-sweep"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- compact cooldown (TESTING-GUIDE §1.3/§3.2) ---
compact_cooldown() {
    log "Compact cooldown..."
    for osd in 0 1 2 3 4 5; do sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    for i in $(seq 1 30); do
        all_done=true
        for osd in 0 1 2 3 4 5; do
            running=$(sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('rocksdb',{}).get('compact_running',0))" 2>/dev/null || echo "1")
            [ "$running" != "0" ] && all_done=false
        done
        $all_done && break; sleep 5
    done
    log "Compact cooldown done"
}

# --- health check (TESTING-GUIDE §1.1/§2.2) ---
check_health() {
    local health=$(sudo ceph health 2>/dev/null | head -1)
    log "Health: ${health}"
}

# --- drop caches (TESTING-GUIDE §5.1: client only, not OSD) ---
drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    rm -f /tmp/jfs-bw/* 2>/dev/null || true
}

# --- clean volume via juicefs destroy (01-2d §4.2.1) ---
clean_volume() {
    local results_dir="$1"
    log "=== 清卷 (juicefs destroy) ==="
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    log "Waiting 65s for session TTL..."
    sleep 65
    local UUID=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    if [ -n "${UUID}" ]; then
        juicefs destroy "${META}" "${UUID}" --yes 2>&1 | tee -a "${results_dir}/destroy.log"
        log "Destroy done"
    fi
    compact_cooldown
    juicefs format --storage ceph --bucket ceph://juicefs-data \
        --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
        "${META}" juicefs-prod 2>&1 | tee -a "${results_dir}/format.log"
}

# --- setup pool + mount ---
setup_mount() {
    local fuse_io="$1" results_dir="$2" expected_maxread="$3"
    local mount_opts="--max-uploads 150 --cache-size 0 --max-readahead 0"
    [ -n "$fuse_io" ] && mount_opts="$mount_opts --max-fuse-io $fuse_io"
    
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it 2>/dev/null || true
    sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
    sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
    sudo ceph osd pool application enable juicefs-data juicefs 2>/dev/null
    sleep 10
    compact_cooldown
    juicefs format --storage ceph --bucket ceph://juicefs-data \
        --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
        "${META}" juicefs-prod 2>/dev/null | tail -1
    juicefs mount -d $mount_opts "${META}" "${MNT}" 2>/dev/null | tail -1
    sleep 3
    local actual=$(mount | grep juice | grep -oE 'max_read=[0-9]+' | grep -oE '[0-9]+')
    [ "$actual" = "$expected_maxread" ] || { log "ERROR: max_read=$actual, expected=$expected_maxread"; exit 1; }
    mkdir -p "${TEST_DIR}"
    log "Mounted: --max-fuse-io ${fuse_io:-default}, max_read=${actual}"
}

# --- run fio + collect (test-commands-reference §9) ---
run_fio() {
    local label="$1" results_dir="$2"
    local subdir="${results_dir}/${label}"
    mkdir -p "${subdir}"
    log "Starting ${label}..."
    drop_caches
    check_health
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) > "${subdir}/nic.txt" &
    local nic_pid=$!
    local jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1)
    ( while true; do echo "------ $(date +%H:%M:%S) ------"; juicefs stats "${MNT}" 2>/dev/null || true; sleep 1; done ) > "${subdir}/jfs-stats.txt" &
    local stats_pid=$!
    shift 2
    eval "$*" 2>&1 | tee "${subdir}/fio.txt"
    kill $nic_pid $stats_pid 2>/dev/null || true
    wait $nic_pid $stats_pid 2>/dev/null || true
    cp /tmp/jfs-bw/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f /tmp/jfs-bw/*_bw.*.log 2>/dev/null || true
    local bw_count=$(ls "${subdir}"/*_bw.*.log 2>/dev/null | wc -l)
    log "${label} done (bw_log: ${bw_count})"
}

# --- run full baseline for one max-fuse-io value ---
run_baseline() {
    local fuse_io="$1" tag="$2" expected_maxread="$3"
    local R="${BASE_RESULTS}/${tag}"
    mkdir -p "${R}"
    log "============================================"
    log "=== START: --max-fuse-io ${fuse_io:-default} (${tag}) ==="
    log "============================================"

    # Pre-test setup
    check_health
    setup_mount "$fuse_io" "$R" "$expected_maxread"

    # STEP 1: Sequential (REPEAT=1)
    mkdir -p "${TEST_DIR}/seqread/"
    fio --name=prep --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=4G >/dev/null 2>&1
    run_fio "seqread" "$R" "fio --name=seqread --directory='${TEST_DIR}/seqread/' --rw=read --refill_buffers --bs=256k --size=4G --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log=/tmp/jfs-bw/seqread --log_avg_msec=1000"
    rm -rf "${TEST_DIR}/seqwrite"; mkdir -p "${TEST_DIR}/seqwrite"
    run_fio "seqwrite" "$R" "fio --name=seqwrite --directory='${TEST_DIR}/seqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 --write_bw_log=/tmp/jfs-bw/seqwrite --log_avg_msec=1000"
    rm -rf "${TEST_DIR}/mseqread"; mkdir -p "${TEST_DIR}/mseqread"
    fio --name=prep --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
    run_fio "mseqread" "$R" "fio --name=mseqread --directory='${TEST_DIR}/mseqread/' --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log=/tmp/jfs-bw/mseqread --log_avg_msec=1000"
    rm -rf "${TEST_DIR}/mseqwrite"; mkdir -p "${TEST_DIR}/mseqwrite"
    run_fio "mseqwrite" "$R" "fio --name=mseqwrite --directory='${TEST_DIR}/mseqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --write_bw_log=/tmp/jfs-bw/mseqwrite --log_avg_msec=1000"

    # STEP 2: 清卷 → randwrite-true ×3
    clean_volume "$R"
    setup_mount "$fuse_io" "$R" "$expected_maxread"
    for r in 1 2 3; do
        run_fio "randwrite-true-r${r}" "$R" "fio --directory='${TEST_DIR}' --name=storage_test --nrfiles=100 --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log=/tmp/jfs-bw/randwrite-true-r${r} --log_avg_msec=1000"
        compact_cooldown
    done

    # STEP 3: 清卷 → layout → randread → randrw → randwrite-ow
    clean_volume "$R"
    setup_mount "$fuse_io" "$R" "$expected_maxread"
    run_fio "layout" "$R" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 --write_bw_log=/tmp/jfs-bw/layout --log_avg_msec=1000"
    compact_cooldown
    for r in 1 2 3; do
        run_fio "randread-r${r}" "$R" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log=/tmp/jfs-bw/randread-r${r} --log_avg_msec=1000"
    done
    for r in 1 2 3; do
        run_fio "randrw-r${r}" "$R" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log=/tmp/jfs-bw/randrw-r${r} --log_avg_msec=1000"
        compact_cooldown
    done
    for r in 1 2 3; do
        run_fio "randwrite-ow-r${r}" "$R" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log=/tmp/jfs-bw/randwrite-ow-r${r} --log_avg_msec=1000"
        compact_cooldown
    done

    # Verify per-job files
    log "=== Per-job verification (${tag}) ==="
    for prefix in seqread seqwrite mseqread mseqwrite layout \
                  randwrite-true-r1 randwrite-true-r2 randwrite-true-r3 \
                  randread-r1 randread-r2 randread-r3 \
                  randrw-r1 randrw-r2 randrw-r3 \
                  randwrite-ow-r1 randwrite-ow-r2 randwrite-ow-r3; do
        count=$(ls "${R}/${prefix}/"*_bw.*.log 2>/dev/null | wc -l)
        case $prefix in
            seqread|seqwrite) expected=1;;
            mseqread|mseqwrite) expected=16;;
            *) expected=128;;
        esac
        log "${tag}/${prefix}: ${count}/${expected} $([ "$count" = "$expected" ] && echo OK || echo MISSING)"
    done

    log "=== DONE: ${tag} ==="
    # Inter-value cleanup
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    compact_cooldown
}

# ============================================================
# Main: run 4 values sequentially
# ============================================================
mkdir -p "${BASE_RESULTS}"

# Values: tag, fuse_io param, expected max_read (bytes)
# 128K = 131072, 256K = 262144, 512K = 524288, 1M = 1048576

run_baseline ""      "128k" "131072"    # default (128K)
run_baseline "256K"  "256k" "262144"
run_baseline "512K"  "512k" "524288"
run_baseline "1M"    "1m"   "1048576"

log "============================================"
log "=== ALL SWEEP TESTS DONE ==="
log "Results in ${BASE_RESULTS}"
log "============================================"
