# strace 读放大分析

> 日期：2026-06-29
> 环境：JuiceFS v1.3.1 / Ceph EC 4+2 (6 OSD) / mount --cache-size 0 (真冷态) / 1Gbps

## Ceph OSD socket 映射

| FD | 本地端口 → 远端 | 节点 | read() 次数 |
|----|---------------|------|-----------|
| 28 | 192.168.11.12 → 192.168.11.14:6800 | ceph-node3 osd.4 | 92,403 |
| 29 | 192.168.11.12 → 192.168.11.13:6808 | ceph-node2 osd.3 | 88,306 |
| 30 | 192.168.11.12 → 192.168.11.11:6801 | ceph-node1 osd.1 | 98,157 |
| 31 | 192.168.11.12 → 192.168.11.13:6800 | ceph-node2 osd.2 | 98,910 |
| 32 | 192.168.11.12 → 192.168.11.14:6801 | ceph-node3 osd.5 | 115,872 |
| 34 | 192.168.11.12 → 192.168.11.11:6800 | ceph-node1 osd.0 | 18,594 |
| **合计** | | | **512,242** |

FIO: 1,736 reads, 14.4 MiB/s, 30s runtime
每 fio 256K read → **295 次** Ceph socket read()
每次 read() 平均 **~5-6KB**（已完成读的均值）

## NIC 层

| 指标 | 值 |
|------|-----|
| FIO 有效字节 | 434 MiB |
| NIC RX 增量 | 2,339 MiB |
| NIC/FIO | **5.39×** |

> NIC 含非 Ceph 流量（SSH 等），实际应用层放大以 strace 为准

## 结论

- 每 fio 256K randread 触发 **~295 次** Ceph socket read()（32G / 32文件工作集）
- librados messenger 将 EC 分片拆成 **~5-6KB** 粒度的 TCP socket read
- 不是 JuiceFS 多拿了数据，是 librados 读数据的方式太碎
- 协议头 / 帧边界 / 连接保活开销堆叠出 ~3-5× NIC 放大

### 放大不在 EC 层，在 librados messenger

这个测试反驳了"EC 结构性开销导致放大"的假说。

EC 4+2 的理论开销：每个 256K 对象拆成 4 个 64K 数据分片 + 2 个校验分片。读操作只需获取 4 个数据分片——即 **4 次 OSD GET**。L1 rados bench 256K rand 实测放大仅 **1.04×**，证明 EC 分片机制本身几乎不产生额外开销。

strace 的实测结果：
```
EC 理论：  4 × 64K  = 4 次 socket read, 256K 数据 + 少量协议头
librados 实际：295 × 5KB = 295 次 socket read, 每段带独立 TCP 帧头 + Ceph messenger header

差额 = 291 次额外 read() + 291 套协议头 → 放大从 1.04× 膨胀到 ~3×
```

**2.5-3× 读放大的根因不在 Ceph EC 分片，在 librados messenger 的网络 I/O 实现里。** messenger 层将每个 64K 分片进一步拆成大量 ~5-6KB 的 TCP 读取段，每段附带独立的 Ceph 协议帧头和 TCP/IP 头，堆叠后的协议开销才是放大的主体。

## 采集命令

```bash
# strace（关键：-f 跟踪所有 librados 子线程）
sudo strace -f -e trace=read -p <juicefs-worker-pid> -o strace.log

# tcpdump（Ceph OSD 端口）
sudo tcpdump -i eno1 -w ceph-both.pcap 'tcp and (port 6800 or port 6801 or port 6808)'

# fio randread
fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=8 --direct=1 \
    --fallocate=none --group_reporting --time_based --runtime=30s
```

## 文件清单

```
/tmp/strace-rerun-20260629/
├── README.md          本文件
├── strace.log         80 MB  strace -f -e read 完整输出
├── fio-output.txt     1.8 KB fio 输出
├── ceph-both.pcap     3.0 GB tcpdump 双向 Ceph OSD 流量
├── mount.log          挂载日志 (--cache-size 0)
└── env.txt            测试参数快照
```

