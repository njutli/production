#!/bin/bash
set -e

# Monitoring test: randread + randwrite with memory/network/juicefs stats
# Purpose: verify whether pagecache or buffer affects write > read phenomenon

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw-mon"
RESULTS_DIR="/tmp/opencode-monitor-test"
NIC_IF="enp139s0f0np0"
JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-readahead 0 --max-fuse-io 1M"

mkdir -p "${RESULTS_DIR}"
rm -rf "${BW_LOG_DIR}" 2>/dev/null
mkdir -p "${BW_LOG_DIR}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- cleanup + remount ---
cleanup_mount() {
    log "Cleaning up + remounting..."
    fusermount -u "${MNT}" 2>/dev/null || true
    fusermount -uz "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 3
    juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -2
    sleep 3
    mount | grep juice | grep -q max_read=1048576 || { echo "ERROR: max_read not 1M!"; exit 1; }
    log "Mounted OK (max_read=1M)"
}

# --- start monitors ---
start_monitors() {
    local label="$1"
    local subdir="${RESULTS_DIR}/${label}"
    mkdir -p "${subdir}"

    # 1. /proc/meminfo (pagecache)
    ( while true; do
        echo "$(date +%s) | $(grep -E '^Cached:|^Buffers:|^MemFree:|^MemAvailable:' /proc/meminfo | tr '\n' '|')"
        sleep 1
    done ) > "${subdir}/meminfo.txt" &
    MEM_PID=$!

    # 2. JuiceFS process VmRSS
    JFS_PID=$(pgrep -f 'juicefs.*mount' | head -1)
    ( while true; do
        echo "$(date +%s) | $(grep -E 'VmRSS|VmSize|Threads' /proc/${JFS_PID}/status 2>/dev/null | tr '\n' '|')"
        sleep 1
    done ) > "${subdir}/jfs-mem.txt" &
    JFS_MEM_PID=$!

    # 3. juicefs stats (buf/mem/fuse/object)
    ( while true; do
        echo "------ $(date +%H:%M:%S) ------"
        juicefs stats "${MNT}" 2>/dev/null || true
        sleep 1
    done ) > "${subdir}/jfs-stats.txt" &
    STATS_PID=$!

    # 4. Network RX/TX
    ( while true; do
        echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"
        sleep 1
    done ) > "${subdir}/nic.txt" &
    NIC_PID=$!

    # 5. free -m
    ( while true; do
        echo "$(date +%s) | $(free -m | grep Mem)"
        sleep 1
    done ) > "${subdir}/free.txt" &
    FREE_PID=$!
}

stop_monitors() {
    kill ${MEM_PID} ${JFS_MEM_PID} ${STATS_PID} ${NIC_PID} ${FREE_PID} 2>/dev/null || true
    wait ${MEM_PID} ${JFS_MEM_PID} ${STATS_PID} ${NIC_PID} ${FREE_PID} 2>/dev/null || true
}

# --- run fio + collect ---
run_monitored_fio() {
    local label="$1"
    local subdir="${RESULTS_DIR}/${label}"
    shift

    log "Starting ${label}..."
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    mkdir -p "${subdir}"

    # Record baseline before test
    echo "=== BEFORE ===" > "${subdir}/fio.txt"
    free -m >> "${subdir}/fio.txt"
    grep '^Cached:' /proc/meminfo >> "${subdir}/fio.txt"
    echo "===" >> "${subdir}/fio.txt"

    start_monitors "${label}"
    eval "$*" 2>&1 | tee -a "${subdir}/fio.txt"
    stop_monitors

    # Copy bw logs
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true

    # Record after test
    echo "=== AFTER ===" >> "${subdir}/fio.txt"
    free -m >> "${subdir}/fio.txt"
    grep '^Cached:' /proc/meminfo >> "${subdir}/fio.txt"

    log "${label} done"
}

# === Setup ===
cleanup_mount

# === Layout 128G ===
log "=== Layout 128G ==="
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none \
    --direct=1 --ioengine=libaio --iodepth=128 \
    --group_reporting --end_fsync=1 >/dev/null 2>&1
log "Layout done"

# Compact cooldown
for asok in /var/run/ceph/4f4e3ca0-8297-11f1-a671-97520597268c/ceph-osd.*.asok; do
    [ -S "$asok" ] || continue
    sudo ceph --admin-daemon "$asok" compact 2>/dev/null || true
done
sleep 10
log "Compact cooldown done"

# === Test 1: randread (reuse layout) ===
run_monitored_fio "randread" \
    "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randread' --log_avg_msec=1000"

# === Remount between read and write tests ===
cleanup_mount

