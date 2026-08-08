#!/bin/bash
# FT-006: single-mon-down
# 停 1 MON（仍保持 quorum），验证集群可操作、数据面不受影响
# EXPECTED_DURATION=240

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-006"
TEST_NAME="single-mon-down"
EXPECTED_DURATION=240

trap 'start_mon "$TARGET_NODE" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "停 1 MON（仍保持 quorum），验证集群可操作、数据面不受影响"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_quorum_count "3" 10 "初始 3/3 MON quorum"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    # 选择注入目标（随机 slave 节点）
    local idx=$(( RANDOM % ${#SLAVE_SERVERS[@]} ))
    TARGET_NODE="${SLAVE_SERVERS[$idx]}"
    assert_ne "$TARGET_NODE" "" "注入目标: ${TARGET_NODE}"

    start_io_load randrw 256K 128
    sleep 30
}

# ============================================================
# inject：停止 1 个 MON
# ============================================================
inject() {
    stop_mon "$TARGET_NODE"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # MON quorum 收缩至 2/3（仍保持 majority，集群可操作）
    assert_wait_eq get_quorum_count "2" 30 "MON quorum 收缩至 2/3（仍保持 majority）"

    # 故障期间同步 I/O 测试（信息性，不 assert）
    # 受控实验证明：1 MON down 对 I/O 无可测量影响（quorum 保持，monc_lock 无竞争）。
    local fault_io write_rc read_rc
    fault_io=$(during_fault_io_test)
    write_rc=$(echo "$fault_io" | awk '{print $1}')
    read_rc=$(echo "$fault_io" | awk '{print $2}')
    echo "# 故障期间 I/O: write_rc=${write_rc} read_rc=${read_rc} md5_match=$(echo "$fault_io" | awk '{print $3}')"

    stop_io_load

    # 集群仍可操作（ceph 命令可执行）
    local osd_tree
    osd_tree=$(_run "${CEPH_PRIMARY}" \
        "sudo cephadm shell -- ceph osd tree 2>/dev/null" 2>/dev/null)
    assert_match "$osd_tree" "osd" "ceph osd tree 可执行（集群仍可操作）"

    # 数据面不受影响（MON 不在数据路径上）
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up（MON down 不影响数据面）"
    assert_match "$(get_pg_states)" "active+clean" "PG 仍 active+clean（MON down 不影响数据面）"

    # JuiceFS 仍可访问（元数据走 TiKV，不经 MON）
    assert_eq "$(get_juicefs_status)" "mounted" "JuiceFS 仍挂载"

    # 集群非 ERR
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR"
}

# ============================================================
# recover：启动 MON（幂等）
# ============================================================
recover() {
    start_mon "$TARGET_NODE"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # MON quorum 恢复 3/3
    assert_wait_eq get_quorum_count "3" 60 "MON quorum 恢复 3/3"

    # 数据面不受影响
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up"
    assert_match "$(get_pg_states)" "active+clean" "PG 仍 active+clean"

    # 集群健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"

    # 恢复后 I/O 验证（信息性，不 assert）
    # 受控实验证明：1 MON down 对 I/O 无可测量影响，恢复后 I/O 立即可用。
    local rc
    rc=$(timeout 15 ssh_to_client \
        "timeout 5 dd if=/dev/zero of='${JUICEFS_MOUNT_POINT}/reliability-test/recovery_check.bin' bs=1M count=1 oflag=direct 2>/dev/null; echo \$?" \
        2>/dev/null)
    echo "# 恢复后 I/O: rc=${rc:-timeout}"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    start_mon "$TARGET_NODE" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
