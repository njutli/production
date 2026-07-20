#!/bin/bash
# 完整命令记录：randrw 降并发扫描补丁重跑 (01-2b)
# 日期：2026-07-16
# 验收线：不限速 100GbE 口径
# JuiceFS 版本：1.3.1+2025-12-02.e0032b2 (含 eaf3d21f loadRange 修复)
# Ceph FSID：7bb47ec2-8061-11f1-a671-97520597268c

# ---- 环境快照 ----
# ceph health = HEALTH_OK
# 6/6 OSD up/in, dual network (public 10.3.1.x / cluster 10.3.2.x)
# 无 tc qdisc 规则
# juicefs version 1.3.1+2025-12-02.e0032b2

# ---- JuiceFS format（已存在，不重建）----
# juicefs format \
#   --storage ceph \
#   --bucket ceph://juicefs-data \
#   --access-key ceph \
#   --secret-key client.juicefs \
#   --block-size 256K \
#   --trash-days 0 \
#   tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod \
#   juicefs-prod

# ---- JuiceFS mount（冷态 ra0 + cache=0 + mu150）----
# juicefs mount -d \
#   --storage ceph --bucket ceph://juicefs-data \
#   --access-key ceph --secret-key client.juicefs \
#   --block-size 256K \
#   --max-uploads 150 \
#   --cache-size 0 \
#   --max-readahead 0 \
#   tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod \
#   /mnt/juicefs

# ---- §2.1 方案A：建好 §5 layout 卷（一次性，4M 铺满 128G）----
rm -rf /mnt/juicefs/test_dir && mkdir -p /mnt/juicefs/test_dir
fio --directory=/mnt/juicefs/test_dir \
    --name=storage_test \
    --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none \
    --direct=1 --ioengine=libaio --iodepth=128 \
    --group_reporting --end_fsync=1 \
    --write_bw_log=/tmp/jfs-bw/layout --log_avg_msec=1000

# ---- layout 后 compact cooldown ----
# 在每个 slave 节点执行：
# FSID="7bb47ec2-8061-11f1-a671-97520597268c"
# for asok in /var/run/ceph/${FSID}/ceph-osd.*.asok; do
#   sudo ceph --admin-daemon "$asok" compact
# done
# 等待 compact_running=0 compact_queue_len=0

# ---- 每档每轮跑前 drop_caches（157 + 3 slave）----
# 157: sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
# 各 slave: 同上

# ---- §6.4 randrw analysis 版（复用 layout，不 fresh volume）----
# D0: numjobs=128 iodepth=128
# D1: numjobs=32  iodepth=16
# D2: numjobs=16  iodepth=8
# D3: numjobs=8   iodepth=4
# 每档 REPEAT=3

# fio --directory=/mnt/juicefs/test_dir \
#     --name=storage_test \
#     --filesize=1G --size=1G \
#     --bs=256k --rw=randrw \
#     --ioengine=libaio --iodepth=<D> --numjobs=<N> \
#     --direct=1 --fallocate=none --openfiles=100 \
#     --group_reporting --time_based --runtime=180 \
#     --write_bw_log=/tmp/jfs-bw/randrw-<LEVEL>-r<ROUND> --log_avg_msec=1000

# 具体命令（每档每轮）：
# D0 R1: fio ... --iodepth=128 --numjobs=128 --write_bw_log=/tmp/jfs-bw/randrw-D0-r1 ...
# D0 R2: fio ... --iodepth=128 --numjobs=128 --write_bw_log=/tmp/jfs-bw/randrw-D0-r2 ...
# D0 R3: fio ... --iodepth=128 --numjobs=128 --write_bw_log=/tmp/jfs-bw/randrw-D0-r3 ...
# D1 R1: fio ... --iodepth=16  --numjobs=32  --write_bw_log=/tmp/jfs-bw/randrw-D1-r1 ...
# D1 R2: fio ... --iodepth=16  --numjobs=32  --write_bw_log=/tmp/jfs-bw/randrw-D1-r2 ...
# D1 R3: fio ... --iodepth=16  --numjobs=32  --write_bw_log=/tmp/jfs-bw/randrw-D1-r3 ...
# D2 R1: fio ... --iodepth=8   --numjobs=16  --write_bw_log=/tmp/jfs-bw/randrw-D2-r1 ...
# D2 R2: fio ... --iodepth=8   --numjobs=16  --write_bw_log=/tmp/jfs-bw/randrw-D2-r2 ...
# D2 R3: fio ... --iodepth=8   --numjobs=16  --write_bw_log=/tmp/jfs-bw/randrw-D2-r3 ...
# D3 R1: fio ... --iodepth=4   --numjobs=8   --write_bw_log=/tmp/jfs-bw/randrw-D3-r1 ...
# D3 R2: fio ... --iodepth=4   --numjobs=8   --write_bw_log=/tmp/jfs-bw/randrw-D3-r2 ...
# D3 R3: fio ... --iodepth=4   --numjobs=8   --write_bw_log=/tmp/jfs-bw/randrw-D3-r3 ...

# ---- §8.3 每-job 聚合稳态中位数 ----
# python3 /tmp/aggregate-bw-logs-v2.py
# 方法：1秒时间桶聚合所有 job 的逐秒带宽，分 R/W，截前1/4爬坡，取中位数
# 三轮取中位数（第2大）
