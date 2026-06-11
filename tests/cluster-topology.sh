#!/bin/bash
# ============================================================
# 集群拓扑/数据分布快照（一次性，非实时）
#
# 用途：定位"某个节点网卡固定打满"是否源于 CRUSH/EC 把数据或 primary
# 角色结构性地倾斜到了该节点。这类分布是静态的（不加减 OSD、不改 CRUSH、
# 无大规模回填时基本不变），所以压测前/后各跑一次即可，无需高频采样。
#
# 在任一存活的 admin 节点上跑（能执行 ceph 命令即可）：
#   bash cluster-topology.sh
# 或从控制机经 cephadm shell：
#   sudo cephadm shell -- bash < cluster-topology.sh   （不便，建议拷到节点跑）
#
# 输出：各节点 OSD 的 PG/容量分布、primary PG 在各 OSD 的分布、
#       EC profile、CRUSH rule、池的副本/EC 配置 —— 看是否倾斜。
# ============================================================

# 选择可用的 ceph 调用方式（优先原生，避免 cephadm shell 的容器启动开销）
if command -v ceph >/dev/null 2>&1 && ceph -s >/dev/null 2>&1; then
    CEPH="ceph"
elif command -v ceph >/dev/null 2>&1 && sudo ceph -s >/dev/null 2>&1; then
    CEPH="sudo ceph"
elif command -v cephadm >/dev/null 2>&1; then
    CEPH="sudo cephadm shell -- ceph"   # 慢：每条命令起一次容器
else
    echo "ERROR: 本机既没有可用的 ceph 命令，也没有 cephadm。请在 ceph 节点上运行。"
    exit 1
fi

run() { timeout 60 $CEPH "$@" 2>/dev/null; }

echo "========================================================"
echo " 集群拓扑/数据分布快照  $(date '+%F %T')"
echo "========================================================"

echo
echo "===== 1. 健康 & OSD 概览 ====="
run -s | grep -E "health|osd:|pgs:"

echo
echo "===== 2. 各 OSD 的 PG 数 / 容量分布（osd df tree）====="
echo "   关注：各 host 下 OSD 的 PGS 列、USE/%USE 是否明显不均"
run osd df tree

echo
echo "===== 3. primary PG 在各 OSD 上的分布（谁当 primary 多，谁就承担更多协调/扇出）====="
echo "   primary OSD 要负责接收客户端写、做 EC 编码、向其他 OSD 扇出分片，"
echo "   primary 集中在某节点 → 该节点网卡/CPU 负载更高。"
# pg dump 里每个 PG 的 'up' 列第一个 OSD 即 primary（acting primary 用 up_primary）
run pg dump 2>/dev/null | awk '
  /^[0-9]+\.[0-9a-f]+/ {
    # 找 up_primary 字段：pg dump 文本里 acting_primary 在行尾附近，
    # 这里用更稳的方式：up 集合的第一个元素。列位置随版本变，故用正则取 [a,b,c] 后第一个数。
    if (match($0, /\[[0-9,]+\]/)) {
      s=substr($0, RSTART+1, RLENGTH-2); split(s, a, ","); pri=a[1];
      cnt[pri]++; total++
    }
  }
  END{
    if (total==0){ print "  (未解析到 PG，可能 pg dump 格式不同，见下方原始 up 列)"; }
    else {
      print "  primary PG 计数（按 osd.id）："
      for (o in cnt) printf "    osd.%s : %d primary PG (%.1f%%)\n", o, cnt[o], cnt[o]*100/total | "sort -t. -k2 -n"
    }
  }'

echo
echo "===== 4. PG 在各 OSD 的整体分布（up 集合，含非 primary）====="
echo "   看每个 OSD 总共参与多少 PG（osd df tree 的 PGS 列已给出，这里复核）"
run osd df 2>/dev/null | awk 'NR==1||/^[ ]*[0-9]/{print}' | awk '{print $1, $2, $(NF-1), $NF}' 2>/dev/null | head -20

echo
echo "===== 5. EC profile & 池配置（k/m、failure-domain、crush rule）====="
run osd erasure-code-profile ls 2>/dev/null | while read p; do
  echo "--- profile: $p ---"; run osd erasure-code-profile get "$p"
done
echo "--- 池详情（size/min_size/crush_rule/ec profile）---"
run osd pool ls detail 2>/dev/null | grep -E "pool|erasure|crush_rule" | head -30

echo
echo "===== 6. CRUSH rule（数据如何映射到 host/osd）====="
run osd crush rule ls 2>/dev/null
run osd crush rule dump 2>/dev/null | grep -E '"rule_name"|"type"|"op"|"item_name"' | head -40

echo
echo "===== 7. 各 host 的 OSD 归属（确认 3 host × 2 OSD）====="
run osd tree

echo
echo "========================================================"
echo " 判读提示："
echo "  - 若 primary PG 明显集中在某 host 的 OSD（如 node1 的 osd.0/1 占比偏高），"
echo "    该 host 作为 EC 写的协调者+扇出者，网卡会固定偏高 → 可调 primary 均衡"
echo "    （ceph osd primary-affinity / balancer）。"
echo "  - 若各 OSD 的 PGS、primary 数都均匀，则 node1 网卡偏高另有原因"
echo "    （如客户端/LB 拓扑、单链路质量），需结合 node-monitor 的 rx/tx 分方向看。"
echo "========================================================"
