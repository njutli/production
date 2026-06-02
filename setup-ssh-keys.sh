#!/bin/bash
set -euo pipefail

# ============================================================
# SSH Key Setup for 4-Machine Production Deployment
#
# Generates (if needed) an ED25519 key pair and copies the
# public key to all target servers so subsequent deployment
# scripts can SSH without password prompts.
#
# Run once from the deployment control machine.
# You will be prompted for each server's password ONCE.
#
# Usage: bash setup-ssh-keys.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

KEY_FILE="${SSH_KEY}"

# ============================================================
# Step 1: Generate SSH key if missing
# ============================================================

echo "========================================"
echo "SSH Key Setup for Deployment"
echo "========================================"
echo ""

if [ -f "${KEY_FILE}" ]; then
    echo "[skip] SSH key already exists: ${KEY_FILE}"
else
    echo ">>> Generating ED25519 key pair..."
    ssh-keygen -t ed25519 -f "${KEY_FILE}" -N "" -C "deploy-control-$(date +%Y%m%d)"
    echo "   Created: ${KEY_FILE}"
    echo "   Created: ${KEY_FILE}.pub"
fi

echo ""
echo "Public key:"
cat "${KEY_FILE}.pub"
echo ""

# ============================================================
# Step 2: Copy key to target servers
# ============================================================
# TiKV is deployed locally on this machine — deploy-tikv.sh uses sudo,
# no SSH needed.  Only Ceph servers require key distribution.

echo ">>> TiKV server (${TIKV_SERVER}) is on the local machine."
echo "    deploy-tikv.sh uses sudo, no SSH key needed for TiKV."
echo ""

# ============================================================
# Step 3: Copy key to Ceph servers
# ============================================================

for ip in "${CEPH_SERVERS[@]}"; do
    echo "========================================"
    echo ">>> Copying SSH key to ${SSH_USER}@${ip}"
    echo "    (you will be asked for the password once)"
    echo "========================================"
    ssh-copy-id -i "${KEY_FILE}.pub" "${SSH_USER}@${ip}" || {
        echo ""
        echo "ERROR: ssh-copy-id failed for ${ip}."
        echo "  Check that:"
        echo "    1. The server is reachable:  ping ${ip}"
        echo "    2. Password authentication is enabled in /etc/ssh/sshd_config"
        echo "    3. The user '${SSH_USER}' and password are correct"
        exit 1
    }
    echo "   Key installed on ${ip}."
    echo ""
done

# ============================================================
# Step 4: Verify
# ============================================================

echo "========================================"
echo "Verifying SSH access..."
echo "========================================"

all_ok=true
for ip in "${CEPH_SERVERS[@]}"; do
    echo -n "  ${SSH_USER}@${ip}: "
    if ssh ${SSH_OPTS} -i "${KEY_FILE}" -o BatchMode=yes "${SSH_USER}@${ip}" "echo OK" 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
        all_ok=false
    fi
done

echo ""
if ${all_ok}; then
    echo "All servers are accessible without password."
    echo ""
    echo "Next: bash deploy-tikv.sh && bash deploy-ceph.sh"
else
    echo "Some servers still require a password. Re-run this script or check manually."
    exit 1
fi
