#!/bin/bash
# FT-002: disk-fault
# 用 dmsetup error target 让磁盘返回 EIO，验证故障期间 I/O 成功 + 数据完整 + 延迟可控
# EXPECTED_DURATION=480
#
# 设计思路：
#   与 FT-001 相同的客户端本地执行方案。区别在于故障注入方式：
#   FT-001 用 SIGKILL 瞬间杀进程；FT-002 用 dmsetup error target 让磁盘返回 EIO，
#   BlueStore 碰到 EIO 后 abort 退出。EIO-to-crash 间隔不确定（取决于 OSD 何时做磁盘 I/O），
#   因此故障延迟 = EIO-to-crash 延迟 + fast-fail + peering + rerouting，比 FT-001 多一段。
#
# 测试流程：
#   1. 安全检查：确保目标 LV 不是根设备或已挂载文件系统
#   2. 客户端本地基线写入 1GB（dd oflag=direct），记录耗时 + md5
#   3. 客户端后台启动 dd 写入 1GB
#   4. 立即从客户端 SSH 注入 EIO（dmsetup suspend → load error → resume）
#   5. 等待 dd 完成，记录耗时 + 退出码 + md5
#   6. drop cache 后读取文件 md5，与写入 md5 对比
#   7. 恢复：dmsetup 恢复原始表 + start_osd
#
# 验证点：
#   - dd 退出码 = 0（写入成功，I/O 无失败）
#   - 写后 md5 = drop cache 后读 md5（数据完整，不丢不坏）
#   - dm 设备已替换为 error target（EIO 注入生效）
#   - dm 设备恢复后为 linear（恢复成功）
#   - 故障写入延迟 = 故障耗时 - 基线耗时 < 8000ms（EIO-to-crash + fast-fail + peering + rerouting 可控）
#   - PG 进入 degraded（OSD crash 后被检测）
#   - 恢复后 PG active+clean + 6/6 OSD up

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"

TEST_ID="FT-002"
TEST_NAME="disk-fault"
EXPECTED_DURATION=480

WRITE_COUNT=1024
WRITE_BS="1M"
MAX_DELAY=8000

_DM_BACKUP="/tmp/dm_table_backup_ft002"

_CLIENT_SSH="sshpass -p ${SSH_PASSWORD} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3"
_CLIENT_SCP="sshpass -p ${SSH_PASSWORD} scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

trap '_run "$TARGET_NODE" "sudo dmsetup suspend ${TARGET_LV} 2>/dev/null; sudo dmsetup load ${TARGET_LV} < ${_DM_BACKUP} 2>/dev/null; sudo dmsetup resume ${TARGET_LV} 2>/dev/null" 2>/dev/null; ensure_osd_up "$TARGET_OSD" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

_get_osd_data_lv() {
    local osd_id=$1 node=$2
    local meta
    meta=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd metadata ${osd_id} 2>/dev/null" 2>/dev/null)
    echo "$meta" | grep 'bluestore_bdev_partition_path' | head -1 | awk -F'"' '{print $4}'
}

