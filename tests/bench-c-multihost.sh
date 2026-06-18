#!/bin/bash
# ============================================================
# Multi-host C test — 256K block-size volume, clients on different physical machines
# (08_2 第四节 C 实验的跨物理机版本)
#
# 之前的 C 是同一台机器起 2 个挂载点(CPU/网卡共享)，无法区分「单机资源」与「Ceph 后端」。
# 本脚本把第二个客户端放到另一台物理机(ceph-node1)，并在测试全程采集各节点网卡 RX/TX，
# 用于回答：
#   1) 跨物理机加客户端，聚合随机读带宽是否提升(>1×)？
#   2) ceph-node 作 JuiceFS 客户端时，其网卡同时承载 OSD 流量 + 客户端读流量，
#      RX/TX 是否互相抢占千兆带宽(用户关注点)？
#
# 卷：256K block-size、ceph 直连 RADOS(juicefs-data 池)，与生产解一致。
# 口径：randread bs=256k iodepth=128 numjobs=32 direct=1 --cache-size 0 冷态(与原 C 同口径)。
#
# 客户端：
#   C1 = tikv-node (192.168.11.12) 本机 —— 干净客户端(网卡只跑客户端流量)
#   C2 = ceph-node1 (192.168.11.11) 远程 —— OSD 主机(网卡同时跑 OSD + 客户端，被争用)
#
# 阶段：
#   Phase1 单客户端基线：仅 C1 跑 randread
#   Phase2 双客户端聚合：C1 + C2 同时跑 randread
# 两阶段都在所有节点采集网卡。
#
# 用法: bash tests/bench-c-multihost.sh [label]
# env: LAYOUT_NUMJOBS(默认32) RUNTIME(默认60)
# 注意：本脚本应由 run-c-multihost-master.sh 用 setsid 后台串行启动。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "${SCRIPT_DIR}")"
source "${PROD_DIR}/config.sh"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

LABEL="${1:-c-multihost-256k}"
LAYOUT_NUMJOBS="${LAYOUT_NUMJOBS:-32}"
LAYOUT_FILESIZE="1G"
RUNTIME="${RUNTIME:-60}"
BLOCK_SIZE="256K"

TIKV_IP="192.168.11.12"
NODE1_IP="192.168.11.11"
NODE2_IP="192.168.11.13"
NODE3_IP="192.168.11.14"
NIC="eno1"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"

CEPH_POOL="${CEPH_POOL:-juicefs-data}"
METADATA_URL="tikv://${PD_ENDPOINTS}/${JUICEFS_FS_NAME}"
BUCKET_URL="ceph://${CEPH_POOL}"

MP="/mnt/juicefs"
RES_DIR="${PROD_DIR}/results"
TS=$(date +%Y%m%d-%H%M%S)
OUT="${RES_DIR}/c-multihost-${LABEL}-${TS}.txt"
mkdir -p "${RES_DIR}"
log() { echo "$@" | tee -a "${OUT}"; }

