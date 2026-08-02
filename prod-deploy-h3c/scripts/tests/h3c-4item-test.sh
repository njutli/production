#!/bin/bash
# ============================================================
# h3c-4item-test.sh — 新华三对比 4 项测试
# ============================================================
# 测试项（与 H3C 同口径，可横向对比）：
#   1. cp 读：  time cp ${EPC}/20Gfile ${CP_LOCAL_DIR}/   （本地端默认 /mnt/jfs-cache，非 /tmp）
#   2. cp 写：  time cp ${CP_LOCAL_DIR}/20Gfile ${EPC}/
#   3. fio 顺序读： --bs=20M --rw=read   --direct=1 --numjobs=1 --runtime=60
#   4. fio 顺序写： --bs=16M --rw=write  --direct=1 --numjobs=1 --runtime=120
#
# 用法：
#   bash scripts/tests/h3c-4item-test.sh [--repeat N] [--label <name>]
#
# 前置条件：
#   - 集群 HEALTH_OK，6 OSD up
#   - JuiceFS 已挂载到 ${EPC_MOUNT_POINT}（默认 /mnt/epc）
#   - cp 读测试前需在 ${EPC_MOUNT_POINT} 下放好 20Gfile
#   - cp 写测试前需在 ${CP_LOCAL_DIR}（默认 /mnt/jfs-cache）下放好 20Gfile
#   - fio 已安装
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- 加载配置 ---
source "${REPO_ROOT}/config.sh"
source "${SCRIPT_DIR}/lib/ceph-health-check.sh"

# --- 参数 ---
REPEAT=1
LABEL="h3c-4item"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repeat)  REPEAT="$2"; shift 2;;
        --label)   LABEL="$2"; shift 2;;
        *) echo "Unknown option: $1"; exit 1;;
    esac
done

# --- 环境变量 ---
EPC_MOUNT="${EPC_MOUNT_POINT:-/mnt/epc}"
EPC_TESTFILE="${EPC_MOUNT}/testfile1"
EPC_20GFILE="${EPC_MOUNT}/20Gfile"
# cp 项的本地端：默认走 nvme1n1 缓存盘（/mnt/jfs-cache），避免 /tmp（tmpfs/系统盘）
# 与 157 上的 WekaIO 业务争内存/带宽，也避开 /tmp 若为 tmpfs 时撞内存红线。
# 可用 CP_LOCAL_DIR 覆盖；若目录不存在则回退 /tmp。
CP_LOCAL_DIR="${CP_LOCAL_DIR:-${JUICEFS_CACHE_MOUNT:-/mnt/jfs-cache}}"
[ -d "${CP_LOCAL_DIR}" ] || CP_LOCAL_DIR="/tmp"
TMP_20GFILE="${CP_LOCAL_DIR}/20Gfile"     # cp 写的源文件（本地端）
CP_READ_DST="${CP_LOCAL_DIR}/20Gfile.cpread"  # cp 读的目标（独立名，避免与源同名）

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="${REPO_ROOT}/results/${LABEL}-${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

# --- 日志 ---
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- NIC 监控 ---
NIC_IF="${PUBLIC_NIC}"
start_nic_monitor() {
    local outfile="$1"
    ( while true; do
        echo "$(date +%s) | $(cat /proc/net/dev | grep "${NIC_IF}")"
        sleep 1
    done ) > "${outfile}" 2>/dev/null &
    echo $!
}

# --- JuiceFS stats 监控 ---
start_jfs_stats() {
    local outfile="$1"
    local jfs_pid
    jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1)
    if [ -n "${jfs_pid}" ]; then
        ( while true; do
            echo "------ $(date +%H:%M:%S) ------"
            juicefs stats "${EPC_MOUNT}" 2>/dev/null || true
            sleep 1
        done ) > "${outfile}" 2>/dev/null &
        echo $!
    else
        echo ""
    fi
}

