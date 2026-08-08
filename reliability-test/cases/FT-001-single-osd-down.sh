#!/bin/bash
# FT-001: single-osd-down
# SIGKILL 1 OSD，验证故障期间 I/O 成功 + 数据完整 + 延迟可控
# EXPECTED_DURATION=300
#
# 设计思路：
#   脚本部署到客户端(.12)执行，dd 写入和 kill 命令从 .12 发出（同网段 SSH ~0.5s），
#   避免管理机 SSH 开销（~1-2s）掩盖真实延迟。基线写入和故障写入在同一脚本中执行，
#   计时在本地采集（bash time 命令），结果通过管理机 SSH 收集。
#
# 测试流程：
#   1. 客户端本地基线写入 1GB（dd oflag=direct），记录耗时 + md5
#   2. 客户端后台启动 dd 写入 1GB
#   3. 立即从客户端 SSH kill OSD（systemctl stop --no-block + docker kill SIGKILL）
#   4. 等待 dd 完成，记录耗时 + 退出码 + md5
#   5. drop cache 后读取文件 md5，与写入 md5 对比
#
# 验证点：
#   - dd 退出码 = 0（写入成功，I/O 无失败）
#   - 写后 md5 = drop cache 后读 md5（数据完整，不丢不坏）
#   - 故障写入延迟 = 故障耗时 - 基线耗时 < 5000ms（fast-fail + peering + rerouting 可控）
#   - PG 进入 degraded（OSD 被检测为 down）
#   - 恢复后 PG active+clean + 6/6 OSD up

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"

TEST_ID="FT-001"
TEST_NAME="single-osd-down"
EXPECTED_DURATION=300

WRITE_COUNT=1024
WRITE_BS="1M"
MAX_DELAY=5000

# 客户端 SSH 配置（从 .12 到存储节点，同网段，延迟低）
_CLIENT_SSH="sshpass -p ${SSH_PASSWORD} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3"
_CLIENT_SCP="sshpass -p ${SSH_PASSWORD} scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

trap 'ensure_osd_up "$TARGET_OSD" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# 在客户端本地执行写测试脚本（不经过管理机 SSH）
# 脚本内直接执行 dd + 本地 SSH kill OSD，最大限度减少延迟
_run_client_test() {
    local target_osd=$1
    local target_node=$2

    # 生成客户端测试脚本
    cat > /tmp/ft001_client_test.sh << 'CLIENT_SCRIPT'
#!/bin/bash

SSHPASS="$1"
TARGET_OSD="$2"
TARGET_NODE="$3"
WRITE_COUNT="$4"
WRITE_BS="$5"
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
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>/dev/null
dd if="${TEST_DIR}/baseline.bin" of=/dev/null bs=${WRITE_BS} iflag=direct 2>/dev/null
BASELINE_MD5_VERIFY=$(md5sum "${TEST_DIR}/baseline.bin" 2>/dev/null | awk '{print $1}')
rm -f "${TEST_DIR}/baseline.bin"
echo "BASELINE_MS=${BASELINE_MS}"
echo "BASELINE_RC=${BASELINE_RC}"
echo "BASELINE_MD5=${BASELINE_MD5}"
echo "BASELINE_MD5_VERIFY=${BASELINE_MD5_VERIFY}"

# --- 后台 dd 写入 ---
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>/dev/null
rm -f "${TEST_DIR}/fault.bin" /tmp/ft001_timing.txt /tmp/ft001_fault_rc.txt /tmp/ft001_fault_md5.txt

# 后台启动 dd（记录耗时、退出码、md5 到文件）
(
    TIMEFORMAT='%R'
    elapsed_s=$( { time dd if=/dev/urandom of="${TEST_DIR}/fault.bin" bs=${WRITE_BS} count=${WRITE_COUNT} oflag=direct; } 2>&1 )
    rc=$?
    elapsed_ms=$(echo "$elapsed_s" | tail -1 | awk '{printf "%.0f", $1 * 1000}')
    fault_md5=$(md5sum "${TEST_DIR}/fault.bin" 2>/dev/null | awk '{print $1}')
    echo "$elapsed_ms" > /tmp/ft001_timing.txt
    echo "$rc" > /tmp/ft001_fault_rc.txt
    echo "$fault_md5" > /tmp/ft001_fault_md5.txt
) &
DD_PID=$!

    # --- 立即从客户端 SSH kill OSD（同网段，延迟 ~0.5s）---
    sshpass -p "${SSHPASS}" ssh ${SSH_OPTS} "turboai@${TARGET_NODE}" "sudo systemctl stop --no-block ceph-*@osd.${TARGET_OSD}.service 2>/dev/null; cid=\$(sudo docker ps --format '{{.Names}} {{.ID}}' 2>/dev/null | awk -v id=\"osd[-.]${TARGET_OSD}\$\" '\$1 ~ id {print \$2}'); [ -n \"\$cid\" ] && sudo docker kill --signal KILL \$cid 2>/dev/null; echo killed" 2>/dev/null

# --- 等待 dd 完成 ---
wait $DD_PID 2>/dev/null || true
FAULT_MS=$(cat /tmp/ft001_timing.txt 2>/dev/null || echo "0")
FAULT_RC=$(cat /tmp/ft001_fault_rc.txt 2>/dev/null || echo "1")
FAULT_MD5=$(cat /tmp/ft001_fault_md5.txt 2>/dev/null || echo "")
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>/dev/null
dd if="${TEST_DIR}/fault.bin" of=/dev/null bs=${WRITE_BS} iflag=direct 2>/dev/null
FAULT_MD5_VERIFY=$(md5sum "${TEST_DIR}/fault.bin" 2>/dev/null | awk '{print $1}')
rm -f "${TEST_DIR}/fault.bin" /tmp/ft001_timing.txt /tmp/ft001_fault_rc.txt /tmp/ft001_fault_md5.txt

echo "FAULT_MS=${FAULT_MS}"
echo "FAULT_RC=${FAULT_RC}"
echo "FAULT_MD5=${FAULT_MD5}"
echo "FAULT_MD5_VERIFY=${FAULT_MD5_VERIFY}"
echo "DELAY_MS=$((FAULT_MS - BASELINE_MS))"

echo "RESULT_END"
CLIENT_SCRIPT
    chmod +x /tmp/ft001_client_test.sh

    # 推送脚本到客户端
    $_CLIENT_SCP /tmp/ft001_client_test.sh "turboai@${CLIENT_SERVER}:/tmp/ft001_client_test.sh"

    # 在客户端执行
    $_CLIENT_SSH "turboai@${CLIENT_SERVER}" "bash /tmp/ft001_client_test.sh '${SSH_PASSWORD}' '${target_osd}' '${target_node}' '${WRITE_COUNT}' '${WRITE_BS}'" 2>/dev/null
}

