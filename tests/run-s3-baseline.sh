#!/bin/bash
# Dedicated s3 (RGW) 128G baseline rerun.
# Fixes:
#   - 404 NoSuchKey root cause: reusing a bucket right after radosgw-admin purge
#     (async delete) corrupts freshly written objects. => use a BRAND-NEW fs/bucket
#     name so there is zero stale-object conflict.
#   - master now CAPTURES the child's real exit code (no fake rc=0).
set -uo pipefail
cd /home/turboai/production
LOG=/tmp/opencode/s3-baseline-master.log
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1

FS="jfs-s3base"   # fresh, unused bucket + metadata key
clean_env() {
    pkill -9 fio 2>/dev/null || true
    for mp in /mnt/juicefs /mnt/juicefs2; do
        fusermount -uz "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
    done
    sleep 3
}

echo "=== S3 BASELINE MASTER START $(date)  fs=${FS} ==="
clean_env

# Make sure the fresh name really is unused (drop leftover metadata + bucket if any)
echo "--- ensuring ${FS} is unused ---"
juicefs destroy "tikv://192.168.11.12:2379/${FS}" --yes 2>/dev/null | tail -1 || true
ssh 192.168.11.11 "sudo cephadm shell -- radosgw-admin bucket rm --bucket=${FS} --purge-objects" 2>&1 | tail -1 || true
sleep 10   # let any purge settle before we (re)create

echo "=== STEP s3 baseline (128G) START $(date) ==="
set +e
JUICEFS_FS_NAME="${FS}" STORAGE=s3 LAYOUT_NUMJOBS=128 \
    bash tests/bench-juicefs.sh rgw-s3-128-baseline
RC=$?
set -e
echo "=== STEP s3 baseline END $(date) REAL_RC=${RC} ==="

clean_env
if [ "${RC}" -eq 0 ]; then
    echo "=== S3 BASELINE MASTER DONE OK $(date) ==="
else
    echo "=== S3 BASELINE MASTER FAILED rc=${RC} $(date) ==="
fi