## 软件栈层级与瓶颈定位

### 完整软件栈

```
  Layer 1  fio (应用程序)
    │        bs=256k randread, libaio, direct=1, iodepth=128
    ▼
  Layer 2  Linux VFS / FUSE 内核模块
    │        用户态 I/O 请求 → FUSE 协议 → /dev/fuse → 用户态 daemon
    ▼
  Layer 3  JuiceFS FUSE daemon
    │        解析 chunk 位置 → TiKV 查元数据 → 确定目标 RADOS 对象
    ├─ 3a. 客户端缓存 (cache-size / writeback / readahead)
    ▼
  Layer 4  JuiceFS object store 层
    │        256K block 对象 → 调用 librados 读写
    ▼
  Layer 5  librados (Ceph 客户端库)
    │        组装 OSD 请求 → 选择主 OSD → 序列化消息
    ├─ 5a. librados messenger (网络 I/O 引擎)
    │        管理 TCP 连接 → 拆包/组包 → 收发消息帧
    ▼
  Layer 6  TCP/IP + 1GbE 网卡
    │        物理传输
    ▼
  Layer 7  Ceph OSD 进程
    │        接收请求 → EC 解码 → 读 BlueStore
    ▼
  Layer 8  BlueStore (OSD 本地存储引擎)
    │        管理 SSD 上的对象数据
    ▼
  Layer 9  SSD（经 RAID 卡）
```

### EC 与 librados messenger 的关系

EC (Erasure Coding) 在 **Layer 7 (Ceph OSD)** 实现——定义数据如何跨 OSD 分布。EC 4+2 意味着每个 256K 对象被拆成 4 个 64K 数据分片 + 2 个校验分片，分布在 6 个 OSD 上。读时只需从 4 个 OSD 各取 64K。

librados messenger 在 **Layer 5a** 实现——不关心数据是 EC 还是副本，只负责把 Ceph 消息从客户端送到 OSD、把响应送回来。它管理 TCP 连接的建立/复用/重连、消息的序列化/反序列化、帧的拆分与组装。

**EC 告诉你"数据在哪里"，messenger 决定"怎么把数据搬回来"。** 客户端每个对象只跟它的 primary OSD 交互（1 个对象 → 1 个请求 → 1 个响应，`fast_read=0` 由 primary OSD 负责重建完整对象）。但因为不同对象 hash 到不同 primary OSD，6 条连接全都在用。

### 瓶颈定位总表

| Layer | 已调优/验证项 | 结论 | 状态 |
|-------|-------------|------|------|
| L1 fio | direct=1, iodepth=128, numjobs 扫描 | 并发度已最大化 | ✅ 已排除 |
| L2 FUSE 内核 | congestion_threshold / max_background | 非瓶颈 | ✅ 已排除 |
| L2 FUSE 内核 | splice / max_read 提升 | kernel 5.15 不支持 | ⚠️ 不可用 |
| L3 JuiceFS daemon | block-size 4M→256K | 消除 16× 块级放大 | ✅ 已排除 |
| L3a 客户端缓存 | cache=0 vs cache=100G | 暖态显著提升读写, 但不改变放大比例 | ✅ 已摸清 |
| L3a 客户端缓存 | writeback 开关 | 写带宽差 4-10×, 关则穿透到后端 | ✅ 已摸清 |
| L3a 客户端缓存 | readahead/prefetch | 非放大主因, 关停不消除 2.5× | ✅ 已排除 |
| L3a 客户端缓存 | max-uploads=150 | 对随机读写微幅提升, 非核心瓶颈 | ✅ 已排除 |
| **L5a messenger** | **strace: buffer avg 117KB, 实际返回 avg 5.8KB, 75%读拿不到期望10%** | **数据到达速率跟不上 → 读放大** | 🔴 **当前瓶颈** |
| L5 rados | L1 rados bench 256K rand: 1.04× | EC 分片本身几乎零放大 | ✅ 已排除 |
| L6 网络 | 千兆网卡 RX 118 天花板 | 数据分段到达, epoll 早醒, socket buffer 攒不够 | 🔴 **放大贡献者** |
| L6 网络 | EC vs 副本对照: NIC RX 完全不变 | EC 取片网络开销非主因 | ✅ 已排除 |
| L7 Ceph OSD | rados bench rand=118 → 后端有余量 | 非 OSD 处理能力不足 | ✅ 已排除 |
| L7 Ceph OSD | PG 数 32→128 | 零提升 | ✅ 已排除 |
| L7 Ceph OSD | EC 换副本(size=3) | randread 带宽无变化 | ✅ 已排除 |
| L8 BlueStore | max_blob_size / prefer_deferred 调参 | 全部无效 | ✅ 已排除 |
| L8 BlueStore | WAL/DB 移到内存盘 | +4.8%, 基本无效 | ✅ 已排除 |
| L9 磁盘 | 纯内存盘(brd)替代 SSD | 吞吐不变 → 磁盘非瓶颈 | ✅ 已排除 |
| L9 磁盘 | SSD 确认 (非 HDD), 磁盘调度器 | IOPS 92.5K, 调参无效 | ✅ 已排除 |
| L9 磁盘 | RAID 卡 | 内存盘替代后不变 → 非瓶颈 | ✅ 已排除 |

