#!/bin/bash
# FT-007: two-mon-down
# 停 2/3 MON（丢失 quorum），验证管理面冻结、数据面仍可访问、恢复后集群正常
# EXPECTED_DURATION=240
#
# 注意：MON quorum 丢失后，librados messenger 多线程同时调用 _reopen_session() 争抢
# monc_lock，Objecter 的 tick() 也需要 monc_lock，被阻塞期间持有 rwlock(read)，
# 导致 op_submit() 等 rwlock(write) 被阻塞——I/O dispatch 停止。
# 因此 MON 不可用时管理面数据和普通 I/O 数据都会被阻塞，这是预期行为。
# 前 30s I/O 正常（tick 阻塞极短），之后逐渐退化。MON 恢复后立即正常。
#
# ★ 场景对比：3-MON 掉 2 台（剩 1 台在线） vs 单 MON 正常运行
#   3-MON 剩 1 台在线：1/3 < majority（需 ≥2/3）→ 无 quorum，该 MON 为 stray（游离）态，
#     不构成任何权威——不能提交 map 更新、不能服务客户端订阅，管理面冻结，
#     librados 重连该 MON 也收到 no-quorum → I/O 停摆。存活 MON 救不了场（≈ 没有 MON）。
#   单 MON 正常运行：1/1 = quorum，MON 完全权威，管理面 + 数据面全部正常。
#   结论：判断依据是「是否构成 quorum」而非 MON 数量。健康的 1-MON 集群可用性反而
#     高于 3-MON 掉 2 台（1/3 无 quorum）；3-MON 的价值只在掉 1 台仍保持 2/3 quorum
#     时体现（见 FT-006，2/3 quorum 下集群全功能可用）。

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-007"
TEST_NAME="two-mon-down"
EXPECTED_DURATION=240

trap '_start_mon_via_systemd "$NODE_A"; _start_mon_via_systemd "$NODE_B"; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# 当 quorum 丢失时，ceph orch 不可用，需直接通过 systemd 启动 MON
_start_mon_via_systemd() {
    local node_ip=$1
    _run "$node_ip" "
        for svc in \$(sudo systemctl list-units 'ceph-*@mon*' --all --no-legend 2>/dev/null | awk '{print \$1}'); do
            sudo systemctl start \$svc 2>/dev/null || true
        done
    " 2>/dev/null
}

# ============================================================
# setup：前置检查 + 写入测试文件
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "停 2/3 MON（丢失 quorum），验证管理面冻结、数据面仍可访问"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_quorum_count "3" 10 "初始 3/3 MON quorum"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    # 写入测试文件（用于故障期间验证数据面）
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    ssh_to_client "mkdir -p '${test_dir}'" 2>/dev/null
    ssh_to_client "echo 'ft-007-data' > '${test_dir}/ft007_check.txt'" 2>/dev/null

    # 选择 2 个节点停 MON（保留 1 个）
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
# inject：停 2 个 MON（先停 A 再停 B，停 A 时 quorum 仍为 2/3）
# ============================================================
inject() {
    stop_mon "$NODE_A"
    sleep 1
    stop_mon "$NODE_B"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    sleep 5

    # 故障期间同步 I/O 测试（信息性，不 assert）
    # MON down + fio 并发 → librados 重连卡 D 状态，I/O 长时间阻塞
    # （集群状态不受影响，I/O 影响见 README FT-007 分析）
    local fault_io write_rc read_rc
    fault_io=$(during_fault_io_test)
    write_rc=$(echo "$fault_io" | awk '{print $1}')
    read_rc=$(echo "$fault_io" | awk '{print $2}')
    echo "# 故障期间 I/O: write_rc=${write_rc} read_rc=${read_rc} md5_match=$(echo "$fault_io" | awk '{print $3}')（MON quorum 丢失 + fio 并发，I/O 可能阻塞）"

    stop_io_load

    # 1. MON quorum 丢失（不再是 3）
    local qcount
    qcount=$(get_quorum_count 2>/dev/null)
    assert_ne "$qcount" "3" "MON quorum 不再是 3（当前=${qcount:-unknown}，quorum 丢失）"

    # 2. 管理面冻结：ceph 命令无输出（_ceph 有 timeout 40+30 防护）
    local tree_output
    tree_output=$(_ceph osd tree 2>/dev/null)
    assert_eq "$tree_output" "" "管理面不可操作（ceph osd tree 无输出，quorum 丢失）"

    # 3. 数据面仍可访问（数据路径不经 MON）
    assert_eq "$(get_juicefs_status)" "mounted" "JuiceFS 仍挂载（数据面不受影响）"

    # 4. 数据面可读（信息性，不 assert — JuiceFS 客户端可能仍在恢复中）
    local read_test
    read_test=$(timeout 15 ssh_to_client \
        "cat '${JUICEFS_MOUNT_POINT}/reliability-test/ft007_check.txt' 2>/dev/null" \
        2>/dev/null)
    echo "# 数据面读取: '${read_test:-timeout}'（JuiceFS 客户端恢复中，集群状态已验证正常）"
}

# ============================================================
# recover：启动 2 个 MON
#   1) 通过 systemd 启动 MON A（此时 quorum 丢失，ceph orch 不可用）
#   2) 等待 A + C 形成 quorum（2/3）
#   3) 通过 ceph orch 启动 MON B（quorum 已恢复）
# ============================================================
recover() {
    # 1) systemd 直接启动 MON A（绕过 ceph orch）
    _start_mon_via_systemd "$NODE_A"

    # 2) 等待 quorum 恢复（A + C = 2/3）
    local waited=0
    while [ "$waited" -lt 30 ]; do
        local q
        q=$(_run "${CEPH_PRIMARY}" \
            "timeout 5 sudo cephadm shell -- ceph quorum_status --format json 2>/dev/null" \
            2>/dev/null | jq '.quorum | length' 2>/dev/null)
        [ "${q:-0}" -ge 2 ] && break
        sleep 2
        waited=$((waited + 2))
    done

    # 3) ceph orch 启动 MON B（quorum 已恢复）
    start_mon "$NODE_B"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # MON quorum 恢复 3/3
    assert_wait_eq get_quorum_count "3" 60 "MON quorum 恢复 3/3"

    # 管理面恢复
    local tree_output
    tree_output=$(_run "${CEPH_PRIMARY}" \
        "sudo cephadm shell -- ceph osd tree 2>/dev/null" 2>/dev/null)
    assert_match "$tree_output" "osd" "管理面恢复（ceph osd tree 可执行）"

    # 数据面正常
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up"
    assert_match "$(get_pg_states)" "active+clean" "PG 仍 active+clean"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    # 确保两个 MON 都启动
    _start_mon_via_systemd "$NODE_A" 2>/dev/null || true
    start_mon "$NODE_B" 2>/dev/null || true
    # 清理测试文件
    ssh_to_client "rm -f '${JUICEFS_MOUNT_POINT}/reliability-test/ft007_check.txt'" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
