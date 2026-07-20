#!/bin/bash
set -euo pipefail

# ============================================================
# Ceph 带宽限速脚本 — 千兆网卡环境模拟
#
# 策略：
#   不限速（默认）：Ceph public=10.3.1.0/24, cluster=10.3.2.0/24（100GbE）
#   千兆限速：     Ceph public+cluster=10.114.1.0/24（eno12409）+ TBF 1Gbps
#
# 切换方式：
#   1. ceph config set global public_network / cluster_network
#   2. 逐个迁移 MON（mon rm + orch daemon add mon <host>:<新IP>），始终保 quorum
#      —— MON 的 IP 固死在 monmap 里，config 改了不会跟着走，必须显式迁移，
#         否则集群 HEALTH_ERR "osds not reachable"（见 doc 限速 MON 迁移问题）
#   3. 重启所有 OSD（重新绑定新网络）
#   4. eno12409 上 tc tbf 1Gbps（限速模式）
#   5. 更新 157 上 /etc/ceph/ceph.conf 的 mon_host
#
# 红线：不在 100GbE RDMA 网卡上做任何限速/QoS（与 WekaIO 共用）
#
# 用法: bash limit-bandwidth.sh [apply|remove|status]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

PRIMARY="${CEPH_PRIMARY}"

LIMIT_IFACE="${LIMIT_NIC}"        # eno12409
LIMIT_NET="${LIMIT_NETWORK}"       # 10.114.1.0/24
RATE="${LIMIT_RATE}"               # 1gbit
BURST="${LIMIT_BURST}"             # 32kb
LATENCY="${LIMIT_LATENCY}"        # 50ms

PUBLIC_NET="${CEPH_PUBLIC_NETWORK}"     # 10.3.1.0/24
CLUSTER_NET="${CEPH_CLUSTER_NETWORK}"   # 10.3.2.0/24

_run_ceph() {
    _run "${PRIMARY}" "sudo cephadm shell -- ceph $* 2>/dev/null"
}

update_157_ceph_conf() {
    local mon_ips="$1"
    echo "  Updating ceph.conf on ${CLIENT_SERVER} (mon_host=${mon_ips})..."
    local fsid
    fsid=$(_run "${PRIMARY}" "grep '^fsid' /etc/ceph/ceph.conf | awk '{print \$3}'" 2>/dev/null)
    local conf_content="[global]
fsid = ${fsid}
mon_host = ${mon_ips}
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx, none"
    local conf_b64
    conf_b64=$(echo "${conf_content}" | base64 -w0)
    ssh_to_client "echo '${conf_b64}' | base64 -d | sudo tee /etc/ceph/ceph.conf > /dev/null && echo '  ceph.conf updated on 157'" 2>/dev/null \
        || echo "  WARNING: ceph.conf update failed — update manually"
}

restart_osds() {
    echo "  Restarting OSDs (rebind to new public/cluster network)..."
    _run_ceph "orch restart osd" 2>/dev/null || true
    echo "  Waiting for OSDs to stabilize (30s)..."
    sleep 30
}

# 等待 MON quorum 恢复到 expect 个成员（最多 wait_max 秒）
wait_mon_quorum() {
    local expect="${1:-3}"
    local wait_max="${2:-120}"
    local waited=0
    while [ "${waited}" -lt "${wait_max}" ]; do
        # mon_status 里 quorum 是索引数组，如 "quorum":[0,1,2]
        local qs n
        qs=$(_run_ceph "quorum_status --format json" 2>/dev/null \
             | grep -oP '"quorum":\[[^]]*\]' || echo '"quorum":[]')
        n=$(echo "${qs}" | grep -oP '[0-9]+' | wc -l)
        if [ "${n}" -ge "${expect}" ]; then
            echo "    quorum OK (${n}/${expect})"
            return 0
        fi
        sleep 5
        waited=$(( waited + 5 ))
    done
    echo "    WARNING: quorum 未在 ${wait_max}s 内恢复到 ${expect} 成员（当前 ${n:-?}）"
    return 1
}

