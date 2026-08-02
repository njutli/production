#!/bin/bash
set -euo pipefail
export LC_ALL=C

# SUPPLEMENT-RANDRW128.sh — randrw-128 预热后多轮测试
#
# V3 主测试中 randrw-128 出现单调下降（1347→911，-32%），疑似 128-job 逐轮
# 驱逐 BlueStore 缓存。本脚本多测几轮，观察 BW 是否收敛到某个区间。
#
# 前提：V3 主测试已完成 --layout（layout 文件存在）
#
# 用法（在 157 上运行）：
#   bash SUPPLEMENT-RANDRW128.sh dry-run
#   bash SUPPLEMENT-RANDRW128.sh F 180 10
#
# 遵循：SYSTEM-SAFETY-SKILL.md

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/opencode-fullbaseline-v3"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

LABEL="${1:-F}"
RUNTIME=180
REPEAT=10
LAYOUT_JOBS=128
LAYOUT_SIZE="1G"
JUICEFS_MOUNT_OPTS="${JUICEFS_MOUNT_OPTS:---max-uploads 150 --cache-size 0}"

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

# ===== Helpers（与 V3 一致）=====

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    local ok_count=0
    for ip in "${SLAVES[@]}"; do
        if ${SSHPASS_CMD}@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null; then
            ok_count=$((ok_count+1))
        fi
    done
    if [ "${ok_count}" -lt 3 ]; then
        log "  ⚠️ drop_caches: ${ok_count}/3 节点成功"
    fi
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
                'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "1 1")
            if [ "$running" != "0" ]; then all_done=false; fi
            if [ "$queued" != "0" ]; then all_done=false; fi
        done
        $all_done && { done_ok=true; break; }
        sleep 5
    done
    $done_ok && log "  compact ✅ (~$((i*5))s)" || log "  ⚠️ compact 超时"
}

aggressive_cleanup() {
    log "  aggressive_cleanup"
    compact_cooldown
    sleep 30
    compact_cooldown
    drop_caches
}

deterministic_warmup() {
    log "=== 确定性预热（顺序读 128G layout）==="
    local count=0
    for f in ${TEST_DIR}/storage_test.*.0; do
        [ -f "$f" ] || continue
        dd if="$f" of=/dev/null bs=4M 2>/dev/null
        count=$((count+1))
    done
    log "  warmup done: read ${count} files sequentially"
    compact_cooldown
    drop_caches
}

