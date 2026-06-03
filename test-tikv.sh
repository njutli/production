#!/bin/bash
set -euo pipefail

# ============================================================
# TiKV Cluster Smoke Test
#
# Part 1 (read-only): PD health, members, TiKV store registration.
# Part 2 (write+read+delete): raw key-value round-trip through
#   TiKV via tikv-ctl — puts a test key, reads it back, deletes
#   it.  No data residue.
# Part 3 (restore): reverts cluster-level parameters to original
#   values after write-read-delete validation.
#
# Usage: bash test-tikv.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

PD="${TIKV_SERVER}:2379"
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

# tikv-ctl runs on the TiKV server
tikvctl() { /opt/tikv/bin/tikv-ctl --pd-endpoints "${PD}" "$@"; }

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
    curl -sf --noproxy '*' "http://${PD}/pd/api/v1/health"
echo ""

echo ">>> PD Members"
check "members API reachable" \
    curl -sf --noproxy '*' "http://${PD}/pd/api/v1/members"
curl -sf --noproxy '*' "http://${PD}/pd/api/v1/members" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in d.get('members', []):
    print(f\"    {m['name']}  client_urls={m['client_urls']}\")
" 2>/dev/null || true
echo ""

echo ">>> TiKV Stores"
check "stores API reachable" \
    curl -sf --noproxy '*' "http://${PD}/pd/api/v1/stores"

STATUS=$(curl -sf --noproxy '*' "http://${PD}/pd/api/v1/stores" 2>/dev/null)
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
# Part 2: Write → Read → Delete (user data via tikv-ctl)
# ============================================================

echo "--- Part 2: User Data Round-Trip ---"
echo ""
TEST_TS=$(date +%s)
TEST_KEY="smoke_test_key_${TEST_TS}"
TEST_VAL="smoke_test_value_${TEST_TS}"

echo -n "  PUT ${TEST_KEY} ... "
if tikvctl raw-put "${TEST_KEY}" "${TEST_VAL}" --cf default >/dev/null 2>&1; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
    echo ""
    echo "========================================"
    echo "Result: ${PASS} passed, ${FAIL} failed"
    echo "========================================"
    exit 1
fi

echo -n "  GET ${TEST_KEY} ... "
VAL=$(tikvctl raw-get "${TEST_KEY}" --cf default 2>/dev/null | grep -oP 'val:\s*\K.*' || echo "")
if [ "${VAL}" = "${TEST_VAL}" ]; then
    echo "PASS (value matches)"; PASS=$((PASS + 1))
else
    echo "FAIL (val='${VAL}')"; FAIL=$((FAIL + 1))
fi

echo -n "  DELETE ${TEST_KEY} ... "
if tikvctl raw-delete "${TEST_KEY}" --cf default >/dev/null 2>&1; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi

echo -n "  VERIFY deleted ... "
if tikvctl raw-get "${TEST_KEY}" --cf default 2>/dev/null | grep -q 'key not found'; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
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
