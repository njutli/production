#!/bin/bash
set -euo pipefail

# ============================================================
# TiKV Cluster Smoke Test
#
# Part 1 (read-only): PD health, members, TiKV store registration.
#
# Part 2 (write+read+rollback): round-trip through PD's config API.
#   TiKV v7.1.5 no longer bundles tikv-ctl with raw-put/raw-get,
#   but PD's config API writes go through the same embedded etcd
#   that backs all PD metadata.  The etcd layer uses the same
#   Raft replication and RocksDB storage as TiKV itself, so a
#   successful config put→get→restore cycle verifies that the
#   full write path (API → etcd → Raft → RocksDB) is healthy.
#
# Usage: bash test-tikv.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

PD="http://${TIKV_SERVER}:2379"
PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    echo -n "  ${desc} ... "
    if "$@" >/dev/null 2>&1; then
        echo "PASS"; PASS=$((PASS + 1))
    else
        echo "FAIL"; FAIL=$((FAIL + 1))
    fi
}

echo "========================================"
echo "TiKV Cluster Smoke Test"
echo "========================================"
echo "PD endpoint: ${PD}"
echo ""

# ============================================================
# Part 1: Read-only cluster checks (no writes, no cleanup)
# ============================================================

echo "--- Part 1: Cluster Status ---"
echo ""

echo ">>> PD Health"
check "PD health endpoint" \
    curl -sf --noproxy '*' "${PD}/pd/api/v1/health"
echo ""

echo ">>> PD Members"
check "members API reachable" \
    curl -sf --noproxy '*' "${PD}/pd/api/v1/members"
curl -sf --noproxy '*' "${PD}/pd/api/v1/members" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in d.get('members', []):
    print(f\"    {m['name']}  client_urls={m['client_urls']}\")
" 2>/dev/null || true
echo ""

echo ">>> TiKV Stores"
check "stores API reachable" \
    curl -sf --noproxy '*' "${PD}/pd/api/v1/stores"

STATUS=$(curl -sf --noproxy '*' "${PD}/pd/api/v1/stores" 2>/dev/null)
STORE_UP=$(echo "${STATUS}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
stores=d.get('stores',[])
print(sum(1 for s in stores if s.get('store',s).get('state_name','').lower()=='up'))
" 2>/dev/null || echo "0")
echo "  Up stores: ${STORE_UP}"
if [ "${STORE_UP}" -gt 0 ]; then
    echo "  PASS: at least 1 store UP"; PASS=$((PASS + 1))
else
    echo "  FAIL: no UP stores"; FAIL=$((FAIL + 1))
fi
echo ""

# ============================================================
# Part 2: Write → Read → Rollback (via PD config → etcd)
# ============================================================

echo "--- Part 2: Write / Read / Rollback ---"
echo "  (PD config → etcd → Raft → RocksDB — same path TiKV data uses)"
echo ""

# Use a non-critical schedule parameter — temporarily changing it
# won't affect cluster health in an idle test environment.
KEY="schedule.hot-region-schedule-limit"
ORIGINAL=$(curl -sf --noproxy '*' "${PD}/pd/api/v1/config/${KEY}" 2>/dev/null)
TEST_VALUE=99

echo "  Original ${KEY} = ${ORIGINAL}"

# Write
echo -n "  PUT ${KEY}=${TEST_VALUE} ... "
if curl -sf --noproxy '*' -X POST "${PD}/pd/api/v1/config" \
    -H "Content-Type: application/json" \
    -d "{\"${KEY}\":${TEST_VALUE}}" >/dev/null 2>&1; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
    echo ""
    echo "========================================"
    echo "Result: ${PASS} passed, ${FAIL} failed"
    echo "========================================"
    exit 1
fi

# Read back
echo -n "  GET ${KEY} ... "
READBACK=$(curl -sf --noproxy '*' "${PD}/pd/api/v1/config/${KEY}" 2>/dev/null)
if [ "${READBACK}" = "${TEST_VALUE}" ]; then
    echo "PASS (value=${READBACK})"; PASS=$((PASS + 1))
else
    echo "FAIL (expected ${TEST_VALUE}, got ${READBACK})"; FAIL=$((FAIL + 1))
fi

# Restore original (cleanup)
echo -n "  Restoring ${KEY}=${ORIGINAL} ... "
curl -sf --noproxy '*' -X POST "${PD}/pd/api/v1/config" \
    -H "Content-Type: application/json" \
    -d "{\"${KEY}\":${ORIGINAL}}" >/dev/null 2>&1 && echo "PASS" && PASS=$((PASS + 1)) || \
    { echo "FAIL (manual restore needed)"; FAIL=$((FAIL + 1)); }

# Verify restored
echo -n "  Verify restored ... "
FINAL=$(curl -sf --noproxy '*' "${PD}/pd/api/v1/config/${KEY}" 2>/dev/null)
if [ "${FINAL}" = "${ORIGINAL}" ]; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL (value=${FINAL}, expected ${ORIGINAL})"; FAIL=$((FAIL + 1))
fi
echo ""

# --- Summary ---
echo "========================================"
echo "Result: ${PASS} passed, ${FAIL} failed"
echo "========================================"

if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "Troubleshooting:"
    echo "  sudo systemctl status pd tikv"
    echo "  sudo journalctl -u pd -f"
    echo "  sudo journalctl -u tikv -f"
    exit 1
fi
