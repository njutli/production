#!/bin/bash
set -euo pipefail

# ============================================================
# Performance Tuning
#
# 仅在 slave(150-152) 上执行 — 157 不动（WekaIO 红线）。
#
# Tuning notes:
#   - 100GbE TCP buffer 调大（万兆 + EC 取片需要更大 buffer）
#   - THP disable (Ceph/TiKV recommended)
#   - dirty_ratio 5/10
#   - IO scheduler none（NVMe 内核默认）
#   - 不设 MTU（100GbE 已 4200，不动）
#
# 用法（在每台 slave 上执行）:
#   scp_to scripts/tune-servers.sh 10.20.1.150 /tmp/tune-servers.sh
#   ssh_to_slave 10.20.1.150 "sudo bash /tmp/tune-servers.sh"
# 或通过 prepare-all-servers.sh 后手动执行。
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "========================================"
echo "Performance Tuning — $(hostname)"
echo "========================================"

# ============================================================
# 1. Swap — disable
# ============================================================

echo ""
echo ">>> Disabling swap..."
if swapon --show | grep -q '^/'; then
    swapoff -a
    sed -i '/\sswap\s/d' /etc/fstab
    echo "  Swap disabled."
else
    echo "  Swap already disabled."
fi

# ============================================================
# 2. THP — disable (Ceph/TiKV recommended)
# ============================================================

echo ""
echo ">>> Disabling Transparent Huge Pages..."

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

# Remove old enable-thp service if present
systemctl disable enable-thp 2>/dev/null || true
rm -f /etc/systemd/system/enable-thp.service 2>/dev/null || true

systemctl daemon-reload
systemctl enable disable-thp
systemctl start disable-thp
echo "  THP disabled (never)."

# ============================================================
# 3. Sysctl tuning
# ============================================================

echo ""
echo ">>> Sysctl tuning..."

cat > /etc/sysctl.d/99-juicefs-ceph.conf <<'EOF'
# Network — 100GbE TCP buffer for Ceph messenger + EC 4+2 取片
net.core.somaxconn = 32768
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 16384

# 万兆/十万兆 TCP auto-tune 上限
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 250000

# Virtual memory
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
# 4. I/O scheduler — none for NVMe (kernel default)
# ============================================================

echo ""
echo ">>> I/O scheduler..."
for disk in /sys/block/nvme*/queue/scheduler; do
    [ -f "${disk}" ] && echo "  $(basename $(dirname $(dirname ${disk}))): $(cat ${disk})"
done
echo "  NVMe: none (kernel default, not changed)."

# ============================================================
# 5. File descriptor limits
# ============================================================

echo ""
echo ">>> File descriptor limits..."
cat > /etc/security/limits.d/99-juicefs-ceph.conf <<'EOF'
root    soft    nofile  1000000
root    hard    nofile  1000000
*       soft    nofile  1000000
*       hard    nofile  1000000
EOF
echo "  Done."

# ============================================================
# 6. CPU governor — performance
# ============================================================

echo ""
echo ">>> CPU governor..."
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "${gov}" ] && echo "performance" > "${gov}" 2>/dev/null || true
done
echo "  Done."

# ============================================================
# 7. rc.local for non-persistent settings
# ============================================================

echo ""
echo ">>> Creating rc.local..."

cat > /etc/rc.local <<'EOF'
#!/bin/bash
# JuiceFS + Ceph + TiKV non-persistent tuning

# THP
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# CPU governor
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "${gov}" ] && echo "performance" > "${gov}" 2>/dev/null || true
done

exit 0
EOF
chmod +x /etc/rc.local
systemctl enable rc-local 2>/dev/null || true
echo "  rc.local created."

echo ""
echo "========================================"
echo "Tuning complete."
echo "========================================"
echo ""
echo "Changes:"
echo "  - THP: never (Ceph/TiKV 推荐)"
echo "  - Sysctl: dirty 5/10, TCP buffer 128MB"
echo "  - CPU governor: performance"
echo "  - 157 未调优（WekaIO 红线）"
echo ""
echo "Restart services to apply fd limits:"
echo "  sudo systemctl restart pd tikv (TiKV)"
echo "  sudo cephadm shell -- ceph orch restart osd (Ceph)"
