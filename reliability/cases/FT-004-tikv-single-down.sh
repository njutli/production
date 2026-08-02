#!/bin/bash
# FT-003: tikv-single-down
# 停 1 TiKV，验证元数据操作可完成、Raft leader 切换、I/O 不中断
# EXPECTED_DURATION=360

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-004"
TEST_NAME="tikv-single-down"
EXPECTED_DURATION=360

trap 'stop_io_load; start_tikv "$TARGET_NODE" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 启动 I/O 负载
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "停 1 TiKV，验证元数据操作可完成、I/O 不中断"

    # 集群初始健康（接受 OK 或 WARN）
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"

    # 初始状态
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_match get_pg_states "active" 10 "初始 PG 含 active"

    # 选择注入目标（随机 slave 节点）
    local idx=$(( RANDOM % ${#SLAVE_SERVERS[@]} ))
    TARGET_NODE="${SLAVE_SERVERS[$idx]}"
    assert_ne "$TARGET_NODE" "" "注入目标: ${TARGET_NODE}"

    # 启动 I/O 负载
    start_io_load randrw 256K 128

    # 预热
    sleep 30
}

# ============================================================
# inject：停止 1 个 TiKV（systemctl stop，优雅停止）
# ============================================================
inject() {
    stop_tikv "$TARGET_NODE"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # 循环测试元数据操作，从 inject 后立即开始，捕捉 Raft 选举窗口
    # 每次 touch+stat+rm 走一次元数据路径，阻塞说明 Raft leader 还在切换
    # 外层 timeout 8s 杀 SSH 客户端（兜底，防止 FUSE D 状态导致循环卡死）
    # 内层 timeout 3s 杀单个操作（touch/stat/rm），超时则视为 blocked
    local meta_file="${JUICEFS_MOUNT_POINT}/reliability-test/meta_check"
    local meta_ok=0 meta_block=0 meta_first_ok=""
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
            [ -z "$meta_first_ok" ] && meta_first_ok=$i
        else
            meta_block=$((meta_block + 1))
        fi
        echo "  t=${i}s meta=${result:-block}"
        sleep 1
    done

    # 元数据操作最终恢复（Raft leader 切换完成）
    assert_gt "$meta_ok" "0" "元数据操作恢复（${meta_ok}/15 次成功）"

    # 首次成功时间（衡量 Raft 选举延迟）
    if [ -n "$meta_first_ok" ]; then
        echo "# 元数据首次恢复: 第 ${meta_first_ok}s"
    fi

    # 停止 I/O 收集 fio 结果
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

    # TiKV store 数量减少
    local tikv_up
    tikv_up=$(get_tikv_store_count_up)
    assert_eq "$tikv_up" "2" "TiKV store 2/3 Up（目标 TiKV down）"

    # 数据面不受影响（TiKV down 不影响 Ceph OSD）
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up（数据面不受影响）"
    assert_match "$(get_pg_states)" "active" "PG 仍 active（数据面不受影响）"

    # 集群非 ERR（Raft 2/3 majority 仍可服务）
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（TiKV down）"

    # I/O 断言（数据面不受影响，I/O 应正常）
    assert_io_success_rate 100 "I/O 成功率 100%（数据面不受影响）"
    assert_fio_lat_p99_lt 30000000 "P99 < 30s"
}

# ============================================================
# recover：启动 TiKV（幂等）
# ============================================================
recover() {
    start_tikv "$TARGET_NODE"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # TiKV store 恢复
    assert_wait_eq get_tikv_store_count_up "3" 60 "TiKV 3/3 store Up"

    # OSD 不受影响
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up"

    # PG 不受影响
    assert_match "$(get_pg_states)" "active" "PG 仍 active"

    # 集群健康（非 ERR）
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    start_tikv "$TARGET_NODE" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