# ============================================================
# 测试 1: cp 读（storage → 本地缓存盘 CP_LOCAL_DIR）
# ============================================================
test_cp_read() {
    local r=$1
    local outdir="${RESULTS_DIR}/cp-read-r${r}"
    mkdir -p "${outdir}"

    log "=== Test 1: cp read (r${r}) ==="
    check_ceph_health "before cp-read r${r}"

    if [ ! -f "${EPC_20GFILE}" ]; then
        log "ERROR: ${EPC_20GFILE} not found, skipping cp-read"
        return 1
    fi

    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    local nic_pid jfs_pid
    nic_pid=$(start_nic_monitor "${outdir}/nic-raw.txt")
    jfs_pid=$(start_jfs_stats "${outdir}/jfs-stats.txt")

    log "cp ${EPC_20GFILE} ${CP_READ_DST}"
    { time cp "${EPC_20GFILE}" "${CP_READ_DST}" 2>&1; } | tee "${outdir}/cp-time.txt"
    sync

    [ -n "${nic_pid}" ] && kill "${nic_pid}" 2>/dev/null
    [ -n "${jfs_pid}" ] && kill "${jfs_pid}" 2>/dev/null

    # 只删 cp 读复制出的副本；绝不删 cp 写的源文件 ${TMP_20GFILE}
    rm -f "${CP_READ_DST}" 2>/dev/null
    log "cp read r${r} done. See ${outdir}/cp-time.txt"
}

# ============================================================
# 测试 2: cp 写（本地缓存盘 CP_LOCAL_DIR → storage）
# ============================================================
test_cp_write() {
    local r=$1
    local outdir="${RESULTS_DIR}/cp-write-r${r}"
    mkdir -p "${outdir}"

    log "=== Test 2: cp write (r${r}) ==="
    check_ceph_health "before cp-write r${r}"

    if [ ! -f "${TMP_20GFILE}" ]; then
        log "ERROR: ${TMP_20GFILE} not found, skipping cp-write"
        return 1
    fi

    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    local nic_pid jfs_pid
    nic_pid=$(start_nic_monitor "${outdir}/nic-raw.txt")
    jfs_pid=$(start_jfs_stats "${outdir}/jfs-stats.txt")

    log "cp ${TMP_20GFILE} ${EPC_MOUNT}/"
    { time cp "${TMP_20GFILE}" "${EPC_MOUNT}/" 2>&1; } | tee "${outdir}/cp-time.txt"
    sync

    [ -n "${nic_pid}" ] && kill "${nic_pid}" 2>/dev/null
    [ -n "${jfs_pid}" ] && kill "${jfs_pid}" 2>/dev/null

    rm -f "${EPC_MOUNT}/20Gfile" 2>/dev/null
    log "cp write r${r} done. See ${outdir}/cp-time.txt"
}

# ============================================================
# 测试 3: fio 顺序读（bs=20M, runtime=60s）
# ============================================================
test_fio_seq_read() {
    local r=$1
    local outdir="${RESULTS_DIR}/fio-seq-read-r${r}"
    mkdir -p "${outdir}"

    log "=== Test 3: fio seq_read (r${r}) ==="
    check_ceph_health "before fio-seq-read r${r}"

    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    local nic_pid jfs_pid
    nic_pid=$(start_nic_monitor "${outdir}/nic-raw.txt")
    jfs_pid=$(start_jfs_stats "${outdir}/jfs-stats.txt")

    log "fio seq_read (bs=20M, runtime=60s)"
    fio --name=seq_read \
        --filename="${EPC_TESTFILE}" \
        --size=10G \
        --bs=20M \
        --rw=read \
        --direct=1 \
        --numjobs=1 \
        --runtime=60 \
        --time_based \
        --group_reporting \
        2>&1 | tee "${outdir}/fio-seq-read.txt"

    [ -n "${nic_pid}" ] && kill "${nic_pid}" 2>/dev/null
    [ -n "${jfs_pid}" ] && kill "${jfs_pid}" 2>/dev/null
    log "fio seq_read r${r} done. See ${outdir}/fio-seq-read.txt"
}

