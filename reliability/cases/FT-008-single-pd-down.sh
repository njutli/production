#!/bin/bash
# FT-008: single-pd-down
# 停 1 PD（仍保持 Raft quorum），验证 PD leader 切换、TiKV 读写不受影响
# EXPECTED_DURATION=300

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-008"
TEST_NAME="single-pd-down"
EXPECTED_DURATION=300

trap 'start_pd "$TARGET_NODE" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 记录 PD leader
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "停 1 PD（仍保持 Raft quorum），验证 PD leader 切换、TiKV 读写不受影响"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    # 记录 PD leader，映射到节点 IP（停 leader 确保切换发生）
    ORIGINAL_LEADER=$(get_tikv_leader)
    assert_ne "$ORIGINAL_LEADER" "" "记录 PD leader: ${ORIGINAL_LEADER}"

    case "$ORIGINAL_LEADER" in
        ceph-node1) TARGET_NODE="${SLAVE_SERVERS[0]}" ;;
        ceph-node2) TARGET_NODE="${SLAVE_SERVERS[1]}" ;;
        ceph-node3) TARGET_NODE="${SLAVE_SERVERS[2]}" ;;
        *)          TARGET_NODE="${SLAVE_SERVERS[0]}" ;;
    esac
    assert_ne "$TARGET_NODE" "" "注入目标: ${TARGET_NODE}（PD leader=${ORIGINAL_LEADER}）"

    start_io_load randrw 256K 128
    sleep 30
}

# ============================================================
# inject：停止 1 个 PD
# ============================================================
inject() {
    stop_pd "$TARGET_NODE"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # 等待 PD Raft 选举（election-timeout=3s）
    sleep 5

    # 故障期间同步 I/O 测试（带 timeout + direct，不依赖 fio）
    local fault_io write_rc read_rc
    fault_io=$(during_fault_io_test)
    write_rc=$(echo "$fault_io" | awk '{print $1}')
    read_rc=$(echo "$fault_io" | awk '{print $2}')
    md5_match=$(echo "$fault_io" | awk '{print $3}')
    assert_eq "$md5_match" "true" "故障期间数据完整性验证（MD5 一致）"
    assert_eq "$write_rc" "0" "故障期间写 I/O 可用（PD down 不影响数据面）"
    assert_eq "$read_rc" "0" "故障期间读 I/O 可用（PD down 不影响数据面）"

    stop_io_load

    # 1. PD leader 切换（原 leader 已停）
    assert_wait_ne get_tikv_leader "$ORIGINAL_LEADER" 30 \
        "PD leader 30s 内切换（原=${ORIGINAL_LEADER}）"

    # 2. TiKV 不受影响（PD 是管理层，不是数据层）
    assert_eq "$(get_tikv_store_count_up)" "3" "TiKV 仍 3/3 Up（PD down ≠ TiKV down）"

    # 3. 元数据操作不受影响（TiKV 有本地 region cache，不依赖 PD）
    # timeout 8s 兜底：PD down 不应阻塞元数据，但如果阻塞了不能让测试卡死
    local meta_file="${JUICEFS_MOUNT_POINT}/reliability-test/ft008_check"
    local meta_test
    meta_test=$(timeout 8 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
        "${SSH_USER}@${CLIENT_SERVER}" \
        "timeout 3 touch '${meta_file}' && \
         timeout 3 stat '${meta_file}' >/dev/null && \
         timeout 3 rm '${meta_file}' && \
         echo ok" 2>/dev/null)
    assert_eq "$meta_test" "ok" "元数据操作可完成（touch+stat+rm，不依赖 PD）"

    # 4. Ceph 完全不受影响（PD 是 TiKV 的组件，与 Ceph 无关）
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up（Ceph 不受影响）"
    assert_match "$(get_pg_states)" "active+clean" "PG 仍 active+clean（Ceph 不受影响）"

    # 5. 集群非 ERR
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR"
}

# ============================================================
# recover：启动 PD（幂等）
# ============================================================
recover() {
    start_pd "$TARGET_NODE"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # TiKV 不受影响
    assert_eq "$(get_tikv_store_count_up)" "3" "TiKV 仍 3/3 Up"

    # Ceph 不受影响
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up"
    assert_match "$(get_pg_states)" "active+clean" "PG 仍 active+clean"

    # 集群健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    start_pd "$TARGET_NODE" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
