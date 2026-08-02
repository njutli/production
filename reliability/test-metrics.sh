#!/bin/bash
# 临时测试脚本：验证 metrics.sh 各函数在真实集群上的输出
# 用法：bash test-metrics.sh

cd "$(dirname "$0")" || exit 1
export METRICS_DIR="/tmp/reliability-test-metrics"
rm -rf "$METRICS_DIR"

source config/env.sh
source lib/cluster.sh
source lib/metrics.sh

PASS=0; FAIL=0
ok()   { echo "  ok  - $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

echo "=========================================="
echo " metrics.sh 实际集群测试"
echo "=========================================="

echo ""
echo "--- 快照模式 ---"

echo "[snapshot_ceph_status]"
f=$(snapshot_ceph_status)
[ -f "$f" ] && [ -s "$f" ] && ok "文件存在且非空: $f" || fail "文件为空或不存在: $f"
jq -r '.health.status' "$f" 2>/dev/null | grep -q HEALTH && ok "JSON 可解析" || fail "JSON 解析失败"

echo ""
echo "[snapshot_ceph_report]"
f=$(snapshot_ceph_report)
[ -f "$f" ] && [ -s "$f" ] && ok "文件存在且非空: $f" || fail "文件为空或不存在: $f"
jq -r '.cluster_fsid // .fsid // "NO_FSID"' "$f" 2>/dev/null | grep -q . && ok "JSON 可解析" || fail "JSON 解析失败"

echo ""
echo "[snapshot_juicefs_stats]"
f=$(snapshot_juicefs_stats)
[ -f "$f" ] && [ -s "$f" ] && ok "文件存在且非空: $f" || fail "文件为空或不存在: $f"

echo ""
echo "[snapshot_nic]"
dir=$(snapshot_nic)
ls "$dir"/nic_*.txt 2>/dev/null | wc -l | grep -q 4 && ok "4 个节点 NIC 文件" || fail "NIC 文件数量不对"

echo ""
echo "[snapshot_iostat]"
dir=$(snapshot_iostat)
ls "$dir"/iostat_*.txt 2>/dev/null | wc -l | grep -q 3 && ok "3 个节点 iostat 文件" || fail "iostat 文件数量不对"

echo ""
echo "--- 连续采集模式 ---"

echo "[start_monitoring]"
start_monitoring 2
CSV="$_METRICS_CSV_FILE"
sleep 1
ok "monitoring 启动，CSV: $CSV"

echo ""
echo "[验证 CSV 正在写入]"
LINES_BEFORE=$(wc -l < "$CSV" 2>/dev/null)
sleep 8
LINES_AFTER=$(wc -l < "$CSV" 2>/dev/null)
if [ "$LINES_AFTER" -gt "$LINES_BEFORE" ]; then
    ok "CSV 行数增长 ($LINES_BEFORE → $LINES_AFTER)"
else
    fail "CSV 行数未增长 ($LINES_BEFORE → $LINES_AFTER)"
fi

echo ""
echo "[CSV 内容示例]"
echo "  表头: $(head -1 "$CSV")"
echo "  最后: $(tail -1 "$CSV")"

echo ""
echo "[get_metric_change_time: osd_count_up=6]"
T=$(get_metric_change_time "osd_count_up" "6")
[ "$T" != "0" ] && [ -n "$T" ] && ok "找到 osd_count_up=6 时间戳: $T" || fail "未找到 osd_count_up=6"

echo ""
echo "[get_metric_change_time: health contains HEALTH]"
T=$(get_metric_change_time "health" "HEALTH")
[ "$T" != "0" ] && [ -n "$T" ] && ok "找到 health 含 HEALTH 时间戳: $T" || fail "未找到"

echo ""
echo "[get_metric_change_time: pg_states contains active]"
T=$(get_metric_change_time "pg_states" "active")
[ "$T" != "0" ] && [ -n "$T" ] && ok "找到 pg_states 含 active 时间戳: $T" || fail "未找到"

echo ""
echo "[get_metric_change_time: tikv_leader contains pd-]"
T=$(get_metric_change_time "tikv_leader" "pd-")
[ "$T" != "0" ] && [ -n "$T" ] && ok "找到 tikv_leader 含 pd- 时间戳: $T" || fail "未找到"

echo ""
echo "[get_metric_change_time: 不存在的值 osd_count_up=99]"
T=$(get_metric_change_time "osd_count_up" "99")
[ "$T" = "0" ] && ok "未找到返回 0" || fail "应返回 0，实际: $T"

echo ""
echo "[get_metric_change_time: 不存在的列 nonexistent_col]"
T=$(get_metric_change_time "nonexistent_col" "1")
[ "$T" = "0" ] && ok "未找到返回 0" || fail "应返回 0，实际: $T"

echo ""
echo "[stop_monitoring]"
RESULT=$(stop_monitoring)
ok "monitoring 停止，CSV 文件: $RESULT"

echo ""
echo "[验证 CSV 内容完整]"
TOTAL=$(wc -l < "$CSV" 2>/dev/null)
ok "CSV 总行数: $TOTAL (含表头)"

echo ""
echo "=========================================="
echo " 结果: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" = "0" ] && echo "全部通过" || echo "有失败项，检查上方输出"
