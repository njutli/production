#!/bin/bash
set -euo pipefail
export LC_ALL=C

# probe-cross-wrapper.sh — 03-1 档位探针交叉验证
# 编排 8 次挂载实例，每实例先 randread 探针(1轮) 后 mseqwrite(2轮)
# 调用 FULLBASELINE_V4.sh (SKIP_REMOUNT=1)，wrapper 负责实例间 unmount/mount

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
V4_RESULTS="/tmp/opencode-fullbaseline-v4"
PROBE_RESULTS="/tmp/opencode-probe-cross"
JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

V4_SCRIPT="/tmp/FULLBASELINE_V4.sh"
NUM_INSTANCES=8
EXPECTED_MD5="3fd1281fea1c08342051d64fc8eb1348"

log() { echo "[$(date '+%F %T')] $*"; }

jfs_pid_of_mnt() {
    pgrep -af juicefs 2>/dev/null | awk -v m="${MNT}" '$0 ~ ("mount.*" m "([[:space:]]|$)") {print $1}' | head -1
}

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
        log "  juicefs umount rc=${rc}，回退 fusermount -u"
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
        log "  30s 未退出，TERM pid=${pid}"
        kill -TERM "${pid}" 2>/dev/null || true
        UMOUNT_MODE="term"
        for i in $(seq 15); do
            [ -z "$(jfs_pid_of_mnt)" ] && { log "  TERM 后已退出（${i}s）"; return 0; }
            sleep 1
        done
        pid=$(jfs_pid_of_mnt)
        if [ -n "${pid}" ] && kill_guard "${pid}"; then
            log "  TERM 无效，KILL pid=${pid} — 标记 UNCLEAN_UMOUNT"
            kill -KILL "${pid}" 2>/dev/null || true
            UMOUNT_MODE="kill"
            echo "UNCLEAN_UMOUNT mode=kill pid=${pid} $(date '+%F %T')" >> "${PROBE_RESULTS}/UNCLEAN_UMOUNT.txt"
            sleep 5
        fi
    fi
}

