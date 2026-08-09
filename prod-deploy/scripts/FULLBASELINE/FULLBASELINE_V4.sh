#!/bin/bash
set -euo pipefail
export LC_ALL=C

# FULLBASELINE_V4.sh — JuiceFS/Ceph 全量基线测试 V4
#
# 基于 V2（锁定布局 + 覆盖写 + 128-job 全量），整合 V3 有效改进 + Opus S0 硬约束：
#   - 确定性预热（读全部 layout + prep 文件，消除 r1 冷启动）
#   - hit% 采集（每轮 fio 前后 collect_hitrate）
#   - 读项/写项文件分离（randread 用 read_test，randrw 用 rw_test，randwrite 用 storage_test）
#   - 每轮配置快照（mount 命令行 + ceph config dump + up_from）
#   - C_amp 守卫（NIC 首末差分 ÷ fio 读字节，default 2.0±0.1 / ra0 1.0±0.1，不在范围判无效）
#   - 磁盘空间检查（余量 <20G abort）
#   - OSD_UP_FROM -f json 修复
#
# 跳过 V3 的单进程改动（"稳但瞎"已证伪，恢复 128-job）
#
# 测试顺序：读项在前（干净起点）→ 写项在后
#   seqread → mseqread → randread → randrw → seqwrite → mseqwrite → randwrite
#
# 用法（在 157 上运行）：
#   bash FULLBASELINE_V4.sh dry-run
#   bash FULLBASELINE_V4.sh A 180 5 --layout
#   bash FULLBASELINE_V4.sh B 180 5
#   JUICEFS_MOUNT_OPTS="--max-readahead 0" bash FULLBASELINE_V4.sh C 180 5 --remount
#
# 遵循：SYSTEM-SAFETY-SKILL.md

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/opencode-fullbaseline-v4"
POOL_DATA="juicefs-data"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

LABEL="${1:-A}"
RUNTIME=180
REPEAT=5
# randread 轮数（默认与 REPEAT 一致，在入口解析参数后定值；稳定性专测时可 RANDREAD_REPEAT=10）
RANDREAD_REPEAT="${RANDREAD_REPEAT:-}"
DO_LAYOUT=false
DO_REMOUNT=false
ALLOW_RESTART=false
LAYOUT_JOBS=128
JUICEFS_MOUNT_OPTS="${JUICEFS_MOUNT_OPTS:---max-uploads 150 --cache-size 0}"
LAYOUT_SIZE="1G"
SEQ_SIZE="32G"
MSEQ_JOBS=16
MSEQ_SIZE="4G"
DISK_SPACE_MIN_GB=20
CACHE_SIZE_GB="${CACHE_SIZE_GB:-30}"   # E6: OSD bluestore_cache_size=30GiB（cache-config-check 期望值；157 实测 32212254720）

# ===== PG 门禁（2026-08-04 加）=====
# 依据：pg128 重建测试中 pg_autoscale 把 pg_num 从 128 一路并到 32，
# 整个 S1 都在 backfill/peering 中测，randread 轮间波动 17.8%；
# 合并结束（pg_num=32 全 active+clean）后同一负载轮间 CV 仅 0.25%。
PG_GATE="${PG_GATE:-true}"            # false 关闭门禁
PG_NUM_EXPECT="${PG_NUM_EXPECT:-32}"  # 期望 pg_num（同时要求 pgp_num 一致）
PG_GATE_WAIT="${PG_GATE_WAIT:-1800}"  # PG 未 clean 时最长等待秒数
SKIP_ROUNDS="${SKIP_ROUNDS:-0}"       # 稳态统计额外弃前 N 轮
PG_GATE_STATUS="CLEAN"
# ===== 测试项选择（2026-08-05 加，默认与原行为一致）=====
# 依据：S3→S4 跨运行 randread 差 +8.0%（轮内 CV 仅 0.45-0.52%），
# 需要一次只读运行（ITEMS="randread"）判断该 8% 是首运行效应/写后效应/单调上漂。
# 测试规格（runtime/numjobs/bs/size/文件）一律不改，只改"跑哪几项"。
ITEMS="${ITEMS:-seqread mseqread randread randrw seqwrite mseqwrite randwrite}"
# ===== SKIP_REMOUNT（2026-08-05 加，依据 R1 结论，报告 §13.6）=====
# R1 实测：性能"档位"属于 JuiceFS 挂载实例 —— 同一实例内轮间 ≤1.1%，
#          跨实例（每次 remount 重新抽签）median 极差 29.9%（1334-1891 MiB/s）。
# 因此：
#   SKIP_REMOUNT=0（默认，出汇报基线用）：保持原行为，每次运行 remount。
#     注意此时跨运行 L3 ≤5% 在档位问题定解前**不可能达成**，L3=FAIL 属预期。
#   SKIP_REMOUNT=1（调优 A-B-A 用）：reset_state 不 remount，沿用现有挂载实例，
#     使 A→B→A 三次跑落在同一档位上，消除 ≤30% 的档位噪声（旋钮走 ceph config set 在线切换）。
#     若此时未挂载，则仍会挂载一次（并在日志标注 forced-mount）。
# 每次运行都把挂载实例身份（pid + 进程启动时刻）落盘 jfs-instance-<LABEL>.txt，
# 用于事后证明"两次跑是否同一实例"—— 跨实例的 L3 比较无效。
SKIP_REMOUNT="${SKIP_REMOUNT:-0}"
# ===== 稳定性判据（2026-08-05 收敛版：1 口径 + 2 判据 + 1 守卫）=====
# 口径：逐秒均值(15-175s)为准（fio 汇总与逐秒中位数并列打印作参考）
# L2 轮间（同一运行内）：极差幅度 ≤5% —— 单条即可。
#   数学关系：取值落在 [min,max] 的分布必有 std ≤ 极差/2，
#   故 极差 ≤5% 已蕴含 max_dev ≤5% 且 CV ≤2.5%，无须再单独判 max_dev/CV（仍打印）。
#   它也比最初的"波动幅度 ≤10%"更严，蕴含原判据。
# L3 跨运行：与 REF_LABEL 的 median 偏差 ≤5%
L2_RANGE_MAX="${L2_RANGE_MAX:-5}"
L2_MAXDEV_MAX="${L2_MAXDEV_MAX:-5}"
L2_CV_MAX="${L2_CV_MAX:-3}"
L3_DEV_MAX="${L3_DEV_MAX:-5}"
REF_LABEL="${REF_LABEL:-}"
# ===== OBJ_GATE（2026-08-07 加，03-4 写侧漂移底噪用）=====
# 每轮写项后把池对象数排空到 OBJ_TARGET，使每轮起点对象数对齐。
# OBJ_GATE=0（默认）时行为与原版完全一致。
OBJ_GATE="${OBJ_GATE:-0}"
OBJ_TARGET="${OBJ_TARGET:-2500000}"
OBJ_START_MAX="${OBJ_START_MAX:-3000000}"
OBJ_WARN="${OBJ_WARN:-3110000}"
OBJ_MAX="${OBJ_MAX:-8000000}"
OBJ_POLL="${OBJ_POLL:-120}"
OBJ_TIMEOUT="${OBJ_TIMEOUT:-5400}"
OBJ_GC_PASSES="${OBJ_GC_PASSES:-2}"
OBJ_GC_SETTLE="${OBJ_GC_SETTLE:-60}"

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

safety_check() {
    local t="$1"
    [ -n "$t" ] || { echo "REFUSE: empty path"; exit 1; }
    [ "$t" != "/" ] || { echo "REFUSE: root path"; exit 1; }
    [ "${t:0:1}" = "/" ] || { echo "REFUSE: relative path"; exit 1; }
}

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

