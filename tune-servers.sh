#!/bin/bash
set -euo pipefail

# ============================================================
# Performance Tuning (run AFTER deployment, on each server)
#
# Tuning grouped by whether a restart is needed.
# Most kernel-level changes (swap, THP, sysctl, I/O scheduler)
# take effect immediately.  Only fd limits require restarting
# the affected services.
#
# Usage: sudo bash tune-servers.sh tikv
#        sudo bash tune-servers.sh ceph
# ============================================================

ROLE="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

if [ "${ROLE}" != "tikv" ] && [ "${ROLE}" != "ceph" ]; then
    echo "Usage: sudo bash tune-servers.sh tikv|ceph"
    exit 1
fi

echo "========================================"
echo "Performance Tuning — ${ROLE}"
echo "========================================"

# ============================================================
# 1. Swap — takes effect immediately (swapoff)
# ============================================================

echo ""
echo ">>> Disabling swap..."
echo ""
echo "    Why: Both TiKV and Ceph OSD embed RocksDB. During compaction,"
echo "    RocksDB uses memory heavily. If compaction spills to swap, I/O"
echo "    latency jumps from <1ms to tens of ms, causing:"
echo "      • TiKV: Raft heartbeat timeout → leader ejection → cluster instability"
echo "      • Ceph: OSD heartbeat timeout → MON marks OSD down → unnecessary rebalance"
echo "    For distributed storage, OOM-kill is safer than swap thrashing."
echo ""

if swapon --show | grep -q '^/'; then
    echo "  Disabling swap..."
    swapoff -a
    sed -i '/\sswap\s/d' /etc/fstab
else
    echo "  Swap already disabled."
fi

# ============================================================
# 2. THP — takes effect immediately (sysfs write)
# ============================================================

echo ""
echo ">>> Disabling Transparent Huge Pages..."
echo ""
echo "    Why: THP causes latency spikes because the kernel periodically"
echo "    compacts memory to create 2MB huge pages.  This compaction can"
echo "    stall user-space processes for hundreds of ms — deadly for"
echo "    Raft/Paxos heartbeat-driven systems."
echo ""

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

# ============================================================
# 3. Sysctl — takes effect immediately (sysctl --system)
# ============================================================

echo ""
echo ">>> Sysctl tuning..."

cat > /etc/sysctl.d/99-tikv-ceph.conf <<'EOF'
# Network — increase connection backlog and reduce TIME_WAIT buildup
net.core.somaxconn = 32768
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 16384

# Virtual memory — minimise swap tendency, keep writes in memory
vm.swappiness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 65536

# File descriptors
fs.file-max = 1000000
EOF
sysctl --system >/dev/null 2>&1
echo "  Done."

# ============================================================
# 4. I/O scheduler — takes effect immediately
# ============================================================

echo ""
echo ">>> Setting I/O scheduler to none (best for NVMe/SSD)..."

for disk in /sys/block/sd*/queue/scheduler; do
    if [ -f "${disk}" ]; then
        if grep -q '\[none\]' "${disk}" 2>/dev/null; then
            :
        else
            echo "none" > "${disk}" 2>/dev/null || true
        fi
    fi
done
echo "  Done."

# ============================================================
# 5. File descriptor limits (requires service restart)
# ============================================================

echo ""
echo ">>> Setting file descriptor limits..."

cat > /etc/security/limits.d/99-tikv-ceph.conf <<'EOF'
root    soft    nofile  1000000
root    hard    nofile  1000000
*       soft    nofile  1000000
*       hard    nofile  1000000
EOF

echo "  Done."
echo ""

# ============================================================
# Restart required?
# ============================================================

echo "========================================"
echo "Tuning complete."
echo "========================================"
echo ""
echo "Swap, THP, sysctl, I/O scheduler: 生效，无需重启"
echo "File descriptor limits:            已写入，但已运行的进程不会自动继承新值"

if [ "${ROLE}" = "tikv" ]; then
    echo ""
    echo "使 fd limits 对 TiKV/PD 生效："
    echo "  sudo systemctl restart pd tikv"
elif [ "${ROLE}" = "ceph" ]; then
    echo ""
    echo "使 fd limits 对 Ceph 容器生效（容器由 cephadm 管理，需重建）："
    echo "  sudo cephadm shell -- ceph orch daemon restart osd.<id>   (逐 OSD 重启)"
    echo "  # 或者简单粗暴：重启整台机器"
fi
