#!/bin/bash
set -e

# Full baseline test with --max-fuse-io 1M
# ra0 (cold, cache=0, max-readahead=0)
# REPEAT=3 for random items

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw-128k"
RESULTS_DIR="/tmp/opencode-baseline-128k-ra0"
FSID="4f4e3ca0-8297-11f1-a671-97520597268c"
NIC_IF="enp139s0f0np0"
JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-readahead 0"

mkdir -p "${RESULTS_DIR}"
rm -rf "${BW_LOG_DIR}" 2>/dev/null
mkdir -p "${BW_LOG_DIR}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- helper: compact cooldown ---
compact_cooldown() {
    log "Compact cooldown..."
    for asok in /var/run/ceph/${FSID}/ceph-osd.*.asok; do
        [ -S "$asok" ] || continue
        sudo ceph --admin-daemon "$asok" compact 2>/dev/null || true
    done
    sleep 10
    log "Compact cooldown done"
}

# --- helper: drop caches ---
drop_caches() {
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
}

# --- helper: remount juicefs (for write test rounds) ---
remount_jfs() {
    log "Remounting JuiceFS..."
    fusermount -u "${MNT}" 2>/dev/null || true
    fusermount -uz "${MNT}" 2>/dev/null || true
    sleep 2
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 3
    juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1
    sleep 3
    mount | grep juice | grep -q max_read=131072 || { echo "ERROR: max_read not 128K!"; exit 1; }
    log "JuiceFS remounted OK (max_read=128K)"
}

# --- helper: run fio + collect data ---
run_fio() {
    local name="$1"
    local subdir="${RESULTS_DIR}/${name}"
    mkdir -p "${subdir}"

    log "Starting ${name}..."
    drop_caches

    # NIC monitor
    ( while true; do
        echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"
        sleep 1
    done ) > "${subdir}/nic-raw.txt" &
    local nic_pid=$!

    # juicefs stats
    local jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1)
    if [ -n "$jfs_pid" ]; then
        ( while true; do
            echo "------ $(date +%H:%M:%S) ------"
            sudo cat /proc/${jfs_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads'
            juicefs stats "${MNT}" 2>/dev/null || true
            sleep 1
        done ) > "${subdir}/jfs-stats.txt" &
        local stats_pid=$!
    fi

    # Run fio (passed as remaining args)
    shift
    eval "$*" 2>&1 | tee "${subdir}/fio.txt"

    kill ${nic_pid} 2>/dev/null || true
    kill ${stats_pid} 2>/dev/null || true
    wait ${nic_pid} 2>/dev/null || true
    wait ${stats_pid} 2>/dev/null || true

    # Copy bw logs
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true

    log "${name} done"
}

# === 1. Sequential Tests ===

# 1a. seqread prep
log "=== seqread prep ==="
mkdir -p "${TEST_DIR}/seqread/"
fio --name=prep --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=4G >/dev/null 2>&1

run_fio "seqread" "fio --name=seqread --directory='${TEST_DIR}/seqread/' --rw=read --refill_buffers --bs=256k --size=4G --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/seqread' --log_avg_msec=1000"

# 1b. seqwrite (fsync)
rm -rf "${TEST_DIR}/seqwrite"; mkdir -p "${TEST_DIR}/seqwrite"
run_fio "seqwrite" "fio --name=seqwrite --directory='${TEST_DIR}/seqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/seqwrite' --log_avg_msec=1000"

# 1c. mseqread prep
rm -rf "${TEST_DIR}/mseqread"; mkdir -p "${TEST_DIR}/mseqread"
fio --name=prep --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
run_fio "mseqread" "fio --name=mseqread --directory='${TEST_DIR}/mseqread/' --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/mseqread' --log_avg_msec=1000"

# 1d. mseqwrite
rm -rf "${TEST_DIR}/mseqwrite"; mkdir -p "${TEST_DIR}/mseqwrite"
run_fio "mseqwrite" "fio --name=mseqwrite --directory='${TEST_DIR}/mseqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/mseqwrite' --log_avg_msec=1000"

# === 2. Layout + Cooldown ===
log "=== Layout 128G ==="
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
run_fio "layout" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 --write_bw_log='${BW_LOG_DIR}/layout' --log_avg_msec=1000"

compact_cooldown

# === 3. randread ×3 (reuse layout) ===
for round in 1 2 3; do
    run_fio "randread-r${round}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randread-r${round}' --log_avg_msec=1000"
done

# === 4. randwrite analysis ×3 (reuse layout, remount between rounds) ===
for round in 1 2 3; do
    remount_jfs
    run_fio "randwrite-analysis-r${round}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randwrite-analysis-r${round}' --log_avg_msec=1000"
done

# === 5. randrw analysis ×3 (reuse layout, remount between rounds) ===
for round in 1 2 3; do
    remount_jfs
    run_fio "randrw-analysis-r${round}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randrw-analysis-r${round}' --log_avg_msec=1000"
done

# === 6. Done ===
log "=== ALL TESTS DONE ==="
log "Results in ${RESULTS_DIR}"

# Create summary
python3 << 'PYEOF'
import os, glob, statistics
from collections import defaultdict

results_dir = "/tmp/opencode-baseline-maxfuse1M"

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

def parse_fio_bw(subdir):
    fio_file = os.path.join(subdir, "fio.txt")
    if not os.path.exists(fio_file): return None
    with open(fio_file) as f:
        for line in f:
            if 'READ:' in line and 'bw=' in line:
                import re
                m = re.search(r'bw=(\d+)(MiB|MB)', line)
                if m:
                    return int(m.group(1))
    return None

items = {
    "seqread": ["seqread"],
    "seqwrite": ["seqwrite"],
    "mseqread": ["mseqread"],
    "mseqwrite": ["mseqwrite"],
    "layout": ["layout"],
    "randread": ["randread-r1", "randread-r2", "randread-r3"],
    "randwrite-analysis": ["randwrite-analysis-r1", "randwrite-analysis-r2", "randwrite-analysis-r3"],
    "randrw-analysis": ["randrw-analysis-r1", "randrw-analysis-r2", "randrw-analysis-r3"],
}

print("# Full Baseline with --max-fuse-io 1M (ra0, cold, cache=0)")
print(f"# Date: 2026-07-20")
print(f"# Results: {results_dir}")
print()
print("| Test Item | fio avg (MiB/s) | Steady median (MiB/s) |")
print("|-----------|:---:|:---:|")

for item, subdirs in items.items():
    for i, sd in enumerate(subdirs):
        subdir = os.path.join(results_dir, sd)
        if not os.path.isdir(subdir):
            print(f"| {sd} | N/A | N/A |")
            continue
        fio_bw = parse_fio_bw(subdir)
        read_med, write_med = parse_bw_logs(subdir)
        if item.startswith("randrw"):
            print(f"| {sd} | R:{fio_bw} | R:{read_med} W:{write_med} |")
        elif "write" in item:
            print(f"| {sd} | {fio_bw} | W:{write_med} |")
        else:
            print(f"| {sd} | {fio_bw} | R:{read_med} |")
    print()

PYEOF

log "Script completed"
