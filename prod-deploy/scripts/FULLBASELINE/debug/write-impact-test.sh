#!/bin/bash
set -euo pipefail

# write-impact-test.sh — 写操作对读布局影响实验
#
# Phase 0: 一次性 layout（prep 全部数据 ~260G）
# Phase 1: 读基线 ×10（seqread + mseqread + randread）
# Phase 2: seqwrite ×10 → randread ×3 检查
# Phase 3: randrw ×10 → randread ×3 检查
# Phase 4: randwrite ×10 → randread ×3 检查
# Phase 5: mseqwrite ×10 → randread ×3 检查
# Phase 6: 写后读 ×10（seqread + mseqread + randread）
#
# 用法（在 157 上运行）：
#   bash write-impact-test.sh dry-run     # Dry-run（1G layout, 10s runtime, 1 轮）
#   bash write-impact-test.sh phase0     # 只跑 Phase 0（layout）
#   bash write-impact-test.sh phase1     # 只跑 Phase 1
#   bash write-impact-test.sh all        # 全量跑（Phase 0-6）
#
# 遵循：SYSTEM-SAFETY-SKILL.md
#   §2.2 set -euo pipefail ✅
#   §2.3 路径守卫 safety_check() ✅
#   §2.4 dry-run 先行 ✅
#   §1.3 sudo 写操作已确认（drop_caches + ceph tell compact）✅
# 全程不 destroy、不 format（Phase 0 后）、不 rm -rf（Phase 0 后）、不 restart OSD

# ===== 配置 =====
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS_DIR="/tmp/opencode-write-impact"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"
NIC_IF="enp139s0f0np0"
POOL_DATA="juicefs-data"

MODE="${1:-dry-run}"
RUNTIME=180
ROUNDS=10
CHECK_ROUNDS=3

if [ "${MODE}" = "dry-run" ]; then
    RUNTIME=10
    ROUNDS=1
    CHECK_ROUNDS=1
    LAYOUT_JOBS=1
    LAYOUT_SIZE="1G"
    SEQ_SIZE="128M"
    MSEQ_JOBS=1
    MSEQ_SIZE="128M"
else
    LAYOUT_JOBS=128
    LAYOUT_SIZE="1G"
    SEQ_SIZE="4G"
    MSEQ_JOBS=16
    MSEQ_SIZE="4G"
fi

mkdir -p "${RESULTS_DIR}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/test.log"; }

# ===== 路径守卫（SYSTEM-SAFETY-SKILL §2.3）=====
safety_check() {
    local target="$1"
    [ -n "$target" ] || { echo "REFUSE: empty path"; exit 1; }
    [ "$target" != "/" ] || { echo "REFUSE: root path"; exit 1; }
    [ "${target:0:1}" = "/" ] || { echo "REFUSE: relative path"; exit 1; }
}

# ===== Helpers =====

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    for ip in "${SLAVES[@]}"; do
        ${SSHPASS_CMD}@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null || true
    done
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

compact_cooldown() {
    local osd_list
    osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    for osd in ${osd_list}; do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    local done_ok=false
    for i in $(seq 1 60); do
        local all_done=true
        for osd in ${osd_list}; do
            local running queued
            read -r running queued < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c \
                'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "0 0")
            [ "$running" != "0" ] && all_done=false
            [ "$queued" != "0" ] && all_done=false
        done
        $all_done && { done_ok=true; break; }
        sleep 5
    done
    $done_ok && log "  compact_cooldown ✅ (~$((i*5))s)" || log "  ⚠️ compact_cooldown 超时"
}

# ===== Fio 运行器 =====