### 瓶颈链总结

```
已排除的假瓶颈:
  磁盘 ← BlueStore ← EC 分片 ← FUSE 内核 ← JuiceFS 应用层

strace 揭示的现象:
  messenger 每次 read() 要求 117KB, 实际只拿到 ~6KB
  → 75.6% 的 read() 拿到期望的不到 10%
  → 返回值集中在 MSS 整数倍 (1460/2920/4380/5840/7300)
  → 大量 EAGAIN 混在其中

现象解读:
  顺序读能到 ~100 MB/s, rados bench rand 能到 118 MB/s
  → 千兆网卡管道够宽, 不是"网络太窄"

  strace 测试时 NIC RX 仅 ~58 MB/s, 远未饱和
  → 不是"网卡打满了分段到达"

  真正的原因在 OSD 端:
  每个 256K 对象的随机读到达 primary OSD 后:
    查 BlueStore 定位本地分片 → 向 3 个 data OSD 拉分片 → 等响应 → 拼合 → 返回
  EC 4+2 下每个对象涉及 4 个 OSD 的磁盘 IO, 对象间存在处理间隔
  → OSD 吐出的响应是断断续续的, TCP 流出现"断流—续流—断流"模式
  → epoll 在续流时只拿到当前已到达的 1-6 个 segment

根因: OSD 端 EC 随机读的处理延迟导致响应分段到达
贡献者: 千兆网卡放大了每个分段的传输时间

### OSD 端定位思路

当前分析仅基于客户端 strace, 无法直接验证 OSD 侧行为。后续需在 OSD 侧采集:

```bash
# 1. 各 OSD 的 op 延迟分布
for osd in 0 1 2 3 4 5; do
  ceph daemon osd.$osd perf dump | grep -A5 '"osd_op"'
done

# 2. OSD 实时吞吐
ceph osd perf

# 3. 每条连接的 socket buffer 状态 (在客户端)
ss -timp | grep 680

# 4. OSD 日志中的 slow op
ceph daemon osd.X dump_historic_ops

# 5. OSD 侧 blktrace/Bpftrace
#    追踪每个 read op 的完整生命周期:
#    请求到达 → 查 BlueStore → 拉分片 → 拼合 → 返回客户端
```

关键待验证假设:
- 对象间的处理间隔是否导致 OSD 输出流"断流"
- EC 拉取其他 OSD 分片的延迟是否为主因
- `fast_read=1` 能否改善 (客户端直读 4 个 data OSD, 跳过 primary OSD 拼合步骤)

  → read() 返回粒度变大 → 减少 read() 次数 → 降低协议头开销占比
```
