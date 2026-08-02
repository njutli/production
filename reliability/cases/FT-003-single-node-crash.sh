#!/bin/bash
# FT-003: single-node-crash
# 节点宕机（2 OSD + 1 MON + 1 TiKV + 1 PD 同时失效），验证数据可靠性
# EXPECTED_DURATION=600

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-003"
TEST_NAME="single-node-crash"
EXPECTED_DURATION=600

trap 'stop_io_load; restart_node_storage "$TARGET_NODE" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 写入验证文件 + 启动 I/O 负载
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "节点宕机（2 OSD + 1 MON + 1 TiKV + 1 PD），验证数据可靠性"

    # 集群初始健康（接受 OK 或 WARN，拒绝 ERR）
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"

    # 初始状态
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_quorum_count "3" 10 "初始 3/3 MON quorum"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_match get_pg_states "active" 10 "初始 PG 含 active"

    # 记录 PD leader，用于选择注入目标（crash PD leader 所在节点，确保 leader 切换）
    ORIGINAL_LEADER=$(get_tikv_leader)
    assert_ne "$ORIGINAL_LEADER" "" "记录 PD leader: ${ORIGINAL_LEADER}"

    # 映射 PD leader name → 节点 IP
    case "$ORIGINAL_LEADER" in
        ceph-node1) TARGET_NODE="${SLAVE_SERVERS[0]}" ;;
        ceph-node2) TARGET_NODE="${SLAVE_SERVERS[1]}" ;;
        ceph-node3) TARGET_NODE="${SLAVE_SERVERS[2]}" ;;
        *)          TARGET_NODE="${SLAVE_SERVERS[0]}" ;;
    esac
    assert_ne "$TARGET_NODE" "" "注入目标节点: ${TARGET_NODE}（PD leader=${ORIGINAL_LEADER}）"

    # === 故障前：写入验证文件 + drop cache + 计算 MD5 ===
    local verify_file="${JUICEFS_MOUNT_POINT}/reliability-test/ft003_verify.bin"
    ssh_to_client "dd if=/dev/urandom of='${verify_file}' bs=1M count=10 2>/dev/null; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null" 2>/dev/null
    PRE_FAULT_MD5=$(ssh_to_client "md5sum '${verify_file}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
    assert_ne "$PRE_FAULT_MD5" "" "故障前写入验证文件（MD5=${PRE_FAULT_MD5:0:16}...）"
    VERIFY_FILE="$verify_file"

    # 启动 I/O 负载
    start_io_load randrw 256K 4

    # 预热
    sleep 30
}

