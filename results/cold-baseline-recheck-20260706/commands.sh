#!/bin/bash
# Commands: cold-baseline-recheck-20260706
# 日期：2026-07-06
# 二进制：patched v1.3.1+2025-12-02.e0032b2a
# 口径：cache=0, 无 mu 无 ra, bs=256K seq / bs=4M layout / bs=256k rand

# ---- 格式化卷 ----
juicefs format --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs \
  --block-size 256K --trash-days 0 \
  tikv://192.168.11.12:2379/juicefs-prod juicefs-prod

# ---- 挂载 ----
juicefs mount -d --cache-size 0 \
  tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# ---- 顺序测试 (bs=256K, 匹配旧基线) ----
# seqread prep (write 4G)
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G

# seqread (无 --direct=1, 匹配旧基线)
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G

# seqwrite
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1

# multi-seqread
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting

# multi-seqwrite
fio --name=multi-seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1

# ---- 布局 (128 jobs x 1G = 128G, bs=4M) ----
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1

# ---- 随机测试 (3轮, bs=256k, 复用 layout) ----
# Round 1-3: randread / randwrite / randrw
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s

fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s

fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