# === Test 2: randwrite (fresh volume) ===
# Need fresh volume for randwrite to test true random write, not overwrite
log "=== Fresh volume for randwrite ==="
fusermount -u "${MNT}" 2>/dev/null || true
pkill -f 'juicefs.*mount' 2>/dev/null || true
sleep 5
sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it 2>/dev/null
sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
sleep 10
juicefs format --storage ceph --bucket ceph://juicefs-data --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 --force "${META}" juicefs-prod 2>&1 | tail -2
juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -2
sleep 3
mount | grep juice | grep -q max_read=1048576 && log "Remounted OK for randwrite" || { echo "ERROR"; exit 1; }

mkdir -p "${TEST_DIR}"
run_monitored_fio "randwrite" \
    "fio --directory='${TEST_DIR}' --name=storage_test --nrfiles=100 --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randwrite' --log_avg_msec=1000"

# === Analysis ===
log "=== ALL TESTS DONE ==="
log "Results in ${RESULTS_DIR}"

# Quick summary
python3 << 'PYEOF'
import os, glob, statistics
from collections import defaultdict

results_dir = "/tmp/opencode-monitor-test"

def parse_bw_logs(subdir, has_write=False):
    bw_files = glob.glob(os.path.join(subdir, "*_bw.*.log"))
    if not bw_files:
        return None, None
    ts_dir = defaultdict(lambda: [0, 0])
    for f in bw_files:
        for line in open(f):
            parts = line.strip().split(',')
            if len(parts) < 3: continue
            sec = int(parts[0]) // 1000
            bw = float(parts[1])
            d = int(parts[2])
            ts_dir[sec][d] += bw
    read_vals = [v[0] for v in sorted(ts_dir.values()) if v[0] > 0]
    write_vals = [v[1] for v in sorted(ts_dir.values()) if v[1] > 0]
    def median(vals):
        if not vals: return None
        n = len(vals)
        steady = vals[n//4:]
        return round(statistics.median(steady)/1024, 1) if steady else None
    return median(read_vals), median(write_vals)

def parse_nic(subdir):
    """Parse NIC RX/TX bytes per second, return avg MB/s"""
    lines = []
    with open(os.path.join(subdir, "nic.txt")) as f:
        prev = None
        for line in f:
            parts = line.strip().split('|')
            if len(parts) < 2: continue
            ts = int(parts[0])
            fields = parts[1].strip().split()
            # Find RX bytes and TX bytes
            rx_bytes = int(fields[1])
            tx_bytes = int(fields[9])
            if prev:
                dt = ts - prev[0]
                if dt > 0:
                    rx_mbps = (rx_bytes - prev[1]) / dt / 1024 / 1024
                    tx_mbps = (tx_bytes - prev[2]) / dt / 1024 / 1024
                    lines.append((ts, rx_mbps, tx_mbps))
            prev = (ts, rx_bytes, tx_bytes)
    if not lines: return None, None
    # Cut first 1/4, take median
    n = len(lines)
    steady = lines[n//4:]
    rx_med = round(statistics.median([l[1] for l in steady]), 1)
    tx_med = round(statistics.median([l[2] for l in steady]), 1)
    return rx_med, tx_med

def parse_meminfo(subdir):
    """Parse Cached value, return before/after/during"""
    vals = []
    with open(os.path.join(subdir, "meminfo.txt")) as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) < 2: continue
            ts = parts[0]
            for field in parts[1:]:
                field = field.strip()
                if field.startswith('Cached:'):
                    cached_kb = int(field.split(':')[1].strip().replace(' kB',''))
                    vals.append((int(ts), cached_kb / 1024))  # MB
    if not vals: return None, None, None
    before = vals[0][1]
    after = vals[-1][1]
    n = len(vals)
    steady_med = round(statistics.median([v[1] for v in vals[n//4:]]), 1)
    delta = round(after - before, 1)
    return before, after, delta

for label in ["randread", "randwrite"]:
    subdir = os.path.join(results_dir, label)
    if not os.path.isdir(subdir):
        print(f"{label}: N/A")
        continue
    read_med, write_med = parse_bw_logs(subdir)
    rx_med, tx_med = parse_nic(subdir)
    cached_before, cached_after, cached_delta = parse_meminfo(subdir)
    
    print(f"\n=== {label} ===")
    if read_med: print(f"  fio steady median (read):  {read_med} MiB/s")
    if write_med: print(f"  fio steady median (write): {write_med} MiB/s")
    if rx_med: print(f"  Network RX (from OSD):      {rx_med} MB/s")
    if tx_med: print(f"  Network TX (to OSD):        {tx_med} MB/s")
    if cached_before is not None:
        print(f"  Pagecache Cached: before={cached_before} MB, after={cached_after} MB, delta={cached_delta} MB")

PYEOF

log "Script completed"
