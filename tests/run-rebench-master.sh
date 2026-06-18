#!/bin/bash
# ============================================================
# 重测编排（serial master, single process, no watchdog）
#   基于最新 bench-juicefs.sh（含 REPEAT 多次排除波动 + 布局一次复用）
#   重做三组 128G 全口径对比，REPEAT=5：
#     1. S3 (RGW)        4M block-size  — STORAGE=s3
#     2. Direct RADOS    4M block-size  — STORAGE=ceph, CEPH_POOL=juicefs-data
#     3. 256K block-size                — STORAGE=ceph, CEPH_POOL=juicefs-data, --block-size 256
#
# 关键口径校正（相对 deepseek 本轮）：
#   - RADOS/256K 用独立 EC 池 juicefs-data（deepseek 误用了 default.rgw.buckets.data）。
#   - 全口径：不 SKIP_SEQ（顺序读写也要，和 08_1 原始对比一致）。
#   - REPEAT=5：随机项各跑 5 次取多次，排除单次波动。
#   - LAYOUT 128 jobs × 1G = 128G。
#
# 串行单进程；每组之间 destroy 已含 65s 会话等待 + 池验证。
# 启动方式（务必脱离会话，断网/超时不杀进程）：
#   setsid bash tests/run-rebench-master.sh < /dev/null \
#     > /tmp/opencode/rebench-master.log 2>&1 & disown
# ============================================================
set -uo pipefail
cd /home/turboai/production
LOG=/tmp/opencode/rebench-master.log
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1

clean_env() {
    pkill -9 fio 2>/dev/null || true
    for mp in /mnt/juicefs /mnt/juicefs2; do
        fusermount -uz "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
    done
    sleep 3
}

echo "=== REBENCH MASTER START $(date) ==="
clean_env

echo ""
echo "=== STEP1  S3 (RGW) 128G 4M  START $(date) ==="
STORAGE=s3 LAYOUT_NUMJOBS=128 LAYOUT_FILESIZE=1G REPEAT=5 \
    bash tests/bench-juicefs.sh rebench-s3-4M-128G
echo "=== STEP1  S3 (RGW) 128G 4M  END $(date) rc=$? ==="
clean_env

echo ""
echo "=== STEP2  Direct RADOS 128G 4M  START $(date) ==="
STORAGE=ceph CEPH_POOL=juicefs-data LAYOUT_NUMJOBS=128 LAYOUT_FILESIZE=1G REPEAT=5 \
    bash tests/bench-juicefs.sh rebench-rados-4M-128G
echo "=== STEP2  Direct RADOS 128G 4M  END $(date) rc=$? ==="
clean_env

echo ""
echo "=== STEP3  256K block-size 128G  START $(date) ==="
STORAGE=ceph CEPH_POOL=juicefs-data LAYOUT_NUMJOBS=128 LAYOUT_FILESIZE=1G REPEAT=5 \
    EXTRA_FORMAT_OPTS="--block-size 256" \
    bash tests/bench-juicefs.sh rebench-256K-128G
echo "=== STEP3  256K block-size 128G  END $(date) rc=$? ==="
clean_env

echo ""
echo "=== REBENCH MASTER DONE $(date) ==="
