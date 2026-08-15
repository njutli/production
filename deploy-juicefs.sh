#!/bin/bash
set -euo pipefail

# JuiceFS/TiKV uses Go net/http which respects proxy env vars.
# Local proxy (e.g. localhost:7890) would break PD and S3 connections.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

# ============================================================
# JuiceFS Client Deployment (4-Machine Topology)
#
# Installs JuiceFS client and formats/mounts a filesystem
# backed by TiKV 3-node (metadata) + Ceph RADOS direct (data).
#
# Client placement strategy:
#   Data-heavy tests   → run on ${TIKV_SERVER} (set JUICEFS_CLIENT in config.sh)
#   Metadata-heavy tests → run on one CEPH_SERVERS (change JUICEFS_CLIENT)
# This deliberately co-locates client with the layer NOT under test
# so resource contention doesn't mask the bottleneck.
#
# Prerequisites:
#   1. deploy-tikv.sh completed
#   2. deploy-ceph.sh completed (RADOS pool + client.admin keyring on client)
#
# Usage: bash deploy-juicefs.sh [status|format|mount|unmount|destroy|test]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"

ACTION="${1:-status}"

METADATA_URL="${JUICEFS_METADATA_URL}"
BUCKET_URL="ceph://${CEPH_POOL_NAME}"

# ============================================================
# Pre-flight
# ============================================================

check_tikv() {
    echo -n "Checking TiKV PD... "
    local first_pd="${TIKV_SERVERS[0]}:2379"
    if curl -s --noproxy '*' --connect-timeout 5 "http://${first_pd}/pd/api/v1/health" 2>/dev/null | grep -q '"health"'; then
        echo "OK"
        return 0
    fi
    echo "UNREACHABLE"
    return 1
}

check_ceph_rados() {
    echo -n "Checking Ceph RADOS... "
    if ssh_to_client "sudo ceph -s 2>/dev/null" | grep -q "mon:"; then
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
    check_ceph_rados
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
    check_ceph_rados || { echo "ERROR: Ceph RADOS not reachable."; exit 1; }
    install_juicefs

    # Check if already formatted
    if juicefs status "${METADATA_URL}" >/dev/null 2>&1; then
        echo "Filesystem already formatted."
        echo "To re-format, destroy it first: bash deploy-juicefs.sh destroy"
        exit 0
    fi

    echo ""
    echo ">>> Running juicefs format (Ceph RADOS direct)..."
    sudo CEPH_CONF=/etc/ceph/ceph.conf juicefs format \
        "${JUICEFS_FORMAT_OPTS[@]}" \
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

    sudo mkdir -p "${JUICEFS_MOUNT_POINT}"
    if ! mountpoint -q "${JUICEFS_MOUNT_POINT}" 2>/dev/null; then
        sudo chown $(whoami):$(whoami) "${JUICEFS_MOUNT_POINT}"
    fi

    echo "Mounting ${METADATA_URL} -> ${JUICEFS_MOUNT_POINT}..."
    sudo CEPH_CONF=/etc/ceph/ceph.conf juicefs mount -d \
        "${JUICEFS_MOUNT_OPTS[@]}" \
        "${METADATA_URL}" \
        "${JUICEFS_MOUNT_POINT}"

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
        # Try normal unmount first, then force lazy unmount
        fusermount -u "${JUICEFS_MOUNT_POINT}" 2>/dev/null || \
        fusermount -uz "${JUICEFS_MOUNT_POINT}" 2>/dev/null || \
        umount -l "${JUICEFS_MOUNT_POINT}"
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

    install_juicefs

    # Get UUID for destroy command
    UUID=$(juicefs status "${METADATA_URL}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    if [ -z "${UUID}" ]; then
        echo "ERROR: Could not determine volume UUID. Is the filesystem formatted?"
        exit 1
    fi

    read -rp "Type 'DESTROY' to confirm: " confirm
    if [ "${confirm}" != "DESTROY" ]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo ">>> Deleting metadata + Ceph RADOS data..."
    sudo CEPH_CONF=/etc/ceph/ceph.conf juicefs destroy "${METADATA_URL}" "${UUID}" --yes
    echo "  Metadata and RADOS data deleted."
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
    echo "JuiceFS + TiKV + Ceph RADOS production test - $(date)" > "${JUICEFS_MOUNT_POINT}/hello.txt"
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
    juicefs info "${JUICEFS_MOUNT_POINT}" 2>&1 | head -15

    echo ""
    echo ">>> Directory listing:"
    ls -lh "${JUICEFS_MOUNT_POINT}/"

    echo ""
    echo ">>> Cleanup test files..."
    rm -f "${JUICEFS_MOUNT_POINT}/hello.txt" "${JUICEFS_MOUNT_POINT}/random.bin"
    echo "  Test files removed."
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
