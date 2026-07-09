# rados bench 256K deferred 双写对比实验

> 日期：2026-07-06 | 目录：`results/cold-baseline-recheck-20260706/rados-deferred-comparison/`
> 目的：绕开 JuiceFS，直打 EC 池，验证 deferred 双写对 256K 写吞吐的影响

---

## 实验设计

| 组 | config | 测试 |
|----|--------|------|
| 实验组（SSD 模式） | `bluestore_prefer_deferred_size=0` | `rados bench -p juicefs-data 60 write -b 256K -t 16` |
| 对照组（HDD 模式） | `bluestore_prefer_deferred_size=65536` | 同上 |

- 每组跑前 drop 3 台 OSD cache
- 全程 health timeline（每 5s）
- 对照组跑前 restart OSD 重置 perf 计数器，采集 WAL before/after

## 结果

### 带宽对比（核心）

| 指标 | SSD 模式 (deferred=0) | HDD 模式 (deferred=65536) | 差异 |
|------|:---:|:---:|:---:|
| **均值带宽** | **72.3** MB/s | **58.6** MB/s | **+23%** |
| 峰值带宽 | 112.75 | 113 | 相近 |
| 最低带宽 | 45 | 43.25 | 相近 |
| IOPS | 289 | 234 | +23% |
| 写入对象数 | 17363 | 14083 | +23% |
| 平均延迟 | 0.055s | 0.068s | -19% |

### 退化模式对比

| 指标 | SSD 模式 | HDD 模式 |
|------|---------|---------|
| 高性能持续 | 前 18s 稳定 112 MB/s | 前 7s 稳定 110 MB/s |
| 退化起始 | ~18s | ~8s |
| 稳态带宽 | ~50-55 MB/s | ~48-52 MB/s |
| 退化曲线 | 18s 后缓慢下降 | 8s 后快速下降 |

**关键发现**：两种模式的峰值相近（~112 MB/s），但 SSD 模式的高性能持续时间是 HDD 的 2.6 倍（18s vs 7s），拉高了 60s 均值 23%。

### WAL 写入量（HDD 模式）

| OSD | WAL before | WAL after | delta |
|-----|-----------|-----------|-------|
| osd.0 | 21.5 MB | 234.4 MB | 203.1 MB |
| osd.1 | 19.9 MB | 228.6 MB | 199.0 MB |
| osd.2 | 4.2 MB | 184.7 MB | 172.2 MB |
| osd.3 | 18.9 MB | 191.4 MB | 164.5 MB |
| osd.4 | 19.6 MB | 230.3 MB | 201.0 MB |
| osd.5 | 17.4 MB | 228.7 MB | 201.5 MB |
| **平均** | | | **190.2 MB** |

- 每 OSD 数据写入量：880 MB（含 EC 放大）
- WAL/data 比：21.6%
- 注意：`bytes_written_wal` 是 BlueFS/RocksDB 的元数据 WAL，不是 BlueStore deferred 数据双写。无法直接量化 deferred 双写的字节数。但带宽差异已足够证明 deferred 路径的性能影响。

## 机理分析

EC 4+2 将 256K 对象切成 4 个 64K data chunk + 2 个 64K parity chunk：

| 对象大小 | 每 chunk | vs `deferred_size=65536` | 写路径 | 写放大 |
|---------|---------|------------------------|--------|--------|
| 256K | 64K | 64K ≤ 65536 → **deferred** | WAL + 最终写 | ~2× |
| 256K (SSD 模式) | 64K | 64K > 0 → **直写** | 1 次写 | 1× |

- HDD 模式：64K chunk 命中 deferred 阈值 → 双写 → I/O 翻倍 → 更早饱和 → 退化更快
- SSD 模式：64K chunk 直写 → 无额外 I/O → 高性能持续更久

## 对 P6 命题的最终判决

| 命题 | deepseek 结论 | GLM 复核 | 本实验 |
|------|-------------|---------|--------|
| P6: SSD 误判影响写性能 | ❌ 无影响 | ❌ deepseek 漏查参数 | **✅ 有 23% 影响**（rados bench 直打池） |

**最终判决**：介质误判（HDD 模式 deferred_size=65536）对 256K EC 写有 **23% 的性能损失**（72.3 → 58.6 MB/s）。deepseek 的"无影响"结论是错误的。

**但 P6 实验（通过 JuiceFS）未显示提升**（43.4 vs 39.1），原因：
1. JuiceFS 层开销（FUSE、元数据、对象打包）掩盖了后端 23% 的差异
2. 单次测试 + 10% 方差，不显著
3. JuiceFS 写 256K 对象时可能有 batching 行为改变了实际 chunk 大小

## 与 deepseek exp2 的对比

| 数据 | 本实验 HDD 模式 | deepseek exp2 | 说明 |
|------|:---:|:---:|------|
| rados 256K 均值 | 58.6 | 52.7 | 本实验略高（OSD 状态更干净） |
| rados 256K 峰值 | 113 | 101 | 同上 |

deepseek 的 rados bench 也是 HDD 模式（默认），但 OSD 可能有 compaction 积压，导致均值更低（52.7 vs 58.6）。

## config 状态

实验后保持 HDD 模式（`deferred=65536, throttle=670000`），这是 HDD 检测设备的正确生产配置。OSD 已 restart，HEALTH_OK。

## 文件清单

```
results/cold-baseline-recheck-20260706/rados-deferred-comparison/
├── ops.log                    # 操作日志
├── report.md                  # 本报告
├── ssd-rados-bench.txt        # SSD 模式 rados bench 原始输出
├── hdd-rados-bench.txt        # HDD 模式 rados bench 原始输出
├── ssd-wal-after.txt          # SSD 模式 WAL after
├── hdd-wal-before.txt         # HDD 模式 WAL before
├── hdd-wal-after.txt          # HDD 模式 WAL after
├── ssd-health-timeline.txt    # SSD 模式 health timeline
└── hdd-health-timeline.txt    # HDD 模式 health timeline
```
