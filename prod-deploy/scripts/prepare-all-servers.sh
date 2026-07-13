#!/bin/bash
set -euo pipefail

# ============================================================
# Prepare All Servers
#
# Runs prepare-servers.sh on all nodes via three-level jump host:
#   WSL → HK ECS → 157 → slaves
#
# 157 (client):   role=client  (nvme1n1 → cache mount)
# 150-152 (slaves): role=tikv  (nvme1n1 → TiKV mount, clean old mounts)
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
ssh_to_client "sudo bash -c '
    set -e
    # Inline prepare for 157 (role=client)
    export SSH_USER=${SSH_USER}
    apt-get update -qq || true
    command -v chronyd &>/dev/null || command -v ntpd &>/dev/null || systemctl is-active systemd-timesyncd &>/dev/null || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y chrony 2>/dev/null || true

    # NOPASSWD sudo (already set, verify)
    grep -q \"^${SSH_USER} ALL=(ALL) NOPASSWD:ALL\" /etc/sudoers.d/${SSH_USER} 2>/dev/null || \
        echo \"${SSH_USER} ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/${SSH_USER}

    # Packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar fio htop iotop sysstat 2>/dev/null || true

    # Mount nvme1n1 for cache
    DEV=/dev/nvme1n1
    MNT=/mnt/jfs-cache
    if [ -b \$DEV ]; then
        cur_fs=\$(blkid -s TYPE -o value \$DEV 2>/dev/null || echo \"\")
        [ \"\$cur_fs\" != \"ext4\" ] && mkfs.ext4 -F \$DEV
        if ! mountpoint -q \$MNT 2>/dev/null; then
            mkdir -p \$MNT
            mount -o defaults,noatime \$DEV \$MNT
            uuid=\$(blkid -s UUID -o value \$DEV 2>/dev/null || echo \"\")
            [ -n \"\$uuid\" ] && ! grep -q \" \$MNT \" /etc/fstab 2>/dev/null && \
                echo \"UUID=\$uuid \$MNT ext4 defaults,noatime 0 2\" >> /etc/fstab
        fi
    fi

    # fd limits
    cat > /etc/security/limits.d/99-juicefs.conf <<EOF2
root    soft    nofile  1000000
root    hard    nofile  1000000
*       soft    nofile  1000000
*       hard    nofile  1000000
EOF2

    echo DONE_157
'" 2>/dev/null | grep -q "DONE_157" && echo "  157 prepared." || echo "  157 prepare FAILED (check output)"

# --- Slaves (150-152) ---
for ip in "${SLAVE_SERVERS[@]}"; do
    echo ""
    echo "========================================"
    echo "Preparing slave ${ip}"
    echo "========================================"
    echo ""

    # Copy prepare-servers.sh to the slave
    scp_to "${SCRIPT_DIR}/prepare-servers.sh" "${ip}" "/tmp/prepare-servers.sh"

    # Run it with role=tikv (TiKV+PD data + Ceph prerequisites)
    ssh_to_slave "${ip}" "sudo bash /tmp/prepare-servers.sh tikv" 2>/dev/null || \
        echo "  (prepare had warnings, continuing)"
done

echo ""
echo "========================================"
echo "All servers prepared."
echo ""
echo "Next: bash scripts/deploy-tikv.sh"
echo "      bash scripts/deploy-ceph.sh"
echo "========================================"
