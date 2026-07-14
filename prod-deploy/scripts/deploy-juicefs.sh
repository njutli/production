#!/bin/bash
set -euo pipefail

# ============================================================
# JuiceFS Client Deployment (direct RADOS — no RGW)
#
# Client on 157, metadata in TiKV (150-152), data in Ceph RADOS (150-152).
# Uses --storage ceph (librados direct, no RGW HTTP layer).
# Mount params from config.sh JUICEFS_MOUNT_OPTS (layered: cold baseline
# + conditional warm-state cache/writeback/readahead).
#
# SSH: runs on 157 via ssh_to_client (WSL → HK ECS → 157).
#
# Prerequisites:
#   1. deploy-tikv.sh completed (3 PD + 3 TiKV on 150-152)
#   2. deploy-ceph.sh completed (juicefs-data pool + client.juicefs keyring on 157)
#
# Usage: bash deploy-juicefs.sh [status|format|mount|unmount|destroy|test]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

ACTION="${1:-status}"

METADATA_URL="${JUICEFS_METADATA_URL}"
CEPHX_CLIENT="${CEPHX_CLIENT}"
POOL="${CEPH_POOL_NAME}"

# ============================================================
# Pre-flight checks (run on 157)
# ============================================================

check_tikv() {
    echo -n "Checking TiKV PD (via ${TIKV_SERVERS[0]})... "
    local first="${TIKV_SERVERS[0]}"
    local result
    result=$(ssh_to_client "curl -s --noproxy '*' --connect-timeout 5 'http://${first}:2379/pd/api/v1/health' 2>/dev/null" 2>/dev/null || echo "")
    if echo "${result}" | grep -q '"health"'; then
        echo "OK"
        return 0
    fi
    echo "UNREACHABLE"
    return 1
}

