# strace 顺序读分析

> 日期：2026-06-29
> 环境：JuiceFS v1.3.1 / Ceph EC 4+2 / mount --cache-size 0 (真冷态) / 1Gbps

## Ceph OSD socket 映射

| FD | 远端 | 节点 | read() 次数 |
|----|------|------|-----------|
| 29 | 192.168.11.13:6800 | ceph-node2 osd.2 | 151,075 |
| 30 | 192.168.11.14:6801 | ceph-node3 osd.5 | 144,085 |
| 31 | 192.168.11.14:6800 | ceph-node3 osd.4 | 122,191 |
| 33 | 192.168.11.11:6801 | ceph-node1 osd.1 | 125,660 |
| 34 | 192.168.11.13:6808 | ceph-node2 osd.3 | 122,619 |
| 35 | 192.168.11.11:6800 | ceph-node1 osd.0 | 15,678 |
| **合计** | | | **681,318** |

FIO: 1,024 reads, 95.0 MiB/s, 4M bs, cold cache=0
每 fio 4M read → **665 次** socket read()
每 MB 有效数据 → **166 次** socket read()

## 与随机读对比

| 指标 | 顺序读 (4M) | 随机读 (256K) | 比值 |
|------|-----------|-------------|------|
| fio 带宽 | **95.0** MiB/s | 14.4 MiB/s | 6.6× |
| buffer (期望) | 116 KB | 117 KB | ≈相同 |
| return (实际) | **8.8 KB** | 5.8 KB | 1.5× |
| 拿不到期望 10% | 65.7% | 75.6% | — |
| socket read / MB | **166** | 1,180 | **7.1×** |
| NIC / fio 有效 | **1.06×** | 3-5× | — |

## 关键发现

### buffer 大小相同，messenger 行为一致

顺序读和随机读的 messenger 行为完全一致——每次 read() 要求 ~117KB，但实际返回远小于期望。说明 **messenger 的代码路径相同，不存在"顺序读用大 buffer、随机读用小 buffer"的差异**。

### 顺序读的 NIC 放大几乎为零

顺序读的有效带宽 95 MiB/s，NIC RX 仅 ~101 MiB/s，放大仅 1.06×。随机读的 NIC 放大 3-5×。差别不在 messenger，在 **OSD 端数据处理模式**：

- **顺序读**：4M 块对应连续的 JuiceFS chunk，落在同一个或少数几个 primary OSD。OSD 一次定位后可以流水线式连续吐数据，TCP 管道几乎满载。
- **随机读**：每个 256K 块 hash 到随机 primary OSD。每个对象需要 OSD 重新查 BlueStore → 拉其他分片 → 拼合 → 返回，对象间存在处理间隔，TCP 管道出现"断流—续流"模式。

### 根因定位

不是 messenger 碎读（buffer 一样大，117KB），不是网卡太窄（顺序读轻松到 95 MiB/s）。

**根因在 OSD 端：EC 随机读每个对象的高延迟处理（查 BlueStore + 跨 OSD 拉分片 + 拼合）导致输出流断断续续，epoll 在续流时只攒了少量 segment。**

## 采集命令

```bash
# strace
sudo strace -f -e trace=read -p <juicefs-worker-pid> -o strace-seq.log

# fio seqread
fio --name=seqread --directory=/mnt/juicefs/test_seq --rw=read --bs=4M --size=4G
```

## 文件清单

```
strace-seqread-20260629/
├── README.md          本文件
├── strace-seq.log     111 MB  strace -f 完整输出
├── fio-seq.txt        1.6 KB  fio 输出 (95.0 MiB/s)
└── env.txt            测试参数
```
