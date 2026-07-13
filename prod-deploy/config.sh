#!/bin/bash
# ============================================================
# JuiceFS + TiKV + Ceph 部署配置
#
# 环境：4 机集群（157 client + 150/151/152 storage）
#   157 (client):  WekaIO 业务在跑（红线），nvme1n1(894G) 供 JuiceFS cache
#   150 (slave1):  TiKV(PD) on nvme1n1 + 2 Ceph OSD on nvme2n1/nvme3n1
#   151 (slave2):  同上
#   152 (slave3):  同上
#
# 配置要点：
#   - TiKV 3 节点 3 副本（Raft majority=2）
#   - Ceph 6 物理盘 1 盘 1 OSD（不切 LV）
#   - DB/WAL on tmpfs 内存盘（nvme1n1 已给 TiKV，无剩余物理 NVMe）
#   - 100GbE 双网（public + cluster，已 MTU 4200）
#   - 限速走 eno12409（10GbE 独立网卡 + tc tbf 1Gbps）
#   - SSH 走三层跳板（WSL → HK ECS → 157 → slaves）
#
# 红线：
#   ✅ 可动：slave(150-152) 内核参数、Ceph/TiKV 应用层参数
#   ❌ 禁动：157 内核参数、100GbE 网卡/驱动/RoCE QoS、md0、WekaIO 路径
# ============================================================

# --- SSH / 跳板配置 ---
SSH_USER="sunrise"
SSH_PASSWORD="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# HK ECS 跳板机（WSL → HK → TH）
HK_ECS="190.92.233.189"
HK_ECS_USER="root"
HK_ECS_PASSWORD="Sunrise@801"

# --- 节点信息 ---
CLIENT_SERVER="10.20.1.157"
CLIENT_EXT="203.156.3.194"
CLIENT_PORT="19891"

SLAVE_SERVERS=(
  "10.20.1.150"  # slave1: TiKV + 2 Ceph OSD
  "10.20.1.151"  # slave2: 同上
  "10.20.1.152"  # slave3: 同上
)

ALL_SERVERS=( "${CLIENT_SERVER}" "${SLAVE_SERVERS[@]}" )

# --- SSH 函数（三层跳板）---

# ssh_to_client <command>
# WSL → HK ECS → 157
ssh_to_client() {
    local cmd="$1"
    local encoded
    encoded=$(echo -n "$cmd" | base64 -w0)
    sshpass -p "${HK_ECS_PASSWORD}" ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' 'echo ${encoded} | base64 -d | bash'"
}

# ssh_to_slave <ip> <command>
# WSL → HK ECS → 157 → slave
# 双层 base64 防引号在第二跳被剥离
ssh_to_slave() {
    local ip=$1 cmd="$2"
    local b64_slave b64_157 cmd_157
    b64_slave=$(echo -n "$cmd" | base64 -w0)
    cmd_157="sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T ${SSH_USER}@${ip} 'echo ${b64_slave} | base64 -d | bash'"
    b64_157=$(echo -n "$cmd_157" | base64 -w0)
    sshpass -p "${HK_ECS_PASSWORD}" ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' 'echo ${b64_157} | base64 -d | bash'"
}