# 逐个把 MON 从旧 IP 迁到新 IP（cephadm）：始终保 quorum
# $1 = 关联数组名（管理网IP → 目标MON IP），如 CEPH_MON_LIMIT_IPS / CEPH_MON_IPS
migrate_mons() {
    local -n target_map="$1"
    echo "  Migrating MONs one at a time (keep quorum)..."
    for ip in "${CEPH_SERVERS[@]}"; do
        local host="${CEPH_HOSTNAMES[${ip}]}"
        local newip="${target_map[${ip}]}"
        echo "    ${host}: → ${newip}"
        # 1) 移除该 host 上的 MON（quorum 仍由另外 2 个维持）
        _run_ceph "orch daemon rm mon.${host} --force" 2>/dev/null || true
        # 等它退出 monmap
        sleep 8
        _run_ceph "mon rm ${host}" 2>/dev/null || true
        sleep 3
        # 2) 在新 IP 上重建 MON（cephadm 会拉起容器并绑到该网段 IP）
        _run_ceph "orch daemon add mon ${host}:${newip}" 2>/dev/null || true
        # 3) 等该 MON 重新入 quorum 再迁下一个
        wait_mon_quorum 3 120 || true
    done
}

restart_ceph_services() {
    local mode="$1"       # limit | unlimit
    local mon_map_name="$2"
    # 先迁 MON（保 quorum），再重启 OSD，避免 OSD 先切网络后 MON 不可达
    migrate_mons "${mon_map_name}"
    restart_osds
    local health
    health=$(_run_ceph "health" 2>/dev/null || echo "UNKNOWN")
    echo "  Ceph health: ${health}"
}

apply_limit() {
    echo "========================================"
    echo "Ceph 带宽限速 — 1Gbps 千兆环境模拟"
    echo "网卡: ${LIMIT_IFACE} | 原 100GbE → 切 10GbE + TBF"
    echo "========================================"
    echo ""

    # 1. Switch Ceph network to 10GbE (eno12409)
    echo ">>> Switching Ceph network to ${LIMIT_NET}..."
    _run "${PRIMARY}" "
        sudo cephadm shell -- ceph config set global public_network '${LIMIT_NET}' 2>/dev/null
        sudo cephadm shell -- ceph config set global cluster_network '${LIMIT_NET}' 2>/dev/null
        sudo cephadm shell -- ceph config set mon public_network '${LIMIT_NET}' 2>/dev/null
        sudo cephadm shell -- ceph config set mon cluster_network '${LIMIT_NET}' 2>/dev/null
        echo '  public_network  = ${LIMIT_NET}'
        echo '  cluster_network = ${LIMIT_NET}'
    "

    # 2. Migrate MONs to 10.114.1.x + restart OSDs to rebind
    restart_ceph_services "limit" CEPH_MON_LIMIT_IPS

    # 3. Get MON IPs on the limit network
    # MONs are on ceph-node1/2/3 = 150/151/152, limit network IPs:
    # 150 → 10.114.1.150, 151 → 10.114.1.151, 152 → 10.114.1.152
    LIMIT_MON_IPS=""
    for ip in "${CEPH_SERVERS[@]}"; do
        # Extract last octet and build 10.114.1.x
        last_octet=$(echo "${ip}" | cut -d. -f4)
        limit_ip="10.114.1.${last_octet}"
        [ -n "${LIMIT_MON_IPS}" ] && LIMIT_MON_IPS+=","
        LIMIT_MON_IPS+="${limit_ip}"
    done

    # 4. Update ceph.conf on 157
    update_157_ceph_conf "${LIMIT_MON_IPS}"

    # 5. Apply TBF on eno12409 (all Ceph nodes)
    echo ""
    echo ">>> Applying TBF ${RATE} on ${LIMIT_IFACE} (all nodes)..."
    for ip in "${CEPH_SERVERS[@]}"; do
        echo -n "  ${ip}: "
        _run "${ip}" "
            sudo tc qdisc del dev ${LIMIT_IFACE} root 2>/dev/null || true
            sudo tc qdisc add dev ${LIMIT_IFACE} root tbf rate ${RATE} burst ${BURST} latency ${LATENCY}
            echo 'TBF ${RATE} applied'
        " 2>/dev/null || echo "FAILED"
    done

    echo ""
    echo "========================================"
    echo "限速已应用: Ceph → ${LIMIT_NET} + TBF ${RATE}"
    echo "100GbE RDMA 不受影响（WekaIO 业务正常）"
    echo "========================================"
}