check_ceph_pool() {
    echo -n "Checking Ceph ${POOL} pool + ${CEPHX_CLIENT} keyring... "
    local result
    result=$(ssh_to_client "
        if [ ! -f /etc/ceph/ceph.conf ] || [ ! -f /etc/ceph/ceph.client.juicefs.keyring ]; then
            echo 'MISSING keyring'
        elif sudo ceph --name ${CEPHX_CLIENT} --keyring /etc/ceph/ceph.client.juicefs.keyring osd pool ls 2>/dev/null | grep -q '${POOL}'; then
            echo 'OK'
        else
            echo 'UNREACHABLE'
        fi
    " 2>/dev/null || echo "FAIL")
    echo "${result}"
    [ "${result}" = "OK" ] && return 0 || return 1
}

install_juicefs() {
    ssh_to_client "
        if command -v juicefs &>/dev/null; then
            echo 'JuiceFS: '\$(juicefs version 2>&1 | head -1)
        else
            echo '>>> Installing JuiceFS...'
            curl -sSL https://d.juicefs.com/install | sh -
            hash -r
            echo 'Installed: '\$(juicefs version 2>&1 | head -1)
        fi
    "
}

show_mount_opts() {
    echo "  Mount opts (from config.sh JUICEFS_MOUNT_OPTS):"
    local k v pending=""
    for tok in "${JUICEFS_MOUNT_OPTS[@]}"; do
        if [ -z "${pending}" ]; then
            pending="${tok}"
        else
            echo "    ${pending} ${tok}"
            pending=""
        fi
    done
    [ -n "${pending}" ] && echo "    ${pending}"
    echo ""
    if [ "${JUICEFS_CACHE_SIZE_MB:-0}" -gt 0 ] && [ -n "${JUICEFS_CACHE_DIR:-}" ]; then
        echo "  Cache: ENABLED (dir=${JUICEFS_CACHE_DIR}, size=${JUICEFS_CACHE_SIZE_MB}MB)"
    else
        echo "  Cache: DISABLED (cold-state baseline)"
    fi
    [ "${JUICEFS_ENABLE_WRITEBACK:-false}" = "true" ] && echo "  Writeback: ENABLED" || echo "  Writeback: disabled"
}

# ============================================================
# Commands (all run on 157 via ssh_to_client)
# ============================================================

do_status() {
    echo "========================================"
    echo "JuiceFS Status (direct RADOS)"
    echo "========================================"
    echo ""
    echo "  Filesystem:    ${JUICEFS_FS_NAME}"
    echo "  Metadata URL:  ${METADATA_URL}"
    echo "  Data backend:  librados (direct, no RGW)"
    echo "  Pool:          ${POOL} (EC ${CEPH_EC_K}+${CEPH_EC_M})"
    echo "  Cephx client:  ${CEPHX_CLIENT}"
    echo "  Mount point:   ${JUICEFS_MOUNT_POINT}"
    echo ""
    show_mount_opts
    check_tikv
    check_ceph_pool
    echo ""
    install_juicefs
    echo ""
    echo "Filesystem Info:"
    ssh_to_client "juicefs status '${METADATA_URL}' 2>&1 || echo '  Not yet formatted.'"
    echo ""
    ssh_to_client "mountpoint -q ${JUICEFS_MOUNT_POINT} 2>/dev/null && { echo 'Mount: MOUNTED'; df -h ${JUICEFS_MOUNT_POINT}; } || echo 'Mount: NOT mounted'"
}

do_format() {
    echo "========================================"
    echo "Formatting JuiceFS (direct RADOS)"
    echo "========================================"
    echo "  Metadata: ${METADATA_URL}"
    echo "  Data:     --storage ceph --bucket ceph://${POOL}"
    echo ""

    check_tikv || { echo "ERROR: TiKV PD not reachable."; exit 1; }
    check_ceph_pool || { echo "ERROR: Ceph pool/keyring not ready."; exit 1; }
    install_juicefs

    ssh_to_client "
        if juicefs status '${METADATA_URL}' >/dev/null 2>&1; then
            echo 'Filesystem already formatted.'
            echo 'To re-format: bash deploy-juicefs.sh destroy'
        else
            echo '>>> Running juicefs format...'
            juicefs format \
                --storage ceph \
                --bucket 'ceph://${POOL}' \
                --access-key 'ceph' \
                --secret-key '${CEPHX_CLIENT}' \
                --block-size 256K \
                --trash-days 0 \
                '${METADATA_URL}' \
                '${JUICEFS_FS_NAME}'
            echo 'Format complete!'
        fi
    "
}

do_mount() {
    echo "========================================"
    echo "Mounting JuiceFS (direct RADOS)"
    echo "========================================"

    ssh_to_client "mountpoint -q ${JUICEFS_MOUNT_POINT} 2>/dev/null && { echo 'Already mounted.'; exit 0; } || true"

    install_juicefs
    show_mount_opts

    # Build mount opts string (array → space-separated)
    MOUNT_OPTS_STR=""
    for opt in "${JUICEFS_MOUNT_OPTS[@]}"; do
        MOUNT_OPTS_STR="${MOUNT_OPTS_STR} ${opt}"
    done

    echo "Mounting ${METADATA_URL} -> ${JUICEFS_MOUNT_POINT}..."
    ssh_to_client "
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
        sudo mkdir -p ${JUICEFS_MOUNT_POINT}
        sudo chown \$(whoami):\$(whoami) ${JUICEFS_MOUNT_POINT} 2>/dev/null || true
        juicefs mount -d ${MOUNT_OPTS_STR} '${METADATA_URL}' '${JUICEFS_MOUNT_POINT}'
        sleep 3
        if mountpoint -q ${JUICEFS_MOUNT_POINT}; then
            echo 'Mounted successfully!'
            df -h ${JUICEFS_MOUNT_POINT}
        else
            echo 'ERROR: Mount failed.'
            juicefs log ${JUICEFS_MOUNT_POINT} 2>/dev/null || true
            exit 1
        fi
    "
}

do_unmount() {
    echo ">>> Unmounting ${JUICEFS_MOUNT_POINT}..."
    ssh_to_client "
        if mountpoint -q ${JUICEFS_MOUNT_POINT} 2>/dev/null; then
            fusermount -u ${JUICEFS_MOUNT_POINT} 2>/dev/null || \
            fusermount -uz ${JUICEFS_MOUNT_POINT} 2>/dev/null || \
            sudo umount -l ${JUICEFS_MOUNT_POINT}
            echo 'Unmounted.'
        else
            echo 'Not mounted.'
        fi
    "
}

do_destroy() {
    echo "!!! DANGER: Destroying JuiceFS Filesystem !!!"
    echo "  ${METADATA_URL}"
    echo ""

    do_unmount 2>/dev/null || true
    install_juicefs

    read -rp "Type 'DESTROY' to confirm: " confirm
    [ "${confirm}" = "DESTROY" ] || { echo "Aborted."; exit 0; }

    ssh_to_client "
        UUID=\$(juicefs status '${METADATA_URL}' 2>/dev/null | grep -o '\"UUID\": \"[^\"]*\"' | cut -d'\"' -f4)
        if [ -z \"\${UUID}\" ]; then
            echo 'ERROR: Could not determine volume UUID.'
            exit 1
        fi
        echo '>>> Deleting metadata + RADOS data...'
        juicefs destroy '${METADATA_URL}' \"\${UUID}\" --yes
        echo 'Done.'
    "
}

do_test() {
    echo "========================================"
    echo "JuiceFS Smoke Test (direct RADOS)"
    echo "========================================"

    ssh_to_client "mountpoint -q ${JUICEFS_MOUNT_POINT} 2>/dev/null" || do_mount

    ssh_to_client "
        echo '>>> Write test...'
        echo 'JuiceFS + TiKV + Ceph RADOS test - '\$(date) > ${JUICEFS_MOUNT_POINT}/hello.txt
        dd if=/dev/urandom of=${JUICEFS_MOUNT_POINT}/random.bin bs=1M count=10 2>&1 | tail -1

        echo '>>> Read verification...'
        grep -q 'RADOS test' ${JUICEFS_MOUNT_POINT}/hello.txt && echo '  PASS: text' || echo '  FAIL: text'
        SIZE=\$(stat -c%s ${JUICEFS_MOUNT_POINT}/random.bin)
        [ \"\${SIZE}\" -eq 10485760 ] && echo '  PASS: binary (10MB)' || echo '  FAIL: binary size='\${SIZE}

        echo '>>> Filesystem info:'
        juicefs info ${JUICEFS_MOUNT_POINT} 2>&1 | head -15

        echo '>>> Cleanup...'
        rm -f ${JUICEFS_MOUNT_POINT}/hello.txt ${JUICEFS_MOUNT_POINT}/random.bin
        echo '  Done.'
    "
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
        ;;
esac
