#!/bin/bash
set -euo pipefail

# ============================================================
# Server Preparation
#
# Prepares a server for JuiceFS+TiKV+Ceph deployment:
#   - Time sync (chrony)
#   - NOPASSWD sudo
#   - Essential packages
#   - Firewall rules (TiKV + Ceph ports)
#   - Mount nvme1n1 for TiKV (slaves) or cache (157)
#
# Disk layout:
#   157 (client):  nvme1n1(894G ext4) → /mnt/jfs-cache (JuiceFS cache)
#   150-152:       nvme1n1(894G ext4) → /mnt/jfs-tikv (TiKV+PD data)
#                  nvme2n1(7T XFS)    → Ceph OSD (wipe before deploy)
#                  nvme3n1(7T XFS)    → Ceph OSD (wipe before deploy)
#
# 不设 MTU：100GbE 已 4200（WekaIO 设），10GbE 1500（默认）。
# 红线：不动 100GbE 网卡/驱动参数。
#
# Run on EACH server individually (via prepare-all-servers.sh).
# Usage: sudo bash prepare-servers.sh tikv|ceph|client
# ============================================================

ROLE="${1:-all}"

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
# 3. Install essential packages
# ============================================================

echo ""
echo ">>> Installing essential packages..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget tar gzip build-essential \
    htop iotop iftop sysstat fio \
    >/dev/null 2>&1 || echo "  (some packages unavailable, continuing)"

if [ "${ROLE}" = "ceph" ] || [ "${ROLE}" = "all" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk parted lvm2 podman >/dev/null 2>&1 || \
        echo "  (some ceph prerequisites unavailable, deploy-ceph.sh will retry)"
fi

echo "  Packages installed."

# ============================================================
# 4. Firewall
# ============================================================

echo ""
echo ">>> Configuring firewall (role=${ROLE})..."

configure_firewall() {
    local role=$1

    if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
        echo "  Using UFW..."
        if [ "${role}" = "tikv" ] || [ "${role}" = "all" ]; then
            ufw allow 2379/tcp comment 'PD client'
            ufw allow 2380/tcp comment 'PD peer'
            ufw allow 20160/tcp comment 'TiKV server'
            ufw allow 20180/tcp comment 'TiKV status'
        fi
        if [ "${role}" = "ceph" ] || [ "${role}" = "all" ]; then
            ufw allow 3300/tcp comment 'Ceph MON'
            ufw allow 6789/tcp comment 'Ceph MON v2'
            ufw allow 6800:7300/tcp comment 'Ceph OSD'
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
            firewall-cmd --permanent --add-port=6800-7300/tcp 2>/dev/null || true
        fi
        firewall-cmd --reload 2>/dev/null || true
    else
        echo "  No firewall detected. Ports: TiKV(2379/2380/20160/20180) Ceph(3300/6789/6800-7300)"
    fi
}

configure_firewall "${ROLE}"

# ============================================================
# 5. Mount nvme1n1 (TiKV data or JuiceFS cache)
# ============================================================

echo ""
echo ">>> Preparing nvme1n1 mount..."

# nvme1n1 (ext4). Mount for JuiceFS use.
DEV="/dev/nvme1n1"

if [ "${ROLE}" = "tikv" ]; then
    MNT="/mnt/jfs-tikv"
    SUBDIRS="tikv pd"
elif [ "${ROLE}" = "client" ]; then
    MNT="/mnt/jfs-cache"
    SUBDIRS=""
else
    # ceph role: nvme1n1 not used (OSD uses nvme2n1/nvme3n1)
    # But if tikv+ceph co-located, mount for tikv too
    MNT="/mnt/jfs-tikv"
    SUBDIRS="tikv pd"
fi

if [ ! -b "${DEV}" ]; then
    echo "  WARNING: ${DEV} not found. Disk may have different name."
    echo "  Available NVMe devices:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep nvme || true
else
    # Check if already ext4
    cur_fs=$(blkid -s TYPE -o value "${DEV}" 2>/dev/null || echo "")
    if [ "${cur_fs}" != "ext4" ]; then
        echo "  Formatting ${DEV} as ext4..."
        mkfs.ext4 -F "${DEV}"
    fi

    # Mount if not already mounted
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

    # Create subdirs
    for d in ${SUBDIRS}; do
        mkdir -p "${MNT}/${d}"
    done

    # Clean up old mount point if present
    if [ "${ROLE}" = "tikv" ] && mountpoint -q /mnt/beegfs-meta 2>/dev/null; then
        echo "  Unmounting old metadata mount..."
        umount /mnt/beegfs-meta 2>/dev/null || true
        sed -i '/beegfs-meta/d' /etc/fstab 2>/dev/null || true
    fi
fi

# ============================================================
# 6. Unmount old storage disks (slaves only)
# ============================================================

if [ "${ROLE}" = "tikv" ] || [ "${ROLE}" = "ceph" ] || [ "${ROLE}" = "all" ]; then
    echo ""
    echo ">>> Cleaning up old storage mounts (if present)..."

    for mnt in /data/disk1 /data/disk2; do
        if mountpoint -q "${mnt}" 2>/dev/null; then
            echo "  Unmounting ${mnt} (was old storage)..."
            umount "${mnt}" 2>/dev/null || true
            sed -i "\| ${mnt} |d" /etc/fstab 2>/dev/null || true
        fi
    done

    # nvme2n1/nvme3n1 will be wiped by deploy-ceph.sh before OSD creation
    echo "  OSD disks (nvme2n1, nvme3n1) will be wiped by deploy-ceph.sh."

    # Mount tmpfs for DB/WAL (test env: data loss acceptable, rebuildable)
    if [ "${CEPH_DB_WAL_TMPFS:-false}" = "true" ]; then
        echo ""
        echo "  Mounting tmpfs for DB/WAL at ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}..."
        mkdir -p "${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}"
        if ! mountpoint -q "${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}" 2>/dev/null; then
            mount -t tmpfs -o size=${CEPH_DB_WAL_TMPFS_SIZE:-200}M tmpfs "${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}"
            if ! grep -q " ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal} " /etc/fstab 2>/dev/null; then
                echo "tmpfs ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal} tmpfs size=${CEPH_DB_WAL_TMPFS_SIZE:-200}M,mode=1777 0 0" >> /etc/fstab
            fi
            echo "  tmpfs mounted at ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal} (size=${CEPH_DB_WAL_TMPFS_SIZE:-200}M)"
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
if [ "${ROLE}" = "tikv" ] || [ "${ROLE}" = "all" ]; then
    echo "  TiKV mount:   $(mountpoint -q /mnt/jfs-tikv 2>/dev/null && echo 'OK' || echo 'NOT MOUNTED')"
    echo "  DB/WAL tmpfs: $(mountpoint -q /mnt/dbwal 2>/dev/null && echo 'OK' || echo 'NOT MOUNTED')"
fi
if [ "${ROLE}" = "client" ]; then
    echo "  Cache mount:  $(mountpoint -q /mnt/jfs-cache 2>/dev/null && echo 'OK' || echo 'NOT MOUNTED')"
fi
