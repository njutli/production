#!/bin/bash
# ============================================================
# 完整命令记录：回退测试1 带 RGW + fio bs=4M / block-size=256K
# ============================================================

# ---- 格式化卷 (S3/RGW) ----
juicefs destroy --yes tikv://192.168.11.12:2379/juicefs-prod <UUID>
sudo radosgw-admin bucket rm juicefs-prod --purge-objects

juicefs format   --storage s3   --bucket http://192.168.11.12:8080/juicefs-prod   --access-key I5LFISDKKNMOQCIM7IWY   --secret-key gQVKPfJ0wj3wEoDb3CvgGhyKHOG0KwFPg34ZttK5   --block-size 256K   --trash-days 0   tikv://192.168.11.12:2379/juicefs-prod juicefs-prod

# ---- 挂载 (--cache-size 0, --max-uploads=150) ----
juicefs mount -d --cache-size 0 --max-uploads 150 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# ---- 顺序测试 ----
# seqread prep
fio --name=prep --directory=/mnt/juicefs/test_dir --rw=write --refill_buffers --bs=4M --size=4G

# seqread (1job)
fio --name=seqread --directory=/mnt/juicefs/test_dir --rw=read --refill_buffers --bs=4M --size=4G

# seqwrite (1job, end_fsync)
fio --name=seqwrite --directory=/mnt/juicefs/test_dir --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1

# multi-seqread (16job)
fio --name=multi-seqread --directory=/mnt/juicefs/test_dir --rw=read --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting

# multi-seqwrite (16job, end_fsync)
fio --name=multi-seqwrite --directory=/mnt/juicefs/test_dir --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting --end_fsync=1

# ---- 布局 (128G) ----
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1

# ---- 随机测试 (3轮) ----
# randread
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=100 --group_reporting     --time_based --runtime=60s

# randwrite
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=100 --group_reporting     --time_based --runtime=60s

# randrw
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=100 --group_reporting     --time_based --runtime=60s