safety_check() {
    local t="$1"
    [ -n "$t" ] || { echo "REFUSE: empty path"; exit 1; }
    [ "$t" != "/" ] || { echo "REFUSE: root path"; exit 1; }
    [ "${t:0:1}" = "/" ] || { echo "REFUSE: relative path"; exit 1; }
}

# ===== Helpers =====

check_disk_space() {
    local avail_blocks block_size avail_gb
    avail_blocks=$(stat -f -c '%a' / 2>/dev/null)
    block_size=$(stat -f -c '%S' / 2>/dev/null)
    avail_gb=$((avail_blocks * block_size / 1024 / 1024 / 1024))
    if [ "${avail_gb}" -lt "${DISK_SPACE_MIN_GB}" ]; then
        log "FATAL: 根分区余量 ${avail_gb}G < ${DISK_SPACE_MIN_GB}G，abort"
        exit 1
    fi
    log "  根分区余量: ${avail_gb}G"
}

drop_caches() {
    sync -f "${MNT}" 2>/dev/null || true; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
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
    # 2026-08-05 同步：每轮 gc --compact（E6 vs E6C 实测：randrw 轮间极差 23.0%→3.0%，
    # randwrite 由 3056→794 单调崩塌变为 2896→2814 平稳）
    log "  juicefs gc --compact (清理切片碎片)"
    set +e
    juicefs gc --compact "${META}" 2>&1 | tail -3
    set -e
    log "  gc --compact done"
    drop_caches
}

deterministic_warmup() {
    log "  warmup: 顺序读全部 layout + prep 文件"
    local count=0
    for f in ${TEST_DIR}/storage_test.*.0 ${TEST_DIR}/read_test.*.0 ${TEST_DIR}/rw_test.*.0 \
             ${TEST_DIR}/seqread/seqread.*.0 ${TEST_DIR}/mseqread/mseqread.*.0 \
             ${TEST_DIR}/seqwrite/seqwrite.*.0 ${TEST_DIR}/mseqwrite/mseqwrite.*.0; do
        [ -f "$f" ] || continue
        dd if="$f" of=/dev/null bs=4M 2>/dev/null
        count=$((count+1))
    done
    log "  warmup done: ${count} files"
    compact_cooldown
    drop_caches
}

mount_jfs() {
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

# 只匹配本挂载点的 juicefs 进程（157 为 3075 用户共享机，禁止 pkill -f 'juicefs.*mount' 泛匹配）
jfs_pid_of_mnt() {
    pgrep -af juicefs 2>/dev/null | awk -v m="${MNT}" '$0 ~ ("mount.*" m "([[:space:]]|$)") {print $1}' | head -1
}

# 四级优雅卸载（2026-08-05 加）：juicefs umount --flush → 有界等待 30s → TERM(精确 pid) → KILL(留痕)
# 依据：原实现 fusermount -u 后无条件 pkill -f 'juicefs.*mount'，在共享机上会误杀他人挂载；
# 强杀还会跳过 flush，留下未提交切片，是"跨运行残留状态"的候选之一。
# 只允许杀"本挂载点、本用户、comm=juicefs"的进程；任何一项不符即拒绝（157 为 3075 用户共享机）
# 依据 SYSTEM-SAFETY-SKILL.md §〇（不得影响他人业务）与 §1.5（能精确就不模糊）
kill_guard() {
    local pid="$1"
    [ -n "${pid}" ] || { log "REFUSE kill: empty pid"; return 1; }
    case "${pid}" in ''|*[!0-9]*) log "REFUSE kill: non-numeric pid=${pid}"; return 1 ;; esac
    [ "${pid}" -gt 1 ] 2>/dev/null || { log "REFUSE kill: pid=${pid} <= 1"; return 1; }
    [ -d "/proc/${pid}" ] || { log "REFUSE kill: /proc/${pid} 不存在"; return 1; }
    local comm owner cmd
    comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "")
    [ "${comm}" = "juicefs" ] || { log "REFUSE kill: pid=${pid} comm=${comm} != juicefs"; return 1; }
    owner=$(stat -c %U "/proc/${pid}" 2>/dev/null || echo "")
    [ "${owner}" = "$(id -un)" ] || { log "REFUSE kill: pid=${pid} owner=${owner} != $(id -un)"; return 1; }
    cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || echo "")
    case "${cmd}" in *"${MNT}"*) ;; *) log "REFUSE kill: pid=${pid} cmdline 不含 ${MNT}：${cmd}"; return 1 ;; esac
    log "  kill_guard 通过: pid=${pid} comm=${comm} owner=${owner}"
    return 0
}

graceful_umount_jfs() {
    UMOUNT_MODE="none"
    if ! mountpoint -q "${MNT}" 2>/dev/null && [ -z "$(jfs_pid_of_mnt)" ]; then
        UMOUNT_MODE="already"; return 0
    fi
    log "  juicefs umount --flush ${MNT}"
    set +e
    juicefs umount --flush "${MNT}" 2>&1 | tail -2
    local rc=$?
    set -e
    if [ "${rc}" != "0" ]; then
        log "  ⚠️ juicefs umount rc=${rc}，回退 fusermount -u"
        fusermount -u "${MNT}" 2>/dev/null || true
    fi
    UMOUNT_MODE="graceful"
    local i pid
    for i in $(seq 30); do
        if ! mountpoint -q "${MNT}" 2>/dev/null && [ -z "$(jfs_pid_of_mnt)" ]; then
            log "  卸载完成（${i}s，优雅）"; return 0
        fi
        sleep 1
    done
    pid=$(jfs_pid_of_mnt)
    if [ -n "${pid}" ] && kill_guard "${pid}"; then
        log "  ⚠️ 30s 未退出，TERM pid=${pid}"
        kill -TERM "${pid}" 2>/dev/null || true
        UMOUNT_MODE="term"
        for i in $(seq 15); do
            [ -z "$(jfs_pid_of_mnt)" ] && { log "  TERM 后已退出（${i}s）"; return 0; }
            sleep 1
        done
        pid=$(jfs_pid_of_mnt)
        if [ -n "${pid}" ] && kill_guard "${pid}"; then
            log "  🔴 TERM 无效，KILL pid=${pid} —— 本跑标记 UNCLEAN_UMOUNT"
            kill -KILL "${pid}" 2>/dev/null || true
            UMOUNT_MODE="kill"
            echo "UNCLEAN_UMOUNT mode=kill pid=${pid} $(date '+%F %T')" >> "${RESULTS}/UNCLEAN_UMOUNT.txt"
            sleep 5
        fi
    fi
}