# ============================================================
# setup：前置检查 + 选择目标 OSD + 客户端执行基线+故障测试
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "SIGKILL 1 OSD，客户端本地 dd 写入途中 kill，对比基线与故障场景的时长差"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    TARGET_OSD=$(pick_random_osd)
    assert_ne "$TARGET_OSD" "" "选中的 OSD id: ${TARGET_OSD}"

    TARGET_NODE=$(get_osd_node "$TARGET_OSD")
    assert_ne "$TARGET_NODE" "" "OSD ${TARGET_OSD} 所在节点: ${TARGET_NODE}"
}

# ============================================================
# inject + check：客户端执行基线+后台dd+kill+等待，收集结果
# ============================================================
inject_and_check() {
    echo ""
    echo "=== 客户端执行测试（本地 dd + 本地 SSH kill）==="

    local output
    output=$(_run_client_test "$TARGET_OSD" "$TARGET_NODE")

    # 解析结果
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

    assert_gt "$BASELINE_MS" "0" "基线写入成功（${BASELINE_MS}ms）"
    assert_gt "$FAULT_MS" "0" "故障写入完成（${FAULT_MS}ms）"

    # OSD 状态
    assert_wait_eq get_osd_count_up "5" 30 "5/6 OSD up（OSD down）"
    assert_pg_state_contains "degraded" 60 "PG 进入 degraded"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（EC 容忍内）"

    # 核心断言
    assert_lt "$DELAY_MS" "$MAX_DELAY" "故障写入延迟 < ${MAX_DELAY}ms（实际 ${DELAY_MS}ms）"
}

# ============================================================
# recover：启动 OSD → 等待恢复
# ============================================================
recover() {
    echo ""
    echo "=== 恢复 OSD ${TARGET_OSD} ==="
    start_osd "$TARGET_OSD"
    RECOVER_START=$(date +%s)

    assert_pg_state_contains "active+clean" 300 "PG 300s 内恢复 active+clean"
    RECOVER_END=$(date +%s)

    local recovery_time=$((RECOVER_END - RECOVER_START))
    echo "# 恢复耗时: ${recovery_time}s"

    assert_wait_eq get_osd_count_up "6" 60 "6/6 OSD up"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    ensure_osd_up "$TARGET_OSD"
    ssh_to_client "rm -f /tmp/ft001_client_test.sh /tmp/ft001_timing.txt" 2>/dev/null || true
    ssh_to_client "rm -f /mnt/juicefs/reliability-test/baseline.bin /mnt/juicefs/reliability-test/fault.bin" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject_and_check; recover; teardown; }
main "$@"