_verify_target_safe() {
    local check
    check=$(_run "$TARGET_NODE" "
        real_target=\$(readlink -f ${TARGET_LV} 2>/dev/null)
        real_root=\$(readlink -f \$(findmnt / -o SOURCE -n 2>/dev/null) 2>/dev/null)
        if [ \"\$real_target\" = \"\$real_root\" ]; then
            echo \"REFUSE: ${TARGET_LV} 是根设备\"; exit 1
        fi
        for src in \$(findmnt -o SOURCE -n 2>/dev/null | sort -u); do
            real_src=\$(readlink -f \"\$src\" 2>/dev/null)
            if [ \"\$real_target\" = \"\$real_src\" ]; then
                echo \"REFUSE: ${TARGET_LV} 被挂载文件系统使用: \$src\"; exit 1
            fi
        done
        echo SAFE
    " 2>/dev/null)
    if [ "$check" != "SAFE" ]; then
        echo "FATAL: $check"
        tap_plan_end
        exit 1
    fi
}

_run_client_test() {
    local target_osd=$1
    local target_node=$2
    local target_lv=$3
    local dm_backup=$4

    cat > /tmp/ft002_client_test.sh << 'CLIENT_SCRIPT'
#!/bin/bash
set -e

SSHPASS="$1"
TARGET_OSD="$2"
TARGET_NODE="$3"
TARGET_LV="$4"
DM_BACKUP="$5"
WRITE_COUNT="$6"
WRITE_BS="$7"
TEST_DIR="/mnt/juicefs/reliability-test"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3"

echo "RESULT_START"

# --- 基线写入 ---
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>/dev/null
rm -f "${TEST_DIR}/baseline.bin"
TIMEFORMAT='%R'
BASELINE_S=$( { time dd if=/dev/urandom of="${TEST_DIR}/baseline.bin" bs=${WRITE_BS} count=${WRITE_COUNT} oflag=direct; } 2>&1 )
BASELINE_RC=$?
BASELINE_MS=$(echo "$BASELINE_S" | tail -1 | awk '{printf "%.0f", $1 * 1000}')
BASELINE_MD5=$(md5sum "${TEST_DIR}/baseline.bin" 2>/dev/null | awk '{print $1}')
dd if="${TEST_DIR}/baseline.bin" of=/dev/null bs=${WRITE_BS} iflag=direct 2>/dev/null
BASELINE_MD5_VERIFY=$(md5sum "${TEST_DIR}/baseline.bin" 2>/dev/null | awk '{print $1}')
rm -f "${TEST_DIR}/baseline.bin"
echo "BASELINE_MS=${BASELINE_MS}"
echo "BASELINE_RC=${BASELINE_RC}"
echo "BASELINE_MD5=${BASELINE_MD5}"
echo "BASELINE_MD5_VERIFY=${BASELINE_MD5_VERIFY}"

# --- 后台 dd 写入 ---
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>/dev/null
rm -f "${TEST_DIR}/fault.bin" /tmp/ft002_timing.txt /tmp/ft002_fault_rc.txt /tmp/ft002_fault_md5.txt

(
    TIMEFORMAT='%R'
    elapsed_s=$( { time dd if=/dev/urandom of="${TEST_DIR}/fault.bin" bs=${WRITE_BS} count=${WRITE_COUNT} oflag=direct; } 2>&1 )
    rc=$?
    elapsed_ms=$(echo "$elapsed_s" | tail -1 | awk '{printf "%.0f", $1 * 1000}')
    fault_md5=$(md5sum "${TEST_DIR}/fault.bin" 2>/dev/null | awk '{print $1}')
    echo "$elapsed_ms" > /tmp/ft002_timing.txt
    echo "$rc" > /tmp/ft002_fault_rc.txt
    echo "$fault_md5" > /tmp/ft002_fault_md5.txt
) &
DD_PID=$!

# --- 立即从客户端 SSH 注入 EIO（同网段，延迟 ~0.5s）---
sshpass -p "${SSHPASS}" ssh ${SSH_OPTS} "turboai@${TARGET_NODE}" "sudo dmsetup table ${TARGET_LV} > ${DM_BACKUP} 2>/dev/null; size=\$(sudo blockdev --getsize ${TARGET_LV} 2>/dev/null); sudo dmsetup suspend ${TARGET_LV} 2>/dev/null; echo \"0 \${size} error\" | sudo dmsetup load ${TARGET_LV} 2>/dev/null; sudo dmsetup resume ${TARGET_LV} 2>/dev/null; echo injected" 2>/dev/null

# --- 等待 dd 完成 ---
wait $DD_PID 2>/dev/null || true
FAULT_MS=$(cat /tmp/ft002_timing.txt 2>/dev/null || echo "0")
FAULT_RC=$(cat /tmp/ft002_fault_rc.txt 2>/dev/null || echo "1")
FAULT_MD5=$(cat /tmp/ft002_fault_md5.txt 2>/dev/null || echo "")
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>/dev/null
dd if="${TEST_DIR}/fault.bin" of=/dev/null bs=${WRITE_BS} iflag=direct 2>/dev/null
FAULT_MD5_VERIFY=$(md5sum "${TEST_DIR}/fault.bin" 2>/dev/null | awk '{print $1}')
rm -f "${TEST_DIR}/fault.bin" /tmp/ft002_timing.txt /tmp/ft002_fault_rc.txt /tmp/ft002_fault_md5.txt

echo "FAULT_MS=${FAULT_MS}"
echo "FAULT_RC=${FAULT_RC}"
echo "FAULT_MD5=${FAULT_MD5}"
echo "FAULT_MD5_VERIFY=${FAULT_MD5_VERIFY}"
echo "DELAY_MS=$((FAULT_MS - BASELINE_MS))"

echo "RESULT_END"
CLIENT_SCRIPT
    chmod +x /tmp/ft002_client_test.sh

    $_CLIENT_SCP /tmp/ft002_client_test.sh "turboai@${CLIENT_SERVER}:/tmp/ft002_client_test.sh"

    $_CLIENT_SSH "turboai@${CLIENT_SERVER}" "bash /tmp/ft002_client_test.sh '${SSH_PASSWORD}' '${target_osd}' '${target_node}' '${target_lv}' '${dm_backup}' '${WRITE_COUNT}' '${WRITE_BS}'" 2>/dev/null
}

# ============================================================
# setup：前置检查 + 选择目标 OSD + 安全检查 + dm 备份
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "用 dmsetup error target 让磁盘返回 EIO，客户端本地 dd 写入途中注入，对比基线与故障场景的时长差"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    TARGET_OSD=$(pick_random_osd)
    assert_ne "$TARGET_OSD" "" "选中的 OSD id: ${TARGET_OSD}"

    TARGET_NODE=$(get_osd_node "$TARGET_OSD")
    assert_ne "$TARGET_NODE" "" "OSD ${TARGET_OSD} 所在节点: ${TARGET_NODE}"

    TARGET_LV=$(_get_osd_data_lv "$TARGET_OSD" "$TARGET_NODE")
    assert_ne "$TARGET_LV" "" "OSD 数据 LV: ${TARGET_LV}"

    _verify_target_safe

    # dm 备份在客户端脚本中执行（从 .12 SSH 到存储节点）
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    ssh_to_client "mkdir -p '${test_dir}'" 2>/dev/null
}

# ============================================================
# inject + check：客户端执行基线+后台dd+EIO注入+等待，收集结果
# ============================================================
inject_and_check() {
    echo ""
    echo "=== 客户端执行测试（本地 dd + 本地 SSH EIO 注入）==="

    local output
    output=$(_run_client_test "$TARGET_OSD" "$TARGET_NODE" "$TARGET_LV" "$_DM_BACKUP")

    BASELINE_MS=$(echo "$output" | grep "^BASELINE_MS=" | cut -d= -f2)
    BASELINE_RC=$(echo "$output" | grep "^BASELINE_RC=" | cut -d= -f2)
    BASELINE_MD5=$(echo "$output" | grep "^BASELINE_MD5=" | cut -d= -f2)
    BASELINE_MD5_VERIFY=$(echo "$output" | grep "^BASELINE_MD5_VERIFY=" | cut -d= -f2)
    FAULT_MS=$(echo "$output" | grep "^FAULT_MS=" | cut -d= -f2)
    FAULT_RC=$(echo "$output" | grep "^FAULT_RC=" | cut -d= -f2)
    FAULT_MD5=$(echo "$output" | grep "^FAULT_MD5=" | cut -d= -f2)
    FAULT_MD5_VERIFY=$(echo "$output" | grep "^FAULT_MD5_VERIFY=" | cut -d= -f2)
    DELAY_MS=$(echo "$output" | grep "^DELAY_MS=" | cut -d= -f2)

    echo "# 基线写入耗时: ${BASELINE_MS}ms (rc=${BASELINE_RC})"
    echo "# 基线 md5 写=${BASELINE_MD5:0:16}  读=${BASELINE_MD5_VERIFY:0:16}"
    echo "# 故障写入耗时: ${FAULT_MS}ms (rc=${FAULT_RC})"
    echo "# 故障 md5 写=${FAULT_MD5:0:16}  读=${FAULT_MD5_VERIFY:0:16}"
    echo "# 差值: ${DELAY_MS}ms（阈值=${MAX_DELAY}ms）"

    # 写入成功
    assert_eq "$BASELINE_RC" "0" "基线 dd 写入成功（rc=0）"
    assert_eq "$FAULT_RC" "0" "故障 dd 写入成功（rc=0）"

    # 数据校验：写后 md5 和 drop cache 后读 md5 一致
    assert_eq "$BASELINE_MD5" "$BASELINE_MD5_VERIFY" "基线数据 md5 一致（写后读校验）"
    assert_eq "$FAULT_MD5" "$FAULT_MD5_VERIFY" "故障期间数据 md5 一致（drop cache 后读校验）"

    # 验证 dm 表已替换为 error
    local dm_table
    dm_table=$(_run "$TARGET_NODE" "sudo dmsetup table ${TARGET_LV} 2>/dev/null" 2>/dev/null)
    assert_match "$dm_table" "error" "dm 设备 ${TARGET_LV} 已替换为 error target"

    # OSD 状态
    assert_wait_eq get_osd_count_up "5" 60 "5/6 OSD up（OSD crash）"
    assert_pg_state_contains "degraded" 60 "PG 进入 degraded"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（EC 容忍内）"

    # 核心断言
    assert_lt "$DELAY_MS" "$MAX_DELAY" "故障写入延迟 < ${MAX_DELAY}ms（实际 ${DELAY_MS}ms）"
}

# ============================================================
# recover：恢复 dm 表 + 启动 OSD
# ============================================================
recover() {
    echo ""
    echo "=== 恢复 OSD ${TARGET_OSD} ==="
    _run "$TARGET_NODE" "
        sudo dmsetup suspend ${TARGET_LV} 2>/dev/null
        sudo dmsetup load ${TARGET_LV} < ${_DM_BACKUP} 2>/dev/null
        sudo dmsetup resume ${TARGET_LV} 2>/dev/null
    " 2>/dev/null

    local dm_table
    dm_table=$(_run "$TARGET_NODE" "sudo dmsetup table ${TARGET_LV} 2>/dev/null" 2>/dev/null)
    assert_match "$dm_table" "linear" "dm 设备 ${TARGET_LV} 已恢复为 linear"

    sleep 3
    start_osd "$TARGET_OSD"
    RECOVER_START=$(date +%s)

    assert_pg_state_contains "active+clean" 300 "PG 300s 内恢复 active+clean"
    RECOVER_END=$(date +%s)
    echo "# 恢复耗时: $((RECOVER_END - RECOVER_START))s"

    assert_wait_eq get_osd_count_up "6" 60 "6/6 OSD up"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    _run "$TARGET_NODE" "sudo dmsetup suspend ${TARGET_LV} 2>/dev/null; sudo dmsetup load ${TARGET_LV} < ${_DM_BACKUP} 2>/dev/null; sudo dmsetup resume ${TARGET_LV} 2>/dev/null" 2>/dev/null || true
    _run "$TARGET_NODE" "rm -f ${_DM_BACKUP}" 2>/dev/null || true
    ensure_osd_up "$TARGET_OSD"
    ssh_to_client "rm -f /tmp/ft002_client_test.sh /tmp/ft002_timing.txt" 2>/dev/null || true
    ssh_to_client "rm -f /mnt/juicefs/reliability-test/baseline.bin /mnt/juicefs/reliability-test/fault.bin" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject_and_check; recover; teardown; }
main "$@"
