#!/bin/bash
# FT-009: two-pd-down
# 停 2/3 PD（丢 quorum），验证 PD 管理面冻结、TiKV 事务阻塞（TSO 不可用）、恢复后正常
# EXPECTED_DURATION=480

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-009"
TEST_NAME="two-pd-down"
EXPECTED_DURATION=480

trap 'start_pd "$NODE_A" 2>/dev/null; start_pd "$NODE_B" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "停 2/3 PD（丢 quorum），验证管理面冻结、TiKV 事务阻塞（TSO 不可用）、恢复后正常"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    # 选择 2 个节点停 PD（保留 1 个）
    local shuffled=($(shuf -e "${SLAVE_SERVERS[@]}"))
    NODE_A="${shuffled[0]}"
    NODE_B="${shuffled[1]}"
    assert_ne "$NODE_A" "" "注入目标 A: ${NODE_A}"
    assert_ne "$NODE_B" "" "注入目标 B: ${NODE_B}"
    assert_ne "$NODE_A" "$NODE_B" "两个目标不同"

    start_io_load randrw 256K 128
    sleep 30
}

# ============================================================
# inject：停 2 个 PD（quorum 丢失）
# ============================================================
inject() {
    stop_pd "$NODE_A"
    sleep 1
    stop_pd "$NODE_B"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    sleep 5

    # 1. PD 管理面冻结：PD API 无法返回有效 leader（quorum 丢失）
    local pd_leader
    pd_leader=$(get_tikv_leader 2>/dev/null)
    assert_eq "${pd_leader:-none}" "none" "PD leader 不存在（quorum 丢失，管理面冻结）"

    # 2. TiKV 不受影响（3 个 TiKV 进程都活着，PD down 只影响管理面）
    assert_eq "$(get_juicefs_status)" "mounted" "JuiceFS 仍挂载"

    # 3. 核心断言：新元数据操作阻塞（PD quorum 丢失 → TSO 不可用 → TiKV 新事务无法启动）
    #    touch = 创建新文件 → 需要分配 inode → 写 TiKV → TiKV 用 cache 找到 region leader → 成功
    local meta_file="${JUICEFS_MOUNT_POINT}/reliability-test/ft009_new_io"
    # 故障期间同步 I/O 测试（带 timeout + direct，不依赖 fio）
    local fault_io write_rc read_rc
    fault_io=$(during_fault_io_test)
    write_rc=$(echo "$fault_io" | awk '{print $1}')
    read_rc=$(echo "$fault_io" | awk '{print $2}')
    echo "# 故障期间 I/O: write_rc=${write_rc} read_rc=${read_rc} md5_match=$(echo "$fault_io" | awk '{print $3}')（PD quorum 丢失，写可能失败）"

    stop_io_load

    # 新元数据操作（PD quorum 丢失，需 PD 路由的新操作不可用）
    # timeout 不能包裹 ssh_to_client 函数（返回 127），必须用完整 SSH 命令
    local meta_test
    meta_test=$(timeout 20 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
        "${SSH_USER}@${CLIENT_SERVER}" \
        "timeout 5 touch '${meta_file}' 2>/dev/null && echo ok || echo blocked" \
        2>/dev/null)
    assert_ne "${meta_test:-blocked}" "ok" "新元数据操作阻塞（PD quorum 丢失，需 PD 路由的新操作不可用）"

    # 4. Ceph 完全不受影响（PD 是 TiKV 组件）
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up（Ceph 不受影响）"
    assert_match "$(get_pg_states)" "active+clean" "PG 仍 active+clean（Ceph 不受影响）"

    # 5. 集群非 ERR
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR"
}

# ============================================================
# recover：启动 2 个 PD（systemctl，不需 quorum）
# ============================================================
recover() {
    start_pd "$NODE_A"
    sleep 1
    start_pd "$NODE_B"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # PD 恢复（等待 quorum 重建 + leader 选举）
    assert_wait_eq get_tikv_store_count_up "3" 30 "TiKV 仍 3/3 Up"
    local leader
    leader=$(get_tikv_leader 2>/dev/null)
    assert_ne "$leader" "" "PD leader 已选举（${leader}）"

    # Ceph 不受影响
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up"
    assert_match "$(get_pg_states)" "active+clean" "PG 仍 active+clean"

    # 集群健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"

    # 恢复后元数据可用性验证（参考 FT-005 的恢复探针）
    local rc
    rc=$(timeout 15 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
        "${SSH_USER}@${CLIENT_SERVER}" \
        "timeout 5 touch '${JUICEFS_MOUNT_POINT}/reliability-test/ft009_recover_check' 2>/dev/null && echo ok" \
        2>/dev/null | tail -1)
    assert_eq "${rc:-blocked}" "ok" "恢复后元数据操作可用（PD quorum 恢复，TSO 可用）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    start_pd "$NODE_A" 2>/dev/null || true
    start_pd "$NODE_B" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
