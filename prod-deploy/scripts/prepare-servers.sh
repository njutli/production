#!/bin/bash
set -euo pipefail

# ============================================================
# Server Preparation
#
# 当前集群架构（4 机混部）：
#   150-152 (slave):  TiKV+PD on nvme1n1 + Ceph OSD on nvme2n1/nvme3n1
#   157    (client):  JuiceFS FUSE 客户端，nvme1n1 → cache
#
# 因此只有两个角色：
#   slave  — 装全部包（含 Ceph 前置）、开全部防火墙端口、
#             nvme1n1 → /mnt/jfs-tikv、清旧挂载、tmpfs DB/WAL
#   client — 装基础包、nvme1n1 → /mnt/jfs-cache、不动 Ceph/TiKV
#
# Disk layout:
#   157 (client):  nvme1n1(894G ext4) → /mnt/jfs-cache (JuiceFS cache)
#   150-152:       nvme1n1(894G ext4) → /mnt/jfs-tikv (TiKV+PD data)
#                  nvme2n1(7T XFS)    → Ceph OSD (wipe before deploy)
#                  nvme3n1(7T XFS)    → Ceph OSD (wipe before deploy)
#
# 不设 MTU：100GbE 已 4200（WekaIO 设），10GbE 1500（默认）。
# 红线：不动 100GbE 网卡/驱动参数；不动 157 内核（WekaIO 红线）。
#
# Run on EACH server individually (via prepare-all-servers.sh).
# Usage: sudo bash prepare-servers.sh slave|client
# ============================================================

ROLE="${1:-}"
if [ "${ROLE}" != "slave" ] && [ "${ROLE}" != "client" ]; then
    echo "Usage: sudo bash prepare-servers.sh slave|client"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

_SSH_USER="${SSH_USER:-sunrise}"

echo "========================================"
echo "Server Preparation — Role: ${ROLE}"
echo "Host: $(hostname)"
echo "========================================"

# ============================================================
# 1. Time synchronisation
# ============================================================
# TiKV PD (Raft) 和 Ceph MON (Paxos) 都依赖单调时钟做 leader
# election 和 heartbeat timeout。时钟偏移 > 数秒即可触发误选举 /
# 误判 OSD down → 不必要的数据恢复。chrony 优先，fallback ntp。

echo ""
echo ">>> Time synchronisation..."

apt-get update -qq || echo "  (apt update had errors, continuing)"

if systemctl is-active systemd-timesyncd &>/dev/null; then
    echo "  systemd-timesyncd already active."
elif ! command -v chronyd &>/dev/null && ! command -v ntpd &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y chrony >/dev/null 2>&1 || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntp >/dev/null 2>&1 || {
        echo "  ERROR: failed to install time sync package."
        exit 1
    }
    systemctl enable chrony --now 2>/dev/null || systemctl enable ntp --now 2>/dev/null || true
fi
echo "  Time sync enabled."

# ============================================================
# 2. Grant NOPASSWD sudo
# ============================================================

echo ""
echo ">>> Granting passwordless sudo to ${_SSH_USER}..."
if ! grep -q "^${_SSH_USER} ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/${_SSH_USER} 2>/dev/null; then
    echo "${_SSH_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${_SSH_USER}
    chmod 440 /etc/sudoers.d/${_SSH_USER}
fi
echo "  Done."

# ============================================================
# 3. Install packages
# ============================================================

echo ""
echo ">>> Installing packages..."

# Common packages (all nodes)
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget tar gzip build-essential \
    htop iotop iftop sysstat fio \
    >/dev/null 2>&1 || echo "  (some packages unavailable, continuing)"

