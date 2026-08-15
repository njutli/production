#!/bin/bash
# FT-004: tikv-single-down
# 冻结 1 TiKV（kill -STOP），验证元数据选举延迟 + 成功率 + I/O 不中断
#
# 故障注入：kill -STOP 冻结 TiKV 进程（模拟节点假死：GC pause / CPU 饥饿）
#   - 进程不死 → 不触发 Restart=always
#   - 无 TCP RST → follower 心跳超时 → 真实 Raft 选举
#   - kill -CONT 恢复
#
# 目标选择：PD API 查 metadata region leader 所在节点（确定性命中，非随机）
#
# 元数据探针：nohup 后台循环 touch 唯一文件名，记录 start_ns end_ns rc dur_ms
#   - 不设 per-op timeout：阻塞的操作自然等到选举完成 → rc=0 → 真实延迟
#   - 断言：max_dur_ms < 30s，success_rate = 100%
#
# Raft 配置（全部默认值）：
#   raft-base-tick-interval=1s, raft-election-timeout-ticks=10, max=20 → 选举超时 10-20s
#   选举由心跳超时触发（不是 leader lease）
#
# FT-005 对比：2 TiKV down → 1/3 < majority → 永久阻塞（需 timeout 兜底）
#             1 TiKV down → 2/3 ≥ majority → 选举恢复（10-20s）
# EXPECTED_DURATION=360

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-004"
TEST_NAME="tikv-single-down"
EXPECTED_DURATION=360

trap 'stop_io_load; unfreeze_tikv "$TARGET_NODE" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + PD API 选目标 + 启动 I/O + 启动探针
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "冻结 1 TiKV（kill -STOP），验证元数据选举延迟 + 成功率 + I/O 不中断"

    # 集群初始健康（接受 OK 或 WARN）
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"

    # 初始状态
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_match get_pg_states "active" 10 "初始 PG 含 active"

    # 选择注入目标：PD API 查 metadata region leader 所在节点
    TARGET_NODE=$(get_meta_region_leader_node)
    if [ -z "$TARGET_NODE" ]; then
        echo "# PD API 查询失败，fallback 到随机选择"
        local idx=$(( RANDOM % ${#SLAVE_SERVERS[@]} ))
        TARGET_NODE="${SLAVE_SERVERS[$idx]}"
    fi
    assert_ne "$TARGET_NODE" "" "注入目标: ${TARGET_NODE}（metadata region leader）"

    # 启动 I/O 负载（数据面）
    start_io_load randread 256K 128

    # 预热
    sleep 30

    # 启动后台元数据探针（45s，覆盖 5s baseline + 30s 故障窗口 + 10s 余量）
    start_meta_probe 45

    # 采集 baseline（5s 正常元数据延迟）
    sleep 5
}

# ============================================================
# inject：冻结 TiKV（kill -STOP）
# ============================================================
inject() {
    freeze_tikv "$TARGET_NODE"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # 等待选举完成（10-20s 随机 + 余量）
    echo "# 等待 Raft 选举完成（10-20s）..."
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

    # 元数据成功率 100%（阻塞的操作在选举后自然成功）
    assert_eq "$probe_rate" "100" "元数据成功率 100%（${probe_ok}/${probe_total}，阻塞后自然恢复）"

    # 元数据最大延迟 < 30s（覆盖 10-20s 选举超时 + 余量）
    local max_s=$(( probe_max / 1000 ))
    assert_lt "$probe_max" "30000" "元数据最大延迟 ${max_s}s < 30s（选举超时 10-20s + 余量）"

    # 故障期间数据面 I/O 测试（选举已完成，dd 应正常）
    local fault_io write_rc read_rc md5_match
    fault_io=$(during_fault_io_test)
    write_rc=$(echo "$fault_io" | awk '{print $1}')
    read_rc=$(echo "$fault_io" | awk '{print $2}')
    md5_match=$(echo "$fault_io" | awk '{print $3}')
    assert_eq "$md5_match" "true" "故障期间数据完整性验证（MD5 一致）"
    assert_eq "$write_rc" "0" "故障期间写 I/O 可用（direct）"
    assert_eq "$read_rc" "0" "故障期间读 I/O 可用（direct）"

    # 停止 fio 收集结果
    stop_io_load

    # TiKV store：冻结期间进程仍存活，PD 短期内仍视为 Up（max-peer-down-duration=10m）
    # 不断言 store 数量——PD 的 10m 超时远大于测试窗口

    # 数据面不受影响（TiKV freeze 不影响 Ceph OSD）
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up（数据面不受影响）"
    assert_match "$(get_pg_states)" "active" "PG 仍 active（数据面不受影响）"

    # 集群非 ERR
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（TiKV freeze）"

    # I/O 断言（数据面不受影响）
    assert_io_success_rate 100 "I/O 成功率 100%（数据面不受影响）"
    assert_fio_lat_p99_lt 30000000 "P99 < 30s"
}

# ============================================================
# recover：解冻 TiKV（kill -CONT）
# ============================================================
recover() {
    unfreeze_tikv "$TARGET_NODE"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # TiKV store 恢复（冻结期间 PD 可能仍视为 Up，这里确认 3/3）
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
    unfreeze_tikv "$TARGET_NODE" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
