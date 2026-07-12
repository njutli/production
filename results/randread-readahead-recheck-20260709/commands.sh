#!/bin/bash
# Task 12.1: randread readahead recheck
# 二进制：patched 1.3.1+2025-12-02.e0032b2a
# 后端：全内存盘 6 OSD DATA+WAL/DB tmpfs
# A 组: cache=0 mu=150（基线，无 max-readahead）
# B 组: cache=0 mu=150 + max-readahead 0（单变量）
# 口径：只认 r1（冷态），3 轮看方差，不取 MAX
# layout: 128j×512M=64G（tmpfs 限制），A/B 各自 fresh
# 采集：每轮 eno1 RX(/proc/net/dev) + juicefs stats + pidstat CPU

META="tikv://192.168.11.12:2379/juicefs-memdisk"
MNT=/mnt/juicefs
OUT=results/randread-readahead-recheck-20260709

# ---- A 组挂载（基线） ----
juicefs mount -d --cache-size 0 --max-uploads 150 "$META" "$MNT"

# ---- layout L_A (64G) ----
fio --directory=$MNT/test_dir --name=storage_test --filesize=512M --size=512M \
    --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1

# ---- randread r1-r3 (复用 layout) ----
fio --directory=$MNT/test_dir --name=storage_test --filesize=512M --size=512M \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s

# ---- randrw r1-r3 ----
fio --directory=$MNT/test_dir --name=storage_test --filesize=512M --size=512M \
    --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s

# ---- seqread (4G, refill_buffers) ----
fio --name=prep --directory=$MNT/seq_dir --rw=write --refill_buffers --bs=256K --size=4G
fio --name=seqread --directory=$MNT/seq_dir --rw=read --refill_buffers --bs=256K --size=4G

# ---- B 组重挂（+max-readahead 0） ----
juicefs umount "$MNT"
juicefs mount -d --cache-size 0 --max-uploads 150 --max-readahead 0 "$META" "$MNT"

# ---- layout L_B (fresh 64G) + 同上 randread/randrw/seqread ----
# (同 A 组流程，fresh layout)
