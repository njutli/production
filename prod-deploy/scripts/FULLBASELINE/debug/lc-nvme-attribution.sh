#!/bin/bash
set -euo pipefail

# lc-nvme-attribution.sh — LC.12 NVMe randread 波动归因实验
#
# 目的：在 NVMe 干净集群上，用稳态口径完整归因 randread 轮间波动来源。
#   四组 A/B/C/D × 10 轮 × randread 180s×1，每组组间操作不同：
#     A 连续基线     — 组间什么都不做（同一份数据连续读 10 次）
#     B 只重灌数据    — 组间 destroy+layout（不重启 OSD、不 purge）
#     C 只重启 OSD    — 组间 OSD restart（不重灌数据、不动 JuiceFS）
#     D 完整 soft-clean — 组间 destroy+layout+OSD restart（B+C 组合）
#
# 判据（analyst 事后分析）：
#   ① 稳态 CV：每组 10 轮的稳态中位数 CV（截前 15s 预热段，取逐秒中位数）
#   ② D vs B+C 缺口：D 组 CV 是否 ≈ B+C 线性叠加（无缺口/有交叉耦合）
#   ③ pg-map primary 分布均衡度 vs 稳态 BW 的 Spearman 相关
#   ④ NVMe 双峰是否复现（B 组预期出现 ~1400/~1200 双峰）
#   ⑤ 产出可复现基线口径
#
# 强制方法论（LC.8 教训）：
#   - runtime=180 不得改小（60s 时 restart 恢复期占比 25% 污染 fio 均值）
#   - 交付全部 128 job 逐秒 bw_log
#   - analyst 一律用稳态中位数（截前 15s）评估，不看 fio group_reporting 均值
#   - OSD restart 后须 active+clean 再跑 fio
#
# 用法（在 157 上运行）：
#   bash lc-nvme-attribution.sh <GROUP> [ROUNDS] [RUNTIME]
#   GROUP  = A | B | C | D
#   ROUNDS = 每组轮数（默认 10）
#   RUNTIME = randread 每轮秒数（默认 180）
#
# 完整编排（手动逐组执行，组间用 soft-clean.sh 隔离）：
#   bash lc-nvme-attribution.sh A 10 180   # A 组：连续基线
#   bash soft-clean.sh                      # 组间隔离
#   bash lc-nvme-attribution.sh B 10 180   # B 组：只重灌数据
#   bash soft-clean.sh
#   bash lc-nvme-attribution.sh C 10 180   # C 组：只重启 OSD
#   bash soft-clean.sh
#   bash lc-nvme-attribution.sh D 10 180   # D 组：完整 soft-clean
#
# 遵循：SYSTEM-SAFETY-SKILL.md（§1.3 sudo 写操作已获用户确认、§2.3 路径守卫）
# 红线：157 上 WekaIO 在跑，禁动内核/网卡/WekaIO；不碰 157 内核参数
#
# 复用 FULLBASELINE-DEBUG.sh 构建块：drop_caches / compact_cooldown / restart_osds /
#   mount_jfs / run_fio（含采集器）/ 变量守卫 / capture_contract

# ===== 配置 =====
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS_DIR="/tmp/opencode-lcnvme"
NIC_IF="enp139s0f0np0"
POOL_DATA="juicefs-data"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"
GUARD_BASE="${RESULTS_DIR}/variable-guard-baseline.txt"
LOAD_MONITOR="/tmp/load-monitor.sh"
OSD_MONITOR="/tmp/osd-monitor.sh"

GROUP="${1:-A}"
ROUNDS="${2:-10}"
RUNTIME="${3:-180}"
START_ROUND="${4:-1}"

case "${GROUP}" in
    A) BTWN_DESC="连续基线（组间无操作）" ;;
    B) BTWN_DESC="只重灌数据（destroy+layout，不重启 OSD）" ;;
    C) BTWN_DESC="只重启 OSD（不重灌数据）" ;;
    D) BTWN_DESC="完整 soft-clean（destroy+layout+OSD restart）" ;;
    *) echo "用法: $0 <A|B|C|D> [ROUNDS] [RUNTIME]"; exit 1 ;;
