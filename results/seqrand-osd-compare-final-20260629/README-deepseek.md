# 随机读瓶颈分析

> 数据来源：seqrand-osd-compare-final-20260629
> 日期：2026-06-29

## 原始数据

| 指标 | randread | seqread |
|------|---------|---------|
| BW (baseline) | 33.8 MiB/s | 106 MiB/s |
| BW (strace下) | 33.3 | 104 |
| NIC/FIO | 3.44× | 1.09× |
| strace lines | 886K | 709K |

### OSD op_r_latency (ms)

| osd | node | randread | seqread |
|-----|------|---------|---------|
| 0 | node1 | 11.8 | 13.1 |
| 1 | node1 | 13.0 | 13.2 |
| 2 | node2 | 18.5 | 63.5 |
| 3 | node2 | 24.2 | 31.6 |
| 4 | node3 | 28.7 | 36.3 |
| 5 | node3 | 18.6 | 50.8 |

### historic_ops 单 op 时间线 (osd3, 256K read)

```
initiated → throttled → dispatched → queued → reached_pg → started → done
  0ms        0ms         0ms         0ms     0.14ms      0.03ms    193ms

排队/调度: <1ms    实际工作(started→done): 193ms
```

## 分析

1. **OSD 端 EC 随机读延迟高**：一个 256K 对象在 OSD 端处理时间 12-29ms（平均），historics 中慢 op 达 193ms。排队/调度开销 <1ms，主体在读取和 EC 重建。

2. **但 OSD 延迟不是带宽限制的直接原因**：顺序读时 OSD 延迟甚至更高（node2/3 的 seqread 延迟 > randread），但顺序读带宽仍到 106。说明单 op 延迟本身不是瓶颈，关键在于**有多少 op 能同时在飞**。

3. **随机读的并发不如顺序读**：顺序读 128 个 job 读同一个或相邻的几个文件段，请求打到少数 OSD 产生排队，但 TCP 管道持续满载（NIC/FIO=1.09×）。随机读 128 个 job 的对象 hash 到不同 primary OSD，对象间的 OSD 处理间隔导致 TCP 流断断续续（NIC/FIO=3.44×）。

4. **strace 返回分布已统计**：见 [strace-histogram.md](strace-histogram.md)。关键发现——randread 和 seqread 的 read() 返回分布**差异远小于预期**（中位 5.8KB vs 7.3KB，EAGAIN 0.8% vs 0.5%）。messenger 层面的碎片化不是 rand/seq 差异的主因。两者都碎，差别不大。真正决定 3.2× 带宽差距的因素在 OSD op 发起频率和并发度。

## 修正瓶颈判断

之前的"断流假说"(randread 时 TCP 管间断流、seqread 连续流导致 read() 碎片化差异) 已被 strace 直方图证伪。两种模式的 read() 分布几乎一样碎。

当前判断：瓶颈不在 messenger 的 socket read 粒度，而在 **OSD op 的发起密度**。顺序读 128 job 的对象连续分布在少数 OSD → ops 密集排队 → TCP 管满 → 106 MiB/s。随机读对象 hash 分散到 6 个 OSD → 每个 OSD 排队的 op 稀疏 → TCP 管道有空隙 → 33.7 MiB/s。
