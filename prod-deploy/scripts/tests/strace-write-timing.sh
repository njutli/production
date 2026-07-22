#!/bin/bash
set -e

# Use strace to trace /dev/fuse I/O timing for 128K vs 256K max_fuse_io
# Measures: read() time (from kernel) + processing time + write() time (to kernel)

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
RESULTS_DIR="/tmp/opencode-strace-test"

mkdir -p "${RESULTS_DIR}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Test function: mount with given max_fuse_io, run short randwrite, trace with strace
test_with_strace() {
    local fuse_io="$1" tag="$2"
    local mount_opts="--max-uploads 150 --cache-size 0 --max-readahead 0"
    [ -n "$fuse_io" ] && mount_opts="$mount_opts --max-fuse-io $fuse_io"

    log "=== Testing ${tag} (max_fuse_io=${fuse_io:-default}) ==="

    # Clean up
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it 2>/dev/null || true
    sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
    sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
    sudo ceph osd pool application enable juicefs-data juicefs 2>/dev/null
    sleep 10

    juicefs format --storage ceph --bucket ceph://juicefs-data \
        --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
        "${META}" juicefs-prod 2>/dev/null | tail -1
    juicefs mount -d $mount_opts "${META}" "${MNT}" 2>/dev/null | tail -1
    sleep 3
    mount | grep juice | grep -q "max_read=" || { log "ERROR: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"

    # Get JuiceFS PID and /dev/fuse fd
    local jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1)
    local fuse_fd=$(ls -la /proc/${jfs_pid}/fd/ 2>/dev/null | grep '/dev/fuse' | grep -oE 'fd->[0-9]+' | grep -oE '[0-9]+' || echo "3")
    log "JuiceFS PID=${jfs_pid}, /dev/fuse fd=${fuse_fd}"

    # Start strace (trace read/write on the fuse fd only)
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    strace -e trace=read,write -p ${jfs_pid} -T -t -o "${RESULTS_DIR}/strace-${tag}.log" 2>/dev/null &
    local strace_pid=$!
    sleep 2

    # Run 60s randwrite
    log "Starting fio randwrite (60s)..."
    fio --directory="${TEST_DIR}" --name=storage_test --nrfiles=100 --filesize=1G --size=1G \
        --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 \
        --group_reporting --time_based --runtime=60 2>&1 | tee "${RESULTS_DIR}/fio-${tag}.txt"
    log "fio done"

    # Stop strace
    kill ${strace_pid} 2>/dev/null || true
    wait ${strace_pid} 2>/dev/null || true
    log "strace stopped"

    # Extract key metrics from fio
    local bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/fio-${tag}.txt" | head -1 | grep -oE '[0-9]+')
    local slat=$(grep -oE 'slat \(usec\):.*avg=[0-9.]+' "${RESULTS_DIR}/fio-${tag}.txt" | head -1 | grep -oE 'avg=[0-9.]+$' | grep -oE '[0-9.]+')
    log "${tag}: BW=${bw:-N/A} MiB/s, slat=${slat:-N/A}μs"
}

# Analyze strace log
analyze_strace() {
    local tag="$1"
    local logfile="${RESULTS_DIR}/strace-${tag}.log"
    log "=== Analyzing ${tag} strace ==="

    python3 << PYEOF
import re
import statistics

logfile = "${logfile}"

# Parse strace lines: "HH:MM:SS.ffffff read(fd, ..., size) = ret <duration>"
# and "HH:MM:SS.ffffff write(fd, ..., size) = ret <duration>"
read_times = []   # read() durations
write_times = []  # write() durations
gaps = []         # time between read() return and next write() call

lines = []
with open(logfile) as f:
    for line in f:
        line = line.strip()
        # Extract timestamp, syscall, fd, size, duration
        m = re.match(r'(\d{2}:\d{2}:\d{2}\.\d+)\s+(\w+)\((\d+),.*?=\s*(\d+)\s*<(\d+\.\d+)>', line)
        if m:
            ts_str, syscall, fd, ret, dur = m.groups()
            ts = float(ts_str.split(':')[2])  # seconds part
            fd_num = int(fd)
            dur_s = float(dur)
            size = int(ret)
            lines.append((ts, syscall, fd_num, size, dur_s))

# Find the /dev/fuse fd (the one with largest read/write sizes)
fd_sizes = {}
for ts, syscall, fd, size, dur in lines:
    if syscall in ('read', 'write'):
        fd_sizes[fd] = fd_sizes.get(fd, 0) + size

fuse_fd = max(fd_sizes, key=fd_sizes.get) if fd_sizes else -1
print(f"FUSE fd: {fuse_fd}")

# Filter to FUSE fd only, pair read→write
fuse_ops = [(ts, syscall, size, dur) for ts, syscall, fd, size, dur in lines if fd == fuse_fd]

reads = []
writes = []
gaps = []
i = 0
while i < len(fuse_ops) - 1:
    ts1, op1, size1, dur1 = fuse_ops[i]
    ts2, op2, size2, dur2 = fuse_ops[i+1]
    if op1 == 'read' and op2 == 'write':
        reads.append(dur1 * 1e6)  # convert to μs
        writes.append(dur2 * 1e6)
        gaps.append((ts2 - ts1 - dur1) * 1e6)  # processing time
        i += 2
    else:
        i += 1

if not reads:
    print("No read→write pairs found")
else:
    # Cut first 25% (warmup)
    n = len(reads)
    start = n // 4
    r = reads[start:]
    w = writes[start:]
    g = gaps[start:]

    print(f"Pairs: {n} total, {len(r)} steady")
    print(f"read() avg:    {statistics.mean(r):.0f}μs  median: {statistics.median(r):.0f}μs")
    print(f"gap (process): {statistics.mean(g):.0f}μs  median: {statistics.median(g):.0f}μs")
    print(f"write() avg:   {statistics.mean(w):.0f}μs  median: {statistics.median(w):.0f}μs")
    total = [r[i] + g[i] + w[i] for i in range(len(r))]
    print(f"total avg:     {statistics.mean(total):.0f}μs  median: {statistics.median(total):.0f}μs")
    print(f"  read%:    {statistics.mean(r)/statistics.mean(total)*100:.1f}%")
    print(f"  process%: {statistics.mean(g)/statistics.mean(total)*100:.1f}%")
    print(f"  write%:   {statistics.mean(w)/statistics.mean(total)*100:.1f}%")
PYEOF
}

# Run tests
test_with_strace "" "128k"
analyze_strace "128k"

test_with_strace "256K" "256k"
analyze_strace "256k"

log "=== ALL DONE ==="
