#!/bin/bash
set -euo pipefail

# ============================================================
# JuiceFS Client Deployment (4-Machine Topology)
#
# Installs JuiceFS client and formats/mounts a filesystem
# backed by TiKV single-node (metadata) + Ceph 3-node RGW (data).
#
# Client placement strategy:
#   Data-heavy tests   → run on ${TIKV_SERVER} (set JUICEFS_CLIENT in config.sh)
#   Metadata-heavy tests → run on one CEPH_SERVERS (change JUICEFS_CLIENT)
# This deliberately co-locates client with the layer NOT under test
# so resource contention doesn't mask the bottleneck.
#
# Prerequisites:
#   1. deploy-tikv.sh completed
#   2. deploy-ceph.sh completed
#   3. RGW credentials available from .credentials/rgw-juicefs.env
#
# Usage: bash deploy-juicefs.sh [status|format|mount|unmount|destroy|test]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"

# Load RGW credentials if available
CREDS_FILE="${SCRIPT_DIR}/.credentials/rgw-juicefs.env"
if [ -f "${CREDS_FILE}" ]; then
    source "${CREDS_FILE}"
fi

ACTION="${1:-status}"

METADATA_URL="tikv://${PD_ENDPOINTS}/${JUICEFS_FS_NAME}"
BUCKET_URL="${RGW_ENDPOINT}/${JUICEFS_FS_NAME}"

# ============================================================
# Pre-flight
# ============================================================

check_tikv() {
    echo -n "Checking TiKV PD... "
    if curl -s --noproxy '*' --connect-timeout 5 "http://${TIKV_SERVER}:2379/pd/api/v1/health" 2>/dev/null | grep -q '"health"'; then
        echo "OK"
        return 0
    fi
    echo "UNREACHABLE"
    return 1
}

check_rgw() {
    echo -n "Checking Ceph RGW... "
    if curl -s --noproxy '*' --connect-timeout 5 "${RGW_ENDPOINT}" >/dev/null 2>&1; then
        echo "OK"
        return 0
    fi
    echo "UNREACHABLE"
    return 1
}

install_juicefs() {
    if command -v juicefs &>/dev/null; then
        echo "JuiceFS: $(juicefs version 2>&1 | head -1)"
        return 0
    fi
    echo ">>> Installing JuiceFS..."
    curl -sSL https://d.juicefs.com/install | sh -
    hash -r
}

# ============================================================
# Commands
# ============================================================

do_status() {
    echo "========================================"
    echo "JuiceFS Production Status"
    echo "========================================"
    echo ""
    echo "Configuration:"
    echo "  Filesystem:    ${JUICEFS_FS_NAME}"
    echo "  Metadata URL:  ${METADATA_URL}"
    echo "  Data bucket:   ${BUCKET_URL}"
    echo "  Mount point:   ${JUICEFS_MOUNT_POINT}"
    echo ""
    check_tikv
    check_rgw
    echo ""

    install_juicefs

    echo ""
    echo "Filesystem Info:"
    juicefs status "${METADATA_URL}" 2>&1 || echo "  Filesystem not yet formatted."
    echo ""

    if mountpoint -q "${JUICEFS_MOUNT_POINT}" 2>/dev/null; then
        echo "Mount: ${JUICEFS_MOUNT_POINT} is MOUNTED"
        df -h "${JUICEFS_MOUNT_POINT}"
    else
        echo "Mount: ${JUICEFS_MOUNT_POINT} is NOT mounted"
    fi
}

do_format() {
    echo "========================================"
    echo "Formatting JuiceFS Filesystem"
    echo "========================================"
    echo "  Metadata: ${METADATA_URL}"
    echo "  Data:     ${BUCKET_URL}"
    echo ""

    check_tikv || { echo "ERROR: TiKV PD not reachable."; exit 1; }
    check_rgw || { echo "ERROR: Ceph RGW not reachable."; exit 1; }
    install_juicefs

    # Check if already formatted
    if juicefs status "${METADATA_URL}" >/dev/null 2>&1; then
        echo "Filesystem already formatted."
        echo "To re-format, destroy it first: bash deploy-juicefs.sh destroy"
        exit 0
    fi

    # Check credentials
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        echo "ERROR: RGW credentials not set."
        echo "  Source them: source ${CREDS_FILE}"
        echo "  Or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env vars."
        exit 1
    fi

    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    export AWS_DEFAULT_REGION=""

    # Pre-create S3 bucket (RGW may reject JuiceFS auto-create with region errors)
    echo "Creating S3 bucket '${JUICEFS_FS_NAME}'..."
    if command -v aws &>/dev/null; then
        aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl \
            s3 mb "s3://${JUICEFS_FS_NAME}" 2>/dev/null || true
    elif command -v s3cmd &>/dev/null; then
        s3cmd --host="${RGW_ENDPOINT}" --no-ssl mb "s3://${JUICEFS_FS_NAME}" 2>/dev/null || true
    else
        echo "WARNING: awscli or s3cmd not installed, cannot pre-create bucket."
        echo "  JuiceFS will try to auto-create it (may fail on some RGW versions)."
    fi

    echo ""
    echo ">>> Running juicefs format..."
    # Use --trash-days 1 for auto-cleanup; production may want 7 or 30
    juicefs format \
        --storage s3 \
        --bucket "${BUCKET_URL}" \
        --access-key "${AWS_ACCESS_KEY_ID}" \
        --secret-key "${AWS_SECRET_ACCESS_KEY}" \
        --trash-days 1 \
        "${METADATA_URL}" \
        "${JUICEFS_FS_NAME}"

    echo ""
    echo "Format complete!"
    echo "  Metadata: ${METADATA_URL}"
}

