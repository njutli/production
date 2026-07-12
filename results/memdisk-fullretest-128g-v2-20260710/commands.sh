#!/bin/bash
# 完整命令记录：任务 12.1-步骤2修订版 v2 (口径校准)
# 日期：2026-07-10
# 卷名：juicefs-memdisk
# 集群：tikv://192.168.11.12:2379, Ceph FSID=073f28e0-5fe0-11f1-8ce6-7369ee2be5a1
# JuiceFS: 1.3.1+2025-12-02.e0032b2a (patched)
# fio: 3.28
# NIC: eno1 (千兆), RX=col2 TX=col10 in /proc/net/dev

# ====================================================================
# 口径校准说明（本任务核心变化 vs 上一版 step2）
# 1. fio 全项加 --write_bw_log/--read_bw_log --log_avg_msec=1000（逐秒瞬时带宽）
# 2. 达标值 = 稳态段中位数（截掉开头暂态后取中位数），非全程平均
# 3. 全部改 --time_based --runtime=180s（原 60s 或 size-based）
# 4. NIC 存原始 /proc/net/dev 逐秒行（timestamp + eno1 整行），非汇总
# 5. 读类 drop_caches + seqread 加大 --size=20G 防缓存命中
# 6. object put/get 只算放大，不当达标值
# ====================================================================

# ---- format（已存在，不重复执行）----
# juicefs format tikv://192.168.11.12:2379/juicefs-memdisk juicefs-memdisk \
#   --storage ceph \
#   --bucket ceph://073f28e0-5fe0-11f1-8ce6-7369ee2be5a1 \
#   --block-size 4096 \
#   --trash-days 0

# ---- A组挂载（默认）----
juicefs mount -d --cache-size 0 --max-uploads 150 tikv://192.168.11.12:2379/juicefs-memdisk /mnt/juicefs

# ---- B组挂载（关预读）----
# juicefs mount -d --cache-size 0 --max-uploads 150 --max-readahead 0 tikv://192.168.11.12:2379/juicefs-memdisk /mnt/juicefs

# ---- 目录准备 ----
mkdir -p /mnt/juicefs/seq_dir
mkdir -p /mnt/juicefs/test_dir

# ====================================================================
# 阶段① 顺序类（psync, 非direct, bs=256K）
# seqread 缓存防护：--size=20G（180s 读不完一遍 20G/106MB/s≈194s>180s），且测前 drop_caches
# multi-seqread：16 jobs × 4G=64G，180s 聚合读~21G < 64G，不会读完，无缓存命中
# ====================================================================

# --- prep（写 4G 基线文件）---
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G

# --- seqread（precreate 20G + drop_caches + read 180s + bw_log）---
# 预创建 20G 文件（fio --rw=read 会先创建文件再读，但为保证 drop_caches 在创建后读前，分开执行）
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=20G
echo 3 > /proc/sys/vm/drop_caches
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=20G --time_based --runtime=180s --read_bw_log=A/seqread --log_avg_msec=1000

# --- seqwrite（time_based 180s + bw_log）---
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --time_based --runtime=180s --end_fsync=1 --write_bw_log=A/seqwrite --log_avg_msec=1000

# --- multi-seqread（precreate 64G + drop_caches + read 180s + bw_log）---
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting
echo 3 > /proc/sys/vm/drop_caches
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --time_based --runtime=180s --read_bw_log=A/multi-seqread --log_avg_msec=1000

# --- multi-seqwrite（time_based 180s + bw_log）---
fio --name=multi-seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1 --time_based --runtime=180s --write_bw_log=A/multi-seqwrite --log_avg_msec=1000

# --- 分时清理（seq_dir 数据 + 清池对象 + compact 到 0 + 确认池回空）---
# rm -rf /mnt/juicefs/seq_dir/*
# juicefs gc /mnt/juicefs  # 必须在 mounted 状态
# juicefs compact /mnt/juicefs
# ceph df（确认池回空）

# ====================================================================
# 阶段② layout（128 jobs × 1G = 128G, bs=4M, 非 time_based, +bw_log）
# ====================================================================
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 --write_bw_log=A/layout --log_avg_msec=1000

# --- layout cooldown（compact + 等 health OK）---
for osd_id in 0 1 2 3 4 5; do
  ASOK="/var/run/ceph/073f28e0-5fe0-11f1-8ce6-7369ee2be5a1/ceph-osd.${osd_id}.asok"
  ceph --admin-daemon "$ASOK" compact
done
# 轮询直到 compact_running=0

# ====================================================================
# 阶段③ 随机类（libaio, iodepth=128, numjobs=128, direct=1, time_based 180s, 3轮）
# 每轮：drop_caches → randread → randwrite → randrw
# ====================================================================

# --- randread r1 ---
echo 3 > /proc/sys/vm/drop_caches
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=180s --read_bw_log=A/randread-r1 --log_avg_msec=1000

# --- randwrite r1 ---
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=180s --write_bw_log=A/randwrite-r1 --log_avg_msec=1000

# --- randrw r1 ---
echo 3 > /proc/sys/vm/drop_caches
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=180s --read_bw_log=A/randrw-r1-read --write_bw_log=A/randrw-r1-write --log_avg_msec=1000

# --- r2, r3 同理（--read_bw_log/--write_bw_log 改为 A/randread-r2, A/randread-r3, ...）---
# （省略重复，实际逐个执行）

# ====================================================================
# B组同上，挂载加 --max-readahead 0，bw_log 前缀改 B/
# ====================================================================