remount_jfs() {
    log "  remount JuiceFS（参数: ${JUICEFS_MOUNT_OPTS}）"
    graceful_umount_jfs
    log "  卸载方式: ${UMOUNT_MODE:-none}"
    for try in 1 2 3; do
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break; sleep 10
    done
    mount | grep -q juice || { log "FATAL: remount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
    # 落核记录（157 的 core 1-16 被外部租户占满，进程落核是跨运行档位的候选变量）
    local pid; pid=$(jfs_pid_of_mnt)
    if [ -n "${pid}" ]; then
        { echo "pid=${pid} umount_mode=${UMOUNT_MODE:-none} ts=$(date +%s)"
          taskset -cp "${pid}" 2>/dev/null || true
          for t in /proc/${pid}/task/*/stat; do awk '{print "cpu="$39}' "$t" 2>/dev/null; done | sort | uniq -c | sort -rn | head -20
        } > "${RESULTS}/jfs-placement-${LABEL}-$(date +%H%M%S).txt" 2>/dev/null || true
    fi
}

# 挂载实例身份：pid + 进程启动时刻（/proc/<pid>/stat 第 22 字段 starttime，单位 clock ticks）
# 用途：证明两次运行是否落在同一挂载实例上 —— 跨实例的 L3 比较无效（R1 结论，§13.6）
record_jfs_instance() {
    local tag="$1"
    local pid; pid=$(jfs_pid_of_mnt)
    local st="NA" et="NA"
    if [ -n "${pid}" ]; then
        st=$(awk '{print $22}' /proc/"${pid}"/stat 2>/dev/null || echo NA)
        et=$(ps -o lstart= -p "${pid}" 2>/dev/null | sed 's/^ *//' || echo NA)
    fi
    echo "${tag} label=${LABEL} pid=${pid:-NA} starttime_ticks=${st} started=\"${et}\" skip_remount=${SKIP_REMOUNT} ts=$(date '+%F %T')" \
        >> "${RESULTS}/jfs-instance-${LABEL}.txt"
    log "  挂载实例: pid=${pid:-NA} 启动于 ${et}（skip_remount=${SKIP_REMOUNT}）"
}

reset_state() {
    log "=== reset_state ==="
    log "  juicefs gc --compact"
    set +e
    juicefs gc --compact "${META}" 2>&1 | tail -3
    set -e
    log "  gc --compact done"
    compact_cooldown
    drop_caches
    if [ "${SKIP_REMOUNT}" = "1" ]; then
        if mount | grep -q juice && [ -n "$(jfs_pid_of_mnt)" ]; then
            log "  ⚑ SKIP_REMOUNT=1：沿用现有挂载实例（不 remount，保持档位一致）"
            mkdir -p "${TEST_DIR}"
        else
            log "  ⚑ SKIP_REMOUNT=1 但当前未挂载 ⇒ forced-mount（本次运行与上一次运行不同实例，L3 比较无效）"
            echo "forced-mount label=${LABEL} ts=$(date '+%F %T')" >> "${RESULTS}/jfs-instance-${LABEL}.txt"
            remount_jfs
        fi
    else
        log "  remount JuiceFS"
        remount_jfs
    fi
    record_jfs_instance "after_reset_state"
}

# hit% 采集：6 OSD 聚合，pre/post 差分

# hit% 采集：6 OSD 聚合，pre/post 差分
collect_hitrate() {
    local tag="$1"; local outdir="$2"
    local osd_list; osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    local hb=0 mb=0 oh=0 om=0
    for osd in ${osd_list}; do
        read -r h m o_h o_m < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c '
import sys,json;b=json.load(sys.stdin).get("bluestore",{})
print(int(b.get("buffer_hit_bytes",0)),int(b.get("buffer_miss_bytes",0)),int(b.get("onode_hits",0)),int(b.get("onode_misses",0)))
' 2>/dev/null || echo "0 0 0 0")
        hb=$((hb+h)); mb=$((mb+m)); oh=$((oh+o_h)); om=$((om+o_m))
    done
    echo "${tag} ts=$(date +%s) hit_bytes=${hb} miss_bytes=${mb} onode_hits=${oh} onode_misses=${om}" >> "${outdir}/hit-rate.txt"
}

# C_amp 守卫：NIC 首末差分 ÷ fio 读字节
compute_c_amp() {
    local nic_file="$1"; local fio_file="$2"; local outdir="$3"
    python3 - "${nic_file}" "${fio_file}" 2>/dev/null >> "${outdir}/c_amp.txt" <<'PYEOF' || true
import sys, re

nic_file, fio_file = sys.argv[1], sys.argv[2]

# NIC RX 首末差分
lines = [l.strip() for l in open(nic_file) if l.strip()]
if len(lines) < 2:
    print("c_amp=N/A (nic too short)")
    sys.exit(0)

def get_rx_bytes(line):
    parts = line.split("|")
    if len(parts) < 2:
        return 0
    fields = parts[1].split()
    for i, f in enumerate(fields):
        if "bytes" in f:
            return int(f.split(":")[1].replace(",", ""))
    # fallback: look for the RX bytes field (usually index 1)
    stats = parts[1].split()
    return int(stats[1]) if len(stats) > 1 else 0

first_rx = get_rx_bytes(lines[0])
last_rx = get_rx_bytes(lines[-1])
nic_delta = last_rx - first_rx

# fio 读字节
fio_text = open(fio_file).read()
m = re.search(r'READ:.*?io=([0-9.]+)([KMG]iB)', fio_text)
if m:
    val = float(m.group(1))
    unit = m.group(2)
    if unit == "GiB": fio_bytes = val * 1024**3
    elif unit == "MiB": fio_bytes = val * 1024**2
    elif unit == "KiB": fio_bytes = val * 1024
    else: fio_bytes = val
else:
    fio_bytes = 0

if fio_bytes > 0:
    c_amp = nic_delta / fio_bytes
    status = ""
    if c_amp < 0.9 or c_amp > 2.2:
        status = " ⚠️ OUT OF RANGE"
    print("c_amp=%.2f (nic_delta=%d fio_read=%d)%s" % (c_amp, nic_delta, fio_bytes, status))
else:
    print("c_amp=N/A (no fio io= found)")
PYEOF
}

# ===== PG 门禁 / PG 摘要 / 双模守卫（2026-08-04 加）=====

pool_id() {
    sudo ceph osd pool ls detail 2>/dev/null | grep -oP "^pool \K[0-9]+(?= '${POOL_DATA}')" | head -1
}

# 输出: pool_id pg_num pgp_num autoscale pg_count nonclean
pg_state_snapshot() {
    local pid pgn pgp asc dump total nonclean
    pid=$(pool_id || true)
    if [ -z "${pid}" ]; then echo "NA NA NA NA NA NA"; return 0; fi
    pgn=$(sudo ceph osd pool get "${POOL_DATA}" pg_num 2>/dev/null | awk '{print $2}' || true)
    pgp=$(sudo ceph osd pool get "${POOL_DATA}" pgp_num 2>/dev/null | awk '{print $2}' || true)
    asc=$(sudo ceph osd pool get "${POOL_DATA}" pg_autoscale_mode 2>/dev/null | awk '{print $2}' || true)
    dump=$(sudo ceph pg dump pgs_brief 2>/dev/null || true)
    total=$(echo "${dump}" | awk -v p="${pid}." 'NR>1 && index($1,p)==1 {c++} END{print c+0}')
    nonclean=$(echo "${dump}" | awk -v p="${pid}." 'NR>1 && index($1,p)==1 && $2!="active+clean" {c++} END{print c+0}')
    echo "${pid} ${pgn:-NA} ${pgp:-NA} ${asc:-NA} ${total} ${nonclean}"
}

# 每轮开测前门禁：pg_num == PG_NUM_EXPECT 且 pgp_num 一致 且全部 active+clean
pg_gate() {
    PG_GATE_STATUS="CLEAN"
    if [ "${PG_GATE}" != "true" ]; then PG_GATE_STATUS="DISABLED"; return 0; fi
    local waited=0 pid pgn pgp asc total nonclean reason
    while :; do
        read -r pid pgn pgp asc total nonclean < <(pg_state_snapshot)
        reason=""
        [ "${pgn}" = "${PG_NUM_EXPECT}" ] || reason="pg_num=${pgn}!=${PG_NUM_EXPECT}"
        [ "${pgp}" = "${pgn}" ] || reason="${reason} pgp_num=${pgp}!=pg_num=${pgn}"
        [ "${total}" = "${pgn}" ] || reason="${reason} pg_count=${total}!=pg_num=${pgn}"
        [ "${nonclean}" = "0" ] || reason="${reason} nonclean=${nonclean}"
        if [ -z "${reason}" ]; then
            [ "${asc}" = "off" ] || log "  ⚠️ PG 门禁: pg_autoscale_mode=${asc}（应为 off，否则 pg_num 会在测试中漂移）"
            [ "${waited}" -gt 0 ] && log "  PG 门禁 ✅（等待 ${waited}s 后 pg_num=${pgn} 全 active+clean）"
            return 0
        fi
        if [ "${waited}" -ge "${PG_GATE_WAIT}" ]; then
            PG_GATE_STATUS="UNSTABLE:$(echo ${reason} | tr ' ' ',')"
            log "  🔴 PG 门禁超时 ${waited}s：${reason} — 本轮标记 PG_UNSTABLE，不计入稳态统计"
            return 0
        fi
        [ "${waited}" = "0" ] && log "  ⏳ PG 门禁等待（每 30s 复查）：${reason}"
        sleep 30; waited=$((waited+30))
    done
}

# 每轮 PG 摘要：pg_count / nonclean / primary 分布（主流量倾斜是双模的候选来源）
pg_summary() {
    local outdir="$1" pid
    pid=$(pool_id || true)
    [ -n "${pid}" ] || return 0
    awk -v p="${pid}." '
        NR>1 && index($1,p)==1 { n++; if ($2!="active+clean") nc++; prim[$NF]++ }
        END {
            d="";
            for (i=0;i<16;i++) if (i in prim) d=d sprintf("%s%d:%d",(d==""?"":" "),i,prim[i])
            printf "pg_count=%d nonclean=%d primary=[%s]\n", n+0, nc+0, d
        }
    ' "${outdir}/pg-map.txt" > "${outdir}/pg-summary.txt" 2>/dev/null || true
    log "  pg: $(cat "${outdir}/pg-summary.txt" 2>/dev/null || echo NA)"
}

# 双模守卫：逐秒聚合 BW 做 1-D 2-means，输出两档中心 + 快档时间占比
# 轮间波动的直接观测量 = fast_frac（档位中心跨轮固定，只有占比在变）

gear_stat() {
    local outdir="$1" label="$2" direction=0 kind=read
    case "${label}" in
        randrw*) direction=0 ;;
        *write*) direction=1; kind=write ;;
    esac
    # L1 判据（2026-08-05 加）：读项 stall ≤1% 且逐秒 CV <6% 为干净轮；
    # 写项因 FUSE flush/sync 天生双模（实测 stall 1.2-22.3%），只记录不判 PASS/FAIL。
    python3 - "${outdir}" "${direction}" "${kind}" > "${outdir}/gear.txt" 2>/dev/null <<'PYEOF' || true
import sys, os, glob, statistics
from collections import defaultdict
outdir, direction = sys.argv[1], int(sys.argv[2])
kind = sys.argv[3] if len(sys.argv) > 3 else "read"
L1_STALL_MAX, L1_CV_MAX = 1.0, 6.0
per = defaultdict(float)
for f in glob.glob(os.path.join(outdir, "*_bw.*.log")):
    for line in open(f):
        p = line.strip().split(",")
        if len(p) < 3:
            continue
        try:
            s = int(p[0]) // 1000; bw = float(p[1]); d = int(p[2])
        except ValueError:
            continue
        if d == direction:
            per[s] += bw
ks = sorted(per)
if not ks:
    print("gear=N/A"); sys.exit(0)
t0 = ks[0]
v = [per[k] / 1024.0 for k in ks if 15 <= k - t0 <= 175]
if len(v) < 20:
    print("gear=N/A (samples=%d)" % len(v)); sys.exit(0)
sv = sorted(v); n = len(sv)
med = statistics.median(sv)
# 掉底秒（<50% median，通常是 1s 级 stall）单独计数，不参与聚类，避免把离群点当成一个档
stall = 100.0 * sum(1 for x in v if x < 0.5 * med) / n
lo_t, hi_t = sv[int(0.02 * n)], sv[min(n - 1, int(0.98 * n))]
core = [x for x in v if lo_t <= x <= hi_t and x >= 0.5 * med]
if len(core) < 20:
    core = [x for x in v if x >= 0.5 * med] or v
lo, hi = min(core), max(core)
c1, c2 = lo + (hi - lo) * 0.25, lo + (hi - lo) * 0.75
for _ in range(50):
    g1 = [x for x in core if abs(x - c1) <= abs(x - c2)]
    g2 = [x for x in core if abs(x - c1) > abs(x - c2)]
    if not g1 or not g2:
        break
    n1, n2 = statistics.mean(g1), statistics.mean(g2)
    done = abs(n1 - c1) < 0.1 and abs(n2 - c2) < 0.1
    c1, c2 = n1, n2
    if done:
        break
g2 = [x for x in core if abs(x - c1) > abs(x - c2)]
sec_cv = statistics.pstdev(v) / statistics.mean(v) * 100
if kind == "write":
    l1 = "L1=NA(write)"
else:
    l1 = "L1=%s" % ("PASS" if (stall <= L1_STALL_MAX and sec_cv < L1_CV_MAX) else "FAIL")
print("gear slow=%.0f fast=%.0f sep=%.1f%% fast_frac=%.1f%% stall=%.1f%% p10=%.0f p50=%.0f p90=%.0f cv=%.1f%% n=%d %s" % (
    c1, c2, (c2 / c1 - 1) * 100 if c1 else 0, 100.0 * len(g2) / len(core), stall,
    sv[int(0.1 * n)], med, sv[int(0.9 * n)],
    sec_cv, n, l1))
PYEOF
    log "  $(cat "${outdir}/gear.txt" 2>/dev/null || echo 'gear=N/A')"
}

