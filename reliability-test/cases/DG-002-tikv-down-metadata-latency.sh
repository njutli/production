#!/bin/bash
# DG-002: tikv-down-metadata-latency
# 停 1 TiKV，量化元数据操作延迟退化（P95 < 基线×3）
# 与 FT-004 的区别：FT-004 验证"能否完成"（binary），DG-002 量化"慢了多少"
# EXPECTED_DURATION=420

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"

TEST_ID="DG-002"
TEST_NAME="tikv-down-metadata-latency"
EXPECTED_DURATION=420

trap 'start_tikv "$TARGET_NODE" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

META_FILE="${JUICEFS_MOUNT_POINT}/reliability-test/dg002_meta"

# 采集元数据操作延迟（touch+stat+rm，返回排序后的毫秒列表）
# 内层 timeout 3 防止单次操作卡死，外层 timeout 120 防止 SSH 会话卡死
_collect_meta_latency() {
    local count=${1:-30}
    timeout 120 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
        "${SSH_USER}@${CLIENT_SERVER}" "
            for i in \$(seq 1 ${count}); do
                t0=\$(date +%s%N)
                timeout 3 touch ${META_FILE} 2>/dev/null
                timeout 3 stat ${META_FILE} >/dev/null 2>&1
                timeout 3 rm ${META_FILE} 2>/dev/null
                t1=\$(date +%s%N)
                echo \$(( (t1 - t0) / 1000000 ))
                sleep 0.2
            done
        " 2>/dev/null | sort -n
}

# 从排序后的列表取 P95（第 95 百分位）
_get_percentile() {
    local sorted=($1)
    local count=${#sorted[@]}
    [ "$count" -eq 0 ] && { echo 0; return; }
    local idx=$(( count * 95 / 100 ))
    [ "$idx" -ge "$count" ] && idx=$((count - 1))
    echo "${sorted[$idx]}"
}

# ============================================================
# setup：前置检查 + 采集基线元数据延迟
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "停 1 TiKV，量化元数据操作延迟退化（P95 < 基线×3）"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"

    # 采集基线元数据延迟（30 次 touch+stat+rm）
    echo "# 采集基线元数据延迟（30 次）..."
    local baseline_samples
    baseline_samples=$(_collect_meta_latency 30)
    BASELINE_P95=$(_get_percentile "$baseline_samples")

    if [ "${BASELINE_P95:-0}" -gt 0 ] 2>/dev/null; then
        echo "# 基线 P95=${BASELINE_P95}ms"
    else
        echo "# ⚠ 基线采集失败，延迟断言将跳过"
    fi

    # 选择注入目标（随机 slave 节点）
    local idx=$(( RANDOM % ${#SLAVE_SERVERS[@]} ))
    TARGET_NODE="${SLAVE_SERVERS[$idx]}"
    assert_ne "$TARGET_NODE" "" "注入目标: ${TARGET_NODE}"
}

# ============================================================
# inject：停止 1 个 TiKV
# ============================================================
inject() {
    stop_tikv "$TARGET_NODE"
}

# ============================================================
# check_during：采集故障期间元数据延迟
# ============================================================
check_during() {
    # 等待 Raft leader 切换（~5-10s）
    sleep 10

    # TiKV store 减少（等 PD 心跳超时检测）
    assert_wait_eq get_tikv_store_count_up "2" 30 "TiKV store 2/3 Up"

    # 采集故障期间元数据延迟（30 次）
    echo "# 采集故障期间元数据延迟（30 次）..."
    local fault_samples
    fault_samples=$(_collect_meta_latency 30)
    FAULT_P95=$(_get_percentile "$fault_samples")

    if [ "${BASELINE_P95:-0}" -gt 0 ] 2>/dev/null; then
        echo "# 基线 P95=${BASELINE_P95}ms  故障 P95=${FAULT_P95}ms"

        local threshold=$(( BASELINE_P95 * 3 ))
        assert_lt "$FAULT_P95" "$threshold" \
            "故障期间 P95 < 3×基线（${FAULT_P95}ms < ${threshold}ms）"
    else
        echo "# ⚠ 基线采集失败，跳过延迟断言"
    fi

    # 元数据操作可完成（不是只测延迟，也验证可用性）
    local meta_test
    meta_test=$(timeout 8 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
        "${SSH_USER}@${CLIENT_SERVER}" \
        "timeout 3 touch '${META_FILE}' && timeout 3 stat '${META_FILE}' >/dev/null && timeout 3 rm '${META_FILE}' && echo ok" \
        2>/dev/null)
    assert_eq "$meta_test" "ok" "元数据操作可完成"

    # Ceph 不受影响
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up（Ceph 不受影响）"
}

# ============================================================
# recover：启动 TiKV
# ============================================================
recover() {
    start_tikv "$TARGET_NODE"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    assert_wait_eq get_tikv_store_count_up "3" 60 "TiKV 3/3 store Up"
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    start_tikv "$TARGET_NODE" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