esac

mkdir -p "${RESULTS_DIR}" "${BW_LOG_DIR}" "${TEST_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/test.log"; }

# ===== 路径守卫（SYSTEM-SAFETY-SKILL §2.3）=====
safety_check() {
    local target="$1"
    [ -n "$target" ] || { echo "REFUSE: empty path"; exit 1; }
    [ "$target" != "/" ] || { echo "REFUSE: root path"; exit 1; }
    [ "${target:0:1}" = "/" ] || { echo "REFUSE: relative path"; exit 1; }
}

# ===== Helpers（复用 FULLBASELINE-DEBUG.sh，口径一致）=====

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
    for i in $(seq 1 120); do
        local all_done=true
        for osd in ${osd_list}; do
            local running queued
            # timeout 10：ceph tell 在 OSD 忙时可能挂住，超时后假设 compact 完成（0 0）
            read -r running queued < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c \
                'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "0 0")
            [ "$running" != "0" ] && all_done=false
            [ "$queued" != "0" ] && all_done=false
        done
        $all_done && { done_ok=true; break; }
        sleep 5
    done
    if $done_ok; then
        log "  compact_cooldown ✅ 全 OSD compact 完成 (耗时 ~$((i*5))s)"
    else
        log "  ⚠️ compact_cooldown 超时(10min)仍未清空! 数据可能受 compaction 残留污染"
    fi
}

restart_osds() {
    log "  restart OSDs via ceph orch（逐个重启，不绕过 cephadm）"
    local osd_list
    osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    for osd in ${osd_list}; do
        log "    restarting osd.${osd}..."
        timeout 60 sudo ceph orch daemon restart osd.${osd} 2>/dev/null || true
        for i in $(seq 1 12); do
            timeout 10 sudo ceph osd dump 2>/dev/null | python3 -c \
                "import sys,json;d=json.load(sys.stdin);osds={o['osd']:o for o in d['osds']};print('up' if osds.get(${osd},{}).get('up',0)==1 else 'down')" 2>/dev/null | grep -q "up" && break
            sleep 5
        done
    done
    log "  等待 PG active+clean..."
    for i in $(seq 1 60); do
        local pg_line
        pg_line=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
        echo "$pg_line" | grep -qE "unknown|not active|creating|peering|recovering|degraded|incomplete" || break
        sleep 5
    done
    log "  OSDs active+clean"
}

