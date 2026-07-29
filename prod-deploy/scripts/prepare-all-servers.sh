#!/bin/bash
set -euo pipefail

# ============================================================
# Prepare All Servers
#
# Runs prepare-servers.sh on all nodes via three-level jump host:
#   WSL → HK ECS → 157 → slaves
#
# 157 (client):   role=client  (nvme1n1 → /mnt/jfs-cache)
# 150-152 (slaves): role=slave  (TiKV data + Ceph OSD, all in one)
#
# Prerequisites: config.sh SSH functions work (HK ECS reachable)
#
# Usage: bash prepare-all-servers.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

# --- 157 (client) ---
echo "========================================"
echo "Preparing client (${CLIENT_SERVER})"
echo "========================================"
echo ""

scp_to "${SCRIPT_DIR}/prepare-servers.sh" "${CLIENT_SERVER}" "/home/sunrise/prepare-servers.sh"
ssh_to_client "sudo SSH_USER=${SSH_USER} bash /home/sunrise/prepare-servers.sh client" 2>/dev/null || \
    echo "  157 prepare had warnings (continuing)"

# --- Slaves (150-152) ---
for ip in "${SLAVE_SERVERS[@]}"; do
    echo ""
    echo "========================================"
    echo "Preparing slave ${ip}"
    echo "========================================"
    echo ""

    scp_to "${SCRIPT_DIR}/prepare-servers.sh" "${ip}" "/home/sunrise/prepare-servers.sh"
    ssh_to_slave "${ip}" \
        "sudo SSH_USER=${SSH_USER} CEPH_DB_WAL_TMPFS=${CEPH_DB_WAL_TMPFS} CEPH_DB_WAL_MOUNT=${CEPH_DB_WAL_MOUNT} CEPH_DB_WAL_TMPFS_SIZE=${CEPH_DB_WAL_TMPFS_SIZE} bash /home/sunrise/prepare-servers.sh slave" \
        2>/dev/null || echo "  ${ip} prepare had warnings (continuing)"
done

echo ""
echo "========================================"
echo "All servers prepared."
echo ""
echo "Next: bash scripts/deploy-tikv.sh"
echo "      bash scripts/deploy-ceph.sh"
echo "========================================"
