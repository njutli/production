# strace 读放大重测分析

> 日期：2026-06-26
> 目的：用 strace 精确分解 JuiceFS 读放大（fio 每个 256K 读触发多少次 Ceph socket read）
> 相关文档：`doc/perf-analysis/10_A_2_3-tcpdump-metadata-cache-results.md`

## 测试环境

| 项 | 值 |
|----|-----|
| JuiceFS | v1.3.1 |
| block-size | 256K |
| 存储 | ceph (librados 直连)，池 juicefs-data (EC 4+2) |
| 挂载 | `--cache-size 0`（真冷态，prefetch 强制禁用） |
| 客户端 | tikv-node (192.168.11.12)，千兆网卡 |
| 工作集 | 8 files × 1G = 8G |
| fio | bs=256k, randread, libaio, iodepth=128, numjobs=8, direct=1, runtime=15-30s |

## Ceph OSD 连接

JuiceFS 进程 (PID 839578, 88 线程) 的 Ceph OSD socket FD 映射：

| FD | 目标 | 节点 |
|----|------|------|
| 28 | 192.168.11.14:6800 | ceph-node3 (osd.4) |
| 29 | 192.168.11.11:6800 | ceph-node1 (osd.0) |
| 30 | 192.168.11.11:6801 | ceph-node1 (osd.1) |
| 31 | 192.168.11.13:6800 | ceph-node2 (osd.2) |
| 33 | 192.168.11.13:6802 | ceph-node2 (osd.3) |
| 34 | 192.168.11.14:6801 | ceph-node3 (osd.5) |

## strace 方法

```bash
# 追踪 juicefs worker 进程的全部 read() 系统调用（含所有子线程）
sudo strace -f -e trace=read -p 839578 -o strace-final.log

# 同时运行 fio
fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=8 --direct=1 \
    --fallocate=none --group_reporting --time_based --runtime=30s

# fio 结束后等 10s 排空再 detach
```

> **关键发现**：Ceph socket I/O 发生在 librados 子线程中，必须用 `strace -f` 跟踪全部线程。不用 `-f` 只能看到 `/dev/fuse` (FD 32) 的 read()，完全抓不到 Ceph 数据读取。

## 分析结果

### read() 调用次数

| FD | 总调用 | 每 fio read | 节点 |
|----|--------|-----------|------|
| 28 | 48,044 | 22.2 | ceph-node3 |
| 29 | 9,359 | 4.3 | ceph-node1 |
| 30 | 40,735 | 18.9 | ceph-node1 |
| 31 | 62,219 | 28.8 | ceph-node2 |
| 33 | 64,710 | 30.0 | ceph-node2 |
| 34 | 68,001 | 31.5 | ceph-node3 |
| **合计** | **293,068** | **~133** | 6 OSD |

FIO 有效读：2,160 reads (15s 运行，35.9 MiB/s)
每 fio 256K 读 ≈ 133 次 Ceph socket read()

### 每次 read() 的平均大小

已完成读（约占 15%，大部分在 strace detach 时仍在进行中）的平均大小：

| FD | 平均字节/读 |
|----|-----------|
| 28 | ~7,236 |
| 29 | ~5,270 |
| 30 | ~6,119 |
| 31 | ~7,185 |
| 33 | ~5,094 |
| 34 | ~5,296 |

**平均 ~5-7KB/次**——librados messenger 将 EC 分片拆成大量小粒度 TCP 帧读取，每次 read() 只拿到 5-7KB，协议头和帧边界开销堆叠出 ~3× 放大。

### 放大链路

```
fio 1×256K 随机读
  → JuiceFS: 查 TiKV 元数据获取 chunk 位置 (~1-2 TCP round trip)
  → librados: 连接 4 个 data OSD (EC 4+2 擦除码)
  → 每连接 ~33 次 read() syscall (~5-7KB/次)
  → 合计 ~133 次 socket read, NIC 总流量 ~700-900 KB
  → 有效数据仅 256 KB → 应用层放大 ~3× (NIC 2.5-3.0×)

syscall 层放大（strace 字节 / fio 字节）≈ 2.60×
NIC 层放大（网卡 RX / fio 有效读）≈ 2.5-3.0×
```

### 与 10_A_2_3 的对账

| 指标 | 10_A_2_3 原始 | 本次重测 |
|------|-------------|---------|
| read() / fio read | 139 | ~133 |
| 参与 OSD | 4 (逻辑) | 6 FD (物理连接) |
| NIC/有效读 比 | 2.5-3.0× | ~3.1× |
| 每次 read() 粒度 | ~5KB | ~5-7KB |

差异在可接受范围 (133 vs 139)，strace 窗口含 idle 期少计了尾端读取。

## 结论

- 每 fio 256K randread → ~133 次 Ceph socket read() —— **不是 JuiceFS 多拿了数据，是拿的方式太碎**
- librados messenger 把 4×64K EC 分片拆成 ~5-7KB 粒度的 TCP socket read，协议头开销堆叠放大
- Slice 碎片非主因（8 文件 × 1G 顺序 layout，无碎片历史，仍 ~133 read/fio）
- 与 10_A_2_3 原始分析一致

## 原始数据文件

```
strace-rerun-20260626/
├── strace-final.log   129 MB  strace -f 原始输出 (30s fio + drain)
├── strace-ceph3.log    62 MB  strace -f 原始输出 (15s fio, 计数用)
├── ceph-both.pcap      1.7 GB tcpdump 双向 Ceph 流量 (端口 6800-6803)
└── README.md              本文件
```
