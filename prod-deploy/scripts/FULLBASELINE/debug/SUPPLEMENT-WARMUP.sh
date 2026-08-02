#!/bin/bash
set -euo pipefail
export LC_ALL=C

# SUPPLEMENT-WARMUP.sh — V3 补充测试：4 项 prep 文件预热后重测
#
# V3 主测试的确定性预热只读了 layout 主文件（storage_test.*.0），未覆盖：
#   - seqread prep（seqread/seqread.0.0, 32G）
#   - mseqread prep（mseqread/mseqread.*.0, 64G）
#   - seqwrite prep（seqwrite/seqwrite.0.0, 32G）
#   - mseqwrite prep（mseqwrite/mseqwrite.*.0, 64G）
# 本脚本对每项分别预热后重测，验证预热能否消除 r1 冷启动。
#
# 前提：V3 主测试已完成 --layout（prep 文件存在）。
#
# 用法（在 157 上运行）：
#   bash SUPPLEMENT-WARMUP.sh dry-run
#   bash SUPPLEMENT-WARMUP.sh E 180 5
#
# 遵循：SYSTEM-SAFETY-SKILL.md
#   sudo 写操作：drop_caches + ceph tell compact（已确认）

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/opencode-fullbaseline-v3"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

LABEL="${1:-E}"
RUNTIME=180
REPEAT=5
SEQ_SIZE="32G"
MSEQ_JOBS=16
MSEQ_SIZE="4G"

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

