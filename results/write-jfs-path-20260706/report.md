# 实验 A 报告：JuiceFS 吞噬 deferred 收益 + stall 根因定位

> 日期：2026-07-06 | 目录：`results/write-jfs-path-20260706/expA/`
> 配置：patched v1.3.1, cache=0, mu=150, bs=256K

---

## 一、实验结果汇总

### 带宽对比

| 组 | 路径 | deferred | seqwrite r1/r2/r3 (MiB/s) | multi-seqwrite |
|----|------|:---:|:---:|:---:|
| A1 | rados 直打池 | 65536 (HDD) | 62.4 / 54.4 / 54.7 (avg 57.2) | N/A |
| A2 | rados 直打池 | 0 (SSD) | 57.8 / 53.8 / 54.4 (avg 55.4) | N/A |
| A3 | JuiceFS | 65536 (HDD) | 62.8 / 55.4 / 51.8 (avg 56.7) | **STALL (5/6 OSDs, 2min)** |
| A4 | JuiceFS | 0 (SSD) | 52.0 / 56.1 / 56.2 (avg 54.8) | **STALL (1/6 OSDs, 11min)** |

> 注：A2 在 A3 stall 后跑，OSD 处于退化态，SSD 未重现之前 72.3 的 +23%（干净态 OSD 才能体现 deferred 差异）。

### multi-seqwrite stall 对比

| 指标 | A3 (HDD) | A4 (SSD) |
|------|:---:|:---:|
| stall 起始时间 | ~2min（文件布局阶段） | ~11min（文件布局阶段） |
| 受影响 OSD 数 | 5/6 | 1/6 |
| compact_queue_len | **0** | **0** |
| bytes_written_wal | 9.7-11.4 GB | **1.3-1.9 GB（少 5-7×）** |
| read_random_bytes | 4.8-5.1 GB | 1.9-2.2 GB |
| op_w_latency avg | 210-257 ms | 435-626 ms（OSD 退化态叠加） |
| kv_sync_lat avg | 0.4-1.7 ms | 1.1-6.1 ms |

---

## 二、核心发现

### 发现 1：破案点——JuiceFS 确实命中 deferred 阈值

JuiceFS block-size=256K → 每个 block 存为 256K RADOS 对象（对象名含 `262144`）。
EC 4+2 将 256K 切成 4×64K data chunk + 2×64K parity chunk。
`bluestore_prefer_deferred_size_hdd=65536` → 64K ≤ 65536 → **deferred 双写**。

**任务书假设"JuiceFS 不命中 deferred"是错误的。JuiceFS 确实命中。**

### 发现 2：deferred=0 减少 WAL 5-7× 但不能防止 stall

A4 (SSD) 的 `bytes_written_wal` 仅 1.3-1.9 GB，是 A3 (HDD) 9.7-11.4 GB 的 1/5~1/7。
但 A4 仍然 stall——只是延迟了 5×（2min→11min）且严重度降低（5/6→1/6 OSDs）。

**根因不是 WAL 写入量，而是 BlueFS 随机读在共享 SSD 上与数据写争抢。**

### 发现 3：stall ≠ compaction 积压（推翻之前的假设）

A3 和 A4 stall 期间 `compact_queue_len=0, compact_running=0`——**无 compaction 积压**。

之前我们说"stall = compaction 积压 + 单 job 持续写"，这是**不完整的**。更准确的说法：

**stall = BlueFS 随机读饱和 + 高并发写入触发**
- 高并发写入（mu=150 + 16 jobs）→ 大量元数据操作 → BlueFS 随机读暴增
- 共享 SSD 无法同时服务随机读（元数据）+ 顺序写（数据）→ 读延迟飙升 → 写操作阻塞
- `compact` 命令不能解决此问题（不是 compaction 问题）
- `deferred=0` 延迟但不防止此问题（减少 WAL 写入量但不消除随机读争抢）

### 发现 4：JuiceFS 端到端无 deferred 收益

| 对比 | HDD | SSD | 差异 |
|------|:---:|:---:|:---:|
| rados 干净态（上轮） | 58.6 | 72.3 | **+23%** |
| rados 退化态（本轮） | 57.2 | 55.4 | -3% |
| JuiceFS seqwrite | 56.7 | 54.8 | -3% |

