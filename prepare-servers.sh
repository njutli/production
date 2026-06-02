#!/bin/bash
set -euo pipefail

# ============================================================
# Server Preparation (4-Machine Topology: 1 TiKV + 3 Ceph)
#
# Prepares a physical server for deployment readiness:
#   tikv  – chrony, firewall, /data directories, NOPASSWD sudo
#   ceph  – chrony, firewall, podman, root SSH, NOPASSWD sudo
#
# Performance tuning (swap, THP, sysctl, IO scheduler, fd limits)
# is handled separately by tune-servers.sh — run it after deployment.
#
# Run on EACH server individually (NOT from remote).
#
# Usage: sudo bash prepare-servers.sh tikv
#        sudo bash prepare-servers.sh ceph
# ============================================================

ROLE="${1:-all}"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "========================================"
echo "Production Server Preparation"
echo "Role: ${ROLE}"
echo "========================================"

# ============================================================
# Common: Time sync (critical for distributed consensus)
# ============================================================
#
# NTP/chrony works by measuring the round-trip time to multiple
# reference servers, then gradually adjusting the local clock — not
# by jumping, but by slewing (speeding up / slowing down the system
# tick rate).  This keeps the clock monotonic, avoiding jumps that
# would confuse applications.
#
# Why it matters for TiKV and Ceph:
#
#   TiKV PD (Raft):
#     Leader election and lease expiration both rely on timeouts.
#     If node A's clock is 20s ahead of node B, A will send a
#     heartbeat, B will respond, but A may have already declared B
#     unreachable and started a disruptive leader election.
#
#   Ceph MON (Paxos):
#     MON tracks OSD liveness via heartbeat.  Default timeout is
#     20s — if an OSD misses 20s of heartbeats, MON marks it
#     "down" and triggers data rebalance across the cluster.
#     Clock skew between MON and OSD can cause false-positives,
#     wasting I/O and network bandwidth on unnecessary recovery.
#
# Both chrony and ntp are standard Ubuntu packages.  We prefer
# chrony (default since 22.04) and fall back to ntp.

echo ""
echo ">>> Time synchronisation..."

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y chrony >/dev/null 2>&1 || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y ntp >/dev/null 2>&1
systemctl enable chrony --now 2>/dev/null || systemctl enable ntp --now 2>/dev/null || true
echo "  Time sync enabled."

# ============================================================
# Common: Grant NOPASSWD sudo to turboai
# (required by deploy-ceph.sh for remote sudo commands)
# ============================================================

echo ""
echo ">>> Granting passwordless sudo to turboai..."
if ! grep -q '^turboai ALL=(ALL) NOPASSWD:ALL' /etc/sudoers.d/turboai 2>/dev/null; then
    echo 'turboai ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/turboai
    chmod 440 /etc/sudoers.d/turboai
fi
echo "  Done."

# ============================================================
# Common: Install essential packages
# ============================================================

echo ""
echo ">>> Installing essential packages..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget tar gzip \
    htop iotop iftop sysstat \
    gdisk parted \
    python3 python3-pip \
    >/dev/null 2>&1

echo "  Packages installed."

# ============================================================
# Common: Firewall
#
# Ubuntu's ufw blocks all inbound traffic by default.  In the WSL2/QEMU
# demo all VMs shared one host on internal bridges (br0/br1), so traffic
# never hit the physical firewall.  On physical servers every port must
# be explicitly opened, otherwise:
#   TiKV:  PD/TiKV can't form cluster (ports 2379/2380/20160/20180)
#   Ceph:  MON can't reach quorum (3300/6789), RGW S3 API unreachable (8000),
#          OSD replication blocked (6800-7300)
# ============================================================

echo ""
echo ">>> Configuring firewall..."