run_fio() {
    local label="$1"; shift
    local subdir="${RESULTS}/${LABEL}/${label}"
    mkdir -p "${subdir}"
    drop_caches
    local load_pre
    load_pre=$(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)
    echo "load_pre: ${load_pre}" > "${subdir}/weka-load.txt"
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) \
        > "${subdir}/nic.txt" & local nic_pid=$!
    local jfs_pid
    jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1 || true)
    if [ -n "${jfs_pid}" ]; then
        { echo "=== PRE $(date '+%H:%M:%S') ==="; sudo cat /proc/${jfs_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads' || true; timeout 5 cat /mnt/juicefs/.stats 2>/dev/null || echo "(.stats N/A)"; } > "${subdir}/jfs-stats-pre.txt"
    fi
    sudo ceph pg dump pgs_brief 2>/dev/null > "${subdir}/pg-map.txt" || true
    log "  fio ${label}..."
    fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt" || true
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

# ===== randrw-128 多轮测试 =====

item_randrw_128() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randrw128-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=storage_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
        aggressive_cleanup
    done
}

# ===== 汇总 =====

summary() {
    log "=== 汇总 ${LABEL} randrw-128 (fio BW, MiB/s) ==="
    local line="  randrw-128:"
    for r in $(seq 1 "${REPEAT}"); do
        local bw
        bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/randrw128-${LABEL}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
        line="${line} r${r}=${bw:-NA}"
    done
    log "${line}"
}

# ===== 稳态评估 =====

steady_state_eval() {
    log "=== 稳态评估（randrw-128，截前 15s）==="
    python3 - <<PYEOF 2>/dev/null | while read -r l; do log "$l"; done || true
import os, re, statistics, glob
from collections import defaultdict

base = "${RESULTS}/${LABEL}"
repeat = ${REPEAT}
trim = 15

def parse_bwlog(subdir, direction, trim_sec):
    files = sorted(glob.glob(os.path.join(subdir, "*_bw.*.log")))
    if not files:
        return None
    per_sec = defaultdict(float)
    for f in files:
        for line in open(f):
            parts = line.strip().split(",")
            if len(parts) < 3:
                continue
            try:
                sec = int(parts[0]) // 1000
                bw = float(parts[1])
                d = int(parts[2])
                if d == direction:
                    per_sec[sec] += bw
            except (ValueError, IndexError):
                pass
    all_vals = [(s, v) for s, v in sorted(per_sec.items()) if s >= trim_sec]
    if not all_vals:
        return None
    return statistics.median([v for _, v in all_vals])

items = ["randrw128"]
for item in items:
    for direction, dname in [(0, "R"), (1, "W")]:
        vals = []
        for r in range(1, repeat + 1):
            subdir = os.path.join(base, "%s-%s-r%d" % (item, "${LABEL}", r))
            steady = parse_bwlog(subdir, direction, trim)
            if steady is not None:
                vals.append(steady / 1024)
        if vals:
            med = statistics.median(vals)
            max_dev = max(abs(v - med) for v in vals) / med * 100 if med else 0
            cv = statistics.stdev(vals) / statistics.mean(vals) * 100 if len(vals) > 1 else 0
            print("  %s %s: median=%.0f max_dev=%.1f%% CV=%.1f%% range=%.0f-%.0f MiB/s" % (
                item, dname, med, max_dev, cv, min(vals), max(vals)))
            # 趋势分析
            if len(vals) >= 3:
                half = len(vals) // 2
                first_half = statistics.mean(vals[:half])
                second_half = statistics.mean(vals[-half:])
                trend = (second_half - first_half) / first_half * 100
                print("    趋势: 前半均值=%.0f → 后半均值=%.0f (%+.1f%%)" % (first_half, second_half, trend))
        else:
            print("  %s %s: no data" % (item, dname))
PYEOF
}

# ===== 入口 =====

case "${1:-}" in
    dry-run)
        log "============================================"
        log "=== DRY-RUN（randrw-128 多轮预热测试）==="
        log "============================================"
        HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
        log "ceph health: ${HEALTH}"
        OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
        log "OSDs up: ${OSD_UP} (期望 6)"
        mount | grep -q juice && log "JuiceFS 挂载: ✅" || log "JuiceFS 挂载: ❌"
        [ -f "${TEST_DIR}/storage_test.0.0" ] && log "layout 数据: ✅" || log "layout 数据: ❌ 不存在（需先跑 V3 --layout）"
        command -v fio >/dev/null && log "fio: ✅ $(fio --version)" || log "fio: ❌"
        log ""
        log "  用法: bash $0 <LABEL> 180 10"
        log "  预期耗时: ~50min（10 轮 × 4min + 预热 12min）"
        exit 0
        ;;
    "")
        echo "用法: $0 <LABEL> [RUNTIME] [REPEAT]"
        echo "      $0 dry-run"
        echo ""
        echo "  前提：V3 主测试已完成 --layout"
        echo "  默认 REPEAT=10，观察 BW 是否收敛"
        exit 0
        ;;
    *)
        LABEL="$1"; RUNTIME="${2:-180}"; REPEAT="${3:-10}"
        ;;
esac

log "============================================"
log "=== SUPPLEMENT-RANDRW128 label=${LABEL} runtime=${RUNTIME}s repeat=${REPEAT} ==="
log "=== 预热后 randrw-128 多轮测试，观察收敛 ==="
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || {
    echo "${HEALTH}" | grep -q "clock skew" && log "  ⚠️ clock skew 告警，不影响测试，继续" || { log "ERROR: health 非 OK 且非 clock skew"; exit 1; }
}
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (期望 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全"; exit 1; }

if ! mount | grep -q juice; then
    log "  JuiceFS 未挂载，re-mount"
    juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
    sleep 3
    mount | grep -q juice || { log "ERROR: mount failed"; exit 1; }
fi
mkdir -p "${TEST_DIR}"

[ -f "${TEST_DIR}/storage_test.0.0" ] || { log "ERROR: layout 不存在，需先跑 V3 --layout"; exit 1; }
log "  layout 数据存在"

# 确定性预热
deterministic_warmup

# randrw-128 多轮测试
log "=== ${LABEL}: randrw-128 (${REPEAT} 轮) ==="; item_randrw_128

# 汇总 + 稳态评估
summary
steady_state_eval
log "=== ${LABEL} DONE ==="
