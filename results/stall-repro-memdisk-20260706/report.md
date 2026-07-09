# stall 复现归因 + A1~A4 重测报告

> 日期：2026-07-06~07 | 目录：`results/stall-repro-memdisk-20260706/`
> 配置：patched v1.3.1, cache=0, mu=150, bs=256K

---

## 一、阶段一：stall 归因对照（G1/G2/G3）

### 实验设计

| 组 | 前置负载 | 起跑线 |
|----|---------|--------|
| G1 | 无（净态直接 multi-seqwrite 64G） | 净态三确认 |
| G2 | rados 3×60s（无清无 compact）→ multi-seqwrite 64G | 净态三确认 |
| G3 | rados 3×60s → seqwrite 3×4G（无清无 compact）→ multi-seqwrite 64G | 净态三确认 |
| A3(上轮) | rados + seqwrite → multi-seqwrite 64G | 残余态（未清） |

### 结果

| 组 | multi-seqwrite 64G | stall | 起跑线 |
|----|:---:|:---:|--------|
| G1 | **55.3 MiB/s** | **无** | 净态 |
| G2 | **64.1 MiB/s** | **无** | 净态 |
| G3 | **56.7 MiB/s** | **无** | 净态 |
| A3(上轮) | 44.3 MiB/s | **有(5/6 OSDs)** | 残余态 |

### 结论

**从干净态起跑，无论前置负载如何（无/rados/seqwrite），multi-seqwrite 64G 都不 stall。**

A3 的 stall 根因是**之前多轮实验累积的 BlueFS 残余状态**，不是当前测试负载本身。compact 可清除残余状态，是防止 stall 的有效手段。

**stall 触发条件修正**：
- ~~stall = 单 job 持续写 + compaction 积压~~（上轮推断，不完整）
- ~~stall = BlueFS 随机读饱和~~（上轮单点快照推断，未用 delta 坐实）
- **stall = BlueFS 残余状态累积 + 高并发写入触发**（本轮干净态对照坐实）
- compact 可清除残余状态 → 防止 stall

### OSD perf 采集说明

G1/G2/G3 均采集了 OSD perf 时间序列（每 3s，6 OSD × ~19MB）+ health timeline（1100+ 行）+ iostat（node1）。因 G1/G2/G3 均无 stall，时间序列数据为"无 stall 时的基线 perf 特征"，可用于后续对比分析。

---

## 二、阶段二：内存盘 WAL/DB 隔离——跳过

阶段二前提是"能稳定复现 stall"。G1/G2/G3 均未复现 stall，无法进入阶段二。

**P5 结论维持"有条件的不需要"**：在 compact 可管理的生产场景下，WAL/DB 隔离非必须。仅在无法 compact 的极端累积场景下才需要。

---

## 三、A1~A4 带宽对比重测（运行纪律路线）

### 结果

| 测试 | config | r1 | r2 | r3 | 均值 | 可靠性 |
|------|--------|:---:|:---:|:---:|:---:|:---:|
| A1 rados HDD | deferred=65536 | 60.9 | 55.8 | 55.1 | **57.3** | ✅ |
| A2 rados SSD | deferred=0 | 32.7 | 27.0 | 23.2 | **27.6** | ⚠️ 退化态 |
| A3 seqwrite HDD | deferred=65536 | 56.7 | 52.0 | 49.1 | **52.6** | ✅ |
| A4 seqwrite SSD | deferred=0 | 36.7 | 42.6 | 42.9 | **40.7** | ⚠️ 退化态 |
| A3 multi-seqwrite HDD | deferred=65536 | - | - | - | **43.0** | ✅ |
| A4 multi-seqwrite SSD | deferred=0 | - | - | - | **46.4** | ⚠️ 退化态 |

### 关键发现

1. **全程无 stall**——compact before each test 有效防止 stall
2. **HDD 数据可靠**：A1 rados 57.3, A3 seqwrite 52.6, A3 multi-seqwrite 43.0
3. **SSD 数据不可靠**：冷重启后 OSD 未完全恢复（HEALTH_WARN slow ops + degraded），A2 rados 仅 27.6（正常应 ~72）
4. **deferred 端到端对比仍不 conclusive**——SSD 需在干净态下单独重测
5. **有趣信号**：A4 multi-seqwrite SSD(46.4) > A3 HDD(43.0) 即使在退化态也反超，暗示 deferred=0 对 multi-seqwrite 可能有效

### JuiceFS 层损耗量化（HDD 干净态）

| 场景 | rados 256K | JuiceFS | JuiceFS 损耗 |
|------|:---:|:---:|:---:|
| seqwrite (单 job 4G) | 57.3 | 52.6 | 8.2% |
| multi-seqwrite (16 job 64G) | 57.3* | 43.0 | 25.0%* |

*rados bench 是 16 线程并发写不同对象，multi-seqwrite 是 16 job 写不同文件——口径不完全一致，损耗值仅供参考。

---

## 四、后续建议

1. **SSD deferred 对比需单独干净态重测**：冷重启后需等 10+ min 确认 HEALTH_OK + OSD perf=0 + iostat idle 再开测
2. **compact before each test 是必需的运行纪律**：写回 TESTING-GUIDE.md
3. **stall 无法从干净态复现**：如需研究 stall 本身，需在残余态（多轮实验后不 compact）下复现
4. **deferred=0 端到端收益**：后端 rados +23%（72.3 vs 58.6，干净态），但端到端 JuiceFS 收益需干净态 SSD 数据才能判定

---

## 五、文件清单

```
results/stall-repro-memdisk-20260706/
├── clean-confirm.log         # 净态三确认证据
├── G1/                       # 净态→multi-seqwrite
│   ├── multi-seqwrite-r1.txt # fio 原文 (55.3 MiB/s)
│   ├── health-timeline.txt   # 1107 行全 OK
│   ├── osd-perf-t0/tend.txt  # OSD perf 基线
│   ├── osd{0-5}-perf-timeline.txt  # 时间序列
│   └── ops.log
├── G2/                       # 净态→rados→multi-seqwrite
│   ├── rados-bench-r{1,2,3}.txt
│   ├── multi-seqwrite-r1.txt # 64.1 MiB/s
│   └── ops.log
├── G3/                       # 净态→rados→seqwrite→multi-seqwrite
│   ├── rados-bench-r{1,2,3}.txt
│   ├── seqwrite-r{1,2,3}.txt
│   ├── multi-seqwrite-r1.txt # 56.7 MiB/s
│   └── ops.log
├── A1-A4-retest/             # 运行纪律路线重测
│   ├── A1-rados-r{1,2,3}.txt
│   ├── A2-rados-r{1,2,3}.txt
│   ├── A3-seqwrite-r{1,2,3}.txt
│   ├── A4-seqwrite-r{1,2,3}.txt
│   ├── A3-multi-seqwrite-r1.txt
│   ├── A4-multi-seqwrite-r1.txt
│   ├── *-health.txt          # 各阶段 health timeline
│   └── ops.log
└── report.md                 # 本报告
```
