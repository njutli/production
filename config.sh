#!/bin/bash
# ============================================================
# Production Configuration (4 Machines, 3 TiKV + 3 PD + Ceph EC 4+2)
#
#   .11 (ceph-node1):  Ceph MON+MGR+2 OSD + TiKV + PD + RGW
#   .13 (ceph-node2):  同上
#   .14 (ceph-node3):  同上
#   .12 (tikv-node):   纯客户端（JuiceFS FUSE + fio）
#
# TiKV: 3 节点 3 副本（Raft majority=2），数据在 sdb LV3
# Ceph: 6 OSD（sdb 切 2 LV + tmpfs DB/WAL），EC 4+2，failure_domain=osd
# JuiceFS: --storage ceph 直连 RADOS（非 S3/RGW）
# SSH: sshpass 直连（无三层跳板）
# ============================================================

# --- SSH 配置 ---
SSH_USER="turboai"
SSH_PASSWORD="TurboAi@303"
SSH_KEY="${HOME}/.ssh/id_ed25519"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# --- 节点信息 ---
CLIENT_SERVER="192.168.11.12"

SLAVE_SERVERS=(
  "192.168.11.11"   # ceph-node1: Ceph + TiKV + PD
  "192.168.11.13"   # ceph-node2: 同上
  "192.168.11.14"   # ceph-node3: 同上
)

ALL_SERVERS=( "${CLIENT_SERVER}" "${SLAVE_SERVERS[@]}" )

# --- SSH 函数（sshpass 直连）---
_run() {
    local ip=$1; shift
    sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${ip}" "$*"
}
ssh_to_client() {
    sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" "$*"
}
ssh_to_slave() {
    local ip=$1; shift
    sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${ip}" "$*"
}
scp_to() {
    local src=$1 ip=$2 dest=$3
    sshpass -p "${SSH_PASSWORD}" scp ${SSH_OPTS} "$src" "${SSH_USER}@${ip}:${dest}"
}

# --- Ceph 配置（3 节点 × 2 OSD = 6 OSD，EC 4+2）---
CEPH_SERVERS=( "${SLAVE_SERVERS[@]}" )
CEPH_PRIMARY="${CEPH_SERVERS[0]}"     # = .11

# 管理网 IP → cephadm 主机名
declare -A CEPH_HOSTNAMES
CEPH_HOSTNAMES["192.168.11.11"]="ceph-node1"
CEPH_HOSTNAMES["192.168.11.13"]="ceph-node2"
CEPH_HOSTNAMES["192.168.11.14"]="ceph-node3"

CEPH_EC_K=4
CEPH_EC_M=2
CEPH_FAILURE_DOMAIN="osd"
CEPH_CONTAINER_IMAGE="quay.io/ceph/ceph:v17"
CEPH_POOL_NAME="juicefs-data"
CEPHX_CLIENT="client.juicefs"

# OSD 数据盘（每节点 sdb 切 2 LV + 1 TiKV LV）
CEPH_OSD_DEVICES=( "/dev/sdb" "/dev/sdb" "/dev/sdb" )

# DB/WAL on tmpfs
CEPH_DB_WAL_TMPFS=true
CEPH_DB_WAL_TMPFS_SIZE="20G"

# --- TiKV/PD 配置（3 节点 3 副本 Raft）---
TIKV_SERVERS=( "${SLAVE_SERVERS[@]}" )
TIKV_DATA_DIR="/mnt/tikv/tikv"
PD_DATA_DIR="/mnt/tikv/pd"
TIKV_VERSION="v7.1.5"
PD_VERSION="v7.1.5"
TIKV_MAX_REPLICAS=3

# PD 端点（逗号分隔，无 http:// 前缀，用于 JuiceFS tikv:// URL）
PD_ENDPOINTS=""
for ip in "${TIKV_SERVERS[@]}"; do
    [ -n "${PD_ENDPOINTS}" ] && PD_ENDPOINTS+=","
    PD_ENDPOINTS+="${ip}:2379"
done

# --- JuiceFS 客户端 ---
JUICEFS_CLIENT="${CLIENT_SERVER}"   # .12
JUICEFS_FS_NAME="${JUICEFS_FS_NAME:-juicefs-prod}"
JUICEFS_MOUNT_POINT="/mnt/juicefs"

# JuiceFS metadata URL (TiKV prefix = volume name)
JUICEFS_METADATA_URL="tikv://${PD_ENDPOINTS}/${JUICEFS_FS_NAME}"

# JuiceFS format options (Ceph RADOS 直连)
# --access-key = Ceph cluster name, --secret-key = Ceph client user name
JUICEFS_FORMAT_OPTS=(
    --storage ceph
    --bucket "ceph://${CEPH_POOL_NAME}"
    --access-key ceph
    --secret-key client.admin
    --block-size 256K
    --trash-days 0
)

# JuiceFS 挂载参数（直连 RADOS）
# mount 从元数据读取 storage/bucket/access-key/secret-key，无需重复指定
JUICEFS_BASE_MOUNT_OPTS=(
    --max-uploads 150
)
JUICEFS_MOUNT_OPTS=( "${JUICEFS_BASE_MOUNT_OPTS[@]}" --cache-size 0 )

# --- 二进制下载镜像 ---
TIKV_MIRROR="https://tiup-mirrors.pingcap.com"