# 通用预热：顺序读指定目录下的所有文件
warmup_dir() {
    local dir="$1"
    local desc="$2"
    log "  warmup: ${desc} (${dir})"
    local count=0
    for f in "${dir}"/*; do
        [ -f "$f" ] || continue
        dd if="$f" of=/dev/null bs=4M 2>/dev/null
        count=$((count+1))
    done
    log "  warmup done: read ${count} files"
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
    # NIC 采集
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) \
        > "${subdir}/nic.txt" & local nic_pid=$!
    # pg-map 采集
    sudo ceph pg dump pgs_brief 2>/dev/null > "${subdir}/pg-map.txt" || true
    # fio
    log "  fio ${label}..."
    fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt" || true
    kill ${nic_pid} 2>/dev/null || true; wait ${nic_pid} 2>/dev/null || true
    echo "load_post: $(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)" >> "${subdir}/weka-load.txt"
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    local bw
    bw=$(grep -oE 'bw=[0-9.]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
    log "  ${label}: BW=${bw:-N/A} MiB/s"
}

# ===== 4 项测试（每项前各自预热）=====

item_seqread() {
    warmup_dir "${TEST_DIR}/seqread" "seqread prep 32G"
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqread-${LABEL}-r${r}" --name=seqread --directory="${TEST_DIR}/seqread/" \
            --rw=read --refill_buffers --bs=256k --size=${SEQ_SIZE} \
            --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
    done
}

item_mseqread() {
    warmup_dir "${TEST_DIR}/mseqread" "mseqread prep 64G"
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "mseqread-${LABEL}-r${r}" --name=mseqread --directory="${TEST_DIR}/mseqread/" \
            --rw=read --refill_buffers --bs=256k --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} \
            --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
    done
}

item_seqwrite() {
    warmup_dir "${TEST_DIR}/seqwrite" "seqwrite prep 32G"
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqwrite-${LABEL}-r${r}" --name=seqwrite --directory="${TEST_DIR}/seqwrite/" \
            --rw=write --refill_buffers --bs=4M --size=${SEQ_SIZE} \
            --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
        compact_cooldown
    done
}

item_mseqwrite() {
    warmup_dir "${TEST_DIR}/mseqwrite" "mseqwrite prep 64G"
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "mseqwrite-${LABEL}-r${r}" --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" \
            --rw=write --refill_buffers --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} \
            --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
        compact_cooldown
    done
    aggressive_cleanup
}

# ===== 汇总 =====

summary() {
    log "=== 汇总 ${LABEL} (fio BW, MiB/s) ==="
    for item in seqread mseqread seqwrite mseqwrite; do
        local line="  ${item}:"
        for r in $(seq 1 "${REPEAT}"); do
            local bw
            bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/${item}-${LABEL}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
            line="${line} r${r}=${bw:-NA}"
        done
        log "${line}"
    done
}

# ===== 稳态评估 =====

steady_state_eval() {
    log "=== 稳态评估（读项截前15s，写项截前15s）==="
    python3 - <<PYEOF 2>/dev/null | while read -r l; do log "$l"; done || true
import os, re, statistics, glob
from collections import defaultdict

base = "${RESULTS}/${LABEL}"
repeat = ${REPEAT}
read_trim = 15

item_cfg = {
    "seqread":   (0, read_trim),
    "mseqread":  (0, read_trim),
    "seqwrite":  (1, read_trim),
    "mseqwrite": (1, read_trim),
}

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

def bw_from_fio(f):
    if os.path.exists(f):
        m = re.search(r'(?:READ|WRITE):.*?bw=([0-9.]+)MiB', open(f).read())
        if m:
            return float(m.group(1)) * 1024
    return None

items = ["seqread", "mseqread", "seqwrite", "mseqwrite"]
for item in items:
    direction, trim = item_cfg[item]
    vals = []
    fallback = False
    for r in range(1, repeat + 1):
        subdir = os.path.join(base, "%s-%s-r%d" % (item, "${LABEL}", r))
        steady = parse_bwlog(subdir, direction, trim)
        if steady is None:
            v = bw_from_fio(os.path.join(subdir, "fio.txt"))
            if v is not None:
                vals.append(v / 1024)
                fallback = True
        else:
            vals.append(steady / 1024)
    if vals:
        med = statistics.median(vals)
        max_dev = max(abs(v - med) for v in vals) / med * 100 if med else 0
        cv = statistics.stdev(vals) / statistics.mean(vals) * 100 if len(vals) > 1 else 0
        tag = " (fallback:fio-agg)" if fallback else ""
        print("  %s: median=%.0f max_dev=%.1f%% CV=%.1f%%%s range=%.0f-%.0f MiB/s" % (
            item, med, max_dev, cv, tag, min(vals), max(vals)))
    else:
        print("  %s: no data" % item)
PYEOF
}

# ===== 入口 =====

case "${1:-}" in
    dry-run)
        log "============================================"
        log "=== DRY-RUN（补充预热测试，检查 prep 文件）==="
        log "============================================"
        HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
        log "ceph health: ${HEALTH}"
        [ "${HEALTH}" = "HEALTH_OK" ] && log "  ✅ health OK" || log "  ❌ health 非 OK"
        OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
        log "OSDs up: ${OSD_UP} (期望 6)"
        mount | grep -q juice && log "JuiceFS 挂载: ✅" || log "JuiceFS 挂载: ❌"
        [ -f "${TEST_DIR}/seqread/seqread.0.0" ] && log "seqread prep: ✅" || log "seqread prep: ❌ 不存在（需先跑 V3 --layout）"
        [ -f "${TEST_DIR}/mseqread/mseqread.0.0" ] && log "mseqread prep: ✅" || log "mseqread prep: ❌"
        [ -f "${TEST_DIR}/seqwrite/seqwrite.0.0" ] && log "seqwrite prep: ✅" || log "seqwrite prep: ❌"
        [ -f "${TEST_DIR}/mseqwrite/mseqwrite.0.0" ] && log "mseqwrite prep: ✅" || log "mseqwrite prep: ❌"
        command -v fio >/dev/null && log "fio: ✅ $(fio --version)" || log "fio: ❌"
        log ""
        log "  用法: bash $0 <LABEL> 180 5"
        log "  预期耗时: ~1.5h"
        exit 0
        ;;
    "")
        echo "用法: $0 <LABEL> [RUNTIME] [REPEAT]"
        echo "      $0 dry-run"
        echo ""
        echo "  前提：V3 主测试已完成 --layout（prep 文件存在）"
        echo "  本脚本对 seqread/mseqread/seqwrite/mseqwrite 分别预热后重测"
        exit 0
        ;;
    *)
        LABEL="$1"; RUNTIME="${2:-180}"; REPEAT="${3:-5}"
        ;;
esac

log "============================================"
log "=== SUPPLEMENT-WARMUP label=${LABEL} runtime=${RUNTIME}s repeat=${REPEAT} ==="
log "=== 4 项 prep 文件分别预热后重测 ==="
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || {
    echo "${HEALTH}" | grep -q "clock skew" && log "  ⚠️ clock skew 告警，不影响测试，继续" || { log "ERROR: health 非 OK 且非 clock skew"; exit 1; }
}
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (期望 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全"; exit 1; }

# 检查 JuiceFS 已挂载
if ! mount | grep -q juice; then
    log "  JuiceFS 未挂载，re-mount"
    juicefs mount -d --max-uploads 150 --cache-size 0 "${META}" "${MNT}" 2>&1 | tail -1
    sleep 3
    mount | grep -q juice || { log "ERROR: mount failed"; exit 1; }
fi
mkdir -p "${TEST_DIR}"

# 检查 prep 文件存在
[ -f "${TEST_DIR}/seqread/seqread.0.0" ] || { log "ERROR: seqread prep 不存在，需先跑 V3 --layout"; exit 1; }
[ -f "${TEST_DIR}/mseqread/mseqread.0.0" ] || { log "ERROR: mseqread prep 不存在"; exit 1; }
[ -f "${TEST_DIR}/seqwrite/seqwrite.0.0" ] || { log "ERROR: seqwrite prep 不存在"; exit 1; }
[ -f "${TEST_DIR}/mseqwrite/mseqwrite.0.0" ] || { log "ERROR: mseqwrite prep 不存在"; exit 1; }
log "  prep 文件全部存在"

# 测试：每项前预热该项目的 prep 文件
log "=== ${LABEL}: seqread (预热 32G) ==="; item_seqread
log "=== ${LABEL}: mseqread (预热 64G) ==="; item_mseqread
log "=== ${LABEL}: seqwrite (预热 32G) ==="; item_seqwrite
log "=== ${LABEL}: mseqwrite (预热 64G) ==="; item_mseqwrite

# 汇总 + 稳态评估
summary
steady_state_eval
log "=== ${LABEL} DONE ==="
