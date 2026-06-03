#!/bin/bash
set -euo pipefail

# ============================================================
# TiKV Cluster Smoke Test
#
# Verifies PD health, member list, and TiKV store registration
# via the PD HTTP API.  No data is written to TiKV — purely
# read-only cluster status checks.
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

echo "========================================"
echo "TiKV Cluster Smoke Test"
echo "========================================"
echo "PD endpoint: ${PD}"
echo ""

# --- 1. PD health ---
echo ">>> PD Health"
check "PD health endpoint" \
    curl -sf --noproxy '*' "http://${PD}/pd/api/v1/health"
echo ""

# --- 2. PD members ---
echo ">>> PD Members"
check "PD members API reachable" \
    curl -sf --noproxy '*' "http://${PD}/pd/api/v1/members"
echo "  Members:" 
curl -sf --noproxy '*' "http://${PD}/pd/api/v1/members" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in d.get('members', []):
    print(f\"    {m['name']}  client_urls={m['client_urls']}\")
" 2>/dev/null || echo "    (unable to parse)"
echo ""

# --- 3. TiKV stores ---
echo ">>> TiKV Stores"
check "Stores API reachable" \
    curl -sf --noproxy '*' "http://${PD}/pd/api/v1/stores"

STORE_COUNT=$(curl -sf --noproxy '*' "http://${PD}/pd/api/v1/stores" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
count=sum(1 for s in d.get('stores',[])) if 'count' not in d else d['count']
print(count)
" 2>/dev/null || echo "0")

echo "  Store count: ${STORE_COUNT}"

if [ "${STORE_COUNT}" -gt 0 ]; then
    PASS=$((PASS + 1))
else
    echo "  FAIL: no stores registered"
    FAIL=$((FAIL + 1))
fi
echo ""

# --- 4. Store details ---
echo ">>> Store Details"
curl -sf --noproxy '*' "http://${PD}/pd/api/v1/stores" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
stores=d.get('stores',[])
for s in stores:
    store=s.get('store',s)
    addr=store.get('address','?')
    state=store.get('state_name','?')
    labels=store.get('labels',{})
    free=''
    if 'available' in store:
        free=store.get('available','?')
    print(f\"    {addr}  state={state}  labels={labels}  capacity_free={free}\")
" 2>/dev/null || true
echo ""

# --- Summary ---
echo "========================================"
echo "Result: ${PASS} passed, ${FAIL} failed"
echo "========================================"

if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "Troubleshooting:"
    echo "  ssh turboai@${TIKV_SERVER} sudo systemctl status pd tikv"
    echo "  ssh turboai@${TIKV_SERVER} sudo journalctl -u pd -f"
    echo "  ssh turboai@${TIKV_SERVER} sudo journalctl -u tikv -f"
    exit 1
fi