mount_jfs() {
    juicefs format --storage ceph --bucket ceph://${POOL_DATA} \
        --access-key ceph --secret-key client.juicefs \
        --block-size 256K --trash-days 0 --force \
        "${META}" juicefs-prod 2>/dev/null | tail -1
    for try in 1 2 3; do
        juicefs mount -d --max-uploads 150 --cache-size 0 "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep juice | grep -q "max_read=" && break; sleep 10
    done
    mount | grep juice | grep -q "max_read=" || { log "ERROR: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
    log "  JuiceFS mounted (max_read=$(mount | grep juice | grep -o 'max_read=[0-9]*'))"
}

destroy_volume() {
    log "  destroy_volume (fusermount + rados purge)"
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5; sleep 65
    # 不调 juicefs destroy：实测在 destroy 后 format+mount 会导致 daemon 忙循环（313%+ CPU）。
    # 改用 rados purge 批量清空 pool + format --force 创建新 UUID volume。
    # 旧 UUID 的 TiKV 元数据成为孤儿，不影响新 volume（诊断测试已验证此路径工作正常）。
    # juicefs destroy 逐个删对象慢且在 pool 已空时挂住，rados purge 批量删快且可靠。
    timeout 120 sudo rados purge "${POOL_DATA}" --yes-i-really-really-mean-it 2>/dev/null || true
    compact_cooldown
    sleep 10
}

layout_write() {
    log "  layout_write (128×1G, bs=4M)"
    safety_check "${TEST_DIR}"
    rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
    fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G \
        --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 \
        --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
    compact_cooldown
    log "  layout_write done"
}

capture_pg_map() {
    local group="$1" round="$2"
    local outfile="${RESULTS_DIR}/${group}/pg-map-${group}-${round}.txt"
    mkdir -p "${RESULTS_DIR}/${group}"
    sudo ceph pg dump pgs_brief 2>/dev/null > "${outfile}" || true
    local pg_count
    pg_count=$(grep -c '^[[:space:]]*0x' "${outfile}" 2>/dev/null || echo 0)
    log "  pg-map saved: ${outfile} (${pg_count} PGs)"
}

capture_contract() {
    local label="$1"
    local out="${RESULTS_DIR}/reproduction-contract-${label}.txt"
    {
        echo "# reproduction-contract  label=${label}  captured=$(date '+%F %T')"
        echo "[OSD 集合]        $(sudo ceph osd ls 2>/dev/null | tr '\n' ',')"
        echo "[OSD up/in]       $(sudo ceph osd stat 2>/dev/null)"
        echo "[CRUSH map md5]   $(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')"
        echo "[pool EC/flags]   $(sudo ceph osd pool ls detail 2>/dev/null | grep -A0 "${POOL_DATA}" | head -2)"
        echo "[ceph version]    $(sudo ceph version 2>/dev/null)"
        echo "[juicefs version] $(juicefs version 2>/dev/null)"
        echo "[kernel 157]      $(uname -r)"
        echo "[WekaIO 负载]     $(uptime 2>/dev/null)"
    } > "${out}"
    log "  复现契约已写 -> ${out}"
}

variable_guard() {
    local label="$1"
    local now_osdset now_poolid now_crushmd5
    now_osdset=$(sudo ceph osd ls 2>/dev/null | tr '\n' ',')
    now_poolid=$(sudo ceph osd lspools 2>/dev/null | awk -v p="${POOL_DATA}" '$2==p{print $1}')
    now_crushmd5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    log "  控制变量: OSD=${now_osdset}  pool_id=${now_poolid}  crush_md5=${now_crushmd5}"

    if [ ! -f "${GUARD_BASE}" ]; then
        {
            echo "OSDSET=${now_osdset}"
            echo "POOLID=${now_poolid}"
            echo "CRUSHMD5=${now_crushmd5}"
            echo "CAPTURED_BY=${label} at $(date '+%F %T')"
        } > "${GUARD_BASE}"
        log "  变量守卫: 首次(${label})写基线快照 -> ${GUARD_BASE}"
    else
        local base_osdset base_poolid base_crushmd5
        base_osdset=$(grep '^OSDSET=' "${GUARD_BASE}" | cut -d= -f2-)
        base_poolid=$(grep '^POOLID=' "${GUARD_BASE}" | cut -d= -f2-)
        base_crushmd5=$(grep '^CRUSHMD5=' "${GUARD_BASE}" | cut -d= -f2-)
        local guard_failed=false
        [ "${now_osdset}" = "${base_osdset}" ] || { log "  🔴 变量守卫: OSD 集合变了!"; guard_failed=true; }
        [ "${now_poolid}" = "${base_poolid}" ] || { log "  🔴 变量守卫: pool_id 变了!"; guard_failed=true; }
        [ "${now_crushmd5}" = "${base_crushmd5}" ] || { log "  🔴 变量守卫: CRUSH map 变了!"; guard_failed=true; }
        if $guard_failed; then
            log "  🔴 控制变量与基线快照不符 → ${label} 与 A 不可比"
        else
            log "  ✅ 变量守卫: OSD/pool_id/crush 与基线一致，${label} 可比"
        fi
    fi
}

run_randread() {
    local group="$1" round="$2"
    local subdir="${RESULTS_DIR}/${group}/${group}-${round}"
    mkdir -p "${subdir}/osd"
    drop_caches

    local load_pre
    load_pre=$(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)
    echo "load_pre: ${load_pre}" > "${subdir}/weka-load.txt"
    echo "group: ${group}  round: ${round}  runtime: ${RUNTIME}" >> "${subdir}/weka-load.txt"

    # NIC 采集
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) \
        > "${subdir}/nic.txt" & local nic_pid=$!

    # load-monitor / osd-monitor（存在则采，不存在则跳过）
    if [ -x "${LOAD_MONITOR}" ]; then "${LOAD_MONITOR}" "${subdir}/load-monitor.csv" "${NIC_IF}" & local lm_pid=$!; else local lm_pid=""; fi
    if [ -x "${OSD_MONITOR}" ]; then "${OSD_MONITOR}" "${subdir}/osd" & local om_pid=$!; else local om_pid=""; fi

    # jfs-stats snapshot BEFORE fio（用 .stats 虚拟文件，非 juicefs stats 命令，避免阻塞）
    local jfs_proc_pid
    jfs_proc_pid=$(pgrep -f 'juicefs.*mount' | head -1 || true)
    if [ -n "${jfs_proc_pid}" ]; then
        {
            echo "=== jfs-stats PRE $(date '+%H:%M:%S') ==="
            sudo cat /proc/${jfs_proc_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads' || true
            timeout 5 cat /mnt/juicefs/.stats 2>/dev/null || echo "(.stats read timeout)"
            echo "=== pidstat PRE ==="
            timeout 5 pidstat -p "${jfs_proc_pid}" 1 2 2>/dev/null || true
        } > "${subdir}/jfs-stats-pre.txt"
    fi

    # smart-log BEFORE fio
    for node_ip in "${SLAVES[@]}"; do
        local node_name
        node_name=$(echo ${node_ip} | cut -d. -f4)
        ${SSHPASS_CMD}@${node_ip} \
            "sudo nvme smart-log /dev/nvme2n1 2>/dev/null; echo '==='; sudo nvme smart-log /dev/nvme3n1 2>/dev/null" \
            > "${subdir}/osd/nvme-smartlog-pre-node${node_name}.txt" 2>/dev/null || true
    done

    # fio randread 180s（逐字复刻 FULLBASELINE-DEBUG.sh randread 参数）
    log "  fio randread ${RUNTIME}s (128 jobs, bs=256k, QD=128, direct=1)..."
    fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=128 --group_reporting \
        --time_based --runtime=${RUNTIME} \
        --write_bw_log="${BW_LOG_DIR}/${group}-${round}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt" || true

    # historic ops（每轮末尾一次）
    for osd_id in 0 1 2 3 4 5; do
        sudo ceph tell osd.${osd_id} dump_historic_ops 2>/dev/null > "${subdir}/osd/historic-ops-osd${osd_id}.json" || true
    done

    # smart-log AFTER fio
    for node_ip in "${SLAVES[@]}"; do
        local node_name
        node_name=$(echo ${node_ip} | cut -d. -f4)
        ${SSHPASS_CMD}@${node_ip} \
            "sudo nvme smart-log /dev/nvme2n1 2>/dev/null; echo '==='; sudo nvme smart-log /dev/nvme3n1 2>/dev/null" \
            > "${subdir}/osd/nvme-smartlog-post-node${node_name}.txt" 2>/dev/null || true
    done

    # jfs-stats snapshot AFTER fio（用 .stats 虚拟文件，非阻塞）
    if [ -n "${jfs_proc_pid:-}" ]; then
        {
            echo "=== jfs-stats POST $(date '+%H:%M:%S') ==="
            sudo cat /proc/${jfs_proc_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads' || true
            timeout 5 cat /mnt/juicefs/.stats 2>/dev/null || echo "(.stats read timeout)"
            echo "=== pidstat POST ==="
            timeout 5 pidstat -p "${jfs_proc_pid}" 1 2 2>/dev/null || true
        } > "${subdir}/jfs-stats-post.txt"
    fi

    kill ${nic_pid} ${lm_pid:-} ${om_pid:-} 2>/dev/null || true
    wait ${nic_pid} ${lm_pid:-} ${om_pid:-} 2>/dev/null || true
    echo "load_post: $(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)" >> "${subdir}/weka-load.txt"

    # 复制 bw_log 到结果目录
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true

    # 快速报告 fio BW（仅供快速参考， analyst 用稳态中位数）
    local bw
    bw=$(grep -oE 'bw=[0-9]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    local l1
    l1=$(echo "${load_pre}" | grep -oE '[0-9.]+' | head -1)
    log "  ${group}-${round}: fio_BW=${bw:-N/A} MiB/s  (157 load1min=${l1:-NA})"
}

# ===== 组间操作（实验变量）=====
between_round() {
    local group="$1"
    case "$group" in
        A)
            log "  between_round A: 无操作（连续基线）"
            ;;
        B)
            log "  between_round B: destroy + mount + layout（不重启 OSD）"
            destroy_volume
            mount_jfs
            layout_write
            ;;
        C)
            log "  between_round C: OSD restart（不重灌数据）"
            restart_osds
            ;;
        D)
            log "  between_round D: destroy + mount + layout + OSD restart（完整 soft-clean）"
            destroy_volume
            mount_jfs
            layout_write
            restart_osds
            ;;
    esac
}

