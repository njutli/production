#!/bin/bash
set -euo pipefail

# ============================================================
# Prepare All Servers
#
# Runs prepare-servers.sh on the TiKV machine (locally) and on
# all 3 Ceph machines (remotely via SSH).
#
# Prerequisites: setup-ssh-keys.sh already completed
#
# Usage: bash prepare-all-servers.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# --- TiKV (local machine) ---
# Requires sudo; user will be prompted for local password.
echo "========================================"
echo "Preparing TiKV server (local: ${TIKV_SERVER})"
echo "========================================"
echo ""
sudo bash "${SCRIPT_DIR}/prepare-servers.sh" tikv "${TIKV_DATA_DEVICE:-/dev/sdb}"
echo ""

# --- Ceph (remote machines) ---
# Uses ssh -t to allocate a PTY so the remote sudo password prompt
# appears on the terminal.  After this run, NOPASSWD sudo will be
# configured by prepare-servers.sh itself, so subsequent deploy-ceph.sh
# can sudo without interaction.
echo "========================================"
echo "Preparing Ceph servers (remote)"
echo "========================================"
echo ""

for ip in "${CEPH_SERVERS[@]}"; do
    echo ">>> ${ip}"
    echo "    (enter sudo password when prompted on the remote machine)"
    scp ${SSH_OPTS} -i "${SSH_KEY}" \
        "${SCRIPT_DIR}/prepare-servers.sh" \
        "${SSH_USER}@${ip}:/tmp/prepare-servers.sh"
    ssh ${SSH_OPTS} -t -i "${SSH_KEY}" \
        "${SSH_USER}@${ip}" \
        "sudo bash /tmp/prepare-servers.sh ceph"
    echo ""
done

echo "========================================"
echo "All servers prepared."
echo ""
echo "Next: bash production/deploy-tikv.sh"
echo "      bash production/deploy-ceph.sh"
echo "========================================"
