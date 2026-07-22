#!/bin/bash
set -e

# 4-item sequential test (seqread/seqwrite/mseqread/mseqwrite), ra0
# Follows skills/TESTING-GUIDE.md + skills/test-commands-reference.md

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
NIC_IF="enp139s0f0np0"

ROUND="${1:-A}"
RESULTS_DIR="/tmp/opencode-abcd-test/${ROUND}"
mkdir -p "${RESULTS_DIR}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/test.log"; }

# === Helper: SST check (skill §1.3 + skill draft §2.3) ===
sst_check() {
    log "=== SST check ==="
    for osd in 0 1 2 3 4 5; do
        log -n "  osd.${osd}: "
        sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('rocksdb',{})
cql=r.get('compact_queue_len','?')
cr=r.get('compact_running','?')
gl=r.get('get_latency',{})
ga=gl.get('avgtime','?')
status='OK' if cql==0 and cr==0 and ga<0.002 else 'WARN'
print(f'cq={cql} cr={cr} get_lat={ga:.6f}s [{status}]')
" 2>/dev/null || log "  osd.${osd}: ERROR"
    done
}

# === Helper: drop caches (skill §4.4) ===
drop_caches() {
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    rm -f ${BW_LOG_DIR}/* 2>/dev/null || true
}

# === Helper: compact cooldown (skill §3.2) ===
compact_cooldown() {
    log "Compact cooldown..."
    for osd in 0 1 2 3 4 5; do
        sudo ceph tell osd.${osd} compact 2>/dev/null || true
    done
    for i in $(seq 1 30); do
        all_done=true
        for osd in 0 1 2 3 4 5; do
            running=$(sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('rocksdb',{}).get('compact_running',0))" 2>/dev/null || echo "1")
            [ "$running" != "0" ] && all_done=false
        done
        $all_done && break
        sleep 5
    done
    log "Compact cooldown done"
}

# === Helper: health check (skill §1.1) ===
health_check() {
    local label="$1"
    local health=$(sudo ceph health 2>/dev/null | head -1)
    log "Health (${label}): ${health}"
    if [ "$health" != "HEALTH_OK" ]; then
        log "WARN: health not OK, waiting 60s..."
        sleep 60
        health=$(sudo ceph health 2>/dev/null | head -1)
        log "Health (retry): ${health}"
    fi
}

# === Helper: run fio + collect (skill §9) ===
run_fio() {
    local label="$1"
    local subdir="${RESULTS_DIR}/${label}"
    mkdir -p "${subdir}"

    log "Starting ${label}..."
    drop_caches
    health_check "${label}"

    # NIC monitor
    ( while true; do
        echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"
        sleep 1
    done ) > "${subdir}/nic.txt" &
    local nic_pid=$!

    # Run fio
    shift
    eval "$*" 2>&1 | tee "${subdir}/fio.txt"

    kill ${nic_pid} 2>/dev/null || true
    wait ${nic_pid} 2>/dev/null || true

    # Copy bw logs (skill §9.2)
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true

    # Verify per-job count (skill §10 red line 1)
    local bw_count=$(ls "${subdir}"/*_bw.*.log 2>/dev/null | wc -l)
    log "${label} done (bw_log files: ${bw_count})"
}

# ============================================================
# Pre-test: 轮间清理 (skill draft §2.4)
# ============================================================
log "============================================"
log "=== ROUND ${ROUND}: 轮间清理 + 4项测试 ==="
log "============================================"

# 1. Unmount JuiceFS
fusermount -u "${MNT}" 2>/dev/null || true
pkill -f 'juicefs.*mount' 2>/dev/null || true
sleep 5

# 2. Delete + recreate pool
log "Delete + recreate pool..."
sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it 2>/dev/null || true
sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
sudo ceph osd pool application enable juicefs-data juicefs 2>/dev/null

# 3. Restart all OSDs (on slave nodes)
log "Restarting OSDs..."
for slave_ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
    log "  Restarting OSDs on ${slave_ip}..."
    sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        sunrise@${slave_ip} 'for c in $(sudo podman ps --format "{{.Names}}" | grep osd); do sudo podman restart "$c" >/dev/null 2>&1; done' 2>/dev/null || true
done
log "Waiting for OSD recovery..."

# 4. Wait for all PGs active+clean (after OSD restart)
for i in $(seq 1 60); do
    pg_line=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
    log "  PG status: ${pg_line}"
    if ! echo "$pg_line" | grep -qE "unknown|not active|creating|peering|recovering|degraded|incomplete"; then
        log "  All PGs active+clean"
        break
    fi
    sleep 5
done
health_check "after OSD restart"

# 5. SST check
sst_check

# 5. Format + mount (ra0)
log "Format + mount (ra0)..."
juicefs format --storage ceph --bucket ceph://juicefs-data \
    --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
    --force "${META}" juicefs-prod 2>/dev/null | tail -1
juicefs mount -d --max-uploads 150 --cache-size 0 --max-readahead 0 "${META}" "${MNT}" 2>/dev/null | tail -1
sleep 3
mount | grep juice | grep -q "max_read=" || { log "ERROR: mount failed"; exit 1; }
mkdir -p "${TEST_DIR}"
log "Mounted OK"

# ============================================================
# Test items (skill test-commands-reference §4.1-4.5)
# ============================================================

# 1. seqread (skill §4.1: psync, 256k, 1 job, 180s)
log "=== 1/4: seqread ==="
rm -rf "${TEST_DIR}/seqread"; mkdir -p "${TEST_DIR}/seqread/"
fio --name=prep --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=4G >/dev/null 2>&1
run_fio "seqread" "fio --name=seqread --directory='${TEST_DIR}/seqread/' --rw=read --refill_buffers --bs=256k --size=4G --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/seqread' --log_avg_msec=1000"

# 2. seqwrite (skill §4.2: psync, 4M, 1 job, end_fsync)
log "=== 2/4: seqwrite ==="
rm -rf "${TEST_DIR}/seqwrite"; mkdir -p "${TEST_DIR}/seqwrite"
run_fio "seqwrite" "fio --name=seqwrite --directory='${TEST_DIR}/seqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/seqwrite' --log_avg_msec=1000"

# 3. mseqread (skill §4.4: psync, 256k, 16 jobs, 180s)
log "=== 3/4: mseqread ==="
rm -rf "${TEST_DIR}/mseqread"; mkdir -p "${TEST_DIR}/mseqread"
fio --name=prep --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=4G --numjobs=16 2>&1 | tail -3
prep_count=$(ls "${TEST_DIR}/mseqread/" 2>/dev/null | wc -l)
log "  prep created ${prep_count} files (expected 16)"
run_fio "mseqread" "fio --name=mseqread --directory='${TEST_DIR}/mseqread/' --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/mseqread' --log_avg_msec=1000"

# 4. mseqwrite (skill §4.5: psync, 4M, 16 jobs, end_fsync)
log "=== 4/4: mseqwrite ==="
rm -rf "${TEST_DIR}/mseqwrite"; mkdir -p "${TEST_DIR}/mseqwrite"
run_fio "mseqwrite" "fio --name=mseqwrite --directory='${TEST_DIR}/mseqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/mseqwrite' --log_avg_msec=1000"

# ============================================================
# Summary
# ============================================================
log "=== ROUND ${ROUND} DONE ==="
log "Results in ${RESULTS_DIR}"

# Extract BW + slat
for item in seqread seqwrite mseqread mseqwrite; do
    bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/${item}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    slat=$(grep -oE 'slat \(usec\):.*avg=[0-9.]+' "${RESULTS_DIR}/${item}/fio.txt" 2>/dev/null | head -1 | grep -oE 'avg=[0-9.]+$' | grep -oE '[0-9.]+')
    log "${item}: BW=${bw:-N/A} MiB/s, slat=${slat:-N/A}μs"
done

# Verify per-job files
log "=== Per-job verification ==="
for item in seqread seqwrite; do
    count=$(ls "${RESULTS_DIR}/${item}/"*_bw.*.log 2>/dev/null | wc -l)
    log "${item}: ${count}/1 $([ "$count" = "1" ] && echo OK || echo MISSING)"
done
for item in mseqread mseqwrite; do
    count=$(ls "${RESULTS_DIR}/${item}/"*_bw.*.log 2>/dev/null | wc -l)
    log "${item}: ${count}/16 $([ "$count" = "16" ] && echo OK || echo MISSING)"
done