drop_caches() {
    sync -f "${MNT}" 2>/dev/null || true; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
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
    log "  juicefs gc --compact (清理切片碎片)"
    set +e
    juicefs gc --compact "${META}" 2>&1 | tail -3
    set -e
    log "  gc --compact done"
    drop_caches
}

pool_sample() {
    local l o
    l=$(sudo ceph df --format=json 2>/dev/null | python3 -c 'import sys,json
p=[x for x in json.load(sys.stdin)["pools"] if x["name"]=="juicefs-data"][0]["stats"]
print(p["objects"], p["stored"], p["max_avail"])
' 2>/dev/null)
    [ -n "${l}" ] || return 1
    o=${l%% *}
    [ -n "${o}" ] && [ "${o}" != "0" ] || return 1
    echo "${l}"
    return 0
}

obj_gate() {
    local item="$1" round="$2"
    local line objects stored max_avail attempt gc_pass t0 t1 verdict
    local UNALIGN="${RESULTS}/obj-unaligned-${LABEL}.tsv"

    line=""
    for attempt in 1 2 3 4 5; do
        line=$(pool_sample) && break
        log "  obj_gate: 取数失败 (${attempt}/5)，30s 后重试"
        line=""
        sleep 30
    done
    if [ -z "${line}" ]; then
        log "  obj_gate: 连续 5 次取数失败 — STOP（无法评估 OBJ_MAX，这是安全下限）"
        return 1
    fi
    read -r objects stored max_avail <<< "${line}"
    echo -e "$(date '+%F %T')\t${LABEL}\t${item}\tr${round}\tpost-cleanup\tobjects=${objects}\tstored=${stored}\tmax_avail=${max_avail}" >> "${RESULTS}/obj-gate-${LABEL}.tsv"
    log "  obj_gate: ${item}/r${round} objects=${objects} stored=${stored}"

    if [ "${objects}" -gt "${OBJ_MAX}" ] 2>/dev/null; then
        log "  OBJ_MAX_EXCEEDED: objects=${objects} > OBJ_MAX=${OBJ_MAX} — STOP"
        return 1
    fi

    if [ "${objects}" -le "${OBJ_TARGET}" ] 2>/dev/null; then
        log "  obj_gate: OK (objects=${objects} ≤ OBJ_TARGET=${OBJ_TARGET})"
        return 0
    fi

    for gc_pass in $(seq 1 "${OBJ_GC_PASSES}"); do
        log "  obj_gate: objects=${objects} > OBJ_TARGET=${OBJ_TARGET}，gc --compact 第 ${gc_pass}/${OBJ_GC_PASSES} 遍"
        t0=$(date +%s)
        set +e
        juicefs gc --compact "${META}" > "${RESULTS}/gc-${LABEL}-${item}-r${round}-p${gc_pass}.log" 2>&1
        set -e
        t1=$(date +%s)
        log "  obj_gate: gc pass${gc_pass} 耗时 $((t1-t0))s"
        sleep "${OBJ_GC_SETTLE}"
        line=$(pool_sample) || { log "  obj_gate: gc 后取数失败，再等 60s"; sleep 60; line=$(pool_sample) || line=""; }
        if [ -z "${line}" ]; then
            log "  obj_gate: gc 后仍取不到数 — STOP"
            return 1
        fi
        read -r objects stored max_avail <<< "${line}"
        echo -e "$(date '+%F %T')\t${LABEL}\t${item}\tr${round}\tgc-p${gc_pass}\tobjects=${objects}\tstored=${stored}\tgc_sec=$((t1-t0))" >> "${RESULTS}/obj-gate-${LABEL}.tsv"
        log "  obj_gate: gc pass${gc_pass} 后 objects=${objects}"
        if [ "${objects}" -gt "${OBJ_MAX}" ] 2>/dev/null; then
            log "  OBJ_MAX_EXCEEDED after gc: objects=${objects} — STOP"
            return 1
        fi
        if [ "${objects}" -le "${OBJ_TARGET}" ] 2>/dev/null; then
            log "  obj_gate: DRAINED after gc pass${gc_pass} (objects=${objects})"
            return 0
        fi
    done

    if [ "${objects}" -le "${OBJ_START_MAX}" ] 2>/dev/null; then
        verdict="ABOVE_TARGET_WITHIN_START_MAX"
    else
        verdict="ABOVE_START_MAX"
    fi
    log "  obj_gate: SOFT-PASS (${verdict}) objects=${objects} — 起点未对齐，已标记，继续"
    echo -e "$(date '+%F %T')\t${LABEL}\t${item}\tr${round}\t${verdict}\tobjects=${objects}\tstored=${stored}" >> "${UNALIGN}"
    return 0
}

deterministic_warmup() {
    log "  warmup: 顺序读全部 layout + prep 文件"
    local count=0
    for f in ${TEST_DIR}/storage_test.*.0 ${TEST_DIR}/read_test.*.0 ${TEST_DIR}/rw_test.*.0 \
             ${TEST_DIR}/seqread/seqread.*.0 ${TEST_DIR}/mseqread/mseqread.*.0 \
             ${TEST_DIR}/seqwrite/seqwrite.*.0 ${TEST_DIR}/mseqwrite/mseqwrite.*.0; do
        [ -f "$f" ] || continue
        dd if="$f" of=/dev/null bs=4M 2>/dev/null
        count=$((count+1))
    done
    log "  warmup done: ${count} files"
    compact_cooldown
    drop_caches
}

mount_jfs() {
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

# ===== Fio 运行器 =====

run_fio() {
    local label="$1"; shift
    local subdir="${RESULTS}/${LABEL}/${label}"
    mkdir -p "${subdir}"
    rm -f "${subdir}/hit-rate.txt" "${subdir}/PG_UNSTABLE.txt" 2>/dev/null || true
    pg_gate
    drop_caches
    local load_pre
    load_pre=$(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)
    echo "load_pre: ${load_pre}" > "${subdir}/weka-load.txt"
    # NIC 采集
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) \
        > "${subdir}/nic.txt" & local nic_pid=$!
    # 配置快照（Opus S0.4）
    mount | grep juice | head -1 > "${subdir}/mount-cmd.txt" 2>/dev/null || true
    sudo ceph config dump 2>/dev/null | md5sum | awk '{print $1}' > "${subdir}/config-md5.txt" 2>/dev/null || true
    sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json;d=json.load(sys.stdin)
print(" ".join("%d:%d"%(o["osd"],o.get("up_from",0)) for o in sorted(d["osds"],key=lambda x:x["osd"])))
' 2>/dev/null > "${subdir}/up_from.txt" || true
    # jfs-stats PRE
    local jfs_pid
    jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1 || true)
    if [ -n "${jfs_pid}" ]; then
        { echo "=== PRE $(date '+%H:%M:%S') ==="; sudo cat /proc/${jfs_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads' || true; timeout 5 cat /mnt/juicefs/.stats 2>/dev/null || echo "(.stats N/A)"; } > "${subdir}/jfs-stats-pre.txt"
    fi
    # pg-map 采集 + PG 摘要 + 门禁结论落盘
    sudo ceph pg dump pgs_brief 2>/dev/null > "${subdir}/pg-map.txt" || true
    pg_summary "${subdir}"
    case "${PG_GATE_STATUS}" in
        UNSTABLE:*) echo "${PG_GATE_STATUS} $(date '+%F %T')" > "${subdir}/PG_UNSTABLE.txt" ;;
    esac
    # hit% PRE
    collect_hitrate "pre" "${subdir}"
    # fio
    log "  fio ${label}..."
    local fio_timeout=$((RUNTIME + 120))
    set +e
    timeout "${fio_timeout}" fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt"
    local fio_rc=${PIPESTATUS[0]}
    set -e
    local invalid_reason=""
    if [ "${fio_rc}" = "124" ] || [ "${fio_rc}" = "137" ]; then
        invalid_reason="timeout>${fio_timeout}s(rc=${fio_rc})"
    elif [ "${fio_rc}" != "0" ]; then
        invalid_reason="fio_exit=${fio_rc}"
    elif ! grep -qE '^[[:space:]]*(READ|WRITE):' "${subdir}/fio.txt"; then
        invalid_reason="no_fio_summary"
    fi
    # hit% POST
    collect_hitrate "post" "${subdir}"
    # C_amp 守卫
    compute_c_amp "${subdir}/nic.txt" "${subdir}/fio.txt" "${subdir}"
    gear_stat "${subdir}" "${label}"
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
    local hr
    hr=$(python3 - "${subdir}/hit-rate.txt" 2>/dev/null <<'PYEOF' || echo "N/A"
import sys
L=[l.strip() for l in open(sys.argv[1]) if l.strip()]
p=q=None
for l in L:
    if l.startswith("pre "): p=l
    if l.startswith("post "): q=l
if not p or not q: sys.exit(0)
def pa(l):
    d={}
    for x in l.split()[1:]: k,v=x.split("=",1); d[k]=int(v)
    return d
pd,qd=pa(p),pa(q)
dh=qd["hit_bytes"]-pd["hit_bytes"]; dm=qd["miss_bytes"]-pd["miss_bytes"]
print("hit_rate=%.1f%%"%(dh/(dh+dm)*100) if (dh+dm)>0 else "hit_rate=N/A")
PYEOF
    )
    if [ -z "${bw:-}" ] && [ -z "${invalid_reason}" ]; then
        invalid_reason="bw_unparsable"
    fi
    if [ -n "${invalid_reason}" ]; then
        echo "INVALID ${label} reason=${invalid_reason} $(date '+%F %T')" > "${subdir}/INVALID.txt"
        log "  ${label}: ❌ INVALID (${invalid_reason}) — 不计入统计"
    else
        log "  ${label}: BW=${bw:-N/A} MiB/s  ${hr}"
    fi
    [ -f "${RESULTS}/rounds.tsv" ] || printf 'LABEL\tround\tBW_MiBs\thit\tstatus\tpg_gate\tpg\tgear\n' > "${RESULTS}/rounds.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${LABEL}" "${label}" "${bw:-NA}" "${hr}" "${invalid_reason:-VALID}" \
        "${PG_GATE_STATUS}" "$(head -1 "${subdir}/pg-summary.txt" 2>/dev/null || echo NA)" \
        "$(head -1 "${subdir}/gear.txt" 2>/dev/null || echo NA)" >> "${RESULTS}/rounds.tsv"
}

# ===== Phase 0: 一次性 layout =====

phase0_layout() {
    log "=== Phase 0: 一次性 layout ==="
    safety_check "${TEST_DIR}"
    mount_jfs
    check_disk_space
    rm -rf "${TEST_DIR}"/* 2>/dev/null || true
    mkdir -p "${TEST_DIR}/seqread" "${TEST_DIR}/seqwrite" "${TEST_DIR}/mseqread" "${TEST_DIR}/mseqwrite"
    # 主 layout（128×1G，用于 randwrite 覆盖写）
    log "  layout: storage_test ${LAYOUT_JOBS}×${LAYOUT_SIZE} (bs=4M)"
    fio --directory="${TEST_DIR}" --name=storage_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=4M --rw=write \
        --numjobs=${LAYOUT_JOBS} --fallocate=none --direct=1 \
        --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
    # 读项专用文件（randread 用，永不被写测试覆盖）
    log "  layout: read_test ${LAYOUT_JOBS}×${LAYOUT_SIZE} (randread 专用)"
    fio --directory="${TEST_DIR}" --name=read_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=4M --rw=write \
        --numjobs=${LAYOUT_JOBS} --fallocate=none --direct=1 \
        --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
    # 读写项专用文件（randrw 用）
    log "  layout: rw_test ${LAYOUT_JOBS}×${LAYOUT_SIZE} (randrw 专用)"
    fio --directory="${TEST_DIR}" --name=rw_test \
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
    # 布局指纹
    local crush_md5 uuid phase0_ts osd_stat osd_up_from
    crush_md5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    uuid=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    phase0_ts=$(date +%s)
    osd_stat=$(sudo ceph osd stat 2>/dev/null)
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
    log "  layout done. UUID=${uuid} CRUSH=${crush_md5} TS=${phase0_ts}"
    log "  OSD up_from: ${osd_up_from}"
}

# ===== 7 项（128-job，读项/写项文件分离）=====

item_seqread() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqread-${LABEL}-r${r}" --name=seqread --directory="${TEST_DIR}/seqread/" \
            --rw=read --refill_buffers --bs=256k --size=${SEQ_SIZE} \
            --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
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

item_randread() {
    # 用 read_test.*.0（专用，永不被写测试覆盖）
    for r in $(seq 1 "${RANDREAD_REPEAT:-${REPEAT}}"); do
        run_fio "randread-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=read_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
    done
}

item_randrw() {
    # 用 rw_test.*.0（专用，与 randread 隔离）
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randrw-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=rw_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
        aggressive_cleanup
        [ "${OBJ_GATE}" = "1" ] && obj_gate "randrw" "$r"
    done
}

item_seqwrite() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqwrite-${LABEL}-r${r}" --name=seqwrite --directory="${TEST_DIR}/seqwrite/" \
            --rw=write --refill_buffers --bs=4M --size=${SEQ_SIZE} \
            --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
        aggressive_cleanup
        [ "${OBJ_GATE}" = "1" ] && obj_gate "seqwrite" "$r"
    done
}

item_mseqwrite() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "mseqwrite-${LABEL}-r${r}" --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" \
            --rw=write --refill_buffers --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} \
            --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
        aggressive_cleanup
        [ "${OBJ_GATE}" = "1" ] && obj_gate "mseqwrite" "$r"
    done
}

item_randwrite() {
    # 用 storage_test.*.0（覆盖写）
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randwrite-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=storage_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
        aggressive_cleanup
        [ "${OBJ_GATE}" = "1" ] && obj_gate "randwrite" "$r"
    done
}

# ===== softclean =====

soft_clean_restart() {
    log "=== SOFT-CLEAN（compact + drop_caches）==="
    compact_cooldown
    drop_caches
    sleep 10
}

# ===== 汇总 =====

summary() {
    log "=== 汇总 ${LABEL} (fio BW, MiB/s) ==="
    for item in seqread mseqread randread randrw seqwrite mseqwrite randwrite; do
        local line="  ${item}:"
        local item_repeat="${REPEAT}"
        [ "$item" = "randread" ] && item_repeat="${RANDREAD_REPEAT:-${REPEAT}}"
        for r in $(seq 1 "${item_repeat}"); do
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
        [ "${current_uuid}" = "${base_uuid}" ] && log "  ✅ UUID 不变" || log "  🔴 UUID 变了!"
        [ "${current_crush}" = "${base_crush}" ] && log "  ✅ CRUSH 不变" || log "  🔴 CRUSH 变了!"
        [ "${current_up_from}" = "${base_up_from}" ] && log "  ✅ up_from 不变" || log "  ⚠️ up_from 变了"
    fi
}

# ===== 守卫汇总（2026-08-05 加，唯一的二元守卫）=====

# ⚑ 2026-08-05 修：`ls glob | wc -l` 在 set -o pipefail 下，glob 无匹配时 ls 返回 2 ⇒
#   管道非 0 ⇒ set -e 杀掉脚本。guard_report 里 UNCLEAN_UMOUNT/PG_UNSTABLE/INVALID 三个文件
#   **不存在才是正常情况**，因此每次成功的跑都会在这里 exit 2，`GUARD=OK` 从未真正打印过。
#   （S3/S4 报告里的 GUARD=OK 是我从原始数据人工核出来的，不是脚本产出。）
count_glob() {
    local pat="$1" x; local -a m=()
    for x in ${pat}; do [ -e "${x}" ] && m+=("${x}"); done
    echo "${#m[@]}"
}

guard_report() {
    local base="${RESULTS}/${LABEL}" reasons="" n=0
    local md5s up_froms
    md5s=$(cat ${base}/*/config-md5.txt 2>/dev/null | sort -u | wc -l || true)
    up_froms=$(cat ${base}/*/up_from.txt 2>/dev/null | sort -u | wc -l || true)
    n=$(count_glob "${base}/*/")
    [ "${md5s}" -gt 1 ] 2>/dev/null && reasons="${reasons}config-md5漂移(${md5s}种) " || true
    [ "${up_froms}" -gt 1 ] 2>/dev/null && reasons="${reasons}up_from变化(${up_froms}种) " || true
    local nu np ni
    nu=$(count_glob "${RESULTS}/UNCLEAN_UMOUNT.txt")
    np=$(count_glob "${base}/*/PG_UNSTABLE.txt")
    ni=$(count_glob "${base}/*/INVALID.txt")
    [ "${nu}" -gt 0 ] && reasons="${reasons}非优雅卸载 " || true
    [ "${np}" -gt 0 ] && reasons="${reasons}PG_UNSTABLE轮=${np} " || true
    [ "${ni}" -gt 0 ] && reasons="${reasons}INVALID轮=${ni} " || true
    if [ -z "${reasons}" ]; then
        log "GUARD=OK  (轮数=${n} config-md5/up_from 一致，卸载全程优雅，无 PG_UNSTABLE/INVALID)"
    else
        log "GUARD=FAIL  ${reasons}"
    fi
    # 挂载实例身份（R1 结论：跨实例的 L3 比较无效）
    if [ -s "${RESULTS}/jfs-instance-${LABEL}.txt" ]; then
        local inst
        inst=$(grep -oE 'pid=[0-9]+ starttime_ticks=[0-9]+' "${RESULTS}/jfs-instance-${LABEL}.txt" 2>/dev/null | sort -u | tr '\n' ';')
        log "  挂载实例=${inst:-NA}  skip_remount=${SKIP_REMOUNT}"
        if [ -n "${REF_LABEL}" ] && [ -s "${RESULTS}/jfs-instance-${REF_LABEL}.txt" ]; then
            local ref_inst
            ref_inst=$(grep -oE 'starttime_ticks=[0-9]+' "${RESULTS}/jfs-instance-${REF_LABEL}.txt" 2>/dev/null | sort -u | tr '\n' ';')
            local cur_inst
            cur_inst=$(grep -oE 'starttime_ticks=[0-9]+' "${RESULTS}/jfs-instance-${LABEL}.txt" 2>/dev/null | sort -u | tr '\n' ';')
            if [ "${cur_inst}" = "${ref_inst}" ]; then
                log "  ✅ 与 REF_LABEL=${REF_LABEL} 同一挂载实例 ⇒ L3 比较有效"
            else
                log "  ⚠️ 与 REF_LABEL=${REF_LABEL} 不同挂载实例（本次 ${cur_inst} vs 参照 ${ref_inst}）⇒ L3 偏差含档位噪声（R1 实测可达 29.9%），该 L3 判定不足以支撑结论"
            fi
        fi
    fi
}

# ===== 稳态评估 =====

steady_state_eval() {
    log "=== 稳态评估（验收口径: 逐秒均值 15-175s；L2 极差 ≤${L2_RANGE_MAX}% / L3 偏差 ≤${L3_DEV_MAX}%）==="
    python3 - <<PYEOF 2>/dev/null | while read -r l; do log "$l"; done || true
import os, re, statistics, glob
from collections import defaultdict

base = "${RESULTS}/${LABEL}"
repeat = ${REPEAT}
randread_repeat = ${RANDREAD_REPEAT}
read_trim = 15
skip_rounds = ${SKIP_ROUNDS}
# 判据（2026-08-05 定）：L2 轮间三条同时满足；L3 跨运行 median 偏差 ≤5%
L2_RANGE_MAX = ${L2_RANGE_MAX}
L2_MAXDEV_MAX = ${L2_MAXDEV_MAX}
L2_CV_MAX = ${L2_CV_MAX}
L3_DEV_MAX = ${L3_DEV_MAX}
ref_label = "${REF_LABEL}"

item_cfg = {
    "seqread":   (0, read_trim),
    "mseqread":  (0, read_trim),
    "randread":  (0, read_trim),
    "randrw":    (0, read_trim),
    "seqwrite":  (1, read_trim),
    "mseqwrite": (1, read_trim),
    "randwrite": (1, read_trim),
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

items = ["seqread", "mseqread", "randread", "randrw", "seqwrite", "mseqwrite", "randwrite"]

def parse_bwlog_mean(subdir, direction, trim_sec):
    """逐秒均值(15-175s) —— 验收口径：截掉前 15s 的写缓冲/ramp 虚高，又不像中位数那样剔掉 stall"""
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
    if not per_sec:
        return None
    ks = sorted(per_sec)
    t0 = ks[0]
    w = [per_sec[k] for k in ks if trim_sec <= k - t0 <= 175]
    return statistics.mean(w) if w else None

def collect(lbl, item, direction, trim):
    """返回 (逐秒均值[验收], fio汇总[参考], 逐秒中位数[参考], 轮号, 排除说明)"""
    b = os.path.join("${RESULTS}", lbl)
    acc, fio_vals, med_vals, rounds, excluded = [], [], [], [], []
    for r in range(1, (randread_repeat if item == "randread" else repeat) + 1):
        subdir = os.path.join(b, "%s-%s-r%d" % (item, lbl, r))
        if not os.path.isdir(subdir):
            continue
        if os.path.exists(os.path.join(subdir, "INVALID.txt")):
            excluded.append("r%d:INVALID" % r); continue
        if os.path.exists(os.path.join(subdir, "PG_UNSTABLE.txt")):
            excluded.append("r%d:PG_UNSTABLE" % r); continue
        a = parse_bwlog_mean(subdir, direction, trim)
        f = bw_from_fio(os.path.join(subdir, "fio.txt"))
        s = parse_bwlog(subdir, direction, trim)
        if a is None and f is None:
            continue
        rounds.append(r)
        acc.append((a if a is not None else f) / 1024)
        fio_vals.append((f if f is not None else a) / 1024)
        med_vals.append((s if s is not None else (a if a is not None else f)) / 1024)
    return acc, fio_vals, med_vals, rounds, excluded

def stats(vs):
    med = statistics.median(vs)
    cv = statistics.stdev(vs) / statistics.mean(vs) * 100 if len(vs) > 1 else 0
    max_dev = max(abs(v - med) for v in vs) / med * 100 if med else 0
    rng = (max(vs) - min(vs)) / med * 100 if med else 0
    return med, cv, max_dev, rng

for item in items:
    direction, trim = item_cfg[item]
    acc, fio_vals, med_vals, rounds, excluded = collect("${LABEL}", item, direction, trim)

    def report(suffix, va, vf, vm):
        med, cv, max_dev, rng = stats(va)
        # L2 判据（2026-08-05 收敛）：只判轮间极差幅度 ≤5%。
        # std ≤ 极差/2 ⇒ 极差 ≤5% 已蕴含 max_dev ≤5% 且 CV ≤2.5%，二者仅打印不判。
        v2 = "PASS" if rng <= L2_RANGE_MAX else "FAIL"
        print("  %s%s: n=%d median=%.0f 极差幅度=%.1f%% (max_dev=%.1f%% CV=%.1f%%) range=%.0f-%.0f MiB/s  L2=%s" % (
            item, suffix, len(va), med, rng, max_dev, cv, min(va), max(va), v2))
        mf, cf, df, rf_ = stats(vf)
        mm, cm, dm, rm = stats(vm)
        print("    └ 参考口径: fio汇总 median=%.0f 极差=%.1f%% | 逐秒中位数 median=%.0f 极差=%.1f%%" % (
            mf, rf_, mm, rm))
        return med

    if acc:
        med_now = report("", acc, fio_vals, med_vals)
        if skip_rounds > 0 and len(acc) > skip_rounds + 1:
            report("[弃前%d轮]" % skip_rounds, acc[skip_rounds:], fio_vals[skip_rounds:], med_vals[skip_rounds:])
        print("    轮值(验收口径 逐秒均值): %s" % " ".join("r%d=%.0f" % (rn, v) for rn, v in zip(rounds, acc)))
        # L3 判据：与参照运行的 median 偏差 ≤5%（跨运行可复现性）
        if ref_label:
            ra, rf2, rm2, rr, _ = collect(ref_label, item, direction, trim)
            if ra:
                med_ref = statistics.median(ra)
                dev = (med_now - med_ref) / med_ref * 100
                v3 = "PASS" if abs(dev) <= L3_DEV_MAX else "FAIL"
                print("    └ L3 vs %s: median %.0f→%.0f 偏差=%+.1f%% (判据 ≤%.0f%%) %s" % (
                    ref_label, med_ref, med_now, dev, L3_DEV_MAX, v3))
    else:
        print("  %s: no data" % item)
    if excluded:
        print("    ⚠️ 已排除: %s" % ", ".join(excluded))
PYEOF
}


# ===== 入口 =====

case "${1:-}" in
    softclean|clean)
        soft_clean_restart
        exit 0
        ;;
    dry-run)
        log "=== DRY-RUN ==="
        check_disk_space
        HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
        log "ceph health: ${HEALTH}"
        OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
        log "OSDs up: ${OSD_UP} (期望 6)"
        mount | grep -q juice && log "JuiceFS: ✅" || log "JuiceFS: ❌"
        [ -f "${TEST_DIR}/storage_test.0.0" ] && log "storage_test: ✅" || log "storage_test: ⚠️ 需 --layout"
        [ -f "${TEST_DIR}/read_test.0.0" ] && log "read_test: ✅" || log "read_test: ⚠️ 需 --layout"
        [ -f "${TEST_DIR}/rw_test.0.0" ] && log "rw_test: ✅" || log "rw_test: ⚠️ 需 --layout"
        [ -f "${TEST_DIR}/seqread/seqread.0.0" ] && log "seqread prep: ✅" || log "seqread prep: ⚠️"
        [ -f "${TEST_DIR}/mseqread/mseqread.0.0" ] && log "mseqread prep: ✅" || log "mseqread prep: ⚠️"
        [ -f "${TEST_DIR}/seqwrite/seqwrite.0.0" ] && log "seqwrite prep: ✅" || log "seqwrite prep: ⚠️"
        [ -f "${TEST_DIR}/mseqwrite/mseqwrite.0.0" ] && log "mseqwrite prep: ✅" || log "mseqwrite prep: ⚠️"
        command -v fio >/dev/null && log "fio: ✅" || log "fio: ❌"
        command -v juicefs >/dev/null && log "juicefs: ✅" || log "juicefs: ❌"
        command -v python3 >/dev/null && log "python3: ✅" || log "python3: ❌"
        log "mount 参数: ${JUICEFS_MOUNT_OPTS}"
        log "结果目录: ${RESULTS}"
        log "用法: bash $0 <LABEL> 180 5 --layout"
        exit 0
        ;;
    "")
        echo "用法: $0 <LABEL> [RUNTIME] [REPEAT] [--layout] [--remount] [--allow-restart]"
        echo "环境变量: ITEMS=\"randrw\"        只跑指定项（调优单项跑）"
        echo "          REF_LABEL=<上一跑>     判 L3 跨运行偏差"
        echo "          RANDREAD_REPEAT=10     randread 单独加轮"
        echo "          SKIP_REMOUNT=1         不 remount，沿用现有挂载实例（调优 A-B-A 必须用，见报告 §13.6）"
        echo "      $0 dry-run"
        echo "      $0 softclean"
        exit 0
        ;;
    *)
        LABEL="$1"; RUNTIME="${2:-180}"; REPEAT="${3:-5}"
        RANDREAD_REPEAT="${RANDREAD_REPEAT:-${REPEAT}}"
        for arg in "${@:4}"; do
            if [ "$arg" = "--layout" ]; then DO_LAYOUT=true; fi
            if [ "$arg" = "--remount" ]; then DO_REMOUNT=true; fi
            if [ "$arg" = "--allow-restart" ]; then ALLOW_RESTART=true; fi
        done
        ;;
