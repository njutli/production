#!/bin/bash
# DG-002: tikv-down-throughput-degradation
# 比较 3/3 TiKV up vs 2/3 TiKV down（Raft leader 切换后稳态）的吞吐差异
# 两轮相同时长 fio（randread，预创建文件避免元数据干扰），唯一变量是有无 TiKV down
# EXPECTED_DURATION=300

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="DG-002"
TEST_NAME="tikv-down-throughput-degradation"
EXPECTED_DURATION=300

trap 'stop_io_load; start_tikv "$TARGET_NODE" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 选择目标节点
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "比较 3/3 TiKV up vs 2/3 TiKV down（稳态）的吞吐差异"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"

    local idx=$(( RANDOM % ${#SLAVE_SERVERS[@]} ))
    TARGET_NODE="${SLAVE_SERVERS[$idx]}"
    assert_ne "$TARGET_NODE" "" "注入目标: ${TARGET_NODE}"
}

# ============================================================
# phase 1：基线（3/3 TiKV up）
# ============================================================
phase1_baseline() {
    echo ""
    echo "=== Phase 1: 基线（3/3 TiKV up）==="

    start_io_load randread 256K 128
    sleep 30
    stop_io_load
    cp /tmp/reliability-fio-result.json /tmp/dg002-baseline.json
    BASELINE_IOPS=$(python3 -c "import json; d=json.load(open('/tmp/dg002-baseline.json')); j=d['jobs'][0]; print(f\"{j['read']['iops']:.0f}\")" 2>/dev/null)
    echo "# 基线 IOPS: ${BASELINE_IOPS}"
    assert_gt "$BASELINE_IOPS" "0" "基线吞吐采集成功（IOPS=${BASELINE_IOPS}）"
}

# ============================================================
# phase 2：降级（2/3 TiKV up，Raft leader 切换后稳态）
# ============================================================
phase2_degraded() {
    echo ""
    echo "=== Phase 2: 降级（2/3 TiKV up，Raft 稳态）==="

    stop_tikv "$TARGET_NODE"
    sleep 10
    assert_wait_eq get_tikv_store_count_up "2" 30 "TiKV store 2/3 Up"

    # 等 Raft leader 切换完成，元数据操作恢复
    local _meta_ok=false
    for _i in $(seq 1 15); do
        local _r
        _r=$(timeout 8 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
            "${SSH_USER}@${CLIENT_SERVER}" \
            "timeout 3 touch /mnt/juicefs/reliability-test/.dg002_check 2>/dev/null && \
             timeout 3 rm /mnt/juicefs/reliability-test/.dg002_check 2>/dev/null && echo ok" \
            2>/dev/null)
        if [ "$_r" = "ok" ]; then _meta_ok=true; break; fi
        sleep 2
    done
    assert_eq "$_meta_ok" "true" "Raft leader 切换完成，元数据恢复"

    start_io_load randread 256K 128
    sleep 30
    stop_io_load
    cp /tmp/reliability-fio-result.json /tmp/dg002-degraded.json
    DEGRADED_IOPS=$(python3 -c "import json; d=json.load(open('/tmp/dg002-degraded.json')); j=d['jobs'][0]; print(f\"{j['read']['iops']:.0f}\")" 2>/dev/null)
    echo "# 降级 IOPS: ${DEGRADED_IOPS}"
    assert_gt "$DEGRADED_IOPS" "0" "降级吞吐采集成功（IOPS=${DEGRADED_IOPS}）"
}

# ============================================================
# phase 3：对比
# ============================================================
phase3_compare() {
    echo ""
    echo "=== Phase 3: 对比 ==="

    start_tikv "$TARGET_NODE"

    local pct
    pct=$(python3 -c "print(f'{$DEGRADED_IOPS / $BASELINE_IOPS * 100:.0f}')" 2>/dev/null)
    echo "# 基线 IOPS=${BASELINE_IOPS}  降级 IOPS=${DEGRADED_IOPS}  比率=${pct}%"

    # 吞吐降幅不超过 30%（TiKV down 影响 TSO/元数据，允许一定波动）
    local min_pct=70
    assert_gt "$pct" "$((min_pct - 1))" "降级吞吐 ≥ 基线 ${min_pct}%（${pct}% ≥ ${min_pct}%）"

    assert_wait_eq get_tikv_store_count_up "3" 60 "TiKV 3/3 store Up"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群健康（非 ERR）"
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

main() { setup; phase1_baseline; phase2_degraded; phase3_compare; teardown; }
main "$@"
