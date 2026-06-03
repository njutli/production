#!/bin/bash
set -euo pipefail

# ============================================================
# TiKV Cluster Smoke Test
#
# Part 1 (read-only): PD health, members, TiKV store status.
# Part 2 (real write/read/delete): compiles and runs a Go
#   program that uses tikv/client-go to do Put, Get, BatchPut,
#   BatchGet, Scan, Delete, BatchDelete — all with real user
#   data through TiKV's RawKV API.  All test keys are deleted
#   before the program exits.
#
# Requires: Go 1.20+ (auto-installs if missing)
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
# Part 1: Read-only cluster checks
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
# Part 2: Real user data round-trip (Go + tikv/client-go)
# ============================================================

echo "--- Part 2: RawKV Data Test (Go) ---"
echo ""

# Ensure Go is available
if ! command -v go &>/dev/null; then
    echo ">>> Installing Go..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq golang-go 2>/dev/null || {
        echo "  ERROR: failed to install Go"
        exit 1
    }
fi
echo "Go: $(go version 2>&1)"

# Build test program
echo ">>> Building test..."
cd "${SCRIPT_DIR}/tests"
go mod tidy 2>&1 | tail -3 || { echo "  ERROR: go mod tidy failed (network issue?)"; exit 1; }

BIN="/tmp/tikv-smoke-test-$$"
go build -o "${BIN}" tikv-test.go || { echo "  ERROR: build failed"; exit 1; }
echo "  Binary: ${BIN}"

# Run test — unset proxy so gRPC connects directly to PD
echo ""
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
if "${BIN}"; then
    PASS=$((PASS + 4))  # the 4 internal tests in Go: Put/Get, Batch, Scan, Delete
else
    FAIL=$((FAIL + 4))
fi

# Cleanup binary
rm -f "${BIN}"
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
