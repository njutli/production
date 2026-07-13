#!/bin/bash
set -euo pipefail

# ============================================================
# Ceph Cluster Smoke Test (NO RGW, direct RADOS)
#
# Checks: MON quorum, OSD tree, EC pool, cephx client.juicefs,
#         direct RADOS read/write (JuiceFS data path).
#
# All commands run on PRIMARY via _run (three-level jump host).
#
# Usage: bash test-ceph.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

PRIMARY="${CEPH_PRIMARY}"
PASS=0
FAIL=0

echo "========================================"
echo "Ceph Cluster Smoke Test (NO RGW — direct RADOS)"
echo "========================================"
echo "Primary: ${PRIMARY}"
echo "Pool:    ${CEPH_POOL_NAME}"
echo "Cephx:   ${CEPHX_CLIENT}"
echo ""

# --- 1. MON quorum + health ---
echo ">>> MON Quorum / Health"
echo -n "  ceph health... "
result=$(_run "${PRIMARY}" "sudo cephadm shell -- ceph health 2>/dev/null" 2>/dev/null || echo "FAIL")
if echo "${result}" | grep -q "HEALTH_OK\|HEALTH_WARN"; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL (${result})"; FAIL=$((FAIL + 1))
fi
_run "${PRIMARY}" "sudo cephadm shell -- ceph status 2>/dev/null" 2>/dev/null | grep -E 'health|mon:|osd:' || true
echo ""

# --- 2. OSD tree ---
echo ">>> OSD Tree"
OSD_COUNT=$(_run "${PRIMARY}" "sudo cephadm shell -- ceph osd stat 2>/dev/null" 2>/dev/null | grep -oP '\d+(?= osds)' || echo "0")
echo "  Count: ${OSD_COUNT} (expected 6)"
if [ "${OSD_COUNT}" -ge 6 ]; then
    echo "  PASS"; PASS=$((PASS + 1))
else
    echo "  FAIL"; FAIL=$((FAIL + 1))
fi
_run "${PRIMARY}" "sudo cephadm shell -- ceph osd tree 2>/dev/null" 2>/dev/null | head -15 || true
echo ""

# --- 3. EC pool ---
echo ">>> EC Pool (${CEPH_POOL_NAME})"
echo -n "  pool exists... "
if _run "${PRIMARY}" "sudo cephadm shell -- ceph osd pool ls 2>/dev/null | grep -q '^${CEPH_POOL_NAME}\$'" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi

echo -n "  allow_ec_overwrites=true... "
if _run "${PRIMARY}" "sudo cephadm shell -- ceph osd pool get ${CEPH_POOL_NAME} allow_ec_overwrites 2>/dev/null | grep -q 'true'" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi
echo ""

# --- 4. cephx client.juicefs ---
echo ">>> Cephx user (${CEPHX_CLIENT})"
echo -n "  client.juicefs exists... "
if _run "${PRIMARY}" "sudo cephadm shell -- ceph auth get ${CEPHX_CLIENT} 2>/dev/null | grep -q '${CEPHX_CLIENT}'" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi
echo ""

# --- 5. Direct RADOS read/write ---
echo ">>> Direct RADOS read/write (${CEPH_POOL_NAME}, JuiceFS data path)"
TEST_OBJ="smoke-test-$$"
TEST_PAYLOAD="ceph direct rados smoke $(date +%s)"

echo -n "  rados put... "
if _run "${PRIMARY}" "echo '${TEST_PAYLOAD}' | sudo cephadm shell -- rados -p ${CEPH_POOL_NAME} put ${TEST_OBJ} /dev/stdin 2>/dev/null" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi

echo -n "  rados get + verify... "
GET_OUT=$(_run "${PRIMARY}" "sudo cephadm shell -- rados -p ${CEPH_POOL_NAME} get ${TEST_OBJ} /dev/stdout 2>/dev/null" 2>/dev/null || echo "")
if echo "${GET_OUT}" | grep -q "${TEST_PAYLOAD}"; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi

_run "${PRIMARY}" "sudo cephadm shell -- rados -p ${CEPH_POOL_NAME} rm ${TEST_OBJ} 2>/dev/null" >/dev/null 2>&1 || true
echo ""

# --- Summary ---
echo "========================================"
echo "Result: ${PASS} passed, ${FAIL} failed"
echo "========================================"

[ "${FAIL}" -eq 0 ] || exit 1
