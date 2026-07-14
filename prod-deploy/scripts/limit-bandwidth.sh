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
#   2. 重启所有 OSD + MON（重新绑定新网络）
#   3. eno12409 上 tc tbf 1Gbps（限速模式）
#   4. 更新 157 上 /etc/ceph/ceph.conf 的 mon_host
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

restart_ceph_services() {
    local mode="$1"
    echo "  Restarting MONs..."
    _run_ceph "orch restart mon" 2>/dev/null || true
    echo "  Restarting OSDs..."
    _run_ceph "orch restart osd" 2>/dev/null || true
    echo "  Waiting for services to stabilize (30s)..."
    sleep 30
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

    # 2. Restart Ceph services to rebind
    restart_ceph_services "limit"

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

    # 2. Restart Ceph services to rebind
    restart_ceph_services "unlimit"

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