run_fio() {
    local label="$1"; shift
    local subdir="${RESULTS_DIR}/${label}"
    mkdir -p "${subdir}"
    drop_caches
    local load_pre
    load_pre=$(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)
    echo "load_pre: ${load_pre}" > "${subdir}/weka-load.txt"
    # NIC 采集
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) \
        > "${subdir}/nic.txt" & local nic_pid=$!
    # jfs-stats snapshot PRE（用 .stats 文件，非阻塞）
    local jfs_pid
    jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1 || true)
    if [ -n "${jfs_pid}" ]; then
        { echo "=== PRE $(date '+%H:%M:%S') ==="; sudo cat /proc/${jfs_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads' || true; timeout 5 cat /mnt/juicefs/.stats 2>/dev/null || echo "(.stats N/A)"; } > "${subdir}/jfs-stats-pre.txt"
    fi
    # fio
    log "  fio ${label}..."
    fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt" || true
    # jfs-stats snapshot POST
    if [ -n "${jfs_pid:-}" ]; then
        { echo "=== POST $(date '+%H:%M:%S') ==="; sudo cat /proc/${jfs_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads' || true; timeout 5 cat /mnt/juicefs/.stats 2>/dev/null || echo "(.stats N/A)"; } > "${subdir}/jfs-stats-post.txt"
    fi
    kill ${nic_pid} 2>/dev/null || true; wait ${nic_pid} 2>/dev/null || true
    echo "load_post: $(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)" >> "${subdir}/weka-load.txt"
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    local bw
    bw=$(grep -oE 'bw=[0-9.]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
    log "  ${label}: BW=${bw:-N/A} MiB/s"
}

# ===== Fio 命令模板 =====

do_seqread() {
    local label="$1"
    run_fio "${label}" --name=seqread --directory="${TEST_DIR}/seqread/" \
        --rw=read --refill_buffers --bs=256k --size=${SEQ_SIZE} \
        --direct=1 --ioengine=psync --iodepth=1 \
        --time_based --runtime=${RUNTIME}
}

do_mseqread() {
    local label="$1"
    run_fio "${label}" --name=mseqread --directory="${TEST_DIR}/mseqread/" \
        --rw=read --refill_buffers --bs=256k --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} \
        --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
        --time_based --runtime=${RUNTIME}
}

do_randread() {
    local label="$1"
    run_fio "${label}" --directory="${TEST_DIR}" --name=storage_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
        --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
        --group_reporting --time_based --runtime=${RUNTIME}
}

do_seqwrite() {
    local label="$1"
    run_fio "${label}" --name=seqwrite --directory="${TEST_DIR}/seqwrite/" \
        --rw=write --refill_buffers --bs=4M --size=${SEQ_SIZE} \
        --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1
}

do_mseqwrite() {
    local label="$1"
    run_fio "${label}" --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" \
        --rw=write --refill_buffers --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} \
        --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1
}

do_randrw() {
    local label="$1"
    run_fio "${label}" --directory="${TEST_DIR}" --name=storage_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
        --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
        --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
        --group_reporting --time_based --runtime=${RUNTIME}
}

do_randwrite() {
    local label="$1"
    run_fio "${label}" --directory="${TEST_DIR}" --name=storage_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
        --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
        --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
        --group_reporting --time_based --runtime=${RUNTIME}
}

# ===== Phase 函数 =====

phase0_layout() {
    log "=== Phase 0: 一次性 layout ==="
    safety_check "${TEST_DIR}"
    # 清理旧数据（路径已守卫）
    rm -rf "${TEST_DIR}"/* 2>/dev/null || true
    mkdir -p "${TEST_DIR}/seqread" "${TEST_DIR}/seqwrite" "${TEST_DIR}/mseqread" "${TEST_DIR}/mseqwrite"
    # 1. 主 layout（128×1G 或 dry-run 1×1G）
    log "  layout: ${LAYOUT_JOBS}×${LAYOUT_SIZE} (bs=4M)"
    fio --directory="${TEST_DIR}" --name=storage_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=4M --rw=write \
        --numjobs=${LAYOUT_JOBS} --fallocate=none --direct=1 \
        --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
    # 2. seqread prep
    log "  seqread prep: ${SEQ_SIZE}"
    fio --name=seqread --directory="${TEST_DIR}/seqread/" \
        --rw=write --bs=4M --size=${SEQ_SIZE} --direct=1 >/dev/null 2>&1
    # 3. seqwrite prep
    log "  seqwrite prep: ${SEQ_SIZE}"
    fio --name=seqwrite --directory="${TEST_DIR}/seqwrite/" \
        --rw=write --bs=4M --size=${SEQ_SIZE} --direct=1 >/dev/null 2>&1
    # 4. mseqread prep
    log "  mseqread prep: ${MSEQ_JOBS}×${MSEQ_SIZE}"
    fio --name=mseqread --directory="${TEST_DIR}/mseqread/" \
        --rw=write --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --direct=1 >/dev/null 2>&1
    # 5. mseqwrite prep
    log "  mseqwrite prep: ${MSEQ_JOBS}×${MSEQ_SIZE}"
    fio --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" \
        --rw=write --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --direct=1 >/dev/null 2>&1
    compact_cooldown
    drop_caches
    # 变量守卫基线
    local crush_md5
    crush_md5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    echo "CRUSHMD5=${crush_md5}" > "${RESULTS_DIR}/guard-baseline.txt"
    log "  layout done. CRUSH md5=${crush_md5}"
    log "  test_dir contents: $(ls ${TEST_DIR}/ 2>/dev/null | head -5)..."
    log "  seqread: $(ls ${TEST_DIR}/seqread/ 2>/dev/null | wc -l) files"
    log "  mseqread: $(ls ${TEST_DIR}/mseqread/ 2>/dev/null | wc -l) files"
    log "  mseqwrite: $(ls ${TEST_DIR}/mseqwrite/ 2>/dev/null | wc -l) files"
}

phase_reads() {
    local phase_name="$1" start_round="$2" end_round="$3"
    log "=== ${phase_name}: reads ×$((end_round - start_round + 1)) ==="
    for r in $(seq ${start_round} ${end_round}); do
        log "--- ${phase_name} round ${r} ---"
        do_seqread "${phase_name}-seqread-${r}"
        do_mseqread "${phase_name}-mseqread-${r}"
        do_randread "${phase_name}-randread-${r}"
        compact_cooldown
    done
}

phase_write_with_check() {
    local phase_name="$1" write_fn="$2" start_round="$3" end_round="$4"
    log "=== ${phase_name}: writes ×$((end_round - start_round + 1)) ==="
    for r in $(seq ${start_round} ${end_round}); do
        log "--- ${phase_name} round ${r} ---"
        ${write_fn} "${phase_name}-${r}"
        compact_cooldown
    done
    # 中间读检查
    log "=== ${phase_name} 读检查 ×${CHECK_ROUNDS} ==="
    for r in $(seq 1 ${CHECK_ROUNDS}); do
        do_randread "${phase_name}-check-${r}"
        compact_cooldown
    done
}

phase1() { phase_reads "P1-reads" 1 ${ROUNDS}; }
phase2() { phase_write_with_check "P2-seqwrite" do_seqwrite 1 ${ROUNDS}; }
phase3() { phase_write_with_check "P3-randrw" do_randrw 1 ${ROUNDS}; }
phase4() { phase_write_with_check "P4-randwrite" do_randwrite 1 ${ROUNDS}; }
phase5() { phase_write_with_check "P5-mseqwrite" do_mseqwrite 1 ${ROUNDS}; }
phase6() { phase_reads "P6-post-reads" 1 ${ROUNDS}; }

summary() {
    log "=== 汇总 ==="
    for phase in P1-reads P2-seqwrite P2-seqwrite-check P3-randrw P3-randrw-check P4-randwrite P4-randwrite-check P5-mseqwrite P5-mseqwrite-check P6-post-reads; do
        local label_dir="${RESULTS_DIR}/${phase}"
        if [ -d "${label_dir}" ]; then
            for f in "${label_dir}"/*/fio.txt "${label_dir}"/fio.txt; do
                [ -f "$f" ] || continue
                local bw
                bw=$(grep -oE 'bw=[0-9]+MiB' "$f" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
                local name
                name=$(basename "$(dirname "$f")")
                [ "$name" = "." ] && name=$(basename "$f" .txt)
                log "  ${name}: ${bw:-NA} MiB/s"
            done
        fi
    done
    # 变量守卫复查
    local crush_md5
    crush_md5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    local base_md5
    base_md5=$(grep '^CRUSHMD5=' "${RESULTS_DIR}/guard-baseline.txt" 2>/dev/null | cut -d= -f2-)
    [ "${crush_md5}" = "${base_md5}" ] && log "  ✅ CRUSH md5 不变 (${crush_md5})" || log "  🔴 CRUSH md5 变了! ${base_md5} -> ${crush_md5}"
    log "=== DONE ==="
}

# ===== 主入口 =====

log "============================================"
log "=== 写操作对读布局影响实验 mode=${MODE} ==="
log "=== runtime=${RUNTIME}s rounds=${ROUNDS} check=${CHECK_ROUNDS} ==="
log "=== layout=${LAYOUT_JOBS}×${LAYOUT_SIZE} seq=${SEQ_SIZE} mseq=${MSEQ_JOBS}×${MSEQ_SIZE} ==="
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || { log "ERROR: health 非 OK，放弃"; exit 1; }
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (期望 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全"; exit 1; }

case "${MODE}" in
    dry-run)
        log "=== DRY-RUN 模式（1G layout, 10s runtime, 1 轮）==="
        phase0_layout
        phase_reads "P1-dry" 1 1
        do_randrw "dry-randrw-1"
        do_randwrite "dry-randwrite-1"
        do_seqwrite "dry-seqwrite-1"
        do_mseqwrite "dry-mseqwrite-1"
        phase_reads "P6-dry" 1 1
        summary
        log "=== DRY-RUN 完成，检查输出无误后用 'all' 跑全量 ==="
        ;;
    phase0)  phase0_layout ;;
    phase1)  phase1 ;;
    phase2)  phase2 ;;
    phase3)  phase3 ;;
    phase4)  phase4 ;;
    phase5)  phase5 ;;
    phase6)  phase6 ;;
    all)
        phase0_layout
        phase1
        phase2
        phase3
        phase4
        phase5
        phase6
        summary
        ;;
    summary) summary ;;
    *)
        echo "用法: $0 {dry-run|phase0|phase1|phase2|phase3|phase4|phase5|phase6|all|summary}"
        exit 1
        ;;
esac
