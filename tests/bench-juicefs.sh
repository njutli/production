#!/bin/bash
set -euo pipefail
# ============================================================
# JuiceFS Benchmark Test Script
# Full cycle: format → mount → fio(read+write) → unmount → destroy
# Usage: bash tests/bench-juicefs.sh <label> [extra_mount_opts...]
# ============================================================

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "${SCRIPT_DIR}")"
source "${PROD_DIR}/config.sh"
source "${PROD_DIR}/.credentials/rgw-juicefs.env"

LABEL="${1:-baseline}"
shift || true
EXTRA_MOUNT_OPTS="$@"
METADATA_URL="tikv://${PD_ENDPOINTS}/${JUICEFS_FS_NAME}"
BUCKET_URL="${RGW_ENDPOINT}/${JUICEFS_FS_NAME}"
RESULT_DIR="${PROD_DIR}/results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="${RESULT_DIR}/${TIMESTAMP}-${LABEL}.txt"

mkdir -p "${RESULT_DIR}"

fail() {
    echo "FATAL: $1" | tee -a "${RESULT_FILE}"
    do_cleanup
    exit 1
}

do_cleanup() {
    echo ">>> Cleaning up..." | tee -a "${RESULT_FILE}"
    rm -rf "${JUICEFS_MOUNT_POINT}/test_dir" 2>/dev/null || true
    if mountpoint -q "${JUICEFS_MOUNT_POINT}" 2>/dev/null; then
        fusermount -uz "${JUICEFS_MOUNT_POINT}" 2>/dev/null || umount -l "${JUICEFS_MOUNT_POINT}" 2>/dev/null || true
    fi
    # Wait for session to expire (TTL ~60s) before destroy
    echo "Waiting for session to expire..." | tee -a "${RESULT_FILE}"
    sleep 65
    # Destroy volume (non-interactive)
    UUID=$(juicefs status "${METADATA_URL}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
    if [ -n "${UUID}" ]; then
        echo "Destroying JuiceFS volume..." | tee -a "${RESULT_FILE}"
        juicefs destroy "${METADATA_URL}" "${UUID}" --yes 2>&1 | tail -5 | tee -a "${RESULT_FILE}"
    fi
    rm -f /tmp/juicefs-test-* 2>/dev/null || true
}

# ============================================================
echo "========================================" | tee "${RESULT_FILE}"
echo "JuiceFS Benchmark — ${LABEL}" | tee -a "${RESULT_FILE}"
echo "Date: $(date)" | tee -a "${RESULT_FILE}"
echo "Config: ${METADATA_URL}" | tee -a "${RESULT_FILE}"
echo "Extra mount opts: ${EXTRA_MOUNT_OPTS}" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "" | tee -a "${RESULT_FILE}"

# ============================================================
# 1. Destroy any leftover (clean start)
# ============================================================
echo ">>> Destroying any previous volume..." | tee -a "${RESULT_FILE}"
do_cleanup 2>/dev/null || true
sleep 2

# ============================================================
# 2. Format
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo ">>> Formatting JuiceFS..." | tee -a "${RESULT_FILE}"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=""

# Pre-create bucket
if command -v aws &>/dev/null; then
    aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl s3 mb "s3://${JUICEFS_FS_NAME}" 2>/dev/null || true
fi

juicefs format \
    --storage s3 \
    --bucket "${BUCKET_URL}" \
    --access-key "${AWS_ACCESS_KEY_ID}" \
    --secret-key "${AWS_SECRET_ACCESS_KEY}" \
    --trash-days 0 \
    "${METADATA_URL}" \
    "${JUICEFS_FS_NAME}" 2>&1 | tee -a "${RESULT_FILE}"
echo "Format OK." | tee -a "${RESULT_FILE}"

# ============================================================
# 3. Mount
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo ">>> Mounting JuiceFS..." | tee -a "${RESULT_FILE}"
sudo mkdir -p "${JUICEFS_MOUNT_POINT}"
sudo chown $(whoami):$(whoami) "${JUICEFS_MOUNT_POINT}" 2>/dev/null || true

juicefs mount -d ${EXTRA_MOUNT_OPTS} "${METADATA_URL}" "${JUICEFS_MOUNT_POINT}" 2>&1 | tee -a "${RESULT_FILE}"
sleep 3

if ! mountpoint -q "${JUICEFS_MOUNT_POINT}"; then
    fail "Mount failed!"
fi
echo "Mount OK." | tee -a "${RESULT_FILE}"

# ============================================================
# 4. Sequential Read Test
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Sequential Read Test" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
fio --name=sequential-read --directory="${JUICEFS_MOUNT_POINT}/test_dir/" \
    --rw=read --refill_buffers --bs=4M --size=4G 2>&1 | tee -a "${RESULT_FILE}"

# ============================================================
# 5. Sequential Write Test
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Sequential Write Test" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
rm -rf "${JUICEFS_MOUNT_POINT}/test_dir"
mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
fio --name=sequential-write --directory="${JUICEFS_MOUNT_POINT}/test_dir/" \
    --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 2>&1 | tee -a "${RESULT_FILE}"

# ============================================================
# 6. Multi-job Sequential Read Test
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Multi-job Sequential Read Test" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
rm -rf "${JUICEFS_MOUNT_POINT}/test_dir"
mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
fio --name=big-file-multi-read --directory="${JUICEFS_MOUNT_POINT}/test_dir/" \
    --rw=read --refill_buffers --bs=4M --size=4G --numjobs=16 2>&1 | tee -a "${RESULT_FILE}"

# ============================================================
# 7. Multi-job Sequential Write Test
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Multi-job Sequential Write Test" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
rm -rf "${JUICEFS_MOUNT_POINT}/test_dir"
mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
fio --name=big-file-multi-write --directory="${JUICEFS_MOUNT_POINT}/test_dir/" \
    --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 2>&1 | tee -a "${RESULT_FILE}"

# ============================================================
# 8. Cleanup + Destroy
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Test Complete — Destroying Volume" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"

rm -rf "${JUICEFS_MOUNT_POINT}/test_dir"
do_cleanup

echo "" | tee -a "${RESULT_FILE}"
echo "Results saved to: ${RESULT_FILE}" | tee -a "${RESULT_FILE}"
echo "Done." | tee -a "${RESULT_FILE}"
