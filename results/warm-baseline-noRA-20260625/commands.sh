#!/bin/bash
# ============================================================
# 完整命令记录：暖态基线第一轮
# ============================================================
# 复用冷态基线的卷和 128G 布局，不 destroy/reformat

# ---- 挂载 ----
juicefs mount -d --cache-size 102400 --max-readahead 0 --cache-dir /data/jfsCache     tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# ---- 顺序测试 ----
# seqread prep
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=4M --size=4G

# seqread (1job)
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=4M --size=4G

# seqwrite (1job, end_fsync)
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1

# multi-seqread (16job)
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting

# multi-seqwrite (16job, end_fsync)
fio --name=multi-seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting --end_fsync=1

# ---- 随机测试 (7轮, 不 drop_caches, 复用 128G 布局) ----
# randread
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=100 --group_reporting     --time_based --runtime=60s

# randwrite
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=100 --group_reporting     --time_based --runtime=60s

# randrw
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=100 --group_reporting     --time_based --runtime=60s
