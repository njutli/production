#!/bin/bash
# FT-002: disk-fault
# 挂起 OSD 数据 LV 的 dm 设备（dmsetup suspend）模拟磁盘 I/O 超时，验证 I/O 不中断、恢复后数据完整
# EXPECTED_DURATION=480

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-002"
TEST_NAME="disk-fault"
EXPECTED_DURATION=480

trap 'stop_io_load; _run "$TARGET_NODE" "sudo dmsetup resume ${TARGET_LV} 2>/dev/null" 2>/dev/null; start_osd "$TARGET_OSD" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# 获取 OSD 数据 LV 路径
# cephadm 部署的 OSD 没有 host 端 ceph-volume，改用 ceph osd metadata 获取 block device
_get_osd_data_lv() {
    local osd_id=$1 node=$2
    local meta
    meta=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd metadata ${osd_id} 2>/dev/null" 2>/dev/null)
    echo "$meta" | grep 'bluestore_bdev_partition_path' | head -1 | awk -F'"' '{print $4}'
}

# ============================================================
# setup：前置检查 + 启动 I/O 负载
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "挂起 OSD 数据 dm 设备模拟磁盘 I/O 超时，验证 I/O 不中断、恢复后数据完整"

    # 集群初始健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"

    # 初始状态
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    # 选择注入目标
    TARGET_OSD=$(pick_random_osd)
    assert_ne "$TARGET_OSD" "" "选中的 OSD id: ${TARGET_OSD}"

    # 获取 OSD 所在节点
    TARGET_NODE=$(get_osd_node "$TARGET_OSD")
    assert_ne "$TARGET_NODE" "" "OSD ${TARGET_OSD} 所在节点: ${TARGET_NODE}"

    # 获取 OSD 数据 LV 路径
    TARGET_LV=$(_get_osd_data_lv "$TARGET_OSD" "$TARGET_NODE")
    assert_ne "$TARGET_LV" "" "OSD 数据 LV: ${TARGET_LV}"

    # 启动 I/O 负载
    start_io_load randrw 256K 128

    # 预热
    sleep 30
}

# ============================================================
# inject：挂起 dm 设备（模拟磁盘 I/O 超时）
# ============================================================
inject() {
    # dmsetup suspend：设备还在，但 I/O 被挂起不返回
    # OSD 进程活着但 I/O 卡住，Ceph 靠超时检测（~20-30s）
    _run "$TARGET_NODE" "sudo dmsetup suspend ${TARGET_LV} 2>/dev/null"

    # 验证设备已挂起
    local dm_state
    dm_state=$(_run "$TARGET_NODE" "sudo dmsetup info ${TARGET_LV} 2>/dev/null | grep -i 'SUSPENDED' | head -1" 2>/dev/null)
    assert_match "$dm_state" "SUSPENDED" "dm 设备 ${TARGET_LV} 已挂起"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # 等待 Ceph 检测（OSD I/O 挂起 → slow ops / 心跳超时 → 标记 down）
    sleep 5

    # 集群检测到磁盘 I/O 超时（slow ops 是 dmsetup suspend 的直接症状，出现快）
    assert_wait_match get_ceph_health "slow" 60 "集群检测到磁盘 I/O 超时（slow ops）"

    # OSD 数量：dmsetup suspend 不停止 OSD 进程，OSD 仍 up（靠 slow ops 检测，不靠 OSD down）
    # 不断言 OSD down — dmsetup suspend 下 OSD 进程仍发心跳，down 时序不可控（200-300s+）

    # 集群非 ERR
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（EC 容忍内）"

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

    # I/O 延迟检测：
    # P99 < 30s：dmsetup suspend 不杀 OSD 进程，大部分 IO 走正常路径（EC 从剩余 5 chunk 读）
    # Max 不检查：OSD 活着但磁盘 I/O 挂起，Ceph 不重路由直到 slow ops 超时（~120s）
    #           命中被挂起 OSD 的 PG 的 IO 会被阻塞到 Ceph 重路由，max 高是预期行为
    assert_io_success_rate 100 "I/O 成功率 100%（EC 容忍，数据仍可读）"
    assert_fio_lat_p99_lt 30000000 "P99 < 30s（大部分 I/O 未受影响）"
}

# ============================================================
# recover：恢复 dm 设备（移除磁盘故障）
# ============================================================
recover() {
    # dmsetup resume：I/O 恢复，底层 NVMe 数据完好
    _run "$TARGET_NODE" "sudo dmsetup resume ${TARGET_LV} 2>/dev/null"
    # OSD 可能需要重启（如果进程因 I/O 超时已退出）
    sleep 3
    start_osd "$TARGET_OSD"

    # 验证设备已恢复
    local dm_state
    dm_state=$(_run "$TARGET_NODE" "sudo dmsetup info ${TARGET_LV} 2>/dev/null | grep -i 'SUSPENDED' | head -1" 2>/dev/null)
    assert_eq "$dm_state" "" "dm 设备 ${TARGET_LV} 已恢复（非 SUSPENDED）"
}

# ============================================================
# check_after：恢复后断言（验证数据完整）
# ============================================================
check_after() {
    # OSD 恢复 up
    assert_wait_eq get_osd_status "$TARGET_OSD" "up" 60 "OSD ${TARGET_OSD} 恢复 up"

    # PG 恢复 active+clean
    assert_pg_state_contains "active+clean" 300 "PG 300s 内恢复 active+clean"

    # OSD 数量恢复
    assert_wait_eq get_osd_count_up "6" 60 "6/6 OSD up"

    # 集群恢复健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    # 确保 dm 设备处于恢复状态
    _run "$TARGET_NODE" "sudo dmsetup resume ${TARGET_LV} 2>/dev/null" 2>/dev/null || true
    ensure_osd_up "$TARGET_OSD"
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
