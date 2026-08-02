#!/bin/bash
# FT-001: single-osd-down
# 停 1 OSD，验证 fault 期间 I/O 不中断（功能验证，性能退化由 DG-001 覆盖）
# EXPECTED_DURATION=360

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-001"
TEST_NAME="single-osd-down"
EXPECTED_DURATION=360

trap 'stop_io_load; start_osd "$TARGET_OSD" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 启动 I/O
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "停 1 OSD，验证 fault 期间 I/O 不中断（功能验证）"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    TARGET_OSD=$(pick_random_osd)
    assert_ne "$TARGET_OSD" "" "选中的 OSD id: ${TARGET_OSD}"

    start_io_load randrw 256K 128
    sleep 30
}

# ============================================================
# inject：停止 OSD
# ============================================================
inject() {
    stop_osd "$TARGET_OSD"
}

# ============================================================
# check_during：故障期间断言（停止 I/O 收集 fault 期间结果）
# ============================================================
check_during() {
    sleep 5

    # PG 进入 degraded
    assert_pg_state_contains "degraded" 30 "PG 30s 内进入 degraded"
    assert_eq "$(get_osd_count_up)" "5" "5/6 OSD up"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR"

    # 停止 I/O 收集 fault 期间结果（不需要跑过 recovery，性能由 DG-001 覆盖）
    # 故障期间同步 I/O 测试（带 timeout + direct，不依赖 fio）
    local fault_io write_rc read_rc
    fault_io=$(during_fault_io_test)
    write_rc=$(echo "$fault_io" | awk '{print $1}')
    read_rc=$(echo "$fault_io" | awk '{print $2}')
    md5_match=$(echo "$fault_io" | awk '{print $3}')
    assert_eq "$md5_match" "true" "故障期间数据完整性验证（MD5 一致）"
    assert_eq "$write_rc" "0" "故障期间写 I/O 可用（direct，10s timeout）"
    assert_eq "$read_rc" "0" "故障期间读 I/O 可用（direct，10s timeout）"

    # 停止 fio 收集结果
    stop_io_load

    # I/O 不中断（EC 容忍内无失败）
    assert_io_success_rate 100 "fault 期间 I/O 成功率 100%（EC 容忍内无数据丢失）"

    # I/O 延迟双指标检测：
    # P99 < 25s：大部分 IO 通过已有 TCP 连接感知 RST → 客户端挂起 IO 等 new OSD map
    #           → PG peering 完成后重路由。耗时 = 3s（fast fail 检测）+ ~14s（PG peering）≈ 17s
    # Max < 90s：极少数 IO（< 0.01%）在 kill 后、客户端感知前提交，走 rados_osd_op_timeout=30s
    #           超时重试路径，可能触发两次超时 → ~60-74s
    assert_fio_lat_p99_lt 25000000 "P99 < 25s（PG peering 窗口期内 IO 延迟可控）"
    assert_fio_lat_max_lt 90000000 "Max < 90s（超时重试路径边缘 IO 不超过 rados_osd_op_timeout × 2 + 余量）"
}

# ============================================================
# recover：启动 OSD，记录恢复开始时间
# ============================================================
recover() {
    start_osd "$TARGET_OSD"
    RECOVER_START=$(date +%s)
}

# ============================================================
# check_after：恢复后断言（功能验证）
# ============================================================
check_after() {
    # PG 恢复 clean
    assert_pg_state_contains "active+clean" 300 "PG 300s 内恢复 clean"
    RECOVER_END=$(date +%s)

    # 量化恢复时间
    local recovery_time=$((RECOVER_END - RECOVER_START))
    assert_lt "$recovery_time" 300 "恢复时间 < 300s (actual=${recovery_time}s)"

    # OSD 恢复
    assert_wait_eq get_osd_count_up "6" 60 "6/6 OSD up"

    # 集群健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"
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
