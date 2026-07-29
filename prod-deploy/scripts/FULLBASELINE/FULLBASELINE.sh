#!/bin/bash
set -euo pipefail

# FULLBASELINE.sh — JuiceFS/Ceph 全量 9 项基线测试（干净版）
# 口径：逐字复刻 weka-9item-test.sh 的 fio 参数，清卷用 juicefs destroy + compact
# 调试采集版见 FULLBASELINE-DEBUG.sh
#
# 用法：
#   ./FULLBASELINE.sh <LABEL> [RUNTIME] [REPEAT]
#   ./FULLBASELINE.sh softclean                 # 组间清理
#   ./FULLBASELINE.sh list                      # 列出可选项
#
# 参数（环境变量可覆盖）：
#   META        JuiceFS 元数据 URL
#   MNT         挂载点
#   TEST_DIR    测试目录
#   RESULTS     结果目录
#   RUNTIME     time_based 秒数（默认 180）
#   REPEAT      随机项轮数（默认 3）

META="${META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}"
MNT="${MNT:-/mnt/juicefs}"
TEST_DIR="${TEST_DIR:-${MNT}/test_dir}"
RESULTS="${RESULTS:-/tmp/opencode-fullbaseline}"
BW_LOG_DIR="/tmp/jfs-bw"
RUNTIME="${RUNTIME:-180}"
REPEAT="${REPEAT:-3}"
POOL_DATA="juicefs-data"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

ITEMS_ALL="seqread seqwrite mseqread mseqwrite randwrite-true layout randread randrw randwrite-ow"

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

# ===== helpers =====

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    for ip in "${SLAVES[@]}"; do
        $SSHPASS@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null || true
    done
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