# ============================================================
# inject：节点宕机
# ============================================================
inject() {
    crash_node_storage "$TARGET_NODE"
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # --- 元数据面恢复（T=5~30s）---
    assert_wait_ne get_tikv_leader "$ORIGINAL_LEADER" 30 \
        "PD leader 30s 内切换（原 leader=${ORIGINAL_LEADER} 已失效）"

    # TiKV store 数量减少（PD leader 切换后新 leader 需等 store heartbeat 超时，最长 ~120s）
    assert_wait_eq get_tikv_store_count_up "2" 120 "TiKV store 2/3 Up（宕机节点 store Down）"

    # --- 数据面恢复（T=10~35s）---
    # OSD 心跳超时后集群检测到节点宕机（ceph status 在节点隔离期间可能挂起，改用 OSD count）
    assert_wait_lt get_osd_count_up 6 60 "OSD 心跳超时后集群检测到节点宕机（OSD count < 6）"

    # OSD 数量减少
    assert_wait_eq get_osd_count_up "4" 60 "4/6 OSD up（宕机节点 2 OSD down）"

    # 集群非 ERR（EC 4+2 容忍 2 OSD down）
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（EC 极限容忍内）"

    # --- MON quorum ---
    assert_wait_eq get_quorum_count "2" 60 "MON quorum 收缩至 2/3（宕机节点 MON 被踢出）"

    # === 核心：故障期间 I/O 阻塞时间测量 ===
    # 每 15 秒尝试读验证文件，首次成功后额外验证 2 次确保稳定，然后停止
    stop_io_load
    echo "# 开始 I/O 恢复探测（每 15s 一次，首次成功后验证 2 次即停）..."

    local io_recovered=false
    local first_ok_time=-1
    local fault_start=$(date +%s)
    local consecutive_ok=0

    for i in $(seq 1 20); do
        local t=$((i * 15))

        # 读验证文件 + 对比 MD5（先 drop cache 确保从存储读）
        local read_result
        read_result=$(timeout 75 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
            "${SSH_USER}@${CLIENT_SERVER}" \
            "echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null; timeout 60 dd if='${VERIFY_FILE}' of=/tmp/ft003_readback.bin bs=1M count=10 2>/dev/null; echo \$?" \
            2>/dev/null)
        local read_rc=$(echo "$read_result" | tail -1)

        if [ "$read_rc" = "0" ]; then
            local post_md5
            post_md5=$(timeout 15 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
                "${SSH_USER}@${CLIENT_SERVER}" \
                "md5sum /tmp/ft003_readback.bin 2>/dev/null | awk '{print \$1}'" 2>/dev/null)

            if [ "$post_md5" = "$PRE_FAULT_MD5" ]; then
                if [ "$io_recovered" = "false" ]; then
                    first_ok_time=$t
                    io_recovered=true
                fi
                consecutive_ok=$((consecutive_ok + 1))
                echo "# T+${t}s: 读取成功 MD5一致 ✓ (连续 ${consecutive_ok})"
                # 首次成功后再连续成功 2 次，确认稳定
                if [ "$consecutive_ok" -ge 3 ]; then
                    echo "# I/O 已稳定恢复，停止探测"
                    break
                fi
            else
                consecutive_ok=0
                echo "# T+${t}s: 读取成功 但MD5不一致（${post_md5:0:8} != ${PRE_FAULT_MD5:0:8}）"
            fi
        else
            consecutive_ok=0
            echo "# T+${t}s: 读取失败 rc=$read_rc"
        fi

        [ $i -lt 20 ] && sleep 2
    done

    # 断言：I/O 最终恢复
    local elapsed=$(($(date +%s) - fault_start))
    assert_eq "$io_recovered" "true" "故障期间 I/O 恢复（首次成功 T+${first_ok_time}s）"
    echo "# I/O 阻塞总时长: ${first_ok_time}s（探测耗时 ${elapsed}s）"

    # 清理读回文件
    ssh_to_client "rm -f /tmp/ft003_readback.bin" 2>/dev/null || true
}

# ============================================================
# recover：从 crash 恢复
# ============================================================
recover() {
    restart_node_storage "$TARGET_NODE"
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # --- Ceph 恢复 ---
    assert_pg_state_contains "active+clean" 300 "PG 300s 内恢复 active+clean"
    assert_wait_eq get_osd_count_up "6" 60 "6/6 OSD up"
    assert_wait_eq get_quorum_count "3" 120 "MON quorum 恢复 3/3"

    # 集群恢复健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"

    # --- TiKV/PD 恢复 ---
    assert_wait_eq get_tikv_store_count_up "3" 60 "TiKV 3/3 store Up"

    # --- 恢复后验证 I/O ---
    start_io_load randrw 256K 4
    sleep 10
    stop_io_load
    assert_io_success_rate 100 "恢复后 I/O 成功率 100%"

    # --- 恢复后验证文件 MD5 ---
    local post_md5
    post_md5=$(ssh_to_client "md5sum '${VERIFY_FILE}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
    assert_eq "$post_md5" "$PRE_FAULT_MD5" "恢复后验证文件 MD5 一致（数据无损坏）"

    # 清理验证文件
    ssh_to_client "rm -f '${VERIFY_FILE}'" 2>/dev/null || true

    # 无残留故障
    local noout
    noout=$(_ceph osd dump 2>/dev/null | grep noout)
    assert_eq "$noout" "" "无 noout 残留"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    restart_node_storage "$TARGET_NODE" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
