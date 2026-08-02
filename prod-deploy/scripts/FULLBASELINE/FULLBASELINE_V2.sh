#!/bin/bash
set -euo pipefail
export LC_ALL=C  # 避免 SSH 传递的 locale 在目标节点不存在

# FULLBASELINE_V2.sh — JuiceFS/Ceph 全量基线测试 V2（覆盖写模式）
#
# V1（FULLBASELINE.sh）每轮 clean_volume + destroy + 重建 layout → CV 10-13%
# V2 一次性 layout + 全程覆盖写（不 destroy/rm -rf/restart OSD）→ CV 0.6-3.1%
#
# 测试顺序：读项在前（干净起点）→ 写项在后（每轮 aggressive_cleanup 防污染）
#   seqread → mseqread → randread → randrw → seqwrite → mseqwrite → randwrite
#
# 依据：02-2h-write-impact-20260730.md 实验验证
#   - 锁定 layout randread CV=0.6%
#   - 40 轮覆盖写后读不变（CRUSH md5 不变）
#   - randrw aggressive_cleanup 将 CV 14.5%→3.1%
#
# 用法（在 157 上运行）：
#   bash FULLBASELINE_V2.sh dry-run              # Dry-run（纯检查，不写数据）
#   bash FULLBASELINE_V2.sh <LABEL> [RUNTIME] [REPEAT] [--layout] [--remount]
#   bash FULLBASELINE_V2.sh A 180 5 --layout     # 第一次：layout + 全量测试
#   bash FULLBASELINE_V2.sh B 180 5              # 第二次：复用 layout，只跑全量测试
#   bash FULLBASELINE_V2.sh C 180 5 --remount    # 改 mount 参数后 remount + 测试
#
# 改 mount 参数调优：
#   JUICEFS_MOUNT_OPTS="--max-readahead 0 --max-uploads 150 --cache-size 0" \
#     bash FULLBASELINE_V2.sh C 180 3 --remount
#
# 组间清理：
#   bash FULLBASELINE_V2.sh softclean
#
# 遵循：SYSTEM-SAFETY-SKILL.md（§2.2 set -euo pipefail / §2.3 路径守卫 / §2.4 dry-run）
#   sudo 写操作：drop_caches + ceph tell compact（已确认）

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/opencode-fullbaseline-v2"
POOL_DATA="juicefs-data"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

LABEL="${1:-A}"
RUNTIME=180
REPEAT=5
DO_LAYOUT=false
DO_REMOUNT=false
ALLOW_RESTART=false
LAYOUT_JOBS=128
JUICEFS_MOUNT_OPTS="${JUICEFS_MOUNT_OPTS:---max-uploads 150 --cache-size 0}"
LAYOUT_SIZE="1G"
SEQ_SIZE="32G"
MSEQ_JOBS=16
MSEQ_SIZE="4G"

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

# ===== 路径守卫（SYSTEM-SAFETY-SKILL §2.3）=====
safety_check() {
    local t="$1"
    [ -n "$t" ] || { echo "REFUSE: empty path"; exit 1; }
    [ "$t" != "/" ] || { echo "REFUSE: root path"; exit 1; }
    [ "${t:0:1}" = "/" ] || { echo "REFUSE: relative path"; exit 1; }
}

# ===== Helpers =====

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    local ok_count=0
    for ip in "${SLAVES[@]}"; do
        if ${SSHPASS_CMD}@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null; then
            ok_count=$((ok_count+1))
        fi
    done
    if [ "${ok_count}" -lt 3 ]; then
        log "  ⚠️ drop_caches: ${ok_count}/3 节点成功（缓存状态不一致可能污染 CV）"
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

# aggressive_cleanup: compact → sleep 30 → compact → drop_caches（用于 randrw 轮间）
aggressive_cleanup() {
    log "  aggressive_cleanup"
    compact_cooldown
    sleep 30
    compact_cooldown
    drop_caches
}

