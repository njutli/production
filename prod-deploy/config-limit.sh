#!/bin/bash
# ============================================================
# JuiceFS + TiKV + Ceph 部署配置（千兆限速口径）
#
# 与 config.sh 的唯一区别：Ceph 网络全部走 eno12409（10.114.1.0/24）
# MON bootstrap 时绑在 10.114.1.x，OSD 也在 10.114.1.x
# TBF 1Gbps 在部署前已 apply 到 eno12409 上
#
# 用法：CONFIG_FILE=config-limit.sh bash scripts/deploy-ceph.sh --yes
# ============================================================

# --- SSH / 跳板配置 ---（与 config.sh 相同）
SSH_USER="sunrise"
SSH_PASSWORD="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

HK_ECS="190.92.233.189"
HK_ECS_USER="root"
HK_ECS_PASSWORD="Sunrise@801"

# --- 节点信息 ---（与 config.sh 相同，SSH 走管理网）
CLIENT_SERVER="10.20.1.157"
CLIENT_EXT="203.156.3.194"
CLIENT_PORT="19891"

SLAVE_SERVERS=(
  "10.20.1.150"
  "10.20.1.151"
  "10.20.1.152"
)

ALL_SERVERS=( "${CLIENT_SERVER}" "${SLAVE_SERVERS[@]}" )

# --- SSH 函数（三层跳板）--- 与 config.sh 完全相同
ssh_to_client() {
    local cmd="$1"
    local encoded
    encoded=$(echo -n "$cmd" | base64 -w0)
    sshpass -p "${HK_ECS_PASSWORD}" ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' 'echo ${encoded} | base64 -d | bash'"
}

ssh_to_slave() {
    local ip=$1 cmd="$2"
    local b64_slave b64_157 cmd_157
    b64_slave=$(echo -n "$cmd" | base64 -w0)
    cmd_157="sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T ${SSH_USER}@${ip} 'echo ${b64_slave} | base64 -d | bash'"
    b64_157=$(echo -n "$cmd_157" | base64 -w0)
    sshpass -p "${HK_ECS_PASSWORD}" ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' 'echo ${b64_157} | base64 -d | bash'"
}

_run() {
    local ip=$1; shift
    if [ "${ip}" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "$*"
    else
        ssh_to_slave "${ip}" "$*"
    fi
}

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

# --- TiKV 配置 ---（与 config.sh 相同，TiKV 不受 Ceph 网络影响）
TIKV_SERVERS=( "${SLAVE_SERVERS[@]}" )
TIKV_DATA_DEVICE="/dev/nvme1n1"
TIKV_MOUNT_POINT="/mnt/jfs-tikv"
TIKV_DATA_DIR="/mnt/jfs-tikv/tikv"
PD_DATA_DIR="/mnt/jfs-tikv/pd"
TIKV_VERSION="v7.1.5"
PD_VERSION="v7.1.5"
TIKV_MAX_REPLICAS=3

PD_ENDPOINTS=""
for ip in "${TIKV_SERVERS[@]}"; do
    [ -n "${PD_ENDPOINTS}" ] && PD_ENDPOINTS+=","
    PD_ENDPOINTS+="${ip}:2379"
done

# --- Ceph 配置 --- 与 config.sh 的关键差异在此 ---
CEPH_SERVERS=( "${SLAVE_SERVERS[@]}" )
CEPH_PRIMARY="${CEPH_SERVERS[0]}"     # 150（管理网 IP，用于 SSH）

# MON 绑在 eno12409（10.114.1.x）—— 限速口径
declare -A CEPH_MON_IPS
CEPH_MON_IPS["10.20.1.150"]="10.114.1.150"
CEPH_MON_IPS["10.20.1.151"]="10.114.1.151"
CEPH_MON_IPS["10.20.1.152"]="10.114.1.152"
CEPH_PRIMARY_MON_IP="${CEPH_MON_IPS[${CEPH_PRIMARY}]}"  # 10.114.1.150

declare -A CEPH_HOSTNAMES
CEPH_HOSTNAMES["10.20.1.150"]="ceph-node1"
CEPH_HOSTNAMES["10.20.1.151"]="ceph-node2"
CEPH_HOSTNAMES["10.20.1.152"]="ceph-node3"

CEPH_OSD_DEVICES_PER_NODE=( "/dev/nvme2n1" "/dev/nvme3n1" )

# DB/WAL on tmpfs（与 config.sh 相同）
CEPH_DB_WAL_TMPFS=true
CEPH_DB_WAL_MOUNT="/mnt/dbwal"
CEPH_DB_WAL_TMPFS_SIZE="200G"
CEPH_DB_SIZE="40G"
CEPH_WAL_SIZE="10G"

# EC 池配置（与 config.sh 相同）
CEPH_EC_K=4
CEPH_EC_M=2
CEPH_FAILURE_DOMAIN="osd"
CEPH_ALLOW_EC_OVERWRITES=true
CEPH_PG_NUM=32

# --- Ceph 网络（限速口径：全部走 eno12409）---
CEPH_PUBLIC_NETWORK="10.114.1.0/24"
CEPH_CLUSTER_NETWORK="10.114.1.0/24"
PUBLIC_NIC="eno12409"
CLUSTER_NIC="eno12409"

# --- 限速参数 ---
LIMIT_NIC="eno12409"
LIMIT_NETWORK="10.114.1.0/24"
LIMIT_RATE="1gbit"
LIMIT_BURST="32kb"
LIMIT_LATENCY="50ms"

# --- JuiceFS 客户端 ---（与 config.sh 相同）
JUICEFS_CLIENT="${CLIENT_SERVER}"
JUICEFS_FS_NAME="juicefs-prod"
JUICEFS_MOUNT_POINT="/mnt/juicefs"

JUICEFS_CACHE_DEV="/dev/nvme1n1"
JUICEFS_CACHE_MOUNT="/mnt/jfs-cache"
JUICEFS_CACHE_DIR="${JUICEFS_CACHE_MOUNT}"
JUICEFS_CACHE_SIZE_MB=0

JUICEFS_BASE_MOUNT_OPTS=(
    --storage ceph
    --bucket ceph://juicefs-data
    --block-size 256K
    --max-uploads 150
)

JUICEFS_ENABLE_WRITEBACK=false
JUICEFS_READAHEAD="default"

_jfs_cache_args=( --cache-size 0 )
if [ "${JUICEFS_CACHE_SIZE_MB}" -gt 0 ] && [ -n "${JUICEFS_CACHE_DIR}" ]; then
    _jfs_cache_args=( --cache-size "${JUICEFS_CACHE_SIZE_MB}" --cache-dir "${JUICEFS_CACHE_DIR}" )
fi
[ "${JUICEFS_ENABLE_WRITEBACK}" = "true" ] && _jfs_cache_args+=( --writeback )
[ "${JUICEFS_READAHEAD}" = "0" ] && _jfs_cache_args+=( --max-readahead 0 )
JUICEFS_MOUNT_OPTS=( "${JUICEFS_BASE_MOUNT_OPTS[@]}" "${_jfs_cache_args[@]}" )

JUICEFS_METADATA_URL="tikv://${PD_ENDPOINTS}/${JUICEFS_FS_NAME}"

CEPH_POOL_NAME="juicefs-data"
CEPHX_CLIENT="client.juicefs"

TIKV_MIRROR="https://tiup-mirrors.pingcap.com"
