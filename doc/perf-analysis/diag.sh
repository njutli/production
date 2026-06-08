#!/bin/bash
# ============================================================
# 性能瓶颈逐层排查脚本（自底向上隔离）
#
# 用法：bash diag.sh            # 在 tikv-node（JuiceFS 客户端机）上运行
#
# 思路：先量化硬件上限，再定位瓶颈在哪一层。
#   1. 裸盘  2. 网络  3. Ceph 后端  4. 端到端 JuiceFS
# 不要直接套用通用调优清单——先看数据。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# config.sh 在 production/ 根目录
CONFIG="${SCRIPT_DIR}/../../config.sh"
[ -f "${CONFIG}" ] && source "${CONFIG}"

CEPH1="${CEPH_SERVERS[0]:-192.168.11.11}"
CEPH2="${CEPH_SERVERS[1]:-192.168.11.13}"
CEPH3="${CEPH_SERVERS[2]:-192.168.11.14}"
SSH_USER="${SSH_USER:-turboai}"

hr() { echo "============================================================"; }

hr; echo "1. 网卡协商速率（每个节点）"; hr
for ip in "${CEPH1}" "${CEPH2}" "${CEPH3}"; do
    echo "--- ${ip} ---"
    ssh "${SSH_USER}@${ip}" 'nic=$(ip -o -4 route show to default | awk "{print \$5}"); sudo ethtool $nic | grep -i speed' 2>/dev/null
done
echo "--- local (tikv/client) ---"
nic=$(ip -o -4 route show to default | awk '{print $5}'); sudo ethtool "$nic" 2>/dev/null | grep -i speed

hr; echo "2. OSD 盘类型"; hr
ssh "${SSH_USER}@${CEPH1}" 'sudo cephadm shell -- ceph osd metadata 2>/dev/null | grep -E "\"id\"|bluestore_bdev_type"' 2>/dev/null

hr; echo "3. 节点间实测带宽（iperf3，需先在目标启 iperf3 -s）"; hr
echo "  在 ${CEPH1} 运行: iperf3 -s"
echo "  然后本机运行:  iperf3 -c ${CEPH1} -t 15"
echo "  （本脚本不自动起服务端，避免端口冲突，请手动执行）"

hr; echo "4. Ceph 后端直压（rados bench，绕过 JuiceFS）"; hr
echo ">>> 写测试 30s, 64 并发..."
ssh "${SSH_USER}@${CEPH1}" 'sudo cephadm shell -- rados bench -p default.rgw.buckets.data 30 write -t 64 --no-cleanup 2>/dev/null | tail -15' 2>/dev/null
echo ">>> 读测试 30s, 64 并发..."
ssh "${SSH_USER}@${CEPH1}" 'sudo cephadm shell -- rados bench -p default.rgw.buckets.data 30 rand -t 64 2>/dev/null | tail -10' 2>/dev/null
echo ">>> 清理 bench 对象..."
ssh "${SSH_USER}@${CEPH1}" 'sudo cephadm shell -- rados -p default.rgw.buckets.data cleanup 2>/dev/null' 2>/dev/null || true

hr; echo "5. Ceph 集群状态"; hr
ssh "${SSH_USER}@${CEPH1}" 'sudo cephadm shell -- ceph status 2>/dev/null; echo; sudo cephadm shell -- ceph osd pool ls detail 2>/dev/null' 2>/dev/null

hr
echo "排查完成。解读："
echo "  - 任一网卡 < 1000Mb/s → 先修网络，其余免谈"
echo "  - rados bench 远低于 (最慢网卡线速 × k/(k+m)) → 后端/网络瓶颈"
echo "  - 裸盘 fio 远高于 rados bench → 瓶颈在网络或 EC 编排，不在磁盘"
echo "详见 doc/perf-analysis/02-bottleneck-analysis.md"