# ============================================================
# 测试 4: fio 顺序写（bs=16M, runtime=120s）
# ============================================================
test_fio_seq_write() {
    local r=$1
    local outdir="${RESULTS_DIR}/fio-seq-write-r${r}"
    mkdir -p "${outdir}"

    log "=== Test 4: fio seq_write (r${r}) ==="
    check_ceph_health "before fio-seq-write r${r}"

    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    local nic_pid jfs_pid
    nic_pid=$(start_nic_monitor "${outdir}/nic-raw.txt")
    jfs_pid=$(start_jfs_stats "${outdir}/jfs-stats.txt")

    log "fio seq_write (bs=16M, runtime=120s)"
    fio --name=seq_write \
        --filename="${EPC_TESTFILE}" \
        --size=10G \
        --bs=16M \
        --rw=write \
        --direct=1 \
        --numjobs=1 \
        --runtime=120 \
        --time_based \
        --group_reporting \
        2>&1 | tee "${outdir}/fio-seq-write.txt"

    [ -n "${nic_pid}" ] && kill "${nic_pid}" 2>/dev/null
    [ -n "${jfs_pid}" ] && kill "${jfs_pid}" 2>/dev/null
    log "fio seq_write r${r} done. See ${outdir}/fio-seq-write.txt"
}

# ============================================================
# 主流程
# ============================================================
log "h3c 4-item test"
log "  mount point: ${EPC_MOUNT}"
log "  repeat: ${REPEAT}"
log "  results dir: ${RESULTS_DIR}"

# 环境快照
{
    echo "=== Environment Snapshot ==="
    echo "Date: $(date)"
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "JuiceFS: $(juicefs --version 2>/dev/null || echo 'N/A')"
    echo "Ceph health: $(sudo ceph health 2>/dev/null || echo 'N/A')"
    echo "Ceph OSD stat: $(sudo ceph osd stat 2>/dev/null || echo 'N/A')"
    echo "Mount: $(mount | grep "${EPC_MOUNT}" || echo 'NOT MOUNTED')"
    echo "EPC mount: ${EPC_MOUNT}"
    echo "Test file: ${EPC_TESTFILE}"
    echo "20G file (storage): ${EPC_20GFILE}"
    echo "20G file (local): ${TMP_20GFILE}"
} | tee "${RESULTS_DIR}/env-snapshot.txt"

# 记录完整命令
cat > "${RESULTS_DIR}/commands.sh" << EOF
#!/bin/bash
# 完整命令记录：h3c 4-item test
# 日期：$(date)
# JuiceFS 版本：$(juicefs --version 2>/dev/null || echo 'N/A')

# ---- 测试 1: cp 读 ----
time cp ${EPC_20GFILE} ${CP_READ_DST}

# ---- 测试 2: cp 写 ----
time cp ${TMP_20GFILE} ${EPC_MOUNT}/

# ---- 测试 3: fio 顺序读 ----
fio --name=seq_read --filename=${EPC_TESTFILE} --size=10G --bs=20M --rw=read --direct=1 --numjobs=1 --runtime=60 --time_based --group_reporting

# ---- 测试 4: fio 顺序写 ----
fio --name=seq_write --filename=${EPC_TESTFILE} --size=10G --bs=16M --rw=write --direct=1 --numjobs=1 --runtime=120 --time_based --group_reporting
EOF

# 执行测试
for r in $(seq 1 "${REPEAT}"); do
    log "========== Round ${r}/${REPEAT} =========="
    test_cp_read      "${r}" || log "cp-read r${r} FAILED"
    test_cp_write     "${r}" || log "cp-write r${r} FAILED"
    test_fio_seq_read "${r}" || log "fio-seq-read r${r} FAILED"

    # 写测试前清理 fio 顺序读产生的 testfile1
    rm -f "${EPC_TESTFILE}" 2>/dev/null
    test_fio_seq_write "${r}" || log "fio-seq-write r${r} FAILED"

    # 轮间清理
    if [ "${r}" -lt "${REPEAT}" ]; then
        log "Cleaning up between rounds..."
        rm -f "${EPC_TESTFILE}" 2>/dev/null
        rm -f "${EPC_MOUNT}/20Gfile" "${CP_READ_DST}" 2>/dev/null
        sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    fi
done

# 最终健康检查
check_ceph_health_quick "after all tests"

log "All tests done. Results in ${RESULTS_DIR}/"