do_mount() {
    echo "========================================"
    echo "Mounting JuiceFS Filesystem"
    echo "========================================"

    if mountpoint -q "${JUICEFS_MOUNT_POINT}" 2>/dev/null; then
        echo "Already mounted at ${JUICEFS_MOUNT_POINT}"
        exit 0
    fi

    install_juicefs

    # Unset proxy (JuiceFS Go client connects directly to TiKV PD)
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

    mkdir -p "${JUICEFS_MOUNT_POINT}"

    echo "Mounting ${METADATA_URL} -> ${JUICEFS_MOUNT_POINT}..."
    juicefs mount -d "${METADATA_URL}" "${JUICEFS_MOUNT_POINT}"

    sleep 3

    if mountpoint -q "${JUICEFS_MOUNT_POINT}"; then
        echo "Mounted successfully!"
        df -h "${JUICEFS_MOUNT_POINT}"
    else
        echo "ERROR: Mount failed. Check logs:"
        echo "  juicefs log ${JUICEFS_MOUNT_POINT}"
        exit 1
    fi
}

do_unmount() {
    echo ">>> Unmounting ${JUICEFS_MOUNT_POINT}..."
    if mountpoint -q "${JUICEFS_MOUNT_POINT}" 2>/dev/null; then
        fusermount -u "${JUICEFS_MOUNT_POINT}" 2>/dev/null || umount "${JUICEFS_MOUNT_POINT}"
        echo "Unmounted."
    else
        echo "Not mounted."
    fi
}

do_destroy() {
    echo "========================================"
    echo "!!! DANGER: Destroying JuiceFS Filesystem !!!"
    echo "  ${METADATA_URL}"
    echo "========================================"
    echo ""

    do_unmount 2>/dev/null || true

    read -rp "Type 'DESTROY' to confirm: " confirm
    if [ "${confirm}" != "DESTROY" ]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "Choose what to delete:"
    echo "  1) Metadata only (TiKV) — S3 data in Ceph RGW is kept"
    echo "  2) Everything (TiKV + Ceph RGW S3 data)"
    read -rp "> [1/2]: " choice

    install_juicefs

    case "${choice}" in
        1)
            echo ">>> Deleting metadata only..."
            juicefs destroy "${METADATA_URL}" --yes
            echo "  Metadata deleted. S3 data in Ceph RGW is untouched."
            ;;
        2)
            echo ">>> Deleting metadata + S3 data..."
            juicefs destroy --delete-all "${METADATA_URL}" --yes
            echo "  Metadata and S3 data deleted."
            ;;
        *)
            echo "Invalid choice. Aborted."
            exit 1
            ;;
    esac
}

do_test() {
    echo "========================================"
    echo "Running JuiceFS Smoke Test"
    echo "========================================"

    # Ensure mounted
    if ! mountpoint -q "${JUICEFS_MOUNT_POINT}" 2>/dev/null; then
        do_mount
    fi

    echo ""
    echo ">>> Write test..."
    echo "JuiceFS + TiKV + Ceph RGW production test - $(date)" > "${JUICEFS_MOUNT_POINT}/hello.txt"
    dd if=/dev/urandom of="${JUICEFS_MOUNT_POINT}/random.bin" bs=1M count=10 2>&1 | tail -1

    echo ""
    echo ">>> Read verification..."
    if grep -q "production test" "${JUICEFS_MOUNT_POINT}/hello.txt"; then
        echo "  PASS: Text file read correctly"
    else
        echo "  FAIL: Text file mismatch"
    fi

    SIZE=$(stat -c%s "${JUICEFS_MOUNT_POINT}/random.bin")
    if [ "${SIZE}" -eq 10485760 ]; then
        echo "  PASS: Binary file size correct (10MB)"
    else
        echo "  FAIL: Binary file size mismatch"
    fi

    echo ""
    echo ">>> Filesystem info:"
    juicefs info "${METADATA_URL}" 2>&1 | head -15

    echo ""
    echo ">>> Directory listing:"
    ls -lh "${JUICEFS_MOUNT_POINT}/"
}

# ============================================================
# Main
# ============================================================

case "${ACTION}" in
    status)   do_status ;;
    format)   do_format ;;
    mount)    do_mount ;;
    unmount)  do_unmount ;;
    destroy)  do_destroy ;;
    test)     do_test ;;
    *)
        echo "Usage: bash deploy-juicefs.sh [status|format|mount|unmount|destroy|test]"
        echo ""
        echo "  status   - Show filesystem status and connectivity checks"
        echo "  format   - Format new JuiceFS filesystem"
        echo "  mount    - Mount filesystem"
        echo "  unmount  - Unmount filesystem"
        echo "  destroy  - Destroy filesystem (irreversible!)"
        echo "  test     - Mount and run smoke test"
        ;;
esac
