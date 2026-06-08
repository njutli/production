# 性能瓶颈实测数据记录

> 采集时间：2026-06-08
> 目的：在做任何调优前，先用基准命令隔离各层，定位真实瓶颈。
> 结论速览：**瓶颈在 Ceph 后端，且根因是 ceph-node1/node2 网卡只协商到 100Mb/s。**

---

## 背景：调优前的两组 fio 结果

测试命令（用户最终验收口径，256k 随机读写、128 并发、direct）：

```bash
fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --nrfiles=100 --filesize=1G --size=1G --bs=256k --rw=randrw \
    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
    --fallocate=none --create_on_open=1 --openfiles=100 \
    --group_reporting --time_based --runtime=60s
```

| 阶段 | READ | WRITE |
|------|------|-------|
| 优化前 | （无读数据） | 16.9 MiB/s (17.7 MB/s) |
| 加 JuiceFS 客户端优化后 | 5271 KiB/s (5.4 MB/s) | 38.8 MiB/s (40.7 MB/s) |

> 注意：38.8 MiB/s 这个"提升"是 `--writeback` 把数据先写进本地缓存盘造成的假象，
> 并非后端真实能力（见下方 rados bench 仅 9.87 MB/s）。

---

## 排查 1：OSD 盘类型 —— 全部 HDD

```
# ceph-node1 / node2 / node3 lsblk -d -o NAME,ROTA,SIZE,MODEL
sda      1 446.6G PERC H730 Mini       # ROTA=1 → 机械盘
sdb      1 953.3G PERC H730 Mini       # ROTA=1 → 机械盘
```

Ceph 自身识别（ceph osd metadata）：

```
osd.0..5:
  bluestore_bdev_rotational: "1"
  bluestore_bdev_type: "hdd"
  rotational: "1"
  device: DELL PERC H730 Mini  (RAID 卡后挂的机械盘)
```

OSD 树（3 host × 2 OSD = 6 OSD，符合 EC 4+2）：

```
-1  2.29819  root default
-3  0.43619    host ceph-node1
 0  hdd 0.21809  osd.0   up
 1  hdd 0.21809  osd.1   up
-5  0.93100    host ceph-node2
 2  hdd 0.46550  osd.2   up
 3  hdd 0.46550  osd.3   up
-7  0.93100    host ceph-node3
 4  hdd 0.46550  osd.4   up
 5  hdd 0.46550  osd.5   up
```

**结论**：6 个 OSD 全是机械盘。EC 4+2 在 HDD 上做随机小写有严重读改写放大。

---

## 排查 2：网络带宽 —— node1/node2 仅 100Mb/s（关键！）

```
ceph-node1:  Speed: 100Mb/s     ← 严重瓶颈
ceph-node2:  Speed: 100Mb/s     ← 严重瓶颈
ceph-node3:  Speed: 1000Mb/s
tikv-node:   Speed: 1000Mb/s
```

- 100Mb/s ≈ **12.5 MB/s** 线速。
- **RGW 部署在 ceph-node1 上**，所有 JuiceFS S3 流量挤过这个 12.5 MB/s 的网口。
- EC 4+2 写入时，RGW 还要把分片分发到分布在各节点的 6 个 OSD，
  node1↔node2 之间的 100Mb/s 链路被反复占用。

**结论**：这是整套系统的头号物理瓶颈。

---

## 排查 3：裸盘性能 —— 420 MiB/s（盘本身不慢）

在 ceph-node1 本地盘做 256k 随机写（4 并发，direct）：

```
fio --name=rawdisk --directory=/home/turboai/lilingfeng/test_dir \
    --rw=randwrite --bs=256k --size=2G --numjobs=4 --iodepth=32 \
    --direct=1 --runtime=30 --time_based --group_reporting

WRITE: bw=420MiB/s (441MB/s), io=12.3GiB, run=30003msec
  clat avg=2364us   util=99.75%
```

**结论**：单盘（PERC H730 RAID 卡带缓存）随机写能到 420 MiB/s，
盘**不是**瓶颈。后端慢的原因在网络与 EC 编排，不在磁盘介质本身。

---

## 排查 4：rados bench 直压后端 —— 9.87 MB/s，延迟 17.6 秒（灾难级）

绕过 JuiceFS / TiKV / FUSE，直接压 EC 数据池：

### 写

```
rados bench -p default.rgw.buckets.data 30 write -t 64 --no-cleanup

Bandwidth (MB/sec):     9.87078
Average Latency(s):     17.6648
Max latency(s):         26.3866
Stddev Bandwidth:       27.222   (带宽剧烈抖动，多次掉到 0)
```

### 读

```
rados bench -p default.rgw.buckets.data 30 rand -t 64

Bandwidth (MB/sec):   11.6503
Average Latency(s):   15.5101
Max latency(s):       30.8749
```

**结论**：
- 后端 EC 池写仅 9.87 MB/s、读 11.65 MB/s，平均延迟 15~18 秒。
- 带宽抖动到 0、延迟十几秒，是**网络严重拥塞/丢包**的典型特征
  （裸盘明明 420 MiB/s，所以不是磁盘问题）。
- 9.87 MB/s 已经逼近 100Mb/s 网卡的 ~12.5 MB/s 线速上限。

---

## 数据汇总对照

| 层 | 实测能力 | 是否瓶颈 |
|----|---------|---------|
| 单 HDD（RAID 卡）裸盘随机写 | 420 MiB/s | 否 |
| node3 / tikv 网卡 | 1000 Mb/s (~118 MB/s) | 否 |
| **node1 / node2 网卡** | **100 Mb/s (~12.5 MB/s)** | **是（根因）** |
| Ceph EC 后端（rados bench 写） | 9.87 MB/s | 是（被网络拖死） |
| JuiceFS+writeback fio 写 | 38.8 MiB/s（缓存假象） | — |

一句话：**软件层全都没问题，瓶颈是 node1/node2 的 100Mb/s 网卡，
导致 Ceph EC 后端只能跑出 ~10 MB/s。**