# _run <ip> <command>  — 统一入口，按 IP 自动路由
_run() {
    local ip=$1; shift
    if [ "${ip}" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "$*"
    else
        ssh_to_slave "${ip}" "$*"
    fi
}

# scp_to <src_local> <dest_ip> <dest_path>
# 通过 base64 编码传文件内容（适合文本/脚本；大文件用远程 wget）
scp_to() {
    local src=$1 ip=$2 dest=$3
    local b64
    b64=$(base64 -w0 "$src")
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "echo '${b64}' | base64 -d > '${dest}'"
    else
        ssh_to_slave "$ip" "echo '${b64}' | base64 -d > '${dest}'"
    fi
}

# --- TiKV 配置（3 节点 3 副本，PD+TiKV 共置于 150-152）---
TIKV_SERVERS=( "${SLAVE_SERVERS[@]}" )
TIKV_DATA_DEVICE="/dev/nvme1n1"       # 每节点 894G ext4 NVMe
TIKV_MOUNT_POINT="/mnt/jfs-tikv"      # nvme1n1 挂载点
TIKV_DATA_DIR="/mnt/jfs-tikv/tikv"
PD_DATA_DIR="/mnt/jfs-tikv/pd"
TIKV_VERSION="v7.1.5"
PD_VERSION="v7.1.5"
TIKV_MAX_REPLICAS=3

# PD 端点（逗号分隔）
PD_ENDPOINTS=""
for ip in "${TIKV_SERVERS[@]}"; do
    [ -n "${PD_ENDPOINTS}" ] && PD_ENDPOINTS+=","
    PD_ENDPOINTS+="${ip}:2379"
done

# --- Ceph 配置（3 节点 × 2 盘 = 6 OSD，EC 4+2）---
CEPH_SERVERS=( "${SLAVE_SERVERS[@]}" )
CEPH_PRIMARY="${CEPH_SERVERS[0]}"     # bootstrap 节点 = 150

# 每节点 OSD 数据盘（所有节点相同设备名）
CEPH_OSD_DEVICES_PER_NODE=( "/dev/nvme2n1" "/dev/nvme3n1" )  # 2 × 7T NVMe

# DB/WAL on tmpfs（测试环境：不怕丢数据，可重建 OSD）
# 每节点 2 OSD，每个 OSD 需 1 个 DB + 1 个 WAL 文件 → 4 个文件/节点
# 用 loop device 包装 tmpfs 文件 → ceph-volume lvm create --block.db/--block.wal
# 节点重启 = tmpfs 清空 = OSD 死亡（可接受，重建即可）
CEPH_DB_WAL_TMPFS=true
CEPH_DB_WAL_MOUNT="/mnt/dbwal"
CEPH_DB_WAL_TMPFS_SIZE="200G"         # tmpfs 大小（200G；每节点 2 OSD × 50G = 100G，余量）
CEPH_DB_SIZE="40G"                    # 每个 OSD 的 RocksDB DB 大小
CEPH_WAL_SIZE="10G"                   # 每个 OSD 的 WAL 大小

# EC 池配置
CEPH_EC_K=4
CEPH_EC_M=2
CEPH_FAILURE_DOMAIN="osd"            # 3 节点 6 OSD，osd 级容错
CEPH_ALLOW_EC_OVERWRITES=true        # JuiceFS 整对象写不触发 RMW
CEPH_PG_NUM=32                     # 6 OSD 测试环境

# --- Ceph 网络（100GbE 双网，MTU 已 4200，不改）---
# public: 客户端 → OSD/MON 流量
# cluster: OSD 间 EC 取片/recovery 流量，独立 100GbE 端口
CEPH_PUBLIC_NETWORK="10.3.1.0/24"    # enp139s0f0np0
CEPH_CLUSTER_NETWORK="10.3.2.0/24"   # enp139s0f1np1
# MTU 不设——100GbE 已 4200（WekaIO 设），10GbE 是 1500（默认）
# 不通过 prepare-servers.sh 改 MTU（红线：不动 100GbE 网卡）
PUBLIC_NIC="enp139s0f0np0"
CLUSTER_NIC="enp139s0f1np1"

# --- 限速测试网络（eno12409 独立 10GbE 网卡）---
LIMIT_NIC="eno12409"
LIMIT_NETWORK="10.114.1.0/24"
LIMIT_RATE="1gbit"
LIMIT_BURST="32kb"
LIMIT_LATENCY="50ms"

# --- JuiceFS 客户端 ---
JUICEFS_CLIENT="${CLIENT_SERVER}"   # 157
JUICEFS_FS_NAME="juicefs-prod"
JUICEFS_MOUNT_POINT="/mnt/juicefs"

# JuiceFS cache 盘（157 的 nvme1n1，894G ext4）
JUICEFS_CACHE_DEV="/dev/nvme1n1"
JUICEFS_CACHE_MOUNT="/mnt/jfs-cache"
JUICEFS_CACHE_DIR="${JUICEFS_CACHE_MOUNT}"
JUICEFS_CACHE_SIZE_MB=0             # 0=冷态基线；暖态按需开（如 102400=100G）

# JuiceFS 挂载参数（分层：基线冷态 + 条件性暖态增强）
JUICEFS_BASE_MOUNT_OPTS=(
    --storage ceph                     # 08_1：直连 RADOS，随机写 +71%
    --bucket ceph://juicefs-data
    --access-key ceph
    --secret-key client.juicefs
    --block-size 256K                  # 08_2：消 16× 读放大
    --max-uploads 150                  # 演进报告 §四：顺序写 +23%
)

JUICEFS_ENABLE_WRITEBACK=false       # 突发写负载 + 缓存盘空间充足时置 true
JUICEFS_READAHEAD="default"          # "default" 或 "0"

# 组装最终挂载参数
_jfs_cache_args=( --cache-size 0 )
if [ "${JUICEFS_CACHE_SIZE_MB}" -gt 0 ] && [ -n "${JUICEFS_CACHE_DIR}" ]; then
    _jfs_cache_args=( --cache-size "${JUICEFS_CACHE_SIZE_MB}" --cache-dir "${JUICEFS_CACHE_DIR}" )
fi
[ "${JUICEFS_ENABLE_WRITEBACK}" = "true" ] && _jfs_cache_args+=( --writeback )
[ "${JUICEFS_READAHEAD}" = "0" ] && _jfs_cache_args+=( --max-readahead 0 )
JUICEFS_MOUNT_OPTS=( "${JUICEFS_BASE_MOUNT_OPTS[@]}" "${_jfs_cache_args[@]}" )

# --- JuiceFS metadata URL ---
JUICEFS_METADATA_URL="tikv://${PD_ENDPOINTS}/${JUICEFS_FS_NAME}"

# --- Ceph pool / cephx ---
CEPH_POOL_NAME="juicefs-data"
CEPHX_CLIENT="client.juicefs"

# 注：不部署 RGW、不需 LB。JuiceFS 用 --storage ceph 直连 RADOS（librados）。
# 数据路径为 JuiceFS → RADOS，跳过 RGW HTTP 层（依据 08_1：去 RGW 后随机写 +71%）。

# --- 二进制下载镜像 ---
TIKV_MIRROR="https://tiup-mirrors.pingcap.com"

# --- 安全红线（贯穿所有操作）---
# | 层级 | 可否动 | 原因 |
# |------|:---:|------|
# | slave(150-152) 内核参数 | ✅ | 无业务 |
# | Ceph/TiKV 应用层参数 | ✅ | 纯测试集群 |
# | eno12409 上的 tc tbf 限速 | ✅ | 独立 10GbE 网卡 |
# | 157 内核参数 | ❌ | WekaIO + K8s 在跑 |
# | 100GbE 网卡/驱动/RoCE QoS | ❌ | 与 WekaIO 物理共用 |
# | md0 / /mnt/data01-04 / /opt/weka | ❌ | WekaIO 业务路径 |
