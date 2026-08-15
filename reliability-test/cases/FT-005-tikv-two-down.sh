#!/bin/bash
# FT-005: tikv-two-down
# 停 2/3 TiKV（Raft majority 丢失），验证元数据操作阻塞（无错误返回）、恢复后继续、无损坏
# EXPECTED_DURATION=480

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-005"
TEST_NAME="tikv-two-down"
EXPECTED_DURATION=480

trap 'stop_io_load; start_tikv "$TARGET_A" 2>/dev/null; start_tikv "$TARGET_B" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 启动 I/O 负载
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "停 2/3 TiKV（Raft majority 丢失），验证元数据阻塞→恢复→无损坏"

    # 集群初始健康（接受 OK 或 WARN）
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"

    # 初始状态
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_match get_pg_states "active" 10 "初始 PG 含 active"

    # 选择 2 个 TiKV 节点停止（随机选 2，保留 1 个）
    local shuffled=($(shuf -e "${SLAVE_SERVERS[@]}"))
    TARGET_A="${shuffled[0]}"
    TARGET_B="${shuffled[1]}"
    assert_ne "$TARGET_A" "" "注入目标 A: ${TARGET_A}"
    assert_ne "$TARGET_B" "" "注入目标 B: ${TARGET_B}"
    assert_ne "$TARGET_A" "$TARGET_B" "两个目标不同"

    # 启动 I/O 负载（后台数据读取，元数据路径由显式测试覆盖）
    start_io_load randrw 256K 128

    # 预热
    sleep 30
}

# ============================================================
# inject：停止 2 个 TiKV（Raft majority 丢失）
# ============================================================
inject() {
    stop_tikv "$TARGET_A"
    sleep 1
    stop_tikv "$TARGET_B"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # TiKV store 仅剩 1（majority 丢失，等 PD 心跳超时检测）
    assert_wait_eq get_tikv_store_count_up "1" 30 "TiKV store 1/3 Up（majority 丢失）"

    # 数据面不受影响
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up（数据面不受影响）"
    assert_match "$(get_pg_states)" "active" "PG 仍 active（数据面不受影响）"

    # 集群非 ERR
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（TiKV majority 丢失）"

    # 核心断言：元数据操作阻塞（TiKV majority 丢失，事务无法完成）
    # touch 用 timeout 10s 测短窗口：rc=124 表示阻塞（预期）
    local rc
    rc=$(timeout 30 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
        "${SSH_USER}@${CLIENT_SERVER}" \
        "timeout 10 touch '${JUICEFS_MOUNT_POINT}/reliability-test/block_check' 2>/dev/null; echo \$?" \
        2>/dev/null | tail -1)
    assert_eq "${rc:-124}" "124" "元数据操作阻塞（timeout 10s，rc=124）"

    # 确认不是偶然：再测一次 stat（也应阻塞）
    local rc2
    rc2=$(timeout 30 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
        "${SSH_USER}@${CLIENT_SERVER}" \
        "timeout 10 stat '${JUICEFS_MOUNT_POINT}/reliability-test' >/dev/null 2>&1; echo \$?" \
        2>/dev/null | tail -1)
    assert_eq "${rc2:-124}" "124" "元数据 stat 操作也阻塞（rc=124）"

    # 故障期间 dd 写测试：TiKV majority 丢失 → 事务无法完成 → dd 最终返回错误
    # dd 写新文件需要创建 inode（TiKV 事务），事务耗尽重试后失败，dd 以 rc≠0 退出
    local fault_io write_rc read_rc
    fault_io=$(during_fault_io_test)
    write_rc=$(echo "$fault_io" | awk '{print $1}')
    read_rc=$(echo "$fault_io" | awk '{print $2}')
    echo "# during_fault_io_test: $fault_io"
    # 预期：write_rc≠0（事务失败），不是 rc=0（意外成功）
    assert_ne "$write_rc" "0" "元数据写操作预期失败（rc=${write_rc}，TiKV majority 丢失，事务无法完成）"

    # 停止 I/O（fio 可能因元数据阻塞而卡住，stop_io_load 会 SIGINT→SIGKILL）
    stop_io_load
}

# ============================================================
# recover：启动 2 个 TiKV
# ============================================================
recover() {
    start_tikv "$TARGET_A"
    sleep 1
    start_tikv "$TARGET_B"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # TiKV store 恢复 3/3
    assert_wait_eq get_tikv_store_count_up "3" 60 "TiKV 3/3 store Up"

    # 元数据操作恢复（循环测试，捕捉 Raft 重新组阁）
    # 外层 timeout 8s 杀 SSH 客户端（兜底），内层 timeout 3s 杀单个操作
    local meta_file="${JUICEFS_MOUNT_POINT}/reliability-test/recovery_check"
    local meta_ok=0
    local i
    for i in $(seq 1 15); do
        local result
        result=$(timeout 8 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
            "${SSH_USER}@${CLIENT_SERVER}" \
            "timeout 3 touch '${meta_file}' && \
             timeout 3 stat '${meta_file}' >/dev/null && \
             timeout 3 rm '${meta_file}' && \
             echo ok" 2>/dev/null)
        if [ "$result" = "ok" ]; then
            meta_ok=$((meta_ok + 1))
            break
        fi
        sleep 1
    done
    assert_gt "$meta_ok" "0" "元数据操作恢复（第 ${i}s 恢复）"

    # 数据面不受影响
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up"
    assert_match "$(get_pg_states)" "active" "PG 仍 active"

    # 集群健康（非 ERR）
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"

    # 无元数据损坏
    local fsck_out
    fsck_out=$(ssh_to_client "sudo CEPH_CONF=/etc/ceph/ceph.conf juicefs fsck '${JUICEFS_METADATA_URL}' 2>&1" 2>/dev/null)
    local fsck_rc=$?
    assert_eq "$fsck_rc" "0" "juicefs fsck 通过（无元数据损坏）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    start_tikv "$TARGET_A" 2>/dev/null || true
    start_tikv "$TARGET_B" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
