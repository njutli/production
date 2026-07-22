#!/bin/bash
set -e

# Test different --max-fuse-io values: 128K, 256K, 512K, 1M
# For each: randread (reuse layout) + randwrite-true (fresh volume)
# Collect: fio BW/slat/clat + network TX/RX + juicefs stats

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw-sweep"
RESULTS_DIR="/tmp/opencode-maxfuse-sweep"
NIC_IF="enp139s0f0np0"
FSID="4f4e3ca0-8297-11f1-a671-97520597268c"

mkdir -p "${RESULTS_DIR}"
rm -rf "${BW_LOG_DIR}" 2>/dev/null; mkdir -p "${BW_LOG_DIR}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/test.log"; }

compact_cooldown() {
    for osd in 0 1 2 3 4 5; do sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    for i in $(seq 1 20); do
        all_done=true
        for osd in 0 1 2 3 4 5; do
            running=$(sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('rocksdb',{}).get('compact_running',0))" 2>/dev/null || echo "1")
            [ "$running" != "0" ] && all_done=false
        done
        $all_done && break; sleep 5
    done
}

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    rm -f ${BW_LOG_DIR}/* 2>/dev/null || true
}

setup_pool_mount() {
    local fuse_io="$1"
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
    mount | grep juice | grep -q "max_read=" || { log "ERROR: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
    log "Mounted with --max-fuse-io ${fuse_io:-default} | $(mount | grep juice | grep -o 'max_read=[0-9]*')"
}

run_monitored() {
    local label="$1"
    local subdir="${RESULTS_DIR}/${label}"
    mkdir -p "${subdir}"
    
    drop_caches
    
    # NIC monitor
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) > "${subdir}/nic.txt" &
    local nic_pid=$!
    
    # juicefs stats
    local jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1)
    ( while true; do
        echo "------ $(date +%H:%M:%S) ------"
        juicefs stats "${MNT}" 2>/dev/null || true
        sleep 1
    done ) > "${subdir}/jfs-stats.txt" &
    local stats_pid=$!
    
    shift
    eval "$*" 2>&1 | tee "${subdir}/fio.txt"
    
    kill $nic_pid $stats_pid 2>/dev/null || true
    wait $nic_pid $stats_pid 2>/dev/null || true
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    
    # Extract key metrics
    local bw=$(grep -oE 'bw=[0-9]+MiB' "${subdir}/fio.txt" | head -1 | grep -oE '[0-9]+')
    local slat=$(grep -oE 'slat \(usec\):.*avg=[0-9.]+' "${subdir}/fio.txt" | head -1 | grep -oE 'avg=[0-9.]+' | grep -oE '[0-9.]+')
    local clat=$(grep -oE 'clat \((usec|nsec)\):.*avg=[0-9.]+' "${subdir}/fio.txt" | head -1 | grep -oE 'avg=[0-9.]+' | grep -oE '[0-9.]+')
    log "${label}: BW=${bw} MiB/s, slat=${slat}μs, clat=${clat}"
}

# === Test values ===
VALUES=("128K" "256K" "512K" "1M")

for val in "${VALUES[@]}"; do
    log "=========================================="
    log "=== Testing --max-fuse-io ${val} ==="
    log "=========================================="
    
    # --- randread (needs layout) ---
    setup_pool_mount "$val"
    
    log "Layout 128G..."
    fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G --bs=4M \
        --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio \
        --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
    compact_cooldown
    log "Layout done"
    
    run_monitored "randread-${val}" \
        "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=128 --group_reporting \
        --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randread-${val}' --log_avg_msec=1000"
    
    # --- randwrite-true (fresh volume) ---
    setup_pool_mount "$val"
    
    run_monitored "randwrite-${val}" \
        "fio --directory='${TEST_DIR}' --name=storage_test --nrfiles=100 --filesize=1G --size=1G \
        --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log='${BW_LOG_DIR}/randwrite-${val}' --log_avg_msec=1000"
    
    compact_cooldown
done

# === Summary ===
log "=========================================="
log "=== SUMMARY ==="
log "=========================================="
log "| max-fuse-io | randread BW | randread slat | randwrite BW | randwrite slat |"
log "|-------------|-------------|---------------|-------------|-----------------|"
for val in "${VALUES[@]}"; do
    r_bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/randread-${val}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    r_slat=$(grep -oE 'slat \(usec\):.*avg=[0-9.]+' "${RESULTS_DIR}/randread-${val}/fio.txt" 2>/dev/null | head -1 | grep -oE 'avg=[0-9.]+$' | grep -oE '[0-9.]+')
    w_bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/randwrite-${val}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    w_slat=$(grep -oE 'slat \(usec\):.*avg=[0-9.]+' "${RESULTS_DIR}/randwrite-${val}/fio.txt" 2>/dev/null | head -1 | grep -oE 'avg=[0-9.]+$' | grep -oE '[0-9.]+')
    log "| ${val} | ${r_bw:-N/A} | ${r_slat:-N/A} | ${w_bw:-N/A} | ${w_slat:-N/A} |"
done

# Network analysis
log ""
log "=== Network TX/RX (steady median MB/s) ==="
for val in "${VALUES[@]}"; do
    for mode in randread randwrite; do
        python3 -c "
import statistics
lines = []
prev = None
with open('${RESULTS_DIR}/${mode}-${val}/nic.txt') as f:
    for line in f:
        parts = line.strip().split('|')
        if len(parts) < 2: continue
        ts = int(parts[0])
        fields = parts[1].strip().split()
        rx = int(fields[1]); tx = int(fields[9])
        if prev:
            dt = ts - prev[0]
            if dt > 0:
                lines.append((ts, (rx-prev[1])/dt/1048576, (tx-prev[2])/dt/1048576))
        prev = (ts, rx, tx)
if lines:
    n = len(lines)
    steady = lines[n//4:]
    rx_med = round(statistics.median([l[1] for l in steady]), 1)
    tx_med = round(statistics.median([l[2] for l in steady]), 1)
    print(f'${mode}-${val}: RX={rx_med} MB/s, TX={tx_med} MB/s')
else:
    print(f'${mode}-${val}: N/A')
" 2>/dev/null || log "${mode}-${val}: N/A"
    done
done

log "Script completed"
