#!/bin/bash
set -euo pipefail

# ============================================================
# TiKV Cluster Smoke Test (3-node)
#
# Part 1: PD health, members, stores (via _run on node 0)
# Part 2: Go RawKV read/write/delete (compile + run on PRIMARY)
#
# Usage: bash test-tikv.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

FIRST="${TIKV_SERVERS[0]}"
PD="http://${FIRST}:2379"

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
echo "TiKV Cluster Smoke Test (3-node)"
echo "========================================"
echo "PD endpoint: ${PD}"
echo ""

# ============================================================
# Part 1: PD health, members, stores
# ============================================================

echo "--- Part 1: Cluster Status ---"
echo ""

echo ">>> PD Health"
echo -n "  PD health... "
result=$(_run "${FIRST}" "curl -s --noproxy '*' '${PD}/pd/api/v1/health' 2>/dev/null" 2>/dev/null || echo "")
if echo "${result}" | grep -q '"health"'; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi

echo ""
echo ">>> PD Members"
echo -n "  members API... "
result=$(_run "${FIRST}" "curl -s --noproxy '*' '${PD}/pd/api/v1/members' 2>/dev/null" 2>/dev/null || echo "")
if echo "${result}" | grep -q "members"; then
    echo "PASS"; PASS=$((PASS + 1))
    echo "${result}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in d.get('members', []):
    print(f\"    {m['name']}  client_urls={m.get('client_urls','?')}\")
" 2>/dev/null || true
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi

echo ""
echo ">>> TiKV Stores"
echo -n "  stores API... "
result=$(_run "${FIRST}" "curl -s --noproxy '*' '${PD}/pd/api/v1/stores' 2>/dev/null" 2>/dev/null || echo "")
STORE_UP=$(echo "${result}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
stores=d.get('stores',[])
print(sum(1 for s in stores if s.get('store',s).get('state_name','').lower()=='up'))
" 2>/dev/null || echo "0")
echo "  Up stores: ${STORE_UP} (expected 3)"
if [ "${STORE_UP}" -ge 3 ]; then
    echo "  PASS: 3 stores UP"; PASS=$((PASS + 1))
else
    echo "  FAIL: < 3 stores"; FAIL=$((FAIL + 1))
fi

# ============================================================
# Part 2: Go RawKV test (on PRIMARY node)
# ============================================================

echo ""
echo "--- Part 2: RawKV Data Test (Go) ---"
echo ""

# Copy Go test to PRIMARY and run
TEST_DIR="/home/${SSH_USER}/tikv-test"
_run "${FIRST}" "mkdir -p ${TEST_DIR}" 2>/dev/null || true
scp_to "${SCRIPT_DIR}/tests/tikv-test.go" "${FIRST}" "${TEST_DIR}/tikv-test.go"
scp_to "${SCRIPT_DIR}/tests/go.mod" "${FIRST}" "${TEST_DIR}/go.mod"
[ -f "${SCRIPT_DIR}/tests/go.sum" ] && scp_to "${SCRIPT_DIR}/tests/go.sum" "${FIRST}" "${TEST_DIR}/go.sum" || true

result=$(_run "${FIRST}" "
    mkdir -p ${TEST_DIR}
    cd ${TEST_DIR}
    # Ensure Go is available
    command -v go &>/dev/null || {
        echo '  Installing Go...'
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq golang-go 2>/dev/null || {
            echo '  ERROR: Go not available'; exit 1
        }
    }
    echo 'Go: '\$(go version 2>&1)

    # Build
    echo 'Building test...'
    go mod tidy 2>&1 | tail -2 || true
    go build -o ${TEST_DIR}/tikv-smoke tikv-test.go 2>&1 || { echo '  ERROR: build failed'; exit 1; }

    # Run
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    PD_ADDR='${FIRST}:2379' ${TEST_DIR}/tikv-smoke; rc=\$?
    rm -f ${TEST_DIR}/tikv-smoke
    exit \$rc
" 2>/dev/null || echo "FAIL")

if echo "${result}" | grep -q "PASS\|OK\|done"; then
    PASS=$((PASS + 4))
    echo "${result}" | sed 's/^/    /'
else
    FAIL=$((FAIL + 4))
    echo "  RawKV test failed"
    echo "${result}" | sed 's/^/    /'
fi

echo ""
echo "========================================"
echo "Result: ${PASS} passed, ${FAIL} failed"
echo "========================================"

[ "${FAIL}" -eq 0 ] || exit 1
