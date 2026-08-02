#!/bin/bash
# DG-001: osd-down-throughput-degradation
# 停 1 OSD，I/O 全程运行（覆盖 fault + recovery），量化吞吐和延迟退化
# FT-001 验证功能（I/O 不中断），DG-001 验证性能（退化多少）
# EXPECTED_DURATION=480

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="DG-001"
TEST_NAME="osd-down-throughput-degradation"
EXPECTED_DURATION=480

trap 'stop_io_load; start_osd "$TARGET_OSD" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：采集基线 + 启动 I/O
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "停 1 OSD，量化 fault + recovery 全程吞吐和延迟退化"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    TARGET_OSD=$(pick_random_osd)
    assert_ne "$TARGET_OSD" "" "选中 OSD: ${TARGET_OSD}"

    # 采集基线
    capture_io_baseline
    if [ "${_IO_BASELINE_BW:-0}" -gt 0 ] 2>/dev/null; then
        echo "# 基线: BW=${_IO_BASELINE_BW} MiB/s  P99=${_IO_BASELINE_P99} us"
    else
        echo "# ⚠ 基线采集失败，性能断言将跳过"
    fi

    # 启动 I/O 负载（全程运行，覆盖 fault + recovery）
    start_io_load randread 256K 128
    sleep 30
}

# ============================================================
# inject：停止 OSD
# ============================================================
inject() {
    stop_osd "$TARGET_OSD"
}

# ============================================================
# check_during：故障期间（I/O 继续运行，不停止）
# ============================================================
check_during() {
    sleep 5
    assert_pg_state_contains "degraded" 30 "PG 进入 degraded"
    assert_wait_eq get_osd_count_up "5" 30 "5/6 OSD up"
    # 不停止 I/O——让它跑过 recovery 阶段
}

# ============================================================
# recover：启动 OSD → 等待 recovery 完成 → 停止 I/O
# ============================================================
recover() {
    start_osd "$TARGET_OSD"
    RECOVER_START=$(date +%s)

    # 等待 recovery 完成
    local elapsed=0
    while [ "$elapsed" -lt 300 ]; do
        get_pg_states 2>/dev/null | grep -q "active+clean" && break
        sleep 5
        elapsed=$((elapsed + 5))
    done
    RECOVER_END=$(date +%s)
    echo "# Recovery 耗时: $((RECOVER_END - RECOVER_START))s"

    # 停止 I/O 收集结果（覆盖 warmup + fault + recovery 全程）
    stop_io_load
}

# ============================================================
# check_after：性能量化（吞吐 + 延迟）
# ============================================================
check_after() {
    # PG 恢复
    assert_pg_state_contains "active+clean" 10 "PG active+clean"
    assert_wait_eq get_osd_count_up "6" 60 "6/6 OSD up"

    # 吞吐（fault + recovery 全程，允许降至基线 70%）
    if [ "${_IO_BASELINE_BW:-0}" -gt 0 ] 2>/dev/null; then
        local min_bw=$(( _IO_BASELINE_BW * 70 / 100 ))
        local actual_bw
        actual_bw=$(get_io_bw)
        echo "# 全程吞吐: ${actual_bw} MiB/s（基线 ${_IO_BASELINE_BW}，下限 ${min_bw}）"
        assert_gt "$actual_bw" "$min_bw" "吞吐 ≥ 基线 70%（${actual_bw} ≥ ${min_bw} MiB/s）"
    else
        echo "# ⚠ 基线采集失败，吞吐断言跳过"
    fi

    # P99 延迟（recovery 期间可能升高，允许 3× 基线）
    if [ "${_IO_BASELINE_P99:-0}" -gt 0 ] 2>/dev/null; then
        local p99_threshold=$(( _IO_BASELINE_P99 * 3 ))
        assert_fio_lat_p99_lt "$p99_threshold" \
            "P99 < ${p99_threshold}us（3× 基线 ${_IO_BASELINE_P99}us）"
    else
        echo "# ⚠ 基线采集失败，P99 断言跳过"
    fi

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    ensure_osd_up "$TARGET_OSD"
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