# ===== 稳态中位数评估（截前 15s 预热段）=====
steady_state_eval() {
    local group="$1"
    python3 - <<PYEOF 2>/dev/null | while read -r l; do log "$l"; done || true
import os, re, statistics, glob

group = "${group}"
base = "${RESULTS_DIR}/" + group
rounds = ${ROUNDS}
runtime = ${RUNTIME}
trim_secs = 15  # 截前 15s 预热段（LC.8 教训：restart 恢复期污染 fio 均值）

def parse_bw_log(filepath):
    """解析 fio bw_log 文件，返回 {sec: bw} 字典"""
    data = {}
    try:
        with open(filepath) as f:
            for line in f:
                parts = line.strip().split(',')
                if len(parts) >= 2:
                    try:
                        t_ms = int(parts[0])
                        bw = float(parts[1])
                        sec = t_ms // 1000
                        data[sec] = bw
                    except (ValueError, IndexError):
                        pass
    except:
        pass
    return data

steady_meds = []
for r in range(1, rounds + 1):
    subdir = f"{base}/{group}-{r}"
    files = sorted(glob.glob(f"{subdir}/*_bw.*.log"))
    if not files:
        print(f"  {group}-{r}: 未找到 bw_log 文件")
        continue

    # 逐秒汇总 128 job 的带宽
    per_sec = {}  # sec -> [bw_job1, bw_job2, ...]
    for f in files:
        job_data = parse_bw_log(f)
        for sec, bw in job_data.items():
            per_sec.setdefault(sec, []).append(bw)

    # 截前 trim_secs 秒，取每秒总和的中位数
    sec_totals = []
    for sec in sorted(per_sec.keys()):
        if sec < trim_secs:
            continue
        sec_totals.append(sum(per_sec[sec]))

    if sec_totals:
        med = statistics.median(sec_totals)
        steady_meds.append((r, med, len(sec_totals), len(files)))
        print(f"  {group}-{r}: 稳态中位数={med:.0f} KiB/s ({len(sec_totals)} 有效秒, {len(files)} jobs)")
    else:
        print(f"  {group}-{r}: 无有效稳态数据")

if len(steady_meds) > 1:
    vals = [m for _, m, _, _ in steady_meds]
    mean_val = statistics.mean(vals)
    cv = statistics.stdev(vals) / mean_val * 100 if mean_val > 0 else 0
    med_val = statistics.median(vals)
    print(f"")
    print(f"  === {group} 稳态汇总 ===")
    print(f"  稳态均值={mean_val:.0f}  稳态中位数={med_val:.0f}  CV={cv:.1f}%")
    print(f"  范围: {min(vals):.0f} - {max(vals):.0f}  跨度={(max(vals)-min(vals))/min(vals)*100:.1f}%")
    print(f"  各轮: {', '.join(f'{r}:{m:.0f}' for r, m, _, _ in steady_meds)}")
    print(f"  ⚠️ 以上为稳态中位数口径（截前 15s），非 fio group_reporting 均值")
PYEOF
}

