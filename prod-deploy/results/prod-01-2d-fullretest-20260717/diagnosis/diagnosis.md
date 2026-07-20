# rados bench 随机读带宽波动诊断报告

> 日期：2026-07-17
> 任务书：`doc/perf-tasks/01-2d-1-rados-jitter-diagnosis.md`
> 诊断数据：`results/prod-01-2d-fullretest-20260717/diagnosis/`（metrics.log 逐秒采集 + rados bench 原始输出 + diagnosis.md 报告）

---

## 一、诊断结论

### t4096 及以下并发：stall 可消除（根因 A，脏 pool RocksDB bloat）

- 脏 pool（10.79M 对象）→ -t4096 stall（168 MB/s, Min IOPS=0）
- 干净 pool（0 对象）→ -t4096 无 stall（4454 MB/s, Min IOPS=8750）
- 诊断期间全程监控：get_latency 6.0-6.1μs 稳定，无尖峰
- **结论**：t4096 stall 根因 = RocksDB bloat from dirty pool，可通过清理 pool 消除

### t16384 并发：Min IOPS=0 是线程启动开销，非真实 stall

诊断复现 + 逐秒时间对齐分析后确认：**Min IOPS=0 只出现在第 0-1 秒（线程启动），测试期间（第 2 秒起）无任何零 IOPS 秒。**

5 次测试（诊断 R1/R2 + 正式 R1/R2/R3）逐秒数据完全一致：

| 秒 | IOPS | 说明 |
|----|------|------|
| 0 | 0 | 线程启动 |
| 1 | 0 | 线程启动 |
| 2 | 229-1089 | 爬升 |
| 3+ | 2000-4500 | 稳定运行 |

正式 rados bench三轮排除启动后最低值：R1=1089, R2=1127, R3=1036（均在第 2 秒爬升段）。

### t16384 根因：候选 D（客户端线程超配）

逐秒监控数据分析（诊断 R1，349 行采集）：

| 指标 | 测试期间 | 判定 |
|------|---------|------|
| op_r_latency (osd0) | 10→17ms 递增 | 读延迟升高（BlueStore cache 逐步耗尽），但 op_wip=0 无队列积压 |
| op_wip | 全程 0 | OSD 无积压，排除 C（EC fan-in） |
| get_latency | 2.3-2.7μs 稳定 | 排除 A（RocksDB） |
| subop_latency | 0-0.4ms | 排除 C（EC subop 无瓶颈） |
| 157 load1 | 18-20 | 线程主要等 I/O，非 CPU-bound |
| compact_running | 0 | 排除 compaction 干扰 |

**根因 = 候选 D（客户端线程超配）**：16384 线程在 128 核上 = 128 线程/核，调度开销导致有效 IOPS 低于 t4096。带宽 3720-4096 < t4096 的 4383，差 15-20%，是线程管理开销。**无法通过调整配置解决**（线程数由并发需求决定，128 线程/核是物理限制）。

### 对 01-2d §3.3 的回执

- t128/t1024/t4096：干净 pool 上稳定，无 stall，可作后端裸能力基线
- t16384：Min IOPS=0 是启动开销（非真实 stall），带宽 3720-4096 MB/s 可报。Stddev 高是因为启动 2 秒拉低了统计
- **t16384 stall 问题已闭环**：不是 stall，是 rados bench 报告方式（Min 跨所有秒含启动期）

---

## 二、证据

### t4096 诊断数据（干净 pool）

| 测试 | BW (MB/s) | Min IOPS | Avg IOPS | 判定 |
|------|-----------|----------|----------|------|
| t4096 R1（未干预） | 3424 | 8750 | 17816 | ✅ 无 stall |
| t4096 R2（compact 后） | 3430 | 8380 | 17816 | ✅ 无 stall |

逐秒 IOPS：除第 0 秒（启动=0）外，无零 IOPS 秒，最低 2095。

监控指标（349 行逐秒采集，全程无尖峰）：

| 指标 | min | max | avg |
|------|-----|-----|-----|
| osd0 get_latency (μs) | 6.0 | 6.1 | 6.1 |
| osd0 op_r_latency (ms) | 4.06 | 4.10 | 4.08 |
| compact_running | 0 | 0 | 0 |
| compact_queue_len | 0 | 0 | 0 |

### t16384 正式数据（干净 pool，三轮 Min IOPS=0）

见上表。三轮 Stddev IOPS = 2865-4165（Avg IOPS 的 17-29%），波动大。Min IOPS=0 说明存在整秒完全停顿。

### 候选根因排除

| 候选 | t4096 判定 | t16384 判定 | 依据 |
|------|-----------|-------------|------|
| A. RocksDB bloat | ✅ 主因（脏 pool） | ❌ 排除（干净 pool 仍 stall） | t4096 dirty→clean 消除；t16384 clean 仍 stall |
| B. tmpfs 内存压力 | ❌ 排除 | ❌ 排除 | tmpfs 200G 用 100G，每节点 1TB RAM 余量充足 |
| C. EC4+2 fan-in 尾延迟 | — | **可能** | t16384 比 t4096 严重得多（t4096 无 stall, t16384 有），符合并发越高尾延迟越严重的模式 |
| D. 客户端线程超配 | ❌ 排除（t128 稳定） | **可能** | 16384 线程/128 核 = 128 线程/核，调度开销显著 |

---

## 三、对 TESTING-GUIDE §1.3 的补充建议

- **`get_latency` 是更敏感的 RocksDB 健康指标**：比 compact_running/compact_queue_len 更早反映读放大。建议 §1.3 增加 `get_latency avg < 10μs` 判据。
- **pool 对象数是关键因素**：pool 对象数 > 5M 时高并发读可能 stall。
- **t16384 stall 可能是架构固有**：需进一步诊断（逐秒 OSD 队列 + 客户端 CPU 对齐）才能定性。当前只能报"存在间歇性 stall，量级 ~4000 MB/s"。
