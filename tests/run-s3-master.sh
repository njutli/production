#!/bin/bash
# s3-only re-run: ABC ceph already succeeded earlier; this redoes the s3 side.
#   1. purge s3 bucket via radosgw-admin (only reliable way to empty it)
#   2. s3 (RGW) baseline full bench
#   3. ABC on s3 (RGW)
set -uo pipefail
cd /home/turboai/production
LOG=/tmp/opencode/abc-s3-master.log
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1

clean_env() {
    pkill -9 fio 2>/dev/null || true
    for mp in /mnt/juicefs /mnt/juicefs2; do
        fusermount -uz "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
    done
    sleep 3
}

purge_bucket() {
    echo "--- purging s3 bucket juicefs-prod via radosgw-admin ---"
    ssh 192.168.11.11 "sudo cephadm shell -- radosgw-admin bucket rm --bucket=juicefs-prod --purge-objects" 2>&1 | tail -2 || true
}

echo "=== S3 MASTER START $(date) ==="
clean_env
purge_bucket

echo "=== STEP1 s3 baseline START $(date) ==="
STORAGE=s3 LAYOUT_NUMJOBS=128 bash tests/bench-juicefs.sh rgw-s3-128-baseline
echo "=== STEP1 s3 baseline END $(date) rc=$? ==="
clean_env
purge_bucket

echo "=== STEP2 ABC s3 START $(date) ==="
bash tests/bench-abc.sh s3 rgw
echo "=== STEP2 ABC s3 END $(date) rc=$? ==="
clean_env

echo "=== S3 MASTER DONE $(date) ==="