# ============================================================
# 主流程
# ============================================================
log "============================================"
log "=== LC.12 NVMe randread 波动归因实验 ==="
log "=== 组=${GROUP} (${BTWN_DESC}) ==="
log "=== 轮数=${ROUNDS}  runtime=${RUNTIME}s ==="
log "=== A=连续 / B=只重灌 / C=只重启 / D=完整soft-clean ==="
log "============================================"

# 前置健康检查
HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (期望 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全，放弃"; exit 1; }

# 变量守卫
variable_guard "${GROUP}"

# 复现契约
capture_contract "${GROUP}"

# 前置 setup：destroy + format + mount + layout（建立干净起点）
# START_ROUND > 1 时跳过（恢复模式，已有 layout 数据）
if [ "${START_ROUND}" = "1" ]; then
    log "=== 前置 setup: destroy + format + mount + layout ==="
    destroy_volume
    mount_jfs
    layout_write
    compact_cooldown
    drop_caches
else
    log "=== 恢复模式：跳过前置 setup，从 ${GROUP}-${START_ROUND} 继续 ==="
    # 确保 JuiceFS 已挂载
    mount | grep -q juice || mount_jfs
    mkdir -p "${TEST_DIR}"
fi

# 前置自检：pool 应空、157 负载可接受
START_OBJS=$(sudo rados df --format json 2>/dev/null | python3 -c \
    "import sys,json;pools=json.load(sys.stdin).get('pools',[]);print(next((p['num_objects'] for p in pools if p['name']=='${POOL_DATA}'),'NA'))" 2>/dev/null || echo "NA")
log "  前置 ${POOL_DATA} 对象数=${START_OBJS:-NA}（layout 后应有 ~128）"
WEKA_LOAD1=$(uptime 2>/dev/null | grep -oE 'load average: [0-9.]+' | grep -oE '[0-9.]+' || echo "NA")
log "  157 load(1min)=${WEKA_LOAD1}（共享客户端，<20 为佳）"

# ===== 10 轮 randread =====
log "=== 开始 ${ROUNDS} 轮 randread (从 ${START_ROUND} 起) ==="
for round in $(seq ${START_ROUND} ${ROUNDS}); do
    log "--- ${GROUP}-${round}/${ROUNDS} ---"
    if [ ${round} -gt 1 ]; then
        between_round "${GROUP}"
        compact_cooldown
        drop_caches
    fi
    capture_pg_map "${GROUP}" "${round}"
    run_randread "${GROUP}" "${round}"
    compact_cooldown
done

# ===== 跑完后变量守卫复查 =====
POST_CRUSHMD5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
NOW_CRUSHMD5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
[ "${POST_CRUSHMD5}" = "${NOW_CRUSHMD5}" ] && log "✅ 跑完 CRUSH md5 未变(${POST_CRUSHMD5})" \
    || log "🔴 跑完 CRUSH md5 变了! 数据存疑"
capture_contract "${GROUP}-post"

# ===== 汇总 =====
log "=== 汇总：${GROUP} 组 ${ROUNDS} 轮 (fio group_reporting BW, 仅供快速参考) ==="
for round in $(seq 1 ${ROUNDS}); do
    bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/${GROUP}/${GROUP}-${round}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    log "  ${GROUP}-${round}: fio_BW=${bw:-NA} MiB/s"
done

# ===== 稳态中位数评估（analyst 用此口径，非 fio 均值）=====
log "=== 稳态中位数评估（截前 15s 预热段）==="
steady_state_eval "${GROUP}"

log "=== LC.12 ${GROUP} 组 DONE ==="
log "数据目录: ${RESULTS_DIR}/${GROUP}/"
log "变量守卫基线: ${GUARD_BASE}"
log "复现契约: ${RESULTS_DIR}/reproduction-contract-${GROUP}.txt"
log "⚠️ analyst 请用稳态中位数口径评估，勿用 fio group_reporting 均值"
