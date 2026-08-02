#!/bin/bash
set -euo pipefail

# randrw-stability-test.sh — randrw 覆盖写稳定性测试
#
# 验证加强清理（compact → sleep 30 → 再 compact）能否消除
# JuiceFS chunk 积累导致的 randrw 逐轮退化（原 42.1% 降幅）。
#
# 用法（在 157 上运行，需已有 layout 数据）：
#   bash randrw-stability-test.sh dry-run   # 10s runtime, 2 轮
#   bash randrw-stability-test.sh full      # 180s runtime, 10 轮
#
# 前提：TEST_DIR 已有 128×1G layout 数据（由 write-impact-test.sh Phase 0 创建）

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS_DIR="/tmp/opencode-randrw-stability"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
NIC_IF="enp139s0f0np0"

MODE="${1:-dry-run}"
RUNTIME=180
ROUNDS=10
if [ "${MODE}" = "dry-run" ]; then
    RUNTIME=10
    ROUNDS=2
fi

mkdir -p "${RESULTS_DIR}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/test.log"; }

# ===== Helpers =====

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    for ip in "${SLAVES[@]}"; do
        sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise@${ip} \
            'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null || true
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
    $done_ok && log "  compact ✅ (~$((i*5))s)" || log "  ⚠️ compact 超时"
}

# 加强清理：compact → sleep 30（等异步删除）→ 再 compact → drop_caches
aggressive_cleanup() {
    log "  aggressive_cleanup (compact → sleep 30 → compact → drop_caches)"
    compact_cooldown
    sleep 30
    compact_cooldown
    drop_caches
}

# ===== Fio runner =====

run_randrw() {
    local round="$1"
    local subdir="${RESULTS_DIR}/randrw-${round}"
    mkdir -p "${subdir}"
    drop_caches
    local load_pre
    load_pre=$(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)
    echo "load_pre: ${load_pre}" > "${subdir}/weka-load.txt"
    # NIC 采集
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) \
        > "${subdir}/nic.txt" & local nic_pid=$!
    # fio randrw（覆盖写，128 jobs）
    log "  fio randrw round ${round}..."
    fio --directory="${TEST_DIR}" --name=storage_test \
        --filesize=1G --size=1G \
        --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=${RUNTIME} \
        --write_bw_log="${BW_LOG_DIR}/randrw-${round}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt" || true
    kill ${nic_pid} 2>/dev/null || true; wait ${nic_pid} 2>/dev/null || true
    echo "load_post: $(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)" >> "${subdir}/weka-load.txt"
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    # 提取 READ BW
    local read_bw
    read_bw=$(grep "READ:" "${subdir}/fio.txt" 2>/dev/null | grep -oE 'bw=[0-9.]+MiB' | head -1 | grep -oE '[0-9.]+' || true)
    local write_bw
    write_bw=$(grep "WRITE:" "${subdir}/fio.txt" 2>/dev/null | grep -oE 'bw=[0-9.]+MiB' | head -1 | grep -oE '[0-9.]+' || true)
    log "  randrw-${round}: READ=${read_bw:-N/A} WRITE=${write_bw:-N/A} MiB/s"
}

# ===== Main =====

log "============================================"
log "=== randrw 覆盖写稳定性测试 mode=${MODE} ==="
log "=== runtime=${RUNTIME}s rounds=${ROUNDS} ==="
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || { log "ERROR: health 非 OK"; exit 1; }

# 检查 layout 数据存在
if [ ! -f "${TEST_DIR}/storage_test.0.0" ]; then
    log "ERROR: layout 数据不存在（${TEST_DIR}/storage_test.0.0），请先跑 write-impact-test.sh phase0"
    exit 1
fi
log "layout 数据确认存在: ${TEST_DIR}/storage_test.0.0"

log "=== 开始 ${ROUNDS} 轮 randrw（加强清理）==="
for round in $(seq 1 ${ROUNDS}); do
    log "--- round ${round}/${ROUNDS} ---"
    run_randrw "${round}"
    if [ ${round} -lt ${ROUNDS} ]; then
        aggressive_cleanup
    fi
done

# 汇总
log "=== 汇总 ==="
python3 -c "
import statistics, re, os
base = '${RESULTS_DIR}'
vals = []
for r in range(1, ${ROUNDS}+1):
    f = os.path.join(base, 'randrw-%d' % r, 'fio.txt')
    if not os.path.exists(f): continue
    txt = open(f).read()
    m = re.search(r'READ:.*bw=([0-9.]+)MiB', txt)
    if m:
        v = float(m.group(1))
        vals.append((r, v))
        print('  round %d: %.0f MiB/s' % (r, v))
if len(vals) >= 2:
    bws = [v for _, v in vals]
    mean = statistics.mean(bws)
    med = statistics.median(bws)
    sd = statistics.stdev(bws) if len(bws) > 1 else 0
    cv = sd / mean * 100 if mean > 0 else 0
    vmin = min(bws)
    vmax = max(bws)
    span = (vmax - vmin) / vmin * 100
    print('')
    print('  n=%d  mean=%.0f  median=%.0f  SD=%.0f  CV=%.1f%%' % (len(bws), mean, med, sd, cv))
    print('  range=%.0f-%.0f  span=%.1f%%' % (vmin, vmax, span))
    print('')
    if cv < 5:
        print('  ✅ CV<5%% → 加强清理有效，randrw 稳定')
    elif cv < 10:
        print('  ⚠️ CV 5-10%% → 改善但仍有残余波动')
    else:
        print('  ❌ CV>10%% → 加强清理不足，需更强清理或换方案')
" 2>/dev/null || log "  (统计计算失败)"

log "=== DONE ==="
