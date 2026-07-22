#!/bin/bash
# strace write timing test for 128K and 256K max_fuse_io
# Runs on 157 directly

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
RESULTS_DIR="/tmp/opencode-strace-v2"
mkdir -p "${RESULTS_DIR}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

run_test() {
    local fuse_io="$1" tag="$2"
    local mount_opts="--max-uploads 150 --cache-size 0 --max-readahead 0"
    [ -n "$fuse_io" ] && mount_opts="$mount_opts --max-fuse-io $fuse_io"
    
    log "=== ${tag} (max_fuse_io=${fuse_io:-default}) ==="
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
        --force "${META}" juicefs-prod 2>/dev/null | tail -1
    juicefs mount -d $mount_opts "${META}" "${MNT}" 2>/dev/null | tail -1
    sleep 3
    mount | grep juice | grep -q "max_read=" || { log "ERROR: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
    
    # Find JuiceFS PID and FUSE fd
    local JFS_PID=""
    for pid in $(pgrep -f 'juicefs'); do
        if ls -la /proc/$pid/fd/ 2>/dev/null | grep -q '/dev/fuse'; then
            JFS_PID=$pid
            break
        fi
    done
    local FUSE_FD=$(ls -la /proc/${JFS_PID}/fd/ 2>/dev/null | grep '/dev/fuse' | head -1 | awk '{print $9}' | grep -oE '[0-9]+')
    log "PID=${JFS_PID} FUSE_FD=${FUSE_FD}"
    
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    
    # Start strace (foreground, with timeout)
    log "Starting strace + fio..."
    sudo timeout 35 strace -e trace=read,write -p ${JFS_PID} -tt -T -o "${RESULTS_DIR}/strace-${tag}.log" 2>"${RESULTS_DIR}/strace-${tag}-err.log" &
    local SP=$!
    sleep 3
    
    # Run 30s fio
    fio --directory="${TEST_DIR}" --name=storage_test --nrfiles=100 --filesize=1G --size=1G \
        --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 \
        --group_reporting --time_based --runtime=30 2>&1 | tee "${RESULTS_DIR}/fio-${tag}.txt"
    
    sleep 2
    wait $SP 2>/dev/null || true
    
    # Check strace output
    local lines=$(wc -l < "${RESULTS_DIR}/strace-${tag}.log" 2>/dev/null || echo 0)
    local err=$(cat "${RESULTS_DIR}/strace-${tag}-err.log" 2>/dev/null)
    log "strace: ${lines} lines, err: ${err:-none}"
    
    if [ "$lines" -gt 0 ] && [ -n "$FUSE_FD" ]; then
        log "FUSE fd=${FUSE_FD} reads: $(grep -c "read(${FUSE_FD}" "${RESULTS_DIR}/strace-${tag}.log" 2>/dev/null)"
        log "FUSE fd=${FUSE_FD} writes: $(grep -c "write(${FUSE_FD}" "${RESULTS_DIR}/strace-${tag}.log" 2>/dev/null)"
        
        # Analyze
        python3 << PYEOF
import re, statistics

logfile = "${RESULTS_DIR}/strace-${tag}.log"
fuse_fd = ${FUSE_FD}

reads = []  # (timestamp, duration_us, size)
writes = [] # (timestamp, duration_us, size)

with open(logfile) as f:
    for line in f:
        # Format: HH:MM:SS.ffffff syscall(fd, ..., size) = ret <duration>
        m = re.match(r'(\d{2}):(\d{2}):(\d{2})\.(\d+)\s+(\w+)\((\d+)', line)
        if not m: continue
        h, mi, s, us, syscall, fd = m.groups()
        fd = int(fd)
        if fd != fuse_fd: continue
        
        # Extract duration
        dur_m = re.search(r'<(\d+\.\d+)>\s*$', line)
        if not dur_m: continue
        dur = float(dur_m.group(1)) * 1e6  # to μs
        
        # Extract return value (size)
        ret_m = re.search(r'=\s*(\d+)\s*<', line)
        if not ret_m: continue
        size = int(ret_m.group(1))
        
        # Timestamp in seconds
        ts = int(h)*3600 + int(mi)*60 + int(s) + int(us)/1e6
        
        if syscall == 'read':
            reads.append((ts, dur, size))
        elif syscall == 'write':
            writes.append((ts, dur, size))

log("FUSE reads: %d, writes: %d" % (len(reads), len(writes)))

if not reads or not writes:
    print("Not enough data")
    exit()

# Pair read→write (find closest write after each read)
# Only pair large reads (FUSE WRITE requests, size > 10000)
large_reads = [(ts, dur, size) for ts, dur, size in reads if size > 10000]
log("Large reads (FUSE WRITE reqs): %d" % len(large_reads))

if not large_reads:
    # Try pairing all reads
    large_reads = reads

pairs = []
wi = 0
for rt, rd, rs in large_reads:
    # Find first write after this read
    while wi < len(writes) and writes[wi][0] < rt:
        wi += 1
    if wi < len(writes):
        wt, wd, ws = writes[wi]
        gap = wt - rt - rd/1e6  # processing time
        pairs.append((rd, gap*1e6, wd, rs))  # read_dur, gap, write_dur, read_size
        wi += 1

if not pairs:
    print("No pairs found")
    exit()

# Cut first 25%
n = len(pairs)
start = n // 4
steady = pairs[start:]

r_dur = [p[0] for p in steady]
gaps = [p[1] for p in steady]
w_dur = [p[2] for p in steady]
totals = [p[0] + p[1] + p[2] for p in steady]

print("Pairs: %d total, %d steady" % (n, len(steady)))
print("read() avg:    %.0f μs (median %.0f)" % (statistics.mean(r_dur), statistics.median(r_dur)))
print("gap (process): %.0f μs (median %.0f)" % (statistics.mean(gaps), statistics.median(gaps)))
print("write() avg:   %.0f μs (median %.0f)" % (statistics.mean(w_dur), statistics.median(w_dur)))
print("total avg:     %.0f μs (median %.0f)" % (statistics.mean(totals), statistics.median(totals)))
print("  read%%:    %.1f" % (statistics.mean(r_dur)/statistics.mean(totals)*100))
print("  process%%: %.1f" % (statistics.mean(gaps)/statistics.mean(totals)*100))
print("  write%%:   %.1f" % (statistics.mean(w_dur)/statistics.mean(totals)*100))
if steady:
    print("read size range: %d - %d" % (min(p[3] for p in steady), max(p[3] for p in steady)))
PYEOF
    fi
    
    # Extract fio BW and slat
    local bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/fio-${tag}.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    local slat=$(grep -oE 'slat \(usec\):.*avg=[0-9.]+' "${RESULTS_DIR}/fio-${tag}.txt" 2>/dev/null | head -1 | grep -oE 'avg=[0-9.]+$' | grep -oE '[0-9.]+')
    log "${tag}: BW=${bw:-N/A} slat=${slat:-N/A}μs"
}

run_test "" "128k"
run_test "256K" "256k"

log "=== ALL DONE ==="