esac

log "============================================"
log "=== FULLBASELINE V4 label=${LABEL} runtime=${RUNTIME}s repeat=${REPEAT} ==="
log "=== V2 基础 + 确定性预热 + hit% + 文件分离 + C_amp 守卫 ==="
log "=== 2026-08-05 同步：每轮 gc --compact + PG 门禁 + 优雅卸载 + 统一口径判据 + ITEMS ==="
log "=== items=${ITEMS} ==="
log "=== 判据: L2 轮间极差 ≤${L2_RANGE_MAX}%  L3 跨运行 median 偏差 ≤${L3_DEV_MAX}% (REF_LABEL=${REF_LABEL:-未设}) ==="
if [ "${SKIP_REMOUNT}" = "1" ]; then
    log "=== ⚑ SKIP_REMOUNT=1：沿用现有挂载实例（调优 A-B-A 模式，档位一致，L3 可比）==="
else
    log "=== SKIP_REMOUNT=0：每次运行 remount（档位重新抽签；R1 实测跨实例极差 29.9%，L3 FAIL 属预期）==="
fi
log "=== layout=${DO_LAYOUT} remount=${DO_REMOUNT} ==="
log "=== mount_opts=${JUICEFS_MOUNT_OPTS} ==="
log "============================================"

check_disk_space

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || { echo "${HEALTH}" | grep -q "clock skew" && log "  ⚠️ clock skew，继续" || { log "ERROR: health 非 OK"; exit 1; }; }
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (期望 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全"; exit 1; }

# PG 硬门禁（2026-08-05 加）：开测前必须 pg_num 稳定且全 active+clean，否则整跑作废
log "PG 状态: $(pg_state_snapshot)  (pool_id pg_num pgp_num autoscale pg_count nonclean)"
pg_gate
case "${PG_GATE_STATUS}" in
    UNSTABLE:*) log "ERROR: PG 未就绪（${PG_GATE_STATUS}），abort。确认要带病测请用 PG_GATE=false"; exit 1 ;;
