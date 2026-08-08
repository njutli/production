#!/bin/bash
# DG-001: osd-down-throughput-degradation
# 比较 6/6 OSD up vs 5/6 OSD down 稳态吞吐差异
# 两轮相同时长 fio，唯一变量是有无 OSD down
# EXPECTED_DURATION=300

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="DG-001"
TEST_NAME="osd-down-throughput-degradation"
EXPECTED_DURATION=300

trap 'stop_io_load; ensure_osd_up "$TARGET_OSD" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 选择目标 OSD
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "比较 6/6 OSD up vs 5/6 OSD down（稳态 active+degraded）的吞吐差异"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    TARGET_OSD=$(pick_random_osd)
    assert_ne "$TARGET_OSD" "" "选中 OSD: ${TARGET_OSD}"
}

# ============================================================
# phase 1：基线（6/6 OSD up）
# ============================================================
phase1_baseline() {
    echo ""
    echo "=== Phase 1: 基线（6/6 OSD up）==="

    start_io_load randread 256K 128
    sleep 30
    stop_io_load
    cp /tmp/reliability-fio-result.json /tmp/dg001-baseline.json
    BASELINE_IOPS=$(python3 -c "import json; d=json.load(open('/tmp/dg001-baseline.json')); j=d['jobs'][0]; print(f\"{j['read']['iops']:.0f}\")" 2>/dev/null)
    echo "# 基线 IOPS: ${BASELINE_IOPS}"
    assert_gt "$BASELINE_IOPS" "0" "基线吞吐采集成功（IOPS=${BASELINE_IOPS}）"
}

# ============================================================
# phase 2：降级（5/6 OSD down，稳态 active+degraded）
# ============================================================
phase2_degraded() {
    echo ""
    echo "=== Phase 2: 降级（5/6 OSD up，active+degraded）==="

    stop_osd "$TARGET_OSD"
    sleep 5
    assert_pg_state_contains "degraded" 30 "PG 进入 degraded"
    assert_wait_eq get_osd_count_up "5" 30 "5/6 OSD up"

    # 等 peering 完成，PG 稳定到 active+degraded（不再是 peering/stale）
    local _waited=0
    while [ "$_waited" -lt 60 ]; do
        local _all_active=true
        for _state in $(get_pg_states 2>/dev/null); do
            case "$_state" in *active*) ;; *) _all_active=false; break ;; esac
        done
        if [ "$_all_active" = true ]; then break; fi
        sleep 2
        _waited=$((_waited + 2))
    done
    echo "# 等待 PG 稳定（${_waited}s）"

    start_io_load randread 256K 128
    sleep 30
    stop_io_load
    cp /tmp/reliability-fio-result.json /tmp/dg001-degraded.json
    DEGRADED_IOPS=$(python3 -c "import json; d=json.load(open('/tmp/dg001-degraded.json')); j=d['jobs'][0]; print(f\"{j['read']['iops']:.0f}\")" 2>/dev/null)
    echo "# 降级 IOPS: ${DEGRADED_IOPS}"
    assert_gt "$DEGRADED_IOPS" "0" "降级吞吐采集成功（IOPS=${DEGRADED_IOPS}）"
}

# ============================================================
# phase 3：对比
# ============================================================
phase3_compare() {
    echo ""
    echo "=== Phase 3: 对比 ==="

    # 恢复 OSD
    start_osd "$TARGET_OSD"

    local ratio pct
    ratio=$(python3 -c "print(f'{$DEGRADED_IOPS / $BASELINE_IOPS:.2f}')" 2>/dev/null)
    pct=$(python3 -c "print(f'{$DEGRADED_IOPS / $BASELINE_IOPS * 100:.0f}')" 2>/dev/null)
    echo "# 基线 IOPS=${BASELINE_IOPS}  降级 IOPS=${DEGRADED_IOPS}  比率=${ratio}（${pct}%）"

    # 吞吐降幅不超过 20%（瓶颈在 FUSE/JuiceFS，5/6 OSD 应该够用）
    local min_pct=80
    assert_gt "$pct" "$((min_pct - 1))" "降级吞吐 ≥ 基线 ${min_pct}%（${pct}% ≥ ${min_pct}%）"

    assert_wait_eq get_osd_count_up "6" 60 "6/6 OSD up"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    ensure_osd_up "$TARGET_OSD"
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; phase1_baseline; phase2_degraded; phase3_compare; teardown; }
main "$@"
