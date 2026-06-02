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
# ============================================================
# Common: System tuning
# ============================================================

echo ""
echo ">>> System tuning..."

# Disable swap — both TiKV and Ceph OSD embed RocksDB which uses memory
# heavily during compaction.  If compaction spills to swap, I/O latency
# jumps from <1ms to tens of ms.  TiKV's Raft heartbeat (default 1s) then
# times out → leader ejection → cluster instability.  Ceph OSD heartbeat
# times out → MON marks OSD down → unnecessary data rebalance.
# For distributed storage, OOM-kill is safer than swap thrashing.
if swapon --show | grep -q '^/'; then
    echo "  Disabling swap..."
    swapoff -a
    sed -i '/\sswap\s/d' /etc/fstab
else
    echo "  Swap already disabled."
fi

# Disable THP (Transparent Huge Pages) — causes latency spikes
echo "  Disabling THP..."
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable disable-thp
systemctl start disable-thp

# Increase file descriptor limits
echo "  Setting file descriptor limits..."
cat > /etc/security/limits.d/99-tikv-ceph.conf <<'EOF'
root    soft    nofile  1000000
root    hard    nofile  1000000
*       soft    nofile  1000000
*       hard    nofile  1000000
EOF

# Sysctl tuning
echo "  Setting sysctl parameters..."
cat > /etc/sysctl.d/99-tikv-ceph.conf <<'EOF'
# Network
net.core.somaxconn = 32768
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 16384

# Virtual memory (reduce swap tendency)
vm.swappiness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 65536

# File system
fs.file-max = 1000000
EOF
sysctl --system >/dev/null 2>&1

# I/O scheduler for SSD: noop or none
for disk in /sys/block/sd*/queue/scheduler; do
    if [ -f "${disk}" ] && grep -q '\[none\]' "${disk}" 2>/dev/null; then
        # Already none, good
        :
    elif [ -f "${disk}" ]; then
        echo "none" > "${disk}" 2>/dev/null || true
    fi
done

echo "  System tuning done."

# ============================================================
# Common: Install essential packages
# ============================================================

echo ""
echo ">>> Installing essential packages..."

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget tar gzip \
    ntpdate chrony \
    htop iotop iftop sysstat \
    python3 python3-pip \
    gdisk parted \
    >/dev/null 2>&1

# Enable NTP time sync (critical for Raft/Paxos consensus)
systemctl enable chrony --now 2>/dev/null || systemctl enable ntp --now 2>/dev/null || true

# Grant passwordless sudo to turboai (needed for deploy-ceph.sh remote execution)
if ! grep -q '^turboai ALL=(ALL) NOPASSWD:ALL' /etc/sudoers.d/turboai 2>/dev/null; then
    echo "  Granting passwordless sudo to turboai..."
    echo 'turboai ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/turboai
    chmod 440 /etc/sudoers.d/turboai
fi

echo "  Packages installed."

# ============================================================
# Common: Firewall
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
