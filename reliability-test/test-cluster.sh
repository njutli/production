#!/bin/bash
# test-cluster.sh — 验证 cluster.sh 全部函数（真实集群）
# 用法：bash test-cluster.sh

cd "$(dirname "$0")" || exit 1
source config/env.sh
source lib/cluster.sh

PASS=0; FAIL=0
ok()   { echo "  ok  - $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

echo "=========================================="
echo " cluster.sh 真实集群验证"
echo "=========================================="

# ============================================================
# 1. Ceph 健康查询
# ============================================================
echo ""
echo "--- 1. Ceph 健康查询 ---"

result=$(get_ceph_health 2>/dev/null)
echo "$result" | grep -qE "^HEALTH_(OK|WARN)" && ok "get_ceph_health: $(echo "$result" | head -c 20)" || fail "get_ceph_health: $result"

result=$(get_ceph_health_detail 2>/dev/null)
[ -n "$result" ] && ok "get_ceph_health_detail: 非空" || fail "get_ceph_health_detail: 空"

# ============================================================
# 2. PG 状态
# ============================================================
echo ""
echo "--- 2. PG 状态 ---"

result=$(get_pg_states 2>/dev/null)
echo "$result" | grep -q "active" && ok "get_pg_states: 含 active (实际: $(echo "$result" | head -c 40))" || fail "get_pg_states: 不含 active ($result)"

# ============================================================
# 3. OSD 查询
# ============================================================
echo ""
echo "--- 3. OSD 查询 ---"

result=$(get_osd_count_up 2>/dev/null)
[ "$result" = "6" ] && ok "get_osd_count_up: 6" || fail "get_osd_count_up: $result (expect 6)"

result=$(list_osd_ids 2>/dev/null)
echo "$result" | grep -q "^6 " && ok "list_osd_ids: ${result}" || fail "list_osd_ids: $result"

# get_osd_status
result=$(get_osd_status 6 2>/dev/null)
[ "$result" = "up" ] && ok "get_osd_status 6: up" || fail "get_osd_status 6: $result"

result=$(get_osd_status 7 2>/dev/null)
[ "$result" = "up" ] && ok "get_osd_status 7: up" || fail "get_osd_status 7: $result"

# get_osd_node
result=$(get_osd_node 6 2>/dev/null)
[ "$result" = "192.168.11.11" ] && ok "get_osd_node 6: $result" || fail "get_osd_node 6: $result (expect 192.168.11.11)"

result=$(get_osd_node 8 2>/dev/null)
[ "$result" = "192.168.11.13" ] && ok "get_osd_node 8: $result" || fail "get_osd_node 8: $result (expect 192.168.11.13)"

result=$(get_osd_node 10 2>/dev/null)
[ "$result" = "192.168.11.14" ] && ok "get_osd_node 10: $result" || fail "get_osd_node 10: $result (expect 192.168.11.14)"

# pick_random_osd
result=$(pick_random_osd 2>/dev/null)
echo "6 7 8 9 10 11" | grep -qw "$result" && ok "pick_random_osd: $result" || fail "pick_random_osd: $result (不在 6-11 范围)"

# pick_osd_on_node
result=$(pick_osd_on_node "192.168.11.11" 2>/dev/null)
[ -n "$result" ] && echo "6 7" | grep -qw "$result" && ok "pick_osd_on_node .11: $result" || fail "pick_osd_on_node .11: $result"

result=$(pick_osd_on_node "192.168.11.14" 2>/dev/null)
[ -n "$result" ] && echo "10 11" | grep -qw "$result" && ok "pick_osd_on_node .14: $result" || fail "pick_osd_on_node .14: $result"

# ensure_osd_up（幂等，对已 up 的 OSD 无副作用）
ensure_osd_up 6 2>/dev/null && ok "ensure_osd_up 6: 幂等无报错" || fail "ensure_osd_up 6: 报错"

# 不存在的 OSD ID
result=$(get_osd_status 999 2>/dev/null)
[ "$result" != "up" ] && ok "get_osd_status 999: 非 up ($result)" || fail "get_osd_status 999: 不应返回 up"

result=$(get_osd_node 999 2>/dev/null)
[ "$result" = "unknown" ] && ok "get_osd_node 999: unknown" || fail "get_osd_node 999: $result (expect unknown)"

# ============================================================
# 4. MON quorum
# ============================================================
echo ""
echo "--- 4. MON quorum ---"

result=$(get_quorum_count 2>/dev/null)
[ "$result" = "3" ] && ok "get_quorum_count: 3" || fail "get_quorum_count: $result (expect 3)"

# ============================================================
# 5. PD / TiKV
# ============================================================
echo ""
echo "--- 5. PD / TiKV ---"

result=$(get_pd_health 2>/dev/null)
[ "$result" = "3" ] && ok "get_pd_health: 3" || fail "get_pd_health: $result (expect 3)"

result=$(get_tikv_store_count_up 2>/dev/null)
[ "$result" = "3" ] && ok "get_tikv_store_count_up: 3" || fail "get_tikv_store_count_up: $result (expect 3)"

result=$(get_tikv_leader 2>/dev/null)
echo "$result" | grep -q "ceph-node" && ok "get_tikv_leader: $result" || fail "get_tikv_leader: $result (expect ceph-node*)"

# get_tikv_stores 返回 JSON
result=$(get_tikv_stores 2>/dev/null)
echo "$result" | jq -e '.stores' >/dev/null 2>&1 && ok "get_tikv_stores: JSON 含 stores 数组" || fail "get_tikv_stores: JSON 无效"

# ============================================================
# 6. JuiceFS
# ============================================================
echo ""
echo "--- 6. JuiceFS ---"

result=$(get_juicefs_status 2>/dev/null)
[ "$result" = "mounted" ] && ok "get_juicefs_status: mounted" || fail "get_juicefs_status: $result (expect mounted)"

result=$(get_juicefs_stats 2>/dev/null)
[ -n "$result" ] && ok "get_juicefs_stats: 非空" || fail "get_juicefs_stats: 空"

# ============================================================
# 7. Recovery
# ============================================================
echo ""
echo "--- 7. Recovery ---"

result=$(get_recovery_status 2>/dev/null)
# 可能为空（无 recovery）或非空（有 recovery），都不算 fail
ok "get_recovery_status: $(echo "$result" | head -c 40)..."

# ============================================================
# 8. 快照采集与校验
# ============================================================
echo ""
echo "--- 8. 快照采集与校验 ---"

snap=$(capture_cluster_snapshot 2>/dev/null)
[ -n "$snap" ] && [ -f "$snap" ] && ok "capture_cluster_snapshot: 文件存在 $snap" || fail "capture_cluster_snapshot: 失败"

# 快照内容应有 3 个节点的 PV→VG 映射
if [ -n "$snap" ] && [ -f "$snap" ]; then
    count=$(grep -c '^\[' "$snap" 2>/dev/null)
    [ "$count" = "3" ] && ok "快照含 3 个节点" || fail "快照含 $count 个节点 (expect 3)"

    # 快照内容示例
    echo "  快照内容:"
    head -10 "$snap" 2>/dev/null | sed 's/^/    /'
fi

# verify_cluster_snapshot
# 固定校验项：health 非 ERR, OSD=6, PG active+clean, quorum=3, TiKV=3, JuiceFS mounted, no noout, no iptables, no dmsetup
# 快照对比：PV→VG 映射
echo "  正在校验（可能需要 10-20s）..."
verify_cluster_snapshot 2>&1
rc=$?
[ "$rc" = "0" ] && ok "verify_cluster_snapshot: 全部通过" || fail "verify_cluster_snapshot: 有异常 (rc=$rc)"

# remove_cluster_snapshot
# 注意：capture_cluster_snapshot 在 $(...) 子 shell 中运行，_SNAPSHOT_FILE 不回传
# 需在父 shell 手动设置才能让 remove_cluster_snapshot 删除文件
_SNAPSHOT_FILE="$snap"
remove_cluster_snapshot 2>/dev/null
[ ! -f "$snap" ] && ok "remove_cluster_snapshot: 文件已删除" || fail "remove_cluster_snapshot: 文件仍存在"

# ============================================================
# 9. 二次快照——确保可重复采集
# ============================================================
echo ""
echo "--- 9. 二次快照（可重复性）---"

snap2=$(capture_cluster_snapshot 2>/dev/null)
[ -n "$snap2" ] && [ -f "$snap2" ] && ok "二次快照: 文件存在" || fail "二次快照: 失败"
remove_cluster_snapshot 2>/dev/null

# ============================================================
# 结果
# ============================================================
echo ""
echo "=========================================="
echo " 结果: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" = 0 ] && echo "全部通过" || echo "有失败项，检查上方输出"
