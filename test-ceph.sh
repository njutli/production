#!/bin/bash
set -euo pipefail

# ============================================================
# Ceph Cluster Smoke Test
#
# Verifies MON quorum, OSD tree, and RGW S3 API.  Creates a
# temporary RGW user + test bucket, then cleans up everything so
# no data residue remains.  Installs awscli temporarily for S3
# operations (removed afterwards if it wasn't already installed).
#
# Usage: bash test-ceph.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

PRIMARY="${CEPH_SERVERS[0]}"
# 冒烟测试要直接验证某个具体 RGW（PRIMARY）的 S3 读写删，故意直连它、
# 不走 config.sh 的 RGW_ENDPOINT（多 RGW 时那是 LB 地址）。用独立变量名，
# 避免覆盖 config.sh 的全局 RGW_ENDPOINT 造成混淆。
RGW_TEST_ENDPOINT="http://${PRIMARY}:8000"
PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT
HAD_AWSCLI=false

# --- helpers ---
ssh_srv() { ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${PRIMARY}" "$@"; }

check() {
    local desc="$1"; shift
    echo -n "  ${desc} ... "
    if "$@" >/dev/null 2>&1; then
        echo "PASS"; PASS=$((PASS + 1))
    else
        echo "FAIL"; FAIL=$((FAIL + 1))
    fi
}

cleanup_test_user() {
    local uid="$1"
    ssh_srv "sudo radosgw-admin user remove --uid=${uid} --purge-data 2>/dev/null" || true
}

install_awscli() {
    if command -v aws &>/dev/null; then
        HAD_AWSCLI=true
        return 0
    fi
    echo "  (installing awscli temporarily for S3 test)"
    pip3 install --quiet awscli 2>/dev/null && return 0
    # Fallback: apt
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq awscli 2>/dev/null && return 0
    echo "  FAIL: could not install awscli"; return 1
}

remove_awscli() {
    if ${HAD_AWSCLI}; then return 0; fi
    pip3 uninstall -y awscli 2>/dev/null || true
    sudo apt-get remove -y -qq awscli 2>/dev/null || true
}

echo "========================================"
echo "Ceph Cluster Smoke Test"
echo "========================================"
echo "Primary: ${PRIMARY}"
echo "RGW:     ${RGW_TEST_ENDPOINT}"
echo ""

# --- 1. MON quorum ---
echo ">>> MON Quorum"
check "ceph status" \
    ssh_srv "sudo cephadm shell -- ceph status 2>/dev/null | grep -q 'HEALTH_'"
ssh_srv "sudo cephadm shell -- ceph status 2>/dev/null" | grep -E 'health|mon:|osd:' || true
echo ""

# --- 2. OSD tree ---
echo ">>> OSD Tree"
OSD_COUNT=$(ssh_srv "sudo cephadm shell -- ceph osd stat 2>/dev/null" | grep -oP '\d+(?= osds)' || echo "0")
echo "  Count: ${OSD_COUNT}"

if [ "${OSD_COUNT}" -ge 3 ]; then
    echo "  PASS: Sufficient OSDs for EC 4+2"; PASS=$((PASS + 1))
else
    echo "  WARNING: < 3 OSDs"; FAIL=$((FAIL + 1))
fi
ssh_srv "sudo cephadm shell -- ceph osd tree 2>/dev/null" | head -12 || true
echo ""

# --- 3. RGW pools ---
echo ">>> RGW Pool"
check "default.rgw.buckets.data pool exists" \
    ssh_srv "sudo cephadm shell -- ceph osd pool ls 2>/dev/null | grep -q 'default.rgw.buckets.data'"
echo ""

# --- 4. RGW S3 API ---
echo ">>> RGW S3 API Test"
TEST_UID="smoke-test-$$"

if ! install_awscli; then exit 1; fi

echo "  Creating temporary S3 user (${TEST_UID})..."
USER_JSON=$(ssh_srv "
    sudo radosgw-admin user create \
        --uid=${TEST_UID} \
        --display-name='Smoke Test' \
        2>/dev/null
" 2>/dev/null)

if [ -z "${USER_JSON:-}" ]; then
    echo "  FAIL: could not create RGW user"; FAIL=$((FAIL + 1))
else
    AK=$(echo "${USER_JSON}" | grep -o '"access_key": *"[^"]*"' | cut -d'"' -f4)
    SK=$(echo "${USER_JSON}" | grep -o '"secret_key": *"[^"]*"' | cut -d'"' -f4)

    if [ -z "${AK:-}" ] || [ -z "${SK:-}" ]; then
        echo "  FAIL: could not extract credentials"; FAIL=$((FAIL + 1))
    else
        cat > "${TMPDIR}/aws.config" <<EOF
[default]
aws_access_key_id = ${AK}
aws_secret_access_key = ${SK}
EOF
        export AWS_CONFIG_FILE="${TMPDIR}/aws.config"
        export AWS_DEFAULT_REGION=""

        TEST_BUCKET="smoke-test-bucket-$$"
        AWS="aws --endpoint-url=${RGW_TEST_ENDPOINT} --no-verify-ssl"

        # Create bucket
        check "bucket creation" \
            bash -c "${AWS} s3 mb s3://${TEST_BUCKET} 2>/dev/null"

        # Put object
        echo "ceph rgw smoke test $(date)" > "${TMPDIR}/test.txt"
        check "object write" \
            bash -c "${AWS} s3 cp ${TMPDIR}/test.txt s3://${TEST_BUCKET}/test.txt 2>/dev/null"

        # Get object + verify
        ${AWS} s3 cp "s3://${TEST_BUCKET}/test.txt" "${TMPDIR}/downloaded.txt" 2>/dev/null
        if grep -q "ceph rgw smoke test" "${TMPDIR}/downloaded.txt" 2>/dev/null; then
            echo "  PASS: object read + content verified"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: object read"; FAIL=$((FAIL + 1))
        fi

        # List
        check "bucket listing" \
            bash -c "${AWS} s3 ls s3://${TEST_BUCKET}/ 2>/dev/null | grep -q test.txt"

        # --- Cleanup ---
        echo ""
        echo ">>> Cleanup"
        echo -n "  Deleting test data..."
        ${AWS} s3 rm "s3://${TEST_BUCKET}/test.txt" 2>/dev/null || true
        ${AWS} s3 rb "s3://${TEST_BUCKET}" --force 2>/dev/null || true
        cleanup_test_user "${TEST_UID}"
        remove_awscli
        echo " done"
    fi
fi
echo ""

# --- Summary ---
echo "========================================"
echo "Result: ${PASS} passed, ${FAIL} failed"
echo "========================================"

if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "Troubleshooting:"
    echo "  ssh ${SSH_USER}@${PRIMARY} 'sudo cephadm shell -- ceph status'"
    echo "  ssh ${SSH_USER}@${PRIMARY} 'sudo cephadm shell -- ceph osd tree'"
    exit 1
fi
