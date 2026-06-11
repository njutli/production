#!/bin/bash
set -euo pipefail

# ============================================================
# Remove MinIO Deployment
#
# Stops MinIO, cleans XFS mount and fstab, wipes data disk.
# Leaves sdb clean for Ceph re-deployment.
#
# Usage: bash remove-minio.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

ssh_srv() {
    local ip=$1; shift
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" "$@"
}

echo "========================================"
echo "Remove MinIO Deployment"
echo "========================================"
echo "Nodes: ${MINIO_SERVERS[*]}"
echo "Data:  ${MINIO_MOUNT} (from ${MINIO_DATA_DEVICE})"
echo "========================================"
echo ""

# ——— Pre-flight ———

# Warn if JuiceFS is mounted
if mountpoint -q "${JUICEFS_MOUNT_POINT}" 2>/dev/null; then
    echo "WARNING: JuiceFS is still mounted at ${JUICEFS_MOUNT_POINT}."
    echo "  Unmount it first: bash deploy-juicefs.sh unmount"
    echo ""
    read -rp "Continue anyway? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

echo ""
read -rp "This will STOP MinIO and wipe data on sdb. Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ——— Step 1: Stop MinIO on all nodes ———
echo ""
echo ">>> Step 1: Stopping MinIO on all nodes..."
for ip in "${MINIO_SERVERS[@]}"; do
    echo "  ${ip}..."
    ssh_srv "${ip}" "
        sudo systemctl stop minio 2>/dev/null || true
        sudo systemctl disable minio 2>/dev/null || true
        sudo rm -f /etc/systemd/system/minio.service
        sudo rm -f /etc/default/minio
        sudo systemctl daemon-reload
    " 2>/dev/null || true
done
echo "  MinIO stopped and removed."

# ——— Step 2: Unmount & clean data disks ———
echo ""
echo ">>> Step 2: Unmounting and wiping data disks..."

for ip in "${MINIO_SERVERS[@]}"; do
    echo "  Cleaning ${ip}..."

    ssh_srv "${ip}" "
        set -e
        dev='${MINIO_DATA_DEVICE}'
        mnt='${MINIO_MOUNT}'

        # Safety check
        root_dev=\$(findmnt -n -o SOURCE / | sed 's/[0-9]*\$//;s/p[0-9]*\$//')
        if [ \"\${root_dev}\" = \"\${dev}\" ]; then
            echo '    FATAL: \${dev} is system disk!'; exit 1
        fi
    "

    # Unmount
    ssh_srv "${ip}" "
        if mountpoint -q ${MINIO_MOUNT} 2>/dev/null; then
            sudo umount ${MINIO_MOUNT} 2>/dev/null || sudo umount -l ${MINIO_MOUNT} 2>/dev/null || true
            echo '    Unmounted ${MINIO_MOUNT}.'
        else
            echo '    ${MINIO_MOUNT} not mounted.'
        fi
    "

    # Remove fstab entry
    ssh_srv "${ip}" "
        sudo sed -i '\|${MINIO_MOUNT}|d' /etc/fstab 2>/dev/null || true
    "

    # Remove mount point
    ssh_srv "${ip}" "
        sudo rmdir ${MINIO_MOUNT} 2>/dev/null || sudo rm -rf ${MINIO_MOUNT} 2>/dev/null || true
        echo '    Mount point removed.'
    "

    # Wipe filesystem signature
    ssh_srv "${ip}" "
        sudo wipefs -af ${MINIO_DATA_DEVICE} 2>/dev/null || true
        echo '    Disk ${MINIO_DATA_DEVICE} wiped.'
    "
done

# ——— Step 3: Clean up credentials ———
echo ""
echo ">>> Step 3: Cleaning up credentials..."
rm -f "${SCRIPT_DIR}/.credentials/minio-juicefs.env"
echo "  Removed .credentials/minio-juicefs.env"

echo ""
echo "========================================"
echo "MinIO removed, data disks wiped."
echo "sdb is now clean — ready for Ceph."
echo "========================================"
echo ""
echo "To redeploy MinIO:  bash deploy-minio.sh deploy"
echo "To redeploy Ceph:   bash deploy-ceph.sh"