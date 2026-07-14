#!/bin/bash
set -euo pipefail

MNT="/mnt/juicefs"
TEST_DIR="${MNT}/bench"
mkdir -p "${TEST_DIR}"

echo "========================================"
echo "JuiceFS Performance Test (100GbE, cold cache=0)"
echo "========================================"
echo ""

# --- 1. Sequential write (4M, 1 job) ---
echo ">>> [1] Sequential Write (4M bs, 1 job)"
rm -rf "${TEST_DIR}/seqwrite"
mkdir -p "${TEST_DIR}/seqwrite"
fio --name=seqwrite --directory="${TEST_DIR}/seqwrite/" \
    --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 \
    2>&1 | grep -E 'WRITE|bw=|lat=|IOPS=' | head -5
echo ""

# --- 2. Sequential read (4M, 1 job) ---
echo ">>> [2] Sequential Read (4M bs, 1 job)"
fio --name=seqread --directory="${TEST_DIR}/seqwrite/" \
    --rw=read --refill_buffers --bs=4M --size=4G \
    2>&1 | grep -E 'READ|bw=|lat=|IOPS=' | head -5
echo ""

# --- 3. Layout write (128 jobs × 1G = 128G for randread) ---
echo ">>> [3] Layout Write (128 jobs × 1G = 128G, for randread)"
rm -rf "${TEST_DIR}/layout"
mkdir -p "${TEST_DIR}/layout"
fio --directory="${TEST_DIR}/layout" \
    --name=storage_test \
    --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none \
    --group_reporting --end_fsync=1 \
    2>&1 | grep -E 'WRITE|bw=|IOPS=' | head -5
echo ""

# cooldown 10s
echo ">>> Cooldown 10s..."
sleep 10
echo ""

# --- 4. Random read (256k, 128 jobs, 60s) ---
echo ">>> [4] Random Read (256k bs, 128 jobs, 60s) — CORE METRIC"
echo "  (drop caches first)"
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
fio --directory="${TEST_DIR}/layout" \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none \
    --group_reporting --time_based --runtime=60s \
    2>&1 | grep -E 'READ|bw=|IOPS=|lat=' | head -5
echo ""

# --- 5. Random write (256k, 128 jobs, 60s) ---
echo ">>> [5] Random Write (256k bs, 128 jobs, 60s) — CORE METRIC"
rm -rf "${TEST_DIR}/randwrite"
mkdir -p "${TEST_DIR}/randwrite"
fio --directory="${TEST_DIR}/randwrite" \
    --name=storage_test \
    --nrfiles=100 --filesize=1G --size=1G \
    --bs=256k --rw=randwrite \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
    --group_reporting --time_based --runtime=60s \
    2>&1 | grep -E 'WRITE|bw=|IOPS=|lat=' | head -5
echo ""

# --- 6. Random read-write (256k, 128 jobs, 60s) ---
echo ">>> [6] Random Read-Write (256k bs, 128 jobs, 60s)"
rm -rf "${TEST_DIR}/randrw"
mkdir -p "${TEST_DIR}/randrw"
fio --directory="${TEST_DIR}/randrw" \
    --name=storage_test \
    --nrfiles=100 --filesize=1G --size=1G \
    --bs=256k --rw=randrw \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
    --group_reporting --time_based --runtime=60s \
    2>&1 | grep -E 'READ:|WRITE:|bw=|IOPS=' | head -10
echo ""

# cleanup
rm -rf "${TEST_DIR}"

echo "========================================"
echo "Performance test complete."
echo "========================================"
