#!/bin/bash
# Full serial re-run with corrected B params (buffer-size/prefetch, not max-downloads).
#   1. ABC ceph (no RGW)      — redo so B sweep is valid
#   2. purge s3 bucket; s3 baseline full bench
#   3. purge s3 bucket; ABC s3 (RGW)
# All serial in one process; no overlap possible.
set -uo pipefail
cd /home/turboai/production
LOG=/tmp/opencode/abc-master.log
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

echo "=== MASTER START $(date) ==="
clean_env

echo "=== STEP1 ABC ceph START $(date) ==="
bash tests/bench-abc.sh ceph norgw
echo "=== STEP1 ABC ceph END $(date) rc=$? ==="
clean_env

purge_bucket
echo "=== STEP2 s3 baseline START $(date) ==="
STORAGE=s3 LAYOUT_NUMJOBS=128 bash tests/bench-juicefs.sh rgw-s3-128-baseline
echo "=== STEP2 s3 baseline END $(date) rc=$? ==="
clean_env

purge_bucket
echo "=== STEP3 ABC s3 START $(date) ==="
bash tests/bench-abc.sh s3 rgw
echo "=== STEP3 ABC s3 END $(date) rc=$? ==="
clean_env

echo "=== MASTER DONE $(date) ==="