compact_cooldown() {
    local osd_list
    osd_list=$(sudo ceph osd dump 2>/dev/null | python3 -c \
        "import sys,json;d=json.load(sys.stdin);print(' '.join(str(o['osd']) for o in d['osds'] if o['up']==1))" 2>/dev/null)
    for osd in ${osd_list}; do sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    for i in $(seq 1 120); do
        local all_done=true
        for osd in ${osd_list}; do
            local running queued
            read -r running queued < <(sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c \
                'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "0 0")
            [ "$running" != "0" ] && all_done=false
            [ "$queued" != "0" ] && all_done=false
        done
        $all_done && break
        sleep 5
    done
}

mount_jfs() {
    juicefs format --storage ceph --bucket ceph://${POOL_DATA} --access-key ceph \
        --secret-key client.juicefs --block-size 256K --trash-days 0 --force \
        "${META}" juicefs-prod 2>/dev/null | tail -1
    for try in 1 2 3; do
        juicefs mount -d --max-uploads 150 --cache-size 0 "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break
        sleep 10
    done
    mount | grep -q juice || { log "FATAL: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
}

clean_volume() {
    log "  组内清卷 (juicefs destroy + compact)"
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5; sleep 65
    local UUID
    UUID=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    [ -n "${UUID}" ] && juicefs destroy "${META}" "${UUID}" --yes 2>&1 | tail -1
    rados purge "${POOL_DATA}" --yes-i-really-really-mean-it 2>/dev/null || true
    compact_cooldown
}

restart_osds() {
    log "  restart OSD containers"
    for ip in "${SLAVES[@]}"; do
        $SSHPASS@${ip} \
            'for c in $(sudo podman ps --format "{{.Names}}" 2>/dev/null | grep osd); do sudo podman restart "$c" >/dev/null 2>&1; done' \
            2>/dev/null || true
    done
    for i in $(seq 1 120); do
        local pg
        pg=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
        echo "${pg}" | grep -qE "unknown|not active|creating|peering|recovering|degraded|incomplete" || break
        sleep 5
    done
    log "  OSDs active+clean"
}

soft_clean_restart() {
    log "=== SOFT-CLEAN + OSD-RESTART ==="
    clean_volume
    restart_osds
    compact_cooldown
    drop_caches
    sleep 30
}

run_fio() {
    local label="$1"; shift
    local subdir="${RESULTS}/${LABEL}/${label}"
    mkdir -p "${subdir}"
    drop_caches
    "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 2>&1 | tee "${subdir}/fio.txt"
    local bw
    bw=$(grep -oE 'bw=[0-9.]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || echo NA)
    log "  ${label}: BW=${bw} MiB/s"
}

# ===== 9 项定义 =====

item_seqread() {
    rm -rf "${TEST_DIR}/seqread"; mkdir -p "${TEST_DIR}/seqread"
    fio --name=prep --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=4G >/dev/null 2>&1
    run_fio "seqread-${LABEL}" fio --name=seqread --directory="${TEST_DIR}/seqread/" \
        --rw=read --refill_buffers --bs=256k --size=4G --direct=1 --ioengine=psync \
        --iodepth=1 --time_based --runtime="${RUNTIME}"
}

item_seqwrite() {
    rm -rf "${TEST_DIR}/seqwrite"; mkdir -p "${TEST_DIR}/seqwrite"
    run_fio "seqwrite-${LABEL}" fio --name=seqwrite --directory="${TEST_DIR}/seqwrite/" \
        --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 --direct=1 \
        --ioengine=psync --iodepth=1
}

item_mseqread() {
    rm -rf "${TEST_DIR}/mseqread"; mkdir -p "${TEST_DIR}/mseqread"
    fio --name=prep --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
    run_fio "mseqread-${LABEL}" fio --name=mseqread --directory="${TEST_DIR}/mseqread/" \
        --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting \
        --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime="${RUNTIME}"
}

item_mseqwrite() {
    rm -rf "${TEST_DIR}/mseqwrite"; mkdir -p "${TEST_DIR}/mseqwrite"
    run_fio "mseqwrite-${LABEL}" fio --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" \
        --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 \
        --group_reporting --direct=1 --ioengine=psync --iodepth=1
}

item_randwrite_true() {
    clean_volume; mount_jfs
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randwrite-true-${LABEL}-r${r}" \
            fio --directory="${TEST_DIR}" --name=storage_test --nrfiles=100 \
            --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio \
            --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --create_on_open=1 \
            --openfiles=128 --group_reporting --time_based --runtime="${RUNTIME}"
        compact_cooldown
    done
}

item_layout() {
    clean_volume; mount_jfs
    run_fio "layout-${LABEL}" \
        fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G \
        --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio \
        --iodepth=128 --group_reporting --end_fsync=1
    compact_cooldown
}

item_randread() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randread-${LABEL}-r${r}" \
            fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G \
            --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
            --direct=1 --fallocate=none --openfiles=128 --group_reporting \
            --time_based --runtime="${RUNTIME}"
    done
}

item_randrw() {
    for r in $(seq 1 "${REPEAT}"); do
        log "  randrw r${r}: rebuild layout"
        rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
        fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G \
            --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio \
            --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
        compact_cooldown
        run_fio "randrw-${LABEL}-r${r}" \
            fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G \
            --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
            --direct=1 --fallocate=none --openfiles=128 --group_reporting \
            --time_based --runtime="${RUNTIME}"
        compact_cooldown
    done
}

item_randwrite_ow() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randwrite-ow-${LABEL}-r${r}" \
            fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G \
            --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
            --direct=1 --fallocate=none --openfiles=128 --group_reporting \
            --time_based --runtime="${RUNTIME}"
        compact_cooldown
    done
}

run_group() {
    local LABEL="$1"
    log "=== ${LABEL}: seqread ==="; item_seqread
    log "=== ${LABEL}: seqwrite ==="; item_seqwrite
    log "=== ${LABEL}: mseqread ==="; item_mseqread
    log "=== ${LABEL}: mseqwrite ==="; item_mseqwrite
    log "=== ${LABEL}: randwrite-true ==="; item_randwrite_true
    log "=== ${LABEL}: layout ==="; item_layout
    log "=== ${LABEL}: randread ==="; item_randread
    log "=== ${LABEL}: randrw ==="; item_randrw
    log "=== ${LABEL}: randwrite-ow ==="; item_randwrite_ow
}

summary() {
    log "=== 汇总 ${LABEL} (fio bw, MiB/s) ==="
    for item in seqread seqwrite mseqread mseqwrite layout; do
        local bw
        bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/${item}-${LABEL}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
        log "  ${item}: ${bw:-NA}"
    done
    for item in randwrite-true randread randrw randwrite-ow; do
        local line="  ${item}:"
        for r in $(seq 1 "${REPEAT}"); do
            local bw
            bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/${item}-${LABEL}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
            line="${line} r${r}=${bw:-NA}"
        done
        log "${line}"
    done
}

# ===== 入口 =====

case "${1:-}" in
    ""|list)
        echo "用法: $0 <LABEL> [RUNTIME] [REPEAT]"
        echo "      $0 softclean"
        echo "可选项: ${ITEMS_ALL}"
        exit 0
        ;;
    softclean|clean)
        soft_clean_restart
        exit 0
        ;;
    *)
        LABEL="$1"; RUNTIME="${2:-${RUNTIME}}"; REPEAT="${3:-${REPEAT}}"
        ;;
esac

log "============================================"
log "=== FULLBASELINE label=${LABEL} runtime=${RUNTIME} repeat=${REPEAT} ==="
log "============================================"

# health check
HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || { log "WARN: not HEALTH_OK (${HEALTH}), continue anyway"; }

# mount + run
mount_jfs
run_group "${LABEL}"

# post checks
POST_CRUSH=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
log "post-run CRUSH md5: ${POST_CRUSH}"

summary
log "=== ${LABEL} DONE ==="
