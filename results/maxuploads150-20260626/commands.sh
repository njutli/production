#!/bin/bash
# ============================================================
# 完整命令记录：--max-uploads=150 对照测试
# ============================================================

# ---- 格式化卷 ----
juicefs destroy --yes tikv://192.168.11.12:2379/juicefs-prod <UUID>

juicefs format   --storage ceph   --bucket ceph://juicefs-data   --access-key ceph   --secret-key client.juicefs   --block-size 256K   --trash-days 0   tikv://192.168.11.12:2379/juicefs-prod juicefs-prod

# ---- 挂载 (--max-uploads=150) ----
juicefs mount -d --cache-size 0 --max-uploads 150 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# ---- 顺序写测试 ----
# seqwrite prep
fio --name=prep --directory=/mnt/juicefs/test_dir --rw=write --refill_buffers --bs=4M --size=4G

# seqwrite (1job, end_fsync)
fio --name=seqwrite --directory=/mnt/juicefs/test_dir --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1

# multi-seqwrite (16job, end_fsync)
fio --name=multi-seqwrite --directory=/mnt/juicefs/test_dir --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting --end_fsync=1
