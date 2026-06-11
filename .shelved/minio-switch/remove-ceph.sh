#!/bin/bash
set -euo pipefail

# ============================================================
# Remove Ceph Deployment
#
# Stops Ceph services and cleans LVM/OSD data from sdb on all
# 3 Ceph nodes, leaving disks clean for MinIO or re-deployment.
#
# Usage: bash remove-ceph.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

ssh_srv() {
    local ip=$1; shift
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" "$@"
}

echo "========================================"
echo "Remove Ceph Deployment"
echo "========================================"
echo "Nodes: ${CEPH_SERVERS[*]}"
echo "OSD devices: ${CEPH_OSD_DEVICES[*]}"
echo "========================================"
echo ""

# ——— Pre-flight ———

# 1. Warn if JuiceFS is mounted
if mountpoint -q "${JUICEFS_MOUNT_POINT}" 2>/dev/null; then
    echo "WARNING: JuiceFS is mounted at ${JUICEFS_MOUNT_POINT}."
    echo "  Unmount it first: bash deploy-juicefs.sh unmount"
    echo "  Then destroy:      bash deploy-juicefs.sh destroy"
    echo ""
    read -rp "Continue anyway? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# 2. Verify SSH + sudo on all nodes
for ip in "${CEPH_SERVERS[@]}"; do
    echo -n ">>> Checking ${ip}... "
    if ssh_srv "${ip}" "sudo -n true" 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED (no passwordless sudo)"
        exit 1
    fi
done

PRIMARY="${CEPH_SERVERS[0]}"

echo ""
read -rp "This will STOP Ceph services and WIPE data disks. Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ——— Step 1: Stop RGW ———
echo ""
echo ">>> Step 1: Stopping Ceph RGW service..."
ssh_srv "${PRIMARY}" "
    sudo ceph orch rm rgw.myrgw 2>/dev/null || true
    echo '  RGW removed.'
" 2>/dev/null || true
sleep 10

# ——— Step 2: Stop OSDs and clean disks ———
echo ""
echo ">>> Step 2: Removing OSDs and cleaning data disks..."

for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    dev="${CEPH_OSD_DEVICES[$i]:-}"

    echo ">>> Cleaning ${hostname} (${ip}) / ${dev}..."

    # 2a. Remove OSD daemons for this host
    echo "  Removing OSDs from ${hostname}..."
    ssh_srv "${PRIMARY}" "
        # List OSDs on this host, drain and remove them
        for osd_id in \$(sudo ceph osd tree 2>/dev/null | \
            awk -v h='${hostname}' '\$0~h{found=1; next} found && /osd\\./{print \$2}' | \
            grep -oP 'osd\.\K\d+' || true); do
            echo \"    osd.\${osd_id}: marking out + purge...\"
            sudo ceph osd out osd.\${osd_id} 2>/dev/null || true
            sudo ceph osd purge osd.\${osd_id} --yes-i-really-mean-it 2>/dev/null || true
        done
        sleep 3
    " 2>/dev/null || true
    echo "  OSD removal commands issued."

    # 2b. Clean LVM on the data disk
    if [ -n "${dev}" ]; then
        ssh_srv "${ip}" "
            set -e
            vg_name='ceph-vg-${hostname}'

            # Check if disk is mounted
            if mount | grep -q '^${dev} '; then
                echo '  WARNING: ${dev} is mounted, skipping wipe'
                exit 0
            fi

            # Remove LVs
            if sudo vgs \${vg_name} 2>/dev/null | grep -q \${vg_name}; then
                echo '  Removing LVs in \${vg_name}...'
                sudo lvremove -f \${vg_name} 2>/dev/null || true
                echo '  Removing VG \${vg_name}...'
                sudo vgremove -f \${vg_name} 2>/dev/null || true
            fi

            # Remove PV
            if sudo pvs 2>/dev/null | grep -q '${dev}'; then
                echo '  Removing PV on ${dev}...'
                sudo pvremove -ff -y ${dev} 2>/dev/null || true
            fi

            # Wipe filesystem signatures
            echo '  Wiping ${dev}...'
            sudo wipefs -af ${dev} 2>/dev/null || true

            echo '  Disk ${dev} cleaned.'
        "
    fi
done

# ——— Step 3: Stop MON/MGR (optional, keep by default) ———
echo ""
echo ">>> Step 3: Ceph MON + MGR are kept running (to allow re-deploy)."
echo "    To fully remove Ceph, run: sudo cephadm rm-cluster --fsid <id> --force"

echo ""
echo "========================================"
echo "Ceph services stopped, data disks wiped."
echo "sdb is now clean — ready for MinIO or redeploy."
echo "========================================"
echo ""
echo "To redeploy Ceph:   bash deploy-ceph.sh"
echo "To deploy MinIO:    bash deploy-minio.sh"