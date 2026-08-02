#!/bin/bash
# 临时测试脚本：验证 assert.sh 各函数
# 只覆盖正常集群状态路径（不注入故障，不影响性能测试）
# 用法：bash test-assert.sh

cd "$(dirname "$0")" || exit 1
source config/env.sh
source lib/cluster.sh
source lib/assert.sh

PASS=0; FAIL=0
track() {
    if [ "$1" = "PASS" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

echo "=========================================="
echo " assert.sh 测试"
echo "=========================================="

# ============================================================
# 1. tap_plan_start / tap_plan_end 基本流程
# ============================================================
echo ""
echo "--- 1. tap_plan_start / tap_plan_end ---"

OUT=$(tap_plan_start "TEST-001" "basic-flow" "基本流程验证" 2>&1)
echo "$OUT" | grep -q "TAP version 13" && { echo "  ok  - TAP version 13"; track PASS; } || { echo "  FAIL - 无 TAP version 13"; track FAIL; }
echo "$OUT" | grep -q "# TEST-001: basic-flow" && { echo "  ok  - 用例 ID + 名称"; track PASS; } || { echo "  FAIL - 无用例 ID"; track FAIL; }

tap_plan_start "TEST-001" "basic-flow" "基本流程验证" >/dev/null
assert_eq 1 1 "相等断言"
tap_plan_end >/dev/null  # 重置计数器

# ============================================================
# 2. 基本断言 — PASS 路径
# ============================================================
echo ""
echo "--- 2. 基本断言 PASS ---"

tap_plan_start "TEST-002" "basic-pass" >/dev/null
assert_eq "abc" "abc" "assert_eq PASS"
assert_ne "abc" "xyz" "assert_ne PASS"
assert_lt 3 5 "assert_lt PASS"
assert_gt 5 3 "assert_gt PASS"
assert_match "active+clean" "clean" "assert_match PASS"
# 验证计数
[ "$_ASSERT_PASS" = 5 ] && { echo "  ok  - 5 个断言全 PASS"; track PASS; } || { echo "  FAIL - 计数: $_ASSERT_PASS (expected 5)"; track FAIL; }
tap_plan_end

# ============================================================
# 3. 基本断言 — FAIL 路径（验证输出格式）
# ============================================================
echo ""
echo "--- 3. 基本断言 FAIL ---"

tap_plan_start "TEST-003" "basic-fail" >/dev/null
OUT=$(assert_eq "abc" "xyz" "eq-should-fail" 2>&1)
echo "$OUT" | grep -q "^not ok 1" && { echo "  ok  - assert_eq FAIL 输出 not ok"; track PASS; } || { echo "  FAIL - 未输出 not ok: $OUT"; track FAIL; }
echo "$OUT" | grep -q "actual='abc'" && { echo "  ok  - assert_eq FAIL 含 actual"; track PASS; } || { echo "  FAIL - 不含 actual"; track FAIL; }

OUT=$(assert_lt 10 5 "lt-should-fail" 2>&1)
echo "$OUT" | grep -q "^not ok 2" && { echo "  ok  - assert_lt FAIL 输出 not ok"; track PASS; } || { echo "  FAIL"; track FAIL; }

OUT=$(assert_match "active" "degraded" "match-should-fail" 2>&1)
echo "$OUT" | grep -q "^not ok 3" && { echo "  ok  - assert_match FAIL 输出 not ok"; track PASS; } || { echo "  FAIL"; track FAIL; }
echo "$OUT" | grep -q "!~" && { echo "  ok  - assert_match FAIL 含 !~"; track PASS; } || { echo "  FAIL"; track FAIL; }

[ "$_ASSERT_FAIL" = 3 ] && { echo "  ok  - FAIL 计数 = 3"; track PASS; } || { echo "  FAIL - FAIL 计数: $_ASSERT_FAIL (expected 3)"; track FAIL; }
tap_plan_end

# ============================================================
# 4. tap_plan_end 输出格式
# ============================================================
echo ""
echo "--- 4. tap_plan_end 格式 ---"

tap_plan_start "TEST-004" "plan-format" >/dev/null
assert_eq 1 1 "a"
assert_eq 2 2 "b"
assert_eq 3 4 "c"  # FAIL
OUT=$(tap_plan_end 2>&1)
echo "$OUT" | grep -q "^1..3$" && { echo "  ok  - plan 行 1..3"; track PASS; } || { echo "  FAIL - plan 行: $(echo $OUT | grep '1..')"; track FAIL; }
echo "$OUT" | grep -q "FAIL (2/3)" && { echo "  ok  - 结果行 FAIL (2/3)"; track PASS; } || { echo "  FAIL - 结果行: $(echo $OUT | grep Result)"; track FAIL; }

# ============================================================
# 5. tap_skip
# ============================================================
echo ""
echo "--- 5. tap_skip ---"

OUT=$(tap_skip "前置条件不满足" 2>&1)
echo "$OUT" | grep -q "1..0 # SKIP" && { echo "  ok  - SKIP plan 行"; track PASS; } || { echo "  FAIL"; track FAIL; }
echo "$OUT" | grep -q "Result: SKIP" && { echo "  ok  - SKIP 结果行"; track PASS; } || { echo "  FAIL"; track FAIL; }

# ============================================================
# 6. 轮询断言 — 真实集群正常状态
# ============================================================
echo ""
echo "--- 6. 轮询断言（真实集群，正常状态）---"

tap_plan_start "TEST-006" "poll-real-cluster" "验证轮询断言能查到集群当前状态" >/dev/null

# get_ceph_health 应返回非空（HEALTH_OK 或 HEALTH_WARN）
HEALTH=$(get_ceph_health 2>/dev/null | head -c 11)
assert_wait_eq echo "$HEALTH" 10 "assert_wait_eq 立即匹配 ceph health" >/dev/null 2>&1 && { echo "  ok  - assert_wait_eq 立即匹配"; track PASS; } || { echo "  FAIL - assert_wait_eq"; track FAIL; }

# get_osd_count_up 应返回 6
assert_wait_eq get_osd_count_up "6" 10 "assert_wait_eq get_osd_count_up=6" >/dev/null 2>&1 && { echo "  ok  - assert_wait_eq osd_count_up=6"; track PASS; } || { echo "  FAIL - assert_wait_eq osd_count_up"; track FAIL; }

# get_quorum_count 应返回 3
assert_wait_eq get_quorum_count "3" 10 "assert_wait_eq get_quorum_count=3" >/dev/null 2>&1 && { echo "  ok  - assert_wait_eq quorum_count=3"; track PASS; } || { echo "  FAIL - assert_wait_eq quorum_count"; track FAIL; }

# get_pg_states 应包含 active
assert_wait_match get_pg_states "active" 10 "assert_wait_match pg_states contains active" >/dev/null 2>&1 && { echo "  ok  - assert_wait_match pg_states"; track PASS; } || { echo "  FAIL - assert_wait_match pg_states"; track FAIL; }

# get_tikv_leader 应包含 pd-
assert_wait_match get_tikv_leader "pd-" 10 "assert_wait_match tikv_leader contains pd-" >/dev/null 2>&1 && { echo "  ok  - assert_wait_match tikv_leader"; track PASS; } || { echo "  FAIL - assert_wait_match tikv_leader"; track FAIL; }

tap_plan_end

# ============================================================
# 7. 组合断言 — 真实集群正常状态
# ============================================================
echo ""
echo "--- 7. 组合断言（真实集群，正常状态）---"

tap_plan_start "TEST-007" "combo-real-cluster" >/dev/null

# assert_ceph_health：接受 OK 或 WARN
HEALTH=$(get_ceph_health 2>/dev/null | head -c 11)
assert_ceph_health "$HEALTH" "assert_ceph_health 当前状态" >/dev/null 2>&1 && { echo "  ok  - assert_ceph_health ($HEALTH)"; track PASS; } || { echo "  FAIL - assert_ceph_health"; track FAIL; }

# assert_pg_state_contains
assert_pg_state_contains "active" 10 "assert_pg_state_contains active" >/dev/null 2>&1 && { echo "  ok  - assert_pg_state_contains"; track PASS; } || { echo "  FAIL - assert_pg_state_contains"; track FAIL; }

tap_plan_end

# ============================================================
# 8. 轮询断言 — 超时 FAIL（用一个永远不匹配的值）
# ============================================================
echo ""
echo "--- 8. 轮询断言超时 FAIL ---"

tap_plan_start "TEST-008" "poll-timeout" >/dev/null
T1=$(date +%s)
assert_wait_eq get_osd_count_up "999" 3 "3s 超时后 FAIL" >/dev/null 2>&1
T2=$(( $(date +%s) - T1 ))
[ "$_ASSERT_FAIL" = 1 ] && { echo "  ok  - 超时后标记 FAIL"; track PASS; } || { echo "  FAIL - 未标记 FAIL"; track FAIL; }
[ "$T2" -ge 3 ] && [ "$T2" -le 6 ] && { echo "  ok  - 超时耗时 ${T2}s (expected 3-6s)"; track PASS; } || { echo "  FAIL - 超时耗时 ${T2}s (expected 3-6s)"; track FAIL; }
tap_plan_end

# ============================================================
# 9. assert_wait_ne（值变更检测）
# ============================================================
echo ""
echo "--- 9. assert_wait_ne ---"

tap_plan_start "TEST-009" "wait-ne" >/dev/null
# 当前 tikv_leader 应该不等于 "nonexistent-leader"
assert_wait_ne get_tikv_leader "nonexistent-leader" 5 "tikv_leader != nonexistent" >/dev/null 2>&1 && { echo "  ok  - assert_wait_ne 立即匹配"; track PASS; } || { echo "  FAIL - assert_wait_ne"; track FAIL; }
tap_plan_end

# ============================================================
# 10. assert_wait_eq 带 func args
# ============================================================
echo ""
echo "--- 10. assert_wait_eq 带 func args ---"

tap_plan_start "TEST-010" "wait-eq-with-args" >/dev/null
# get_osd_status 0 应返回 "up"
assert_wait_eq get_osd_status 0 "up" 10 "OSD 0 status = up" >/dev/null 2>&1 && { echo "  ok  - assert_wait_eq with args (get_osd_status 0 = up)"; track PASS; } || { echo "  FAIL - assert_wait_eq with args"; track FAIL; }
tap_plan_end


echo ""
echo "=========================================="
echo " 结果: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" = 0 ] && echo "全部通过" || echo "有失败项，检查上方输出"