drop_caches() {
    sync -f "${MNT}" 2>/dev/null || true; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    local ok_count=0
    for ip in "${SLAVES[@]}"; do
        if ${SSHPASS_CMD}@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null; then
            ok_count=$((ok_count+1))
        fi
    done
    [ "${ok_count}" -lt 3 ] && log "  drop_caches: ${ok_count}/3 节点成功"
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

record_instance() {
    local label="$1"
    local pid; pid=$(jfs_pid_of_mnt)
    local st="NA" et="NA"
    if [ -n "${pid}" ]; then
        st=$(awk '{print $22}' /proc/"${pid}"/stat 2>/dev/null || echo NA)
        et=$(ps -o lstart= -p "${pid}" 2>/dev/null | sed 's/^ *//' || echo NA)
    fi
    echo "wrapper label=${label} pid=${pid:-NA} starttime_ticks=${st} started=\"${et}\" ts=$(date '+%F %T')" \
        >> "${PROBE_RESULTS}/jfs-instances.txt"
    log "  挂载实例: pid=${pid:-NA} 启动于 ${et}"
}

mount_jfs() {
    log "  juicefs mount -d ${JUICEFS_MOUNT_OPTS}"
    for try in 1 2 3; do
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break; sleep 10
    done
    mount | grep -q juice || { log "FATAL: mount failed"; return 1; }
    mkdir -p "${TEST_DIR}"
}

mkdir -p "${PROBE_RESULTS}"

log "============================================"
log "=== PROBE-CROSS-WRAPPER START ==="
log "=== $(date) ==="
log "============================================"

cat > "${PROBE_RESULTS}/commands.sh" << 'CMDS'
# Per instance i=1..8:
#   1. graceful_umount_jfs  (四级优雅卸载)
#   2. juicefs mount -d --max-uploads 150 --cache-size 0 tikv://... /mnt/juicefs
#   3. record pid + starttime_ticks
#   4. drop_caches (157 + 150/151/152)
#   5. ITEMS="randread mseqwrite" RANDREAD_REPEAT=1 SKIP_REMOUNT=1 bash /tmp/FULLBASELINE_V4.sh X$i 180 2
CMDS

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || { log "ERROR: health 非 OK，abort"; exit 1; }

OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (期望 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全，abort"; exit 1; }

log "=== Pre-run ceph df ==="
sudo ceph df 2>/dev/null | grep -E "juicefs-data|POOLS" | tee "${PROBE_RESULTS}/ceph-df-pre.txt"

if [ ! -f "${V4_SCRIPT}" ]; then
    log "ERROR: V4 script not found at ${V4_SCRIPT}"
    exit 1
fi
V4_MD5=$(md5sum "${V4_SCRIPT}" | awk '{print $1}')
log "V4 md5: ${V4_MD5}"
[ "${V4_MD5}" = "${EXPECTED_MD5}" ] || { log "ERROR: V4 md5 mismatch (expected ${EXPECTED_MD5}, got ${V4_MD5})"; exit 1; }

log "=== Layout files check ==="
for f in "${TEST_DIR}/storage_test.0.0" "${TEST_DIR}/read_test.0.0" "${TEST_DIR}/rw_test.0.0"; do
    [ -f "$f" ] || { log "ERROR: $f 不存在"; exit 1; }
done
[ -d "${TEST_DIR}/mseqwrite" ] || log "  WARNING: ${TEST_DIR}/mseqwrite 目录不存在"
log "  layout files OK"

FAILED_COUNT=0
for i in $(seq 1 ${NUM_INSTANCES}); do
    LABEL="X${i}"
    log ""
    log "============================================"
    log "=== Instance ${i}/${NUM_INSTANCES}: label=${LABEL} ==="
    log "============================================"

    log "  Step 1: graceful unmount"
    graceful_umount_jfs
    log "  卸载方式: ${UMOUNT_MODE:-none}"

    log "  Step 2: mount with fixed params"
    if ! mount_jfs; then
        log "  FATAL: mount failed for ${LABEL}, abort"
        echo "MOUNT_FAILED label=${LABEL} ts=$(date '+%F %T')" >> "${PROBE_RESULTS}/failed-instances.txt"
        exit 1
    fi

    log "  Step 3: record instance identity"
    record_instance "${LABEL}"

    log "  Step 4: drop caches (3 nodes)"
    drop_caches

    log "  Step 5: run V4 (ITEMS=randread mseqwrite, RANDREAD_REPEAT=1, SKIP_REMOUNT=1, 180s, 2 rounds)"
    set +e
    ITEMS="randread mseqwrite" RANDREAD_REPEAT=1 SKIP_REMOUNT=1 bash "${V4_SCRIPT}" "${LABEL}" 180 2
    V4_RC=$?
    set -e
    if [ "${V4_RC}" != "0" ]; then
        log "  V4 failed for ${LABEL} (rc=${V4_RC}), continuing to next instance"
        echo "V4_FAILED label=${LABEL} rc=${V4_RC} ts=$(date '+%F %T')" >> "${PROBE_RESULTS}/failed-instances.txt"
        FAILED_COUNT=$((FAILED_COUNT+1))
    else
        log "  Instance ${LABEL} done (rc=0)"
    fi

    if grep -q "forced-mount" "${V4_RESULTS}/jfs-instance-${LABEL}.txt" 2>/dev/null; then
        log "  WARNING: forced-mount detected for ${LABEL} — instance may be invalid"
        echo "FORCED_MOUNT label=${LABEL} ts=$(date '+%F %T')" >> "${PROBE_RESULTS}/forced-mount-instances.txt"
    fi
done

log "=== Post-run ceph df ==="
sudo ceph df 2>/dev/null | grep -E "juicefs-data|POOLS" | tee "${PROBE_RESULTS}/ceph-df-post.txt"

log "=== Copying V4 results to ${PROBE_RESULTS} ==="
for i in $(seq 1 ${NUM_INSTANCES}); do
    LABEL="X${i}"
    [ -d "${V4_RESULTS}/${LABEL}" ] && cp -r "${V4_RESULTS}/${LABEL}" "${PROBE_RESULTS}/" 2>/dev/null || true
done
cp "${V4_RESULTS}"/jfs-instance-X*.txt "${PROBE_RESULTS}/" 2>/dev/null || true
cp "${V4_RESULTS}/rounds.tsv" "${PROBE_RESULTS}/rounds-v4.tsv" 2>/dev/null || true

log "============================================"
log "=== PROBE-CROSS-WRAPPER DONE ==="
log "=== $(date) ==="
log "=== Failed: ${FAILED_COUNT}/${NUM_INSTANCES} ==="
log "============================================"