configure_firewall() {
    local role=$1

    if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
        echo "  Using UFW..."

        if [ "${role}" = "tikv" ] || [ "${role}" = "all" ]; then
            # TiKV / PD ports
            ufw allow 2379/tcp comment 'PD client'
            ufw allow 2380/tcp comment 'PD peer'
            ufw allow 20160/tcp comment 'TiKV server'
            ufw allow 20180/tcp comment 'TiKV status'
        fi

        if [ "${role}" = "ceph" ] || [ "${role}" = "all" ]; then
            # Ceph ports
            ufw allow 3300/tcp comment 'Ceph MON'
            ufw allow 6789/tcp comment 'Ceph MON v2'
            ufw allow 8000/tcp comment 'RGW S3 API'
            ufw allow 6800:7300/tcp comment 'Ceph OSD'
            ufw allow 8443/tcp comment 'Ceph MGR dashboard'
        fi
    elif command -v firewall-cmd &>/dev/null; then
        echo "  Using firewalld..."

        if [ "${role}" = "tikv" ] || [ "${role}" = "all" ]; then
            firewall-cmd --permanent --add-port=2379/tcp 2>/dev/null || true
            firewall-cmd --permanent --add-port=2380/tcp 2>/dev/null || true
            firewall-cmd --permanent --add-port=20160/tcp 2>/dev/null || true
            firewall-cmd --permanent --add-port=20180/tcp 2>/dev/null || true
        fi
        if [ "${role}" = "ceph" ] || [ "${role}" = "all" ]; then
            firewall-cmd --permanent --add-port=3300/tcp 2>/dev/null || true
            firewall-cmd --permanent --add-port=6789/tcp 2>/dev/null || true
            firewall-cmd --permanent --add-port=8000/tcp 2>/dev/null || true
            firewall-cmd --permanent --add-port=6800-7300/tcp 2>/dev/null || true
            firewall-cmd --permanent --add-port=8443/tcp 2>/dev/null || true
        fi
        firewall-cmd --reload 2>/dev/null || true
    else
        echo "  No firewall detected. Please configure manually:"
        echo "    TiKV: TCP 2379, 2380, 20160, 20180"
        echo "    Ceph: TCP 3300, 6789, 8000, 6800-7300, 8443"
    fi
}

configure_firewall "${ROLE}"

# ============================================================
# TiKV-specific: Prepare /data mount
# ============================================================

if [ "${ROLE}" = "tikv" ] || [ "${ROLE}" = "all" ]; then
    echo ""
    echo ">>> Preparing TiKV data directory..."

    if ! mountpoint -q /data 2>/dev/null; then
        echo "  /data is not mounted!"
        echo "  If you have a dedicated disk, format and mount it:"
        echo "    mkfs.xfs /dev/sdX"
        echo "    mount /dev/sdX /data"
        echo "    echo '/dev/sdX /data xfs defaults,noatime 0 2' >> /etc/fstab"
        echo ""
        echo "  Creating /data directory for now..."
        mkdir -p /data
    fi

    mkdir -p /data/tikv /data/pd
    mkdir -p /var/log/tikv /var/log/pd
    mkdir -p /opt/tikv/bin /opt/tikv/conf /opt/pd/bin /opt/pd/conf

    echo "  TiKV directories ready."
fi

# ============================================================
# Ceph-specific: Verify OSD devices
# ============================================================

if [ "${ROLE}" = "ceph" ] || [ "${ROLE}" = "all" ]; then
    echo ""
    echo ">>> Ceph-specific preparation..."

    # Ensure podman is installed
    if ! command -v podman &>/dev/null; then
        echo "  Installing podman..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y podman >/dev/null 2>&1
    fi

    # Stop docker if running (conflicts with cephadm)
    systemctl stop docker docker.socket 2>/dev/null || true
    systemctl disable docker docker.socket 2>/dev/null || true

    # Enable root SSH (cephadm requirement)
    if ! grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config; then
        echo "  Enabling root SSH..."
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi

    echo "  Ceph preparation done."
fi

echo ""
echo "========================================"
echo "Server preparation complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. bash production/setup-ssh-keys.sh   (from deployment machine)"
echo "  2. bash production/deploy-tikv.sh      (from deployment machine)"
echo "  3. bash production/deploy-ceph.sh      (from deployment machine)"
echo "  4. sudo bash production/tune-servers.sh tikv|ceph  (on each server)"