# ---- NIC counters via /proc/net/dev (portable, no extra tools) ----
# Read cumulative RX/TX bytes for $NIC on a host. host="" = local.
nic_bytes() {  # $1=host (ip or empty for local) -> "rxBytes txBytes"
    local host="$1"
    local cmd="awk -v n=${NIC} '\$1 ~ n\":\" {gsub(/:/,\" \"); print \$2, \$10}' /proc/net/dev"
    if [ -z "${host}" ]; then bash -c "${cmd}"; else ${SSH} "turboai@${host}" "${cmd}"; fi
}
# Sample NIC over the test window: snapshot start, sleep RUNTIME, snapshot end,
# print avg MB/s RX and TX. Runs in background per node.
nic_sample() {  # $1=host  $2=tag  $3=seconds
    local host="$1" tag="$2" secs="$3"
    local s e srx stx erx etx
    s=$(nic_bytes "${host}"); srx=${s% *}; stx=${s#* }
    sleep "${secs}"
    e=$(nic_bytes "${host}"); erx=${e% *}; etx=${e#* }
    local rxmb txmb
    rxmb=$(awk "BEGIN{printf \"%.1f\", (${erx}-${srx})/1048576/${secs}}")
    txmb=$(awk "BEGIN{printf \"%.1f\", (${etx}-${stx})/1048576/${secs}}")
    echo "NIC[${tag}] ${host:-tikv-node} ${NIC}: RX=${rxmb} MB/s TX=${txmb} MB/s (over ${secs}s)" >> "${OUT}.nic.${tag}"
}

# ---- volume lifecycle (run from tikv-node) ----
umount_local() { mountpoint -q "${MP}" 2>/dev/null && { fusermount -uz "${MP}" 2>/dev/null || sudo umount -l "${MP}" 2>/dev/null; }; }
umount_remote() { ${SSH} "turboai@${NODE1_IP}" "mountpoint -q ${MP} && (fusermount -uz ${MP} 2>/dev/null || sudo umount -l ${MP} 2>/dev/null) || true"; }

destroy_vol() {
    umount_local; umount_remote; sleep 65
    local uuid
    uuid=$(juicefs status "${METADATA_URL}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
    [ -n "${uuid}" ] && juicefs destroy "${METADATA_URL}" "${uuid}" --yes 2>&1 | tail -2 | tee -a "${OUT}"
}

format_vol() {
    log ">>> Formatting 256K ceph-direct volume (block-size=${BLOCK_SIZE}, pool=${CEPH_POOL})..."
    unset ACCESS_KEY SECRET_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
    juicefs format --storage ceph --bucket "${BUCKET_URL}" \
        --access-key ceph --secret-key client.juicefs \
        --block-size 256 --trash-days 0 \
        "${METADATA_URL}" "${JUICEFS_FS_NAME}" 2>&1 | tail -4 | tee -a "${OUT}"
}

mount_local() {
    sudo mkdir -p "${MP}"; sudo chown "$(whoami):$(whoami)" "${MP}" 2>/dev/null || true
    juicefs mount -d --cache-size 0 "${METADATA_URL}" "${MP}" 2>&1 | tail -2 | tee -a "${OUT}"
    sleep 3; mountpoint -q "${MP}" || { log "FATAL: local mount failed"; return 1; }
    log ">>> local (tikv-node) mounted."
}
mount_remote() {
    ${SSH} "turboai@${NODE1_IP}" "sudo mkdir -p ${MP} && sudo chown turboai:turboai ${MP} 2>/dev/null; \
        juicefs mount -d --cache-size 0 ${METADATA_URL} ${MP} >/tmp/jfs-mount.log 2>&1; sleep 3; \
        mountpoint -q ${MP} && echo REMOTE_MOUNT_OK || (echo REMOTE_MOUNT_FAIL; tail -5 /tmp/jfs-mount.log)" \
        2>&1 | tee -a "${OUT}" | grep -q REMOTE_MOUNT_OK || { log "FATAL: remote mount on node1 failed"; return 1; }
    log ">>> remote (ceph-node1) mounted."
}

drop_caches_local() {
    sync 2>/dev/null || true; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    for d in /var/jfsCache "${HOME}/.juicefs/cache"; do [ -d "${d}" ] && find "${d}" -type f -path '*raw*' -delete 2>/dev/null || true; done
}
drop_caches_remote() {
    ${SSH} "turboai@${NODE1_IP}" 'sync; sudo sh -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null || true; \
        for d in /var/jfsCache $HOME/.juicefs/cache; do [ -d "$d" ] && find "$d" -type f -path "*raw*" -delete 2>/dev/null || true; done; true'
}

layout() {
    mkdir -p "${MP}/test_dir"
    log ">>> Layout from tikv-node: ${LAYOUT_NUMJOBS} jobs x ${LAYOUT_FILESIZE} (256K block) ..."
    fio --directory="${MP}/test_dir" --name=storage_test \
        --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=4M \
        --rw=write --numjobs="${LAYOUT_NUMJOBS}" --fallocate=none \
        --group_reporting --end_fsync=1 2>&1 | grep -E "WRITE:|err=" | tee -a "${OUT}"
}

# fio randread on local (tikv) ; output -> file
randread_local() { # $1=outfile
    fio --directory="${MP}/test_dir" --name=storage_test \
        --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=256k \
        --rw=randread --ioengine=libaio --iodepth=128 --numjobs="${LAYOUT_NUMJOBS}" \
        --direct=1 --fallocate=none --group_reporting --time_based --runtime="${RUNTIME}s" > "$1" 2>&1
}
# fio randread on node1 (remote); output written remotely then fetched
randread_remote() { # $1=local-outfile
    ${SSH} "turboai@${NODE1_IP}" "fio --directory=${MP}/test_dir --name=storage_test \
        --filesize=${LAYOUT_FILESIZE} --size=${LAYOUT_FILESIZE} --bs=256k \
        --rw=randread --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_NUMJOBS} \
        --direct=1 --fallocate=none --group_reporting --time_based --runtime=${RUNTIME}s" > "$1" 2>&1
}

bw_of() { grep -E "READ: bw=" "$1" | head -1 | sed 's/^[[:space:]]*//'; }

# sample NIC on reachable nodes for a phase, in background; sets PIDS
# node3 (.14) SSH is not reachable from tikv-node (key not authorized) → not sampled.
start_nic_all() { # $1=tag $2=secs
    local tag="$1" secs="$2"
    : > "${OUT}.nic.${tag}"
    nic_sample ""            "${tag}" "${secs}" & NP1=$!
    nic_sample "${NODE1_IP}" "${tag}" "${secs}" & NP2=$!
    nic_sample "${NODE2_IP}" "${tag}" "${secs}" & NP3=$!
}
wait_nic_all() { wait ${NP1} ${NP2} ${NP3} 2>/dev/null || true; sort "${OUT}.nic.$1" | tee -a "${OUT}"; }

# ============================================================
log "============================================================"
log "Multi-host C test — 256K block-size, cross-machine clients"
log "Date: $(date)  layout=${LAYOUT_NUMJOBS}x${LAYOUT_FILESIZE}  runtime=${RUNTIME}s"
log "C1=tikv-node(${TIKV_IP})  C2=ceph-node1(${NODE1_IP})  pool=${CEPH_POOL}  block-size=${BLOCK_SIZE}"
log "NIC monitored: tikv-node, ceph-node1, ceph-node2 (node3/.14 SSH unreachable — not sampled)"
log "============================================================"

umount_local; umount_remote; sleep 2
destroy_vol 2>/dev/null || true
format_vol
mount_local || exit 1
layout

# ------------------------------------------------------------
# Phase 1: single-client baseline (tikv only)
# ------------------------------------------------------------
log ""
log "########## Phase 1: SINGLE client (tikv-node only) ##########"
drop_caches_local
start_nic_all "p1" "${RUNTIME}"
randread_local "${RES_DIR}/c-mh-${LABEL}-p1-tikv.txt"
P1_BW=$(bw_of "${RES_DIR}/c-mh-${LABEL}-p1-tikv.txt")
log "P1 tikv-node randread: ${P1_BW}"
wait_nic_all "p1"

# ------------------------------------------------------------
# Phase 2: two clients aggregate (tikv + ceph-node1) simultaneously
# ------------------------------------------------------------
log ""
log "########## Phase 2: TWO clients (tikv-node + ceph-node1) ##########"
mount_remote || exit 1
drop_caches_local; drop_caches_remote
start_nic_all "p2" "${RUNTIME}"
randread_local  "${RES_DIR}/c-mh-${LABEL}-p2-tikv.txt"  &  L=$!
randread_remote "${RES_DIR}/c-mh-${LABEL}-p2-node1.txt" &  R=$!
wait "${L}" "${R}"
P2_TIKV=$(bw_of "${RES_DIR}/c-mh-${LABEL}-p2-tikv.txt")
P2_NODE1=$(bw_of "${RES_DIR}/c-mh-${LABEL}-p2-node1.txt")
log "P2 tikv-node randread:  ${P2_TIKV}"
log "P2 ceph-node1 randread: ${P2_NODE1}"
wait_nic_all "p2"

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
log ""
log ">>> cleanup: unmount both + destroy volume"
destroy_vol
log ""
log "============================================================"
log "SUMMARY (256K block-size, randread bs=256k cache=0)"
log "  Phase1 single  (tikv)        : ${P1_BW}"
log "  Phase2 tikv                  : ${P2_TIKV}"
log "  Phase2 ceph-node1            : ${P2_NODE1}"
log "  NIC samples: ${OUT}.nic.p1 / ${OUT}.nic.p2 (RX/TX per node)"
log "============================================================"
log "DONE  results: ${OUT}"
echo "=== C-MULTIHOST DONE exit=0 ==="
