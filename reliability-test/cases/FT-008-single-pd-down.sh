#!/bin/bash
# FT-008: single-pd-down
# 冻结 1 PD（kill -STOP），验证 PD leader 选举延迟 + 元数据成功率 + I/O 不中断
#
# 故障注入：kill -STOP 冻结 PD 进程（模拟节点假死）
#   - 进程不死 → 不触发 Restart=always
#   - 无 TCP RST → PD Raft follower 心跳超时 → 真实选举
#   - kill -CONT 恢复
#
# 目标选择：PD API 查 PD leader 所在节点（确定性命中，非随机）
#
# 元数据探针：nohup 后台循环 touch 唯一文件名，记录 start_ns end_ns rc dur_ms
#   - 不设 per-op timeout：阻塞的操作自然等到选举完成 → rc=0 → 真实延迟
#   - 断言：max_dur_ms < 30s，success_rate = 100%
#
# PD Raft 选举比 TiKV 快（默认 ~3s），但客户端 gRPC keepalive 检测连接死亡需要 ~13s
# 总延迟取决于 keepalive + PD 客户端重试逻辑
# EXPECTED_DURATION=360

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-008"
TEST_NAME="single-pd-down"
EXPECTED_DURATION=360

trap 'stop_io_load; unfreeze_pd "$TARGET_NODE" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 查 PD leader + 启动 I/O + 启动探针
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "冻结 1 PD（kill -STOP），验证 PD leader 选举延迟 + 元数据成功率 + I/O 不中断"

    # 集群初始健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_match get_pg_states "active" 10 "初始 PG 含 active"

    # 查 PD leader 所在节点（确保冻结的是 leader，触发选举）
    ORIGINAL_LEADER=$(get_tikv_leader)
    assert_ne "$ORIGINAL_LEADER" "" "当前 PD leader: ${ORIGINAL_LEADER}"

    case "$ORIGINAL_LEADER" in
        ceph-node1) TARGET_NODE="${SLAVE_SERVERS[0]}" ;;
        ceph-node2) TARGET_NODE="${SLAVE_SERVERS[1]}" ;;
        ceph-node3) TARGET_NODE="${SLAVE_SERVERS[2]}" ;;
        *)          TARGET_NODE="${SLAVE_SERVERS[0]}" ;;
    esac
    assert_ne "$TARGET_NODE" "" "注入目标: ${TARGET_NODE}（PD leader=${ORIGINAL_LEADER}）"

    # 启动 I/O 负载（数据面）
    start_io_load randrw 256K 128

    # 预热
    sleep 30

    # 启动后台元数据探针（45s）
    start_meta_probe 45

    # 采集 baseline
    sleep 5
}

# ============================================================
# inject：冻结 PD（kill -STOP）
# ============================================================
inject() {
    freeze_pd "$TARGET_NODE"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # 等待 PD 选举 + 客户端检测连接死亡（~13s keepalive + 选举）
    echo "# 等待 PD Raft 选举 + 客户端重连..."
    sleep 30

    # 停止探针，解析指标
    local probe_result
    probe_result=$(stop_meta_probe)
    echo "# meta_probe: $probe_result"

    local probe_total probe_ok probe_max probe_rate
    probe_total=$(echo "$probe_result" | grep -o 'total=[0-9]*' | cut -d= -f2)
    probe_ok=$(echo "$probe_result" | grep -o 'ok=[0-9]*' | cut -d= -f2)
    probe_max=$(echo "$probe_result" | grep -o 'max_dur_ms=[0-9]*' | cut -d= -f2)
    probe_rate=$(echo "$probe_result" | grep -o 'success_rate=[0-9]*' | cut -d= -f2)

    # 元数据成功率 100%
    assert_eq "$probe_rate" "100" "元数据成功率 100%（${probe_ok}/${probe_total}，PD 选举期间阻塞后恢复）"

    # 元数据最大延迟 < 30s
    local max_s=$(( probe_max / 1000 ))
    assert_lt "$probe_max" "30000" "元数据最大延迟 ${max_s}s < 30s"

    # 故障期间数据面 I/O 测试
    local fault_io write_rc read_rc md5_match
    fault_io=$(during_fault_io_test)
    write_rc=$(echo "$fault_io" | awk '{print $1}')
    read_rc=$(echo "$fault_io" | awk '{print $2}')
    md5_match=$(echo "$fault_io" | awk '{print $3}')
    assert_eq "$md5_match" "true" "故障期间数据完整性验证（MD5 一致）"
    assert_eq "$write_rc" "0" "故障期间写 I/O 可用（direct）"
    assert_eq "$read_rc" "0" "故障期间读 I/O 可用（direct）"

    # 停止 fio
    stop_io_load

    # PD leader 切换
    assert_wait_ne get_tikv_leader "$ORIGINAL_LEADER" 30 \
        "PD leader 30s 内切换（原=${ORIGINAL_LEADER}）"

    # TiKV 不受影响
    assert_eq "$(get_tikv_store_count_up)" "3" "TiKV 仍 3/3 Up（PD down ≠ TiKV down）"

    # 数据面不受影响
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up（数据面不受影响）"
    assert_match "$(get_pg_states)" "active" "PG 仍 active（数据面不受影响）"

    # 集群非 ERR
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（PD freeze）"

    # I/O 断言
    assert_io_success_rate 100 "I/O 成功率 100%（数据面不受影响）"
    assert_fio_lat_p99_lt 30000000 "P99 < 30s"
}

# ============================================================
# recover：解冻 PD（kill -CONT）
# ============================================================
recover() {
    unfreeze_pd "$TARGET_NODE"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # TiKV 不受影响
    assert_eq "$(get_tikv_store_count_up)" "3" "TiKV 仍 3/3 Up"

    # OSD 不受影响
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up"

    assert_match "$(get_pg_states)" "active" "PG 仍 active"

    # 集群健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    unfreeze_pd "$TARGET_NODE" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
