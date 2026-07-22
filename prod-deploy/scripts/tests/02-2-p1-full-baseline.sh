#!/bin/bash
set -e

# 02-2 P1 Full baseline (9 items × REPEAT=3, A→B with OSD restart)
# Follows skills: TESTING-GUIDE, test-commands-reference, baseline-reproduction-skill

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS_DIR="/tmp/opencode-02-2-p1"
NIC_IF="enp139s0f0np0"
REPEAT=3
ROUND="${1:-1}"
GROUP="${2:-A}"   # A, B, A2, B2, etc. (label + readahead derived from prefix)
MODE="${3:-full}"  # "full" = A→cleanup→B; "single" = only one group

# Derive label and readahead from GROUP prefix
LABEL="${GROUP}"
case "${GROUP}" in
    A*) RA="default" ;;
    B*) RA="ra0" ;;
    *)  RA="default" ;;
esac

mkdir -p "${RESULTS_DIR}/round-${ROUND}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/round-${ROUND}/test.log"; }

# === Helpers ===
drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    # Also drop caches on all OSD nodes (150-152)
    for slave_ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
        sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise@${slave_ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null || true
    done
    rm -f ${BW_LOG_DIR}/* 2>/dev/null || true
}

compact_cooldown() {
    # Dynamically get OSD IDs (don't hardcode)
    local osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    for osd in ${osd_list}; do sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    for i in $(seq 1 30); do
        all_done=true; for osd in ${osd_list}; do
            running=$(sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("rocksdb",{}).get("compact_running",0))' 2>/dev/null || echo "1")
            [ "$running" != "0" ] && all_done=false
        done; $all_done && break; sleep 5
    done
}

clean_volume() {
    log "=== 清卷 (juicefs destroy) ==="
    fusermount -u "${MNT}" 2>/dev/null || true; pkill -f 'juicefs.*mount' 2>/dev/null || true; sleep 5
    sleep 65
    UUID=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    [ -n "${UUID}" ] && juicefs destroy "${META}" "${UUID}" --yes 2>&1 | tail -1
    compact_cooldown
    sleep 10
}

mount_jfs() {
    local readahead="$1"; local label="$2"
    local opts="--max-uploads 150 --cache-size 0"
    [ "$readahead" = "ra0" ] && opts="$opts --max-readahead 0"
    juicefs format --storage ceph --bucket ceph://juicefs-data --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 --force "${META}" juicefs-prod 2>/dev/null | tail -1
    for try in 1 2 3; do
        local mount_output
        mount_output=$(juicefs mount -d $opts "${META}" "${MNT}" 2>&1)
        echo "$mount_output" | tail -1
        sleep 3
        mount | grep juice | grep -q "max_read=" && break
        log "mount attempt ${try} failed, collecting diagnostics..."
        log "  mount output: ${mount_output}"
        log "  juicefs status: $(juicefs status "${META}" 2>&1 | head -5)"
        log "  pool exists: $(sudo ceph osd pool ls 2>/dev/null | grep juicefs-data || echo NO)"
        log "  ceph health: $(sudo ceph health 2>/dev/null)"
        log "  TiKV reachable: $(juicefs status "${META}" 2>&1 | head -1)"
        log "  fusermount status: $(fusermount -u "${MNT}" 2>&1 || true)"
        sleep 10
    done
    mount | grep juice | grep -q "max_read=" || { log "ERROR: mount failed after 3 retries"; exit 1; }
    mkdir -p "${TEST_DIR}"
    log "Mounted ${label} (max_read=$(mount | grep juice | grep -o 'max_read=[0-9]*'))"
}

run_fio() {
    local label="$1"; local subdir="${RESULTS_DIR}/round-${ROUND}/${label}"; mkdir -p "${subdir}"
    log "Starting ${label}..."
    drop_caches
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) > "${subdir}/nic.txt" & local nic_pid=$!
    shift; eval "$*" 2>&1 | tee "${subdir}/fio.txt"
    kill ${nic_pid} 2>/dev/null || true; wait ${nic_pid} 2>/dev/null || true
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true; rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    local bw=$(grep -oE 'bw=[0-9]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    log "${label}: BW=${bw:-N/A} MiB/s"
}

run_group() {
    local readahead="$1"; local label="$2"

    # === Sequential tests (REPEAT=1) ===
    log "=== ${label}: seqread ==="
    rm -rf "${TEST_DIR}/seqread"; mkdir -p "${TEST_DIR}/seqread"
    fio --name=prep --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=4G >/dev/null 2>&1
    run_fio "seqread-${label}" "fio --name=seqread --directory='${TEST_DIR}/seqread/' --rw=read --refill_buffers --bs=256k --size=4G --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/seqread-${label}' --log_avg_msec=1000"

    log "=== ${label}: seqwrite ==="
    rm -rf "${TEST_DIR}/seqwrite"; mkdir -p "${TEST_DIR}/seqwrite"
    run_fio "seqwrite-${label}" "fio --name=seqwrite --directory='${TEST_DIR}/seqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/seqwrite-${label}' --log_avg_msec=1000"

    log "=== ${label}: mseqread ==="
    rm -rf "${TEST_DIR}/mseqread"; mkdir -p "${TEST_DIR}/mseqread"
    fio --name=prep --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
    run_fio "mseqread-${label}" "fio --name=mseqread --directory='${TEST_DIR}/mseqread/' --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/mseqread-${label}' --log_avg_msec=1000"

    log "=== ${label}: mseqwrite ==="
    rm -rf "${TEST_DIR}/mseqwrite"; mkdir -p "${TEST_DIR}/mseqwrite"
    run_fio "mseqwrite-${label}" "fio --name=mseqwrite --directory='${TEST_DIR}/mseqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/mseqwrite-${label}' --log_avg_msec=1000"

    # === Clean volume → randwrite-true ×3 ===
    clean_volume
    mount_jfs "${readahead}" "${label}"
    for r in $(seq 1 ${REPEAT}); do
        run_fio "randwrite-true-${label}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --nrfiles=100 --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randwrite-true-${label}-r${r}' --log_avg_msec=1000"
        compact_cooldown
    done

    # === Clean volume → layout → randread ×3 → randrw ×3 → randwrite-ow ×3 ===
    clean_volume
    mount_jfs "${readahead}" "${label}"
    log "=== ${label}: layout ==="
    run_fio "layout-${label}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 --write_bw_log='${BW_LOG_DIR}/layout-${label}' --log_avg_msec=1000"
    compact_cooldown

    for r in $(seq 1 ${REPEAT}); do
        run_fio "randread-${label}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randread-${label}-r${r}' --log_avg_msec=1000"
    done

    for r in $(seq 1 ${REPEAT}); do
        run_fio "randrw-${label}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randrw-${label}-r${r}' --log_avg_msec=1000"
        compact_cooldown
    done

    for r in $(seq 1 ${REPEAT}); do
        run_fio "randwrite-ow-${label}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=180 --write_bw_log='${BW_LOG_DIR}/randwrite-ow-${label}-r${r}' --log_avg_msec=1000"
        compact_cooldown
    done
}

restart_osds() {
    log "=== Restart OSDs (clear cache) ==="
    for slave_ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
        sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise@${slave_ip} '
            for c in $(sudo podman ps --format "{{.Names}}" 2>/dev/null | grep osd); do sudo podman restart "$c" >/dev/null 2>&1; done
            for svc in $(systemctl list-units "ceph-osd@*" --no-legend 2>/dev/null | grep active | awk "{print \$1}"); do
                sudo systemctl reset-failed "$svc" 2>/dev/null || true
                sudo systemctl restart "$svc" 2>/dev/null || true
            done
        ' 2>/dev/null || true
    done
    log "Waiting for PG active+clean..."
    for i in $(seq 1 60); do
        pg_line=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
        echo "$pg_line" | grep -qE "unknown|not active|creating|peering|recovering|degraded|incomplete" || break
        sleep 5
    done
    log "OSD restart done"
}

full_cleanup() {
    log "=== FULL CLEANUP (A<->B switch, cannot skip) ==="
    # 1. Unmount JuiceFS
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5

    # 2. Delete + recreate Ceph pool (彻底清数据)
    log "Deleting pool juicefs-data..."
    sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it 2>/dev/null || true
    sleep 3
    log "Recreating pool juicefs-data (EC4+2, fast_read=true)..."
    sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
    sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
    sudo ceph osd pool set juicefs-data fast_read true 2>/dev/null
    sudo ceph osd pool application enable juicefs-data juicefs 2>/dev/null

    # 3. Restart all OSDs (clear BlueStore memory + RocksDB memtable)
    restart_osds

    # 4. drop_caches on all nodes (157 + 150-152)
    drop_caches

    # 5. compact_cooldown (dynamic OSD IDs)
    compact_cooldown

    # Verify pool config
    local fr=$(sudo ceph osd pool get juicefs-data fast_read 2>/dev/null | awk '{print $2}')
    log "Pool juicefs-data fast_read=${fr} (expected: 1)"

    log "=== FULL CLEANUP done ==="
}

# ============================================================
log "============================================"
log "=== P1 Round ${ROUND} (group=${GROUP}, mode=${MODE}) ==="
log "============================================"

# Pre-test health check (TESTING-GUIDE §1.1)
log "=== Pre-test health check ==="
HEALTH=$(sudo ceph health 2>/dev/null)
log "ceph health: ${HEALTH}"
if [ "${HEALTH}" != "HEALTH_OK" ]; then
    HEALTH_DETAIL=$(sudo ceph health detail 2>/dev/null | head -10)
    log "WARN: health not OK, checking if only stray daemons..."
    if echo "${HEALTH_DETAIL}" | grep -qE "stray|CEPHADM_FAILED_DAEMON|failed cephadm"; then
        log "Only stray/failed cephadm daemons (expected with mixed podman/systemd after rebuild), continuing"
    else
        log "ERROR: health not OK and not just stray daemons, aborting"
        exit 1
    fi
fi
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo "0")
log "OSDs up: ${OSD_UP} (expected: 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: not all OSDs up, aborting"; exit 1; }

if [ "${MODE}" = "single" ]; then
    # Single group mode: mount + run one group only
    mount_jfs "${RA}" "${LABEL}"
    run_group "${RA}" "${LABEL}"
else
    # Full mode: A → full_cleanup → B (original behavior)
    if [ "${GROUP}" = "B" ]; then
        FIRST_RA="ra0"; FIRST_LABEL="B"
        SECOND_RA="default"; SECOND_LABEL="A"
    else
        FIRST_RA="default"; FIRST_LABEL="A"
        SECOND_RA="ra0"; SECOND_LABEL="B"
    fi
    mount_jfs "${FIRST_RA}" "${FIRST_LABEL}"
    run_group "${FIRST_RA}" "${FIRST_LABEL}"
    full_cleanup
    mount_jfs "${SECOND_RA}" "${SECOND_LABEL}"
    run_group "${SECOND_RA}" "${SECOND_LABEL}"
fi

# Summary - dynamically find all labels in this round
log "=== P1 Round ${ROUND} DONE ==="
ALL_LABELS=$(ls -d "${RESULTS_DIR}/round-${ROUND}"/*/ 2>/dev/null | xargs -I{} basename {} | sed 's/-r[0-9]*$//' | sort -u | tr '\n' ' ')
log "Labels found: ${ALL_LABELS}"
for item in seqread seqwrite mseqread mseqwrite layout; do
    for label in ${ALL_LABELS}; do
        bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/round-${ROUND}/${item}-${label}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
        log "  ${item}-${label}: ${bw:-N/A} MiB/s"
    done
done
for item in randread randwrite-true randrw randwrite-ow; do
    for label in ${ALL_LABELS}; do
        for r in 1 2 3; do
            bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/round-${ROUND}/${item}-${label}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
            log "  ${item}-${label}-r${r}: ${bw:-N/A} MiB/s"
        done
    done
done
