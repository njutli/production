#!/bin/bash
# 256K block-size full acceptance matrix on ceph直连.
# Runs the FULL bench-juicefs.sh cycle (seq RW + multi-job + pure randread +
# pure randwrite + randrw acceptance) on a fresh ceph volume formatted with
# --block-size 256K, so we can compare against the 4M-default acceptance numbers
# and judge whether small block-size is viable end-to-end (not just randread).
# Also records side effects: object count in the ceph pool before/after.
set -uo pipefail
cd /home/turboai/production
LOG=/tmp/opencode/bs256k-acceptance.log
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1

clean(){
  pkill -9 fio 2>/dev/null||true
  for mp in /mnt/juicefs /mnt/juicefs2; do fusermount -uz "$mp" 2>/dev/null|| sudo umount -l "$mp" 2>/dev/null||true; done
  sleep 3
}

echo "=== 256K BLOCK-SIZE ACCEPTANCE START $(date) ==="
clean

echo "--- ceph pool object count BEFORE ---"
ssh 192.168.11.11 "sudo cephadm shell -- ceph df" 2>&1 | grep -E "juicefs-data|POOL" || true

# Full cycle with 256K block-size, ceph backend, 128G layout (full caliber).
set +e
JUICEFS_FS_NAME="jfs-bs256k" EXTRA_FORMAT_OPTS="--block-size 256K" STORAGE=ceph CEPH_POOL=juicefs-data LAYOUT_NUMJOBS=128 \
    bash tests/bench-juicefs.sh bs256k-accept
RC=$?
set -e
echo "=== bench RC=${RC} $(date) ==="

echo "--- ceph pool object count AFTER (note: volume destroyed at end of bench) ---"
ssh 192.168.11.11 "sudo cephadm shell -- ceph df" 2>&1 | grep -E "juicefs-data|POOL" || true

clean
if [ "${RC}" -eq 0 ]; then echo "=== 256K ACCEPTANCE DONE OK $(date) ==="; else echo "=== 256K ACCEPTANCE FAILED rc=${RC} $(date) ==="; fi