# Slave-only: Ceph prerequisites (cephadm/podman/root-SSH handled by deploy-ceph.sh)
if [ "${ROLE}" = "slave" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk parted lvm2 podman >/dev/null 2>&1 || \
        echo "  (some ceph prerequisites unavailable, deploy-ceph.sh will retry)"
fi

echo "  Packages installed."

# ============================================================
# 4. Firewall
# ============================================================
# 157 是客户端，FUSE 挂载是本地操作，不需要入站端口。
# 150-152 同时提供 TiKV 和 Ceph 服务，需要全部端口。

echo ""
echo ">>> Configuring firewall (role=${ROLE})..."

if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
    echo "  Using UFW..."
    if [ "${ROLE}" = "slave" ]; then
        ufw allow 2379/tcp comment 'PD client'
        ufw allow 2380/tcp comment 'PD peer'
        ufw allow 20160/tcp comment 'TiKV server'
        ufw allow 20180/tcp comment 'TiKV status'
        ufw allow 3300/tcp comment 'Ceph MON'
        ufw allow 6789/tcp comment 'Ceph MON v2'
        ufw allow 6800:7300/tcp comment 'Ceph OSD'
    fi
elif command -v firewall-cmd &>/dev/null; then
    echo "  Using firewalld..."
    if [ "${ROLE}" = "slave" ]; then
        firewall-cmd --permanent --add-port=2379/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=2380/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=20160/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=20180/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=3300/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=6789/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=6800-7300/tcp 2>/dev/null || true
    fi
    firewall-cmd --reload 2>/dev/null || true
else
    if [ "${ROLE}" = "slave" ]; then
        echo "  No firewall detected. Needed: TiKV(2379/2380/20160/20180) Ceph(3300/6789/6800-7300)"
    else
        echo "  No firewall detected. Client needs no inbound ports."
    fi
fi

# ============================================================
# 5. Mount nvme1n1
# ============================================================

echo ""
echo ">>> Preparing nvme1n1 mount..."

DEV="/dev/nvme1n1"

if [ "${ROLE}" = "slave" ]; then
    MNT="/mnt/jfs-tikv"
    SUBDIRS="tikv pd"
elif [ "${ROLE}" = "client" ]; then
    MNT="/mnt/jfs-cache"
    SUBDIRS=""
fi

if [ ! -b "${DEV}" ]; then
    echo "  WARNING: ${DEV} not found. Disk may have different name."
    echo "  Available NVMe devices:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep nvme || true
else
    cur_fs=$(blkid -s TYPE -o value "${DEV}" 2>/dev/null || echo "")
    if [ "${cur_fs}" != "ext4" ]; then
        echo "  Formatting ${DEV} as ext4..."
        mkfs.ext4 -F "${DEV}"
    fi

    if ! mountpoint -q "${MNT}" 2>/dev/null; then
        mkdir -p "${MNT}"
        mount -o defaults,noatime "${DEV}" "${MNT}"
        uuid=$(blkid -s UUID -o value "${DEV}" 2>/dev/null || echo "")
        if [ -n "${uuid}" ] && ! grep -q " ${MNT} " /etc/fstab 2>/dev/null; then
            echo "UUID=${uuid} ${MNT} ext4 defaults,noatime 0 2" >> /etc/fstab
        fi
        echo "  Mounted ${DEV} -> ${MNT}"
    else
        echo "  ${MNT} already mounted."
    fi

    for d in ${SUBDIRS}; do
        mkdir -p "${MNT}/${d}"
    done

    # Clean up old BeeFS mount (slaves only)
    if [ "${ROLE}" = "slave" ] && mountpoint -q /mnt/beegfs-meta 2>/dev/null; then
        echo "  Unmounting old BeeFS metadata mount..."
        umount /mnt/beegfs-meta 2>/dev/null || true
        sed -i '/beegfs-meta/d' /etc/fstab 2>/dev/null || true
    fi
fi

# ============================================================
# 6. Unmount old storage + tmpfs DB/WAL (slaves only)
# ============================================================

if [ "${ROLE}" = "slave" ]; then
    echo ""
    echo ">>> Cleaning up old storage mounts (if present)..."

    for mnt in /data/disk1 /data/disk2; do
        if mountpoint -q "${mnt}" 2>/dev/null; then
            echo "  Unmounting ${mnt} (was old storage)..."
            umount "${mnt}" 2>/dev/null || true
            sed -i "\| ${mnt} |d" /etc/fstab 2>/dev/null || true
        fi
    done

    echo "  OSD disks (nvme2n1, nvme3n1) will be wiped by deploy-ceph.sh."

    # Mount tmpfs for DB/WAL (test env: data loss acceptable, rebuildable)
    if [ "${CEPH_DB_WAL_TMPFS:-false}" = "true" ]; then
        echo ""
        echo "  Mounting tmpfs for DB/WAL at ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}..."
        mkdir -p "${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}"
        if ! mountpoint -q "${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}" 2>/dev/null; then
            mount -t tmpfs -o size=${CEPH_DB_WAL_TMPFS_SIZE:-200G} tmpfs "${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}"
            if ! grep -q " ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal} " /etc/fstab 2>/dev/null; then
                echo "tmpfs ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal} tmpfs size=${CEPH_DB_WAL_TMPFS_SIZE:-200G},mode=1777 0 0" >> /etc/fstab
            fi
            echo "  tmpfs mounted at ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal} (size=${CEPH_DB_WAL_TMPFS_SIZE:-200G})"
        else
            echo "  ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal} already mounted."
        fi
    fi
fi

# ============================================================
# 7. File descriptor limits
# ============================================================

echo ""
echo ">>> Setting file descriptor limits..."
cat > /etc/security/limits.d/99-juicefs.conf <<'EOF'
root    soft    nofile  1000000
root    hard    nofile  1000000
*       soft    nofile  1000000
*       hard    nofile  1000000
EOF
echo "  Done."

# ============================================================
# 8. Summary
# ============================================================

echo ""
echo "========================================"
echo "Server preparation complete!"
echo "========================================"
echo ""
echo "Checks:"
echo "  Time sync:    $(systemctl is-active chrony 2>/dev/null || systemctl is-active systemd-timesyncd 2>/dev/null || echo 'UNKNOWN')"
echo "  NOPASSWD:     $(sudo -n true 2>/dev/null && echo 'OK' || echo 'FAILED')"
if [ "${ROLE}" = "slave" ]; then
    echo "  TiKV mount:   $(mountpoint -q /mnt/jfs-tikv 2>/dev/null && echo 'OK' || echo 'NOT MOUNTED')"
    echo "  DB/WAL tmpfs: $(mountpoint -q /mnt/dbwal 2>/dev/null && echo 'OK' || echo 'NOT MOUNTED')"
elif [ "${ROLE}" = "client" ]; then
    echo "  Cache mount:  $(mountpoint -q /mnt/jfs-cache 2>/dev/null && echo 'OK' || echo 'NOT MOUNTED')"
fi
