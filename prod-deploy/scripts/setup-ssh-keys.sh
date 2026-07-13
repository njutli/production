#!/bin/bash
set -euo pipefail

# ============================================================
# SSH Key Verification
#
# SSH 密钥已建立（157 → slaves）。
# 本脚本仅验证跳板 SSH 链路是否通畅，不重复分发密钥。
#
# 路径：WSL → HK ECS (190.92.233.189) → 157 (203.156.3.194:19891) → slaves
#
# Usage: bash setup-ssh-keys.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

echo "========================================"
echo "SSH Verification (three-level jump host)"
echo "========================================"
echo ""

# 1. Verify HK ECS reachable
echo ">>> [1/3] HK ECS (${HK_ECS})..."
if sshpass -p "${HK_ECS_PASSWORD}" ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" "echo OK" 2>/dev/null; then
    echo "  HK ECS: reachable"
else
    echo "  HK ECS: UNREACHABLE"
    exit 1
fi

# 2. Verify 157 reachable via HK ECS
echo ""
echo ">>> [2/3] Client 157 (${CLIENT_EXT}:${CLIENT_PORT}) via HK ECS..."
if ssh_to_client "echo OK" 2>/dev/null | grep -q "OK"; then
    echo "  157: reachable"
else
    echo "  157: UNREACHABLE"
    exit 1
fi

# 3. Verify slaves reachable via 157
echo ""
echo ">>> [3/3] Slaves (150-152) via 157..."
all_ok=true
for ip in "${SLAVE_SERVERS[@]}"; do
    echo -n "  ${ip}: "
    if ssh_to_slave "${ip}" "echo OK" 2>/dev/null | grep -q "OK"; then
        echo "reachable"
    else
        echo "UNREACHABLE"
        all_ok=false
    fi
done

echo ""
if ${all_ok}; then
    echo "========================================"
    echo "All nodes reachable via three-level jump host."
    echo "========================================"
    echo ""
    echo "Next: bash scripts/prepare-all-servers.sh"
else
    echo "Some nodes unreachable. Check:"
    echo "  1. HK ECS password: ${HK_ECS_PASSWORD}"
    echo "  2. 157 SSH: sshpass -p '${SSH_PASSWORD}' ssh -p ${CLIENT_PORT} ${SSH_USER}@${CLIENT_EXT}"
    echo "  3. 157 → slave: sshpass -p '${SSH_PASSWORD}' ssh ${SSH_USER}@10.20.1.150"
    exit 1
fi
