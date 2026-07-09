# Write Push 测试报告

> 目标：在 patched v1.3.1 + 冷态(cache=0) + 默认 ra 下，用 max-uploads / buffer-size 推三项写过 59 MB/s。
> 日期：2026-07-04

## 最终结论

**冷态达标：4/5 项**（从 2 项增加 2 项：顺序写 + 随机写）

| 达标项 | 最优值 | 最优配置 |
|--------|--------|---------|
| 顺序读 | 80.1 | mu=150 |
| 多线程读 | 109 | mu=150 |
| **顺序写** | **64.0** | **mu=150** |
| **随机写** | **63.7**（或 76.9） | **mu=150**（或 mu=300+buf=1G） |
| ~~多线程写~~ | 41.1 | EC 写放大 + BlueFS stall 受限 |

## 参数扫描结果

| Grid | 挂载参数 | seqwrite r1 | randwrite r1 | multi-seqwrite |
|------|---------|-------------|-------------|----------------|
| A1 | `--max-uploads 150` | **64.0** MiB/s ✓ | **63.7** MiB/s ✓ | 41.1 ✗(stall) |
| A2 | `--max-uploads 200` | **61.3** ✓ | **65.9** ✓ | 38.4 ✗(stall) |
| A3 | `--max-uploads 300` | 45.8 ✗ | 51.4 ✗ | N/A(skipped) |
| B2 | `--max-uploads 300 --buffer-size 1024` | 45.0 ✗ | **76.9** ✓ | N/A(skipped) |

## 关键发现

1. **顺序写 + 随机写已达标**：mu=150 下顺序写从 57.0→64.0（+12%），随机写从 55.7→63.7（+14%），双双过 59。
2. **mu 的最优点在 150-200**：mu=150 最均衡，mu=200 随机写微升但顺序写微降；mu=300 严重退化（seqwrite 跌至 45.8）。
3. **buffer-size 对 mu=300 有奇效但仅限随机写**：mu=300+buf=1G 随机写 76.9（+50% vs mu=300 的 51.4），但顺序写仍 45.0。buffer 对 mu=150/200 未测，因已达标。
4. **多线程写无法达标**：16 并发顺序写必然触发 BlueFS DB 读停滞（WAL/DB 与 Data 共享物理 SSD）。gap=17.9，属 EC 写放大 + 单千兆物理 + BlueFS stall 三重限制。
5. **mu=150 → mu=200 → mu=300 趋势**：顺序写单调下降（64.0→61.3→45.8），随机写先升后降（63.7→65.9→51.4）。mu 过高增加 upload 线程竞争降低单线程效率。
6. **NIC_RX 均正常**：所有值在 49-81 MB 区间，未超出千兆线速限制。

## 最优配置推荐

```
--cache-size 0 --max-uploads 150
```

不推荐加大 mu/buffer（会 hurt seqwrite），不推荐 mu=300+buf=1G（随机写虽达 76.9 但顺序写跌至 45.0 不达标）。

## 多线程写残余瓶颈

- 16 并发顺序写 → 64GB 连续写入 → WAL/DB compaction 跟不上 → BlueFS stall
- 即使无 stall，基线 43.7 距 59 差 15.3
- 单千兆 EC 4+2 写放大 1.5×，理论净带宽 ~79 MB/s
- **不属 JuiceFS 软件瓶颈，属硬件/EC 物理限制**。需多客户端聚合或升级万兆网卡/NVMe WAL。

## 结果数据目录

```
results/write-push-20260704/
├── mu150/    (seqwrite-r1, randwrite-r1, multi-seqwrite-r1)
├── mu200/    (seqwrite-r1, randwrite-r1, multi-seqwrite-r1 + mount.log)
├── mu300/    (summary.md, seqwrite-r1/2/3, randwrite-r1/2/3)
└── mu300-buf1g/  (summary.md, seqwrite-r1/2/3, randwrite-r1/2/3)
```