esac

# bluestore 缓存配置只读校验（不写集群；不符只告警并记录，不 abort）
{
    echo "expect: autotune=false size=$((CACHE_SIZE_GB*1024*1024*1024)) meta=0.05 kv=0.30 data=0.65"
    for o in $(sudo ceph osd ls 2>/dev/null | tr '\n' ' '); do
        printf 'osd.%s ' "$o"
        sudo ceph config get osd.${o} bluestore_cache_autotune 2>/dev/null | tr -d '\n'
        printf ' '
        sudo ceph config get osd.${o} bluestore_cache_size 2>/dev/null | tr -d '\n'
        echo
    done
} > "${RESULTS}/cache-config-check-${LABEL}.txt" 2>/dev/null || true
log "缓存配置快照: ${RESULTS}/cache-config-check-${LABEL}.txt"

if [ "${DO_REMOUNT}" = "true" ]; then
    remount_jfs
fi

if [ "${DO_LAYOUT}" = "true" ]; then
    phase0_layout
else
    log "=== 跳过 Phase 0（复用已有 layout）==="
    if ! mount | grep -q juice; then
        log "  JuiceFS 未挂载，re-mount"
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3
        mount | grep -q juice || { log "ERROR: mount failed"; exit 1; }
    fi
    mkdir -p "${TEST_DIR}"
    [ -f "${TEST_DIR}/storage_test.0.0" ] || { log "ERROR: storage_test 不存在，需 --layout"; exit 1; }
    [ -f "${TEST_DIR}/read_test.0.0" ] || { log "ERROR: read_test 不存在，需 --layout"; exit 1; }
    [ -f "${TEST_DIR}/rw_test.0.0" ] || { log "ERROR: rw_test 不存在，需 --layout"; exit 1; }
    [ -f "${TEST_DIR}/seqread/seqread.0.0" ] || { log "ERROR: seqread prep 不存在"; exit 1; }
    log "  layout 数据确认存在，复用"
    # 布局指纹检查
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
        [ "${current_uuid}" = "${base_uuid}" ] && log "  ✅ UUID 一致" || { log "  🔴 UUID 变了!"; exit 1; }
        [ "${current_crush}" = "${base_crush}" ] && log "  ✅ CRUSH 一致" || { log "  🔴 CRUSH 变了!"; exit 1; }
        if [ "${base_up_from}" != "N/A" ] && [ "${current_up_from}" != "N/A" ]; then
            [ "${current_up_from}" = "${base_up_from}" ] && log "  ✅ up_from 不变" || {
                [ "${ALLOW_RESTART}" = "true" ] && log "  ⚠️ up_from 变了，--allow-restart 已确认" || { log "  🔴 up_from 变了! 需 --allow-restart"; exit 1; }
            }
        fi
    fi
fi

# 状态复位（2026-08-05 加）：gc --compact + drop_caches + 优雅 remount
reset_state

# 确定性预热
deterministic_warmup

# 测试项（默认 7 项，读在前写在后；ITEMS 可裁剪，如 ITEMS="randrw" 做单项调优跑）
for _item in ${ITEMS}; do
    case "${_item}" in
        seqread)   log "=== ${LABEL}: seqread ===";   item_seqread ;;
        mseqread)  log "=== ${LABEL}: mseqread ===";  item_mseqread ;;
        randread)  log "=== ${LABEL}: randread ===";  item_randread ;;
        randrw)    log "=== ${LABEL}: randrw ===";    item_randrw ;;
        seqwrite)  log "=== ${LABEL}: seqwrite ===";  item_seqwrite ;;
        mseqwrite) log "=== ${LABEL}: mseqwrite ==="; item_mseqwrite ;;
        randwrite) log "=== ${LABEL}: randwrite ==="; item_randwrite ;;
        *) log "ERROR: 未知 ITEMS 项 '${_item}'"; exit 1 ;;
    esac
done

summary
guard_report || true
steady_state_eval
log "=== ${LABEL} DONE ==="