mount_jfs() {
    # 如果已挂载（如 --remount 先执行），跳过 format + mount
    if mount | grep -q juice; then
        log "  JuiceFS 已挂载，跳过 format + mount"
        mkdir -p "${TEST_DIR}"
        return 0
    fi
    juicefs format --storage ceph --bucket ceph://${POOL_DATA} --access-key ceph \
        --secret-key client.juicefs --block-size 256K --trash-days 0 --force \
        "${META}" juicefs-prod 2>/dev/null | tail -1
    for try in 1 2 3; do
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break; sleep 10
    done
    mount | grep -q juice || { log "FATAL: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
}

# remount：umount + 用新参数 mount（不 format，不动 layout）
remount_jfs() {
    log "  remount JuiceFS（参数: ${JUICEFS_MOUNT_OPTS}）"
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    for try in 1 2 3; do
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break; sleep 10
    done
    mount | grep -q juice || { log "FATAL: remount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
}

# ===== Fio 运行器 =====

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
    # jfs-stats snapshot PRE（.stats 文件，非阻塞）
    local jfs_pid
    jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1 || true)
    if [ -n "${jfs_pid}" ]; then
        { echo "=== PRE $(date '+%H:%M:%S') ==="; sudo cat /proc/${jfs_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads' || true; timeout 5 cat /mnt/juicefs/.stats 2>/dev/null || echo "(.stats N/A)"; } > "${subdir}/jfs-stats-pre.txt"
    fi
    # pg-map 采集（每轮 fio 前记录 PG 映射，供 analyst 做 primary 分布 vs BW 的 Spearman）
    sudo ceph pg dump pgs_brief 2>/dev/null > "${subdir}/pg-map.txt" || true
    # fio
    log "  fio ${label}..."
    fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt" || true
    # jfs-stats POST
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

# ===== Phase 0: 一次性 layout =====

phase0_layout() {
    log "=== Phase 0: 一次性 layout ==="
    safety_check "${TEST_DIR}"
    mount_jfs
    rm -rf "${TEST_DIR}"/* 2>/dev/null || true
    mkdir -p "${TEST_DIR}/seqread" "${TEST_DIR}/seqwrite" "${TEST_DIR}/mseqread" "${TEST_DIR}/mseqwrite"
    # 主 layout（128×1G）
    log "  layout: ${LAYOUT_JOBS}×${LAYOUT_SIZE} (bs=4M)"
    fio --directory="${TEST_DIR}" --name=storage_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=4M --rw=write \
        --numjobs=${LAYOUT_JOBS} --fallocate=none --direct=1 \
        --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
    # seqread prep
    log "  seqread prep: ${SEQ_SIZE}"
    fio --name=seqread --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=${SEQ_SIZE} --direct=1 >/dev/null 2>&1
    # seqwrite prep
    log "  seqwrite prep: ${SEQ_SIZE}"
    fio --name=seqwrite --directory="${TEST_DIR}/seqwrite/" --rw=write --bs=4M --size=${SEQ_SIZE} --direct=1 >/dev/null 2>&1
    # mseqread prep
    log "  mseqread prep: ${MSEQ_JOBS}×${MSEQ_SIZE}"
    fio --name=mseqread --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --direct=1 >/dev/null 2>&1
    # mseqwrite prep
    log "  mseqwrite prep: ${MSEQ_JOBS}×${MSEQ_SIZE}"
    fio --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" --rw=write --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --direct=1 >/dev/null 2>&1
    compact_cooldown
    drop_caches
    # 布局指纹（5 要素）
    local crush_md5 uuid phase0_ts osd_stat osd_up_from
    crush_md5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    uuid=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    phase0_ts=$(date +%s)
    osd_stat=$(sudo ceph osd stat 2>/dev/null)
    # 提取各 OSD 的 up_from epoch（restart 必然推高）
    osd_up_from=$(sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(" ".join("%d:%d" % (o["osd"], o.get("up_from",0)) for o in sorted(d["osds"], key=lambda x:x["osd"])))
' 2>/dev/null || echo "N/A")
    {
        echo "UUID=${uuid}"
        echo "PHASE0_TS=${phase0_ts}"
        echo "CRUSHMD5=${crush_md5}"
        echo "OSD_STAT=${osd_stat}"
        echo "OSD_UP_FROM=${osd_up_from}"
    } > "${RESULTS}/guard-baseline.txt"
    log "  layout done. 指纹: UUID=${uuid} CRUSH=${crush_md5} TS=${phase0_ts}"
    log "  OSD up_from: ${osd_up_from}"
    log "  ⚠️ 如 OSD 被重启，锁定布局失效（缓存重抽 CV=13%），须重跑 --layout 或用 --allow-restart"
}

# ===== 9 项（覆盖写模式）=====

item_seqread() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqread-${LABEL}-r${r}" --name=seqread --directory="${TEST_DIR}/seqread/" \
            --rw=read --refill_buffers --bs=256k --size=${SEQ_SIZE} \
            --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
    done
}

item_seqwrite() {
    # 覆盖写：覆盖 Phase 0 prep 的已有文件（不 rm -rf）
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqwrite-${LABEL}-r${r}" --name=seqwrite --directory="${TEST_DIR}/seqwrite/" \
            --rw=write --refill_buffers --bs=4M --size=${SEQ_SIZE} \
            --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
        compact_cooldown
    done
}

item_mseqread() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "mseqread-${LABEL}-r${r}" --name=mseqread --directory="${TEST_DIR}/mseqread/" \
            --rw=read --refill_buffers --bs=256k --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} \
            --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
    done
}

item_mseqwrite() {
    # 覆盖写
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "mseqwrite-${LABEL}-r${r}" --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" \
            --rw=write --refill_buffers --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} \
            --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
        compact_cooldown
    done
    # mseqwrite 后加强清理，防 randwrite r1 被 compaction 残留干扰
    aggressive_cleanup
}

item_randwrite() {
    # 覆盖写：覆盖 Phase 0 layout 的已有文件（无 --create_on_open，无 --nrfiles）
    # aggressive_cleanup 每轮后执行（包括末轮，防跨 item 污染）
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randwrite-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=storage_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
        aggressive_cleanup
    done
}

item_randread() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randread-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=storage_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
    done
}

item_randrw() {
    # 覆盖写 + aggressive_cleanup 每轮后执行（包括末轮，防跨 item 污染）
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randrw-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=storage_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
        aggressive_cleanup
    done
}

# ===== softclean（组间隔离，外部调用）=====

soft_clean_restart() {
    log "=== SOFT-CLEAN（V2：不 destroy，仅 drop_caches + compact）==="
    compact_cooldown
    drop_caches
    sleep 10
}

# ===== 汇总 =====

summary() {
    log "=== 汇总 ${LABEL} (fio BW, MiB/s) ==="
    log "  layout: (Phase 0, 一次性)"
    for item in seqread mseqread randread randrw seqwrite mseqwrite randwrite; do
        local line="  ${item}:"
        for r in $(seq 1 "${REPEAT}"); do
            local bw
            bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/${item}-${LABEL}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
            line="${line} r${r}=${bw:-NA}"
        done
        log "${line}"
    done
    # 布局指纹复查
    local current_uuid current_crush current_up_from base_uuid base_crush base_up_from
    current_uuid=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    current_crush=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    current_up_from=$(sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(" ".join("%d:%d" % (o["osd"], o.get("up_from",0)) for o in sorted(d["osds"], key=lambda x:x["osd"])))
' 2>/dev/null || echo "N/A")
    base_uuid=$(grep '^UUID=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    base_crush=$(grep '^CRUSHMD5=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    base_up_from=$(grep '^OSD_UP_FROM=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    if [ "${base_uuid}" != "N/A" ]; then
        if [ "${current_uuid}" = "${base_uuid}" ]; then
            log "  ✅ volume UUID 不变 (${current_uuid})"
        else
            log "  🔴 volume UUID 变了! ${base_uuid} -> ${current_uuid}（布局已重抽）"
        fi
        if [ "${current_crush}" = "${base_crush}" ]; then
            log "  ✅ CRUSH md5 不变 (${current_crush})（拓扑不变）"
        else
            log "  🔴 CRUSH md5 变了! ${base_crush} -> ${current_crush}"
        fi
        if [ "${base_up_from}" != "N/A" ] && [ "${current_up_from}" != "N/A" ]; then
            if [ "${current_up_from}" = "${base_up_from}" ]; then
                log "  ✅ OSD up_from 不变（测试期间无 restart）"
            else
                log "  ⚠️ OSD up_from 变了! 测试期间可能发生过 restart"
            fi
        fi
    fi
}

# ===== 稳态中位数评估 =====

steady_state_eval() {
    log "=== 稳态评估（读项截前15s，随机写项取末60s floor）==="
    python3 - <<PYEOF 2>/dev/null | while read -r l; do log "$l"; done || true
import os, re, statistics, glob
from collections import defaultdict

base = "${RESULTS}/${LABEL}"
repeat = ${REPEAT}
read_trim = 15   # 读项截前 15s
write_trim = 60  # 随机写项截前 60s（到振荡 floor）

# 每个项的主方向（0=read, 1=write）和截首秒数
item_cfg = {
    "seqread":   (0, read_trim),
    "mseqread":  (0, read_trim),
    "randread":  (0, read_trim),
    "randrw":    (0, read_trim),   # 报 READ，读路径无退化
    "seqwrite":  (1, read_trim),
    "mseqwrite": (1, read_trim),
    "randwrite": (1, write_trim),  # 随机写，截前 60s 取 floor
}

def parse_bwlog(subdir, direction, trim_sec):
    """从 bw_log 文件计算截前 trim_sec 秒的稳态中位数 + floor 中位数"""
    files = sorted(glob.glob(os.path.join(subdir, "*_bw.*.log")))
    if not files:
        return None, None
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
        return None, None
    steady_med = statistics.median([v for _, v in all_vals])
    # floor = 末 60s 中位数（用于随机写项的振荡 floor 对比）
    last60 = [v for _, v in all_vals[-60:]] if len(all_vals) >= 60 else [v for _, v in all_vals]
    floor_med = statistics.median(last60) if last60 else steady_med
    return steady_med, floor_med

def bw_from_fio(f):
    """从 fio.txt 聚合值回退"""
    if os.path.exists(f):
        m = re.search(r'(?:READ|WRITE):.*?bw=([0-9.]+)MiB', open(f).read())
        if m:
            return float(m.group(1)) * 1024  # MiB -> KiB
    return None

items = ["seqread", "mseqread", "randread", "randrw", "seqwrite", "mseqwrite", "randwrite"]
for item in items:
    direction, trim = item_cfg[item]
    is_write = item in ("randwrite",)  # 只对随机写项报 floor
    vals = []
    floor_vals = []
    fallback = False
    for r in range(1, repeat + 1):
        subdir = os.path.join(base, "%s-%s-r%d" % (item, "${LABEL}", r))
        steady, floor = parse_bwlog(subdir, direction, trim)
        if steady is None:
            v = bw_from_fio(os.path.join(subdir, "fio.txt"))
            if v is not None:
                vals.append(v / 1024)
                fallback = True
        else:
            vals.append(steady / 1024)
            floor_vals.append(floor / 1024)
    if vals:
        med = statistics.median(vals)
        cv = statistics.stdev(vals) / statistics.mean(vals) * 100 if len(vals) > 1 else 0
        tag = " (fallback:fio-agg)" if fallback else ""
        if is_write and floor_vals:
            floor_med = statistics.median(floor_vals)
            floor_cv = statistics.stdev(floor_vals) / statistics.mean(floor_vals) * 100 if len(floor_vals) > 1 else 0
            print("  %s: median=%.0f CV=%.1f%%%s | floor_median=%.0f floor_CV=%.1f%% range=%.0f-%.0f MiB/s" % (item, med, cv, tag, floor_med, floor_cv, min(vals), max(vals)))
        else:
            print("  %s: median=%.0f CV=%.1f%%%s range=%.0f-%.0f MiB/s" % (item, med, cv, tag, min(vals), max(vals)))
    else:
        print("  %s: no data" % item)
PYEOF
}

# ===== 入口 =====

case "${1:-}" in
    softclean|clean)
        soft_clean_restart
        exit 0
        ;;
    dry-run)
        # 纯检查模式：不写数据，不破坏 layout
        log "============================================"
        log "=== DRY-RUN（纯检查，不写数据，不破坏 layout）==="
        log "============================================"
        HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
        log "ceph health: ${HEALTH}"
        [ "${HEALTH}" = "HEALTH_OK" ] && log "  ✅ health OK" || log "  ❌ health 非 OK"
        OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
        log "OSDs up: ${OSD_UP} (期望 6)"
        [ "${OSD_UP}" = "6" ] && log "  ✅ OSD 全 up" || log "  ❌ OSD 不全"
        mount | grep -q juice && log "JuiceFS 挂载: ✅ $(mount | grep juice | head -1)" || log "JuiceFS 挂载: ❌ 未挂载"
        [ -f "${TEST_DIR}/storage_test.0.0" ] && log "layout 数据: ✅ 存在" || log "layout 数据: ⚠️ 不存在（需先跑 --layout）"
        [ -f "${TEST_DIR}/seqread/seqread.0.0" ] && log "seqread prep: ✅" || log "seqread prep: ⚠️ 不存在"
        [ -f "${TEST_DIR}/mseqread/mseqread.0.0" ] && log "mseqread prep: ✅" || log "mseqread prep: ⚠️ 不存在"
        [ -f "${TEST_DIR}/seqwrite/seqwrite.0.0" ] && log "seqwrite prep: ✅" || log "seqwrite prep: ⚠️ 不存在"
        [ -f "${TEST_DIR}/mseqwrite/mseqwrite.0.0" ] && log "mseqwrite prep: ✅" || log "mseqwrite prep: ⚠️ 不存在"
        command -v fio >/dev/null && log "fio: ✅ $(fio --version)" || log "fio: ❌ MISSING"
        command -v juicefs >/dev/null && log "juicefs: ✅ $(juicefs version 2>&1 | head -1)" || log "juicefs: ❌ MISSING"
        command -v python3 >/dev/null && log "python3: ✅ $(python3 --version)" || log "python3: ❌ MISSING"
        [ -x /tmp/load-monitor.sh ] && log "load-monitor: ✅" || log "load-monitor: ⚠️ 不存在（非阻塞）"
        [ -x /tmp/osd-monitor.sh ] && log "osd-monitor: ✅" || log "osd-monitor: ⚠️ 不存在（非阻塞）"
        log ""
        log "mount 参数: ${JUICEFS_MOUNT_OPTS}"
        log "layout 目录: ${TEST_DIR}"
        log "结果目录: ${RESULTS}"
        log ""
        log "DRY-RUN 完成。检查无误后用真实参数运行："
        log "  首次: bash $0 <LABEL> 180 5 --layout"
        log "  复用: bash $0 <LABEL> 180 5"
        log "  调优: JUICEFS_MOUNT_OPTS=\"<opts>\" bash $0 <LABEL> 180 5 --remount"
        exit 0
        ;;
    "")
        echo "用法: $0 <LABEL> [RUNTIME] [REPEAT] [--layout] [--remount] [--allow-restart]"
        echo "      $0 dry-run"
        echo "      $0 softclean"
        echo ""
        echo "  --layout         第一次调用时加，执行 Phase 0 layout"
        echo "  --remount        umount + 用 JUICEFS_MOUNT_OPTS 重新挂载（调优用）"
        echo "  --allow-restart  允许在 OSD restart 后运行（缓存已重抽，非锁定布局基线）"
        echo ""
        echo "  环境变量 JUICEFS_MOUNT_OPTS 控制挂载参数（默认: --max-uploads 150 --cache-size 0）"
        echo "  例: JUICEFS_MOUNT_OPTS=\"--max-readahead 0\" $0 C 180 5 --remount"
        exit 0
        ;;
    *)
        LABEL="$1"; RUNTIME="${2:-180}"; REPEAT="${3:-5}"
        # 扫描后续参数中的 flags
        for arg in "${@:4}"; do
            if [ "$arg" = "--layout" ]; then DO_LAYOUT=true; fi
            if [ "$arg" = "--remount" ]; then DO_REMOUNT=true; fi
            if [ "$arg" = "--allow-restart" ]; then ALLOW_RESTART=true; fi
        done
        ;;
esac

log "============================================"
log "=== FULLBASELINE V2 label=${LABEL} runtime=${RUNTIME}s repeat=${REPEAT} ==="
log "=== 覆盖写模式（不 destroy/rm -rf/restart OSD）==="
log "=== layout=${DO_LAYOUT} remount=${DO_REMOUNT} ==="
log "=== mount_opts=${JUICEFS_MOUNT_OPTS} ==="
log "=== 预期 CV: randread 0.6-2% / randrw 3.1% / randwrite 8.2% ==="
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || { log "ERROR: health 非 OK"; exit 1; }
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (期望 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全"; exit 1; }

# --remount：在 layout 之前执行，确保 layout 数据写在新参数下
if [ "${DO_REMOUNT}" = "true" ]; then
    remount_jfs
fi

# Phase 0: 一次性 layout（仅 DO_LAYOUT=true 时执行）
if [ "${DO_LAYOUT}" = "true" ]; then
    phase0_layout
else
    log "=== 跳过 Phase 0（复用已有 layout）==="
    # 检查 JuiceFS 已挂载，未挂载则 re-mount（不 format，复用已有卷）
    if ! mount | grep -q juice; then
        log "  JuiceFS 未挂载，re-mount（不 format）"
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3
        mount | grep -q juice || { log "ERROR: mount failed"; exit 1; }
    fi
    mkdir -p "${TEST_DIR}"
    # 检查 layout 数据存在
    [ -f "${TEST_DIR}/storage_test.0.0" ] || { log "ERROR: layout 数据不存在（${TEST_DIR}/storage_test.0.0），请先跑 --layout"; exit 1; }
    [ -f "${TEST_DIR}/seqread/seqread.0.0" ] || { log "ERROR: seqread prep 数据不存在，请先跑 --layout"; exit 1; }
    [ -f "${TEST_DIR}/mseqread/mseqread.0.0" ] || { log "ERROR: mseqread prep 数据不存在，请先跑 --layout"; exit 1; }
    log "  layout 数据确认存在，复用"
    # 布局指纹检查（5 要素）
    current_uuid=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    current_crush=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    current_osd_stat=$(sudo ceph osd stat 2>/dev/null)
    current_up_from=$(sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(" ".join("%d:%d" % (o["osd"], o.get("up_from",0)) for o in sorted(d["osds"], key=lambda x:x["osd"])))
' 2>/dev/null || echo "N/A")
    base_uuid=$(grep '^UUID=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    base_crush=$(grep '^CRUSHMD5=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    base_up_from=$(grep '^OSD_UP_FROM=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    if [ "${base_uuid}" != "N/A" ]; then
        if [ "${current_uuid}" = "${base_uuid}" ]; then
            log "  ✅ volume UUID 一致 (${current_uuid})"
        else
            log "  🔴 volume UUID 变了! ${base_uuid} -> ${current_uuid}（重新 format 过，布局已重抽，结果不可比）"
            log "  需重跑 --layout 建立新基线"
            exit 1
        fi
        if [ "${current_crush}" = "${base_crush}" ]; then
            log "  ✅ CRUSH md5 一致 (${current_crush})（拓扑不变）"
        else
            log "  🔴 CRUSH md5 变了! ${base_crush} -> ${current_crush}"
            exit 1
        fi
        # OSD restart 检测（up_from epoch 变化 = restart 过）
        if [ "${base_up_from}" != "N/A" ] && [ "${current_up_from}" != "N/A" ]; then
            if [ "${current_up_from}" = "${base_up_from}" ]; then
                log "  ✅ OSD up_from 未变（无 restart）"
            else
                if [ "${ALLOW_RESTART}" = "true" ]; then
                    log "  ⚠️ OSD up_from 变了（restart 过），--allow-restart 已确认，继续运行"
                    log "  ⚠️ 结果在重启后缓存态下有效（非锁定布局基线，CV 可能 ~13%）"
                else
                    log "  🔴 OSD up_from 变了! 检测到 OSD restart"
                    log "  基线: ${base_up_from}"
                    log "  当前: ${current_up_from}"
                    log "  OSD restart 清空 BlueStore 缓存 = 缓存重抽（C 组实测 CV=13%）"
                    log "  如有意重启（如改 OSD 参数），请加 --allow-restart 继续"
                    log "  否则请重跑 --layout 建立新基线"
                    exit 1
                fi
            fi
        else
            log "  ⚠️ 无法读取 OSD up_from，跳过 restart 检测"
        fi
    else
        log "  ⚠️ 无基线指纹文件，无法比对（首次运行请用 --layout）"
    fi
fi

# 8 项测试（覆盖写模式，读在前写在后）
log "=== ${LABEL}: seqread ==="; item_seqread
log "=== ${LABEL}: mseqread ==="; item_mseqread
log "=== ${LABEL}: randread ==="; item_randread
log "=== ${LABEL}: randrw ==="; item_randrw
log "=== ${LABEL}: seqwrite ==="; item_seqwrite
log "=== ${LABEL}: mseqwrite ==="; item_mseqwrite
log "=== ${LABEL}: randwrite ==="; item_randwrite

# 汇总 + 稳态评估
summary
steady_state_eval
log "=== ${LABEL} DONE ==="