remove_limit() {
    echo "========================================"
    echo "移除 Ceph 带宽限速 — 恢复 100GbE"
    echo "========================================"
    echo ""

    # 1. Switch Ceph network back to 100GbE
    echo ">>> Switching Ceph network back to 100GbE..."
    _run "${PRIMARY}" "
        sudo cephadm shell -- ceph config set global public_network '${PUBLIC_NET}' 2>/dev/null
        sudo cephadm shell -- ceph config set global cluster_network '${CLUSTER_NET}' 2>/dev/null
        sudo cephadm shell -- ceph config set mon public_network '${PUBLIC_NET}' 2>/dev/null
        sudo cephadm shell -- ceph config set mon cluster_network '${CLUSTER_NET}' 2>/dev/null
        echo '  public_network  = ${PUBLIC_NET}  (${PUBLIC_NIC})'
        echo '  cluster_network = ${CLUSTER_NET}  (${CLUSTER_NIC})'
    "

    # 2. Migrate MONs back to 10.3.1.x + restart OSDs to rebind
    restart_ceph_services "unlimit" CEPH_MON_IPS

    # 3. Build MON IPs on the 100GbE public network (10.3.1.x)
    PUBLIC_MON_IPS=""
    for ip in "${CEPH_SERVERS[@]}"; do
        public_ip="${CEPH_MON_IPS[${ip}]}"
        [ -n "${PUBLIC_MON_IPS}" ] && PUBLIC_MON_IPS+=","
        PUBLIC_MON_IPS+="${public_ip}"
    done

    # 4. Update ceph.conf on 157
    update_157_ceph_conf "${PUBLIC_MON_IPS}"

    # 5. Remove TBF on eno12409
    echo ""
    echo ">>> Removing TBF on ${LIMIT_IFACE}..."
    for ip in "${CEPH_SERVERS[@]}"; do
        echo -n "  ${ip}: "
        _run "${ip}" "
            sudo tc qdisc del dev ${LIMIT_IFACE} root 2>/dev/null || true
            echo 'TBF removed'
        " 2>/dev/null || echo "FAILED"
    done

    echo ""
    echo "========================================"
    echo "限速已移除: Ceph → 100GbE (${PUBLIC_NET}/${CLUSTER_NET})"
    echo "========================================"
}

show_status() {
    echo "========================================"
    echo "Ceph 带宽限速状态"
    echo "========================================"

    # Ceph network config
    echo ""
    echo ">>> Ceph network config:"
    _run "${PRIMARY}" "
        echo -n '  public_network:  '
        sudo cephadm shell -- ceph config get global public_network 2>/dev/null | grep -v 'Inferring\|Using' || echo '(default)'
        echo -n '  cluster_network: '
        sudo cephadm shell -- ceph config get global cluster_network 2>/dev/null | grep -v 'Inferring\|Using' || echo '(default)'
    " 2>/dev/null || true

    # TBF status
    echo ""
    echo ">>> TBF on ${LIMIT_IFACE}:"
    for ip in "${CEPH_SERVERS[@]}"; do
        echo -n "  ${ip}: "
        _run "${ip}" "
            qdisc=\$(tc -s qdisc show dev ${LIMIT_IFACE} 2>/dev/null)
            rate=\$(echo \"\${qdisc}\" | grep -oP 'tbf.*rate \K[0-9A-Za-z]+' | head -1)
            if [ -n \"\${rate}\" ]; then
                echo \"TBF rate=\${rate}\"
            else
                echo '未限速'
            fi
        " 2>/dev/null || echo "check failed"
    done

    # Ceph health
    echo ""
    echo ">>> Ceph health:"
    _run "${PRIMARY}" "sudo cephadm shell -- ceph health 2>/dev/null" 2>/dev/null || echo "  unknown"

    echo ""
}

ACTION="${1:-status}"

case "${ACTION}" in
    apply)
        apply_limit
        ;;
    remove)
        remove_limit
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: bash limit-bandwidth.sh [apply|remove|status]"
        echo ""
        echo "  apply   - Ceph 切 10GbE + TBF 1Gbps（千兆模拟）"
        echo "  remove  - 恢复 100GbE + 删 TBF"
        echo "  status  - 检查网络 + TBF 状态"
        ;;
esac
