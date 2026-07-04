# 随机读瓶颈定位 —— 数据汇总

> 日期：2026-06-30
> 环境：JuiceFS v1.3.1 / Ceph 17.2.8 / 1Gbps / mount --cache-size 0
> 工作集：128G (128×1G) / block-size=256K / fio: nj=128, direct=1, runtime=60s

## 核心发现：副本池也有 ~3× NIC 放大 —— EC 取片不是主因

| 池类型 | r1 BW | NIC/FIO |
|--------|-------|---------|
| EC 4+2 | 33.8 MiB/s | 3.44× |
| 副本 size=3 | 36.3 MiB/s | **3.15×** |

副本池没有 EC 分片、没有跨 OSD 重建——但 NIC 放大仍有 3.15×。EC 贡献的差额仅 0.29×（~9%）。**3× 放大的主体不在 EC 层。**

## A1: TCP 在途并发（ss 采样）

数据文件：`a1-ss-randread.txt` / `a1-ss-seqread.txt`（各 10 次采样，间隔 2s）
待提取：Recv-Q / Send-Q / cwnd / unacked / rtt

## A2: JuiceFS 线程状态

数据文件：`a2-threads-randread.txt` / `a2-threads-seqread.txt`
待提取：线程数、wchan 分布、是否大量卡同一函数

## A3: buffer-size sweep

| buffer-size | r1 | r2 | r3 |
|------------|----|----|-----|
| 300 MB (default) | 33.6 | 34.7 | 34.1 |
| 600 MB | 33.8 | 34.7 | 34.1 |
| 2048 MB | 33.9 | 34.2 | 34.0 |

**零效果**。读侧缓冲不是瓶颈。

## A4: pprof

跳过（v1.3.1 无内置 pprof 端口）

## B1-B4: 副本池全部数据

- `b2-replica-r{1,2,3}.txt`：副本池 randread 3 轮（无 strace）
- `b3-ec-r{1,2,3}.txt`：同时段 EC 池对照 3 轮
- `b4-fio.txt` / `b4-strace.log`：副本池 strace

## 文件清单

```
randread-bottleneck-20260630/
├── README.md                     本文件
├── a1-ss-sampling.sh             A1 采集脚本
├── a1-ss-randread.txt            ss 采样 (randread)
├── a1-ss-seqread.txt             ss 采样 (seqread)
├── a1-randread-fio.txt           fio 输出
├── a1-seqread-fio.txt            fio 输出
├── a2-threads-randread.txt       ps -L 输出 (randread)
├── a2-threads-seqread.txt        ps -L 输出 (seqread)
├── a2-jfs-status.txt             juicefs status
├── a2-jfs-cmdline.txt            挂载参数
├── a3-bs{300,600,2048}-r{1,2,3}.txt  buffer-size sweep
├── b2-replica-r{1,2,3}.txt       副本池 randread
├── b3-ec-r{1,2,3}.txt            EC 池对照
├── b4-fio.txt                    副本池 strace fio
└── b4-strace.log                 副本池 strace (1.3M lines)

## 多客户端聚合验证（multiclient-randread-20260630）

| 阶段 | tikv | node1 | node2 | 聚合 | vs P1 |
|------|------|-------|-------|------|-------|
| P1 (1 cl) | 33.8 | — | — | **33.8** | 1.00× |
| P2 (2 cl) | 26.3 | 24.4 | — | **50.7** | 1.50× |
| P3 (3 cl) | 18.1 | 18.0 | 15.2 | **51.3** | 1.52× |

P2→P3 几乎无增长，聚合天花板 ~51 MiB/s。距目标 59 差 14%。
```
