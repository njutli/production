#!/bin/bash
# 完整命令记录：后端 rados 裸能力全量诊断
# 日期：2026-07-07 ~ 2026-07-08

# ---- 环境清理 ----
juicefs destroy tikv://192.168.11.12:2379/juicefs-prod e35bc2b1-9f75-4bf8-9129-d30d383c5fff --yes
sudo ceph orch daemon restart osd.0  # 清除 BlueStore slow ops

# ---- 净态确认 ----
sudo ceph health                                    # HEALTH_OK
sudo rados df -p juicefs-data                       # 0 objects
for osd_id in 0 1 2 3 4 5; do
  sudo ceph tell osd.$osd_id perf dump              # compact_queue_len=0, running=0
  sudo ceph tell osd.$osd_id config get bluestore_prefer_deferred_size  # =65536
done

# ---- 实验一 2A: 并发扫描 ----
# 每档 3 轮，轮间: cleanup + compact + health check
for t in 16 32 64 128; do
  for r in 1 2 3; do
    sudo rados -p juicefs-data cleanup
    for osd_id in 0 1 2 3 4 5; do sudo ceph tell osd.$osd_id compact; done
    sudo ceph health
    sudo rados bench -p juicefs-data 300 write -b 256K -t $t --no-cleanup
    sudo rados -p juicefs-data cleanup
  done
done

# ---- 实验一 2B: 全量四项 (t64) ----
# write: 复用 2A t64 数据
# seq read: prefill 600s -> rados bench 300 seq
sudo rados bench -p juicefs-data 600 write -b 256K -t 16 --no-cleanup
for r in 1 2 3; do
  sudo rados bench -p juicefs-data 300 seq -t 64
done
# rand read: prefill 120s -> rados bench 300 rand
sudo rados bench -p juicefs-data 120 write -b 256K -t 16 --no-cleanup
for r in 1 2 3; do
  sudo rados bench -p juicefs-data 300 rand -t 64
done

# ---- 实验二: 块大小矩阵 (t64, 120s) ----
for bs in 4K 64K 256K 1M 4M; do
  for r in 1 2 3; do
    sudo rados -p juicefs-data cleanup
    sudo rados bench -p juicefs-data 120 write -b $bs -t 64 --no-cleanup
  done
  sudo rados -p juicefs-data cleanup
  sudo rados bench -p juicefs-data 120 write -b $bs -t 16 --no-cleanup  # prefill
  for r in 1 2 3; do
    sudo rados bench -p juicefs-data 120 rand -t 64
  done
done

# ---- 实验三: EC vs 副本对照池 ----
# 建副本池
sudo ceph osd pool create rep3-test 32 32 replicated
sudo ceph osd pool set rep3-test size 3
sudo ceph osd pool set rep3-test min_size 2
sudo ceph osd pool application enable rep3-test bench
# 测试 (256K + 4M, write + randread, 3 rounds)
for bs in 256K 4M; do
  for r in 1 2 3; do
    sudo rados -p rep3-test cleanup
    sudo rados bench -p rep3-test 120 write -b $bs -t 64 --no-cleanup
  done
  sudo rados -p rep3-test cleanup
  sudo rados bench -p rep3-test 120 write -b $bs -t 16 --no-cleanup  # prefill
  for r in 1 2 3; do
    sudo rados bench -p rep3-test 120 rand -t 64
  done
done
# 删池回滚
sudo ceph config set mon mon_allow_pool_delete true
sudo ceph osd pool delete rep3-test rep3-test --yes-i-really-really-mean-it
sudo ceph config rm mon mon_allow_pool_delete