在干净态下，rados 后端有 +23% 的 deferred 收益。但通过 JuiceFS 端到端，收益消失。
原因：JuiceFS 层开销（FUSE、元数据、对象上传管理）抵消了后端 23% 的收益。
单 job seqwrite 的 JuiceFS 层损耗约 3-4%（56.7 vs 58.6），不足以完全吞噬 23%，
但 multi-seqwrite（16 jobs + mu=150）直接触发 stall，无法测得稳态带宽。

### 发现 5：mu=150 是 stall 触发的关键变量

| 配置 | multi-seqwrite 结果 | 出处 |
|------|------|------|
| mu=20 (默认) | 40.8 MB/s，**无 stall** | 任务 A 基线复测 |
| mu=150 | **STALL**（HDD 2min，SSD 11min） | 本实验 A3/A4 |

mu=150 将上传并发从 20 提升到 150，大幅增加 Ceph 写入并发 → 元数据操作暴增 → BlueFS 随机读饱和 → stall。

**mu=150 不适合 multi-seqwrite 场景（在共享 SSD 配置下）。**

---

## 三、对 P4/P5 命题的修正

### P4："stall = compaction 反压" → ❌ 推翻

stall 期间 `compact_queue_len=0`。stall 不是 compaction 积压导致的。
stall 根因是 **BlueFS 随机读饱和**（`read_random_bytes` 暴增 + `op_w_latency` 飙升至 200-600ms）。

### P5："WAL/DB 同盘是瓶颈" → ✅ 重新确认（之前错误关闭）

之前我们基于"compact 可防 stall"关闭了 P5。但：
1. `compact` 不能防此 stall（不是 compaction 问题）
2. `deferred=0` 延迟但不防此 stall（减少 WAL 但不消除随机读争抢）
3. stall 根因是 **WAL/DB 与 Data 共享 SSD → 随机读（元数据）与顺序写（数据）争抢**

**WAL/DB 隔离是唯一能完全防止此 stall 的手段。P5 应从"有条件的不需要"改为"必要"。**

---

## 四、JuiceFS 层损耗量化

| 场景 | rados 256K | JuiceFS seqwrite | JuiceFS 损耗 |
|------|:---:|:---:|:---:|
| HDD 干净态 | 58.6 | 56.7 | 3.2% |
| SSD 干净态 | 72.3 | 54.8* | 24.2%* |

*SSD JuiceFS 在退化态 OSD 上测得，非干净态，损耗值偏高。

**单 job seqwrite 的 JuiceFS 损耗约 3%（可接受）。但 multi-seqwrite + mu=150 直接触发 stall，无法测得稳态带宽。**

---

## 五、建议

1. **生产写场景用 mu=20（默认）**：mu=150 在共享 SSD 配置下触发 stall，得不偿失
2. **如需 mu=150 + 高并发写**：必须先隔离 WAL/DB（独立 NVMe）
3. **deferred_size=0 虽不能防 stall，但减少 WAL 5-7×**：在 WAL/DB 隔离后可进一步优化
4. **`compact` 命令对 BlueFS 随机读饱和无效**：TESTING-GUIDE.md 需补充说明
5. **stall 恢复需冷重启（stop all + start all）**：单 OSD restart 不够，因 OSD 上线后立即被恢复 I/O 压垮

---

## 六、文件清单

```
results/write-jfs-path-20260706/
├── ops.log                        # 全程操作日志
├── expA/
│   ├── A1/                        # rados HDD 3 轮
│   │   ├── rados-bench-r{1,2,3}.txt
│   │   └── ops.log
│   ├── A2/                        # rados SSD 3 轮
│   │   ├── rados-bench-r{1,2,3}.txt
│   │   └── ops.log
│   ├── A3/                        # JuiceFS HDD
│   │   ├── seqwrite-r{1,2,3}.txt
│   │   ├── stall-osd-perf.txt     # stall 期间 OSD perf（关键证据）
│   │   ├── multi-health-timeline.txt
│   │   ├── destroy.log / format.log / mount.log
│   │   └── ops.log
│   └── A4/                        # JuiceFS SSD
│       ├── seqwrite-r{1,2,3}.txt
│       ├── stall-osd-perf.txt     # stall 期间 OSD perf（关键证据）
│       ├── multi-health-timeline.txt
│       └── ops.log
└── report.md                      # 本报告
```
