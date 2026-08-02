# 02-2-H Step 2 判定：内存压力推翻 + miss/落盘/onode/compact 全轮复算  [2026-07-26]

> 目的：判断坏轮 hit_rate↓ 是否由 OSD 内存压力驱动；补充 Opus 复核后的 3 项深挖
> 方法：A16-A22（7 轮，首次有 mempool 数据）好轮 vs 坏轮全路径对比
> 数据：每轮 randread-r1 的 osd-perf.csv（37 列，6 OSD 首末差分）

---

## 一、测试轮次

| 轮 | randread | hit_rate | 归类 | mempool |
|---|---|---|---|---|
| A17 | 1299 | 71.86% | 坏 | ✅ |
| A18 | 1293 | 71.79% | 坏 | ✅ |
| A19 | 1297 | 71.88% | 坏 | ✅ |
| A20 | 1306 | 72.19% | 坏 | ✅ |
| A16 | 1325 | 72.67% | gap | ✅ |
| A21 | 1355 | 73.36% | gap | ✅ |
| A22 | 1473 | 75.68% | 好 | ✅ |

---

## 一-B、指标说明

### 1.2.1 数据来源

所有指标取自 `ceph tell osd.N perf dump` 的 BlueStore 段（bluestore），按 6 OSD 分组、首末采样差分（Δ = last - first），再跨 6 OSD 汇总。采集窗口 = fio randread r1 的 180s 运行期。

### 1.2.2 指标定义

| 指标 | perf dump 字段 | 含义 |
|---|---|---|
| **Δhit(GB)** | buffer_hit_bytes | BlueStore buffer cache **命中**的累积字节数，窗口内首末差分。即 180s 内 BlueStore 从内存缓存直接返回的数据量（含数据和元数据） |
| **Δmiss(GB)** | buffer_miss_bytes | BlueStore buffer cache **未命中**的累积字节数，窗口内首末差分。即 180s 内 BlueStore 不得不从 NVMe 磁盘实际读取的数据量（含数据和元数据） |
| **hit%** | 计算值 | Δhit / (Δhit + Δmiss) × 100。BlueStore buffer cache 的命中率 |
| **read_lat_cnt** | read_lat.avgcount | BlueStore 从磁盘读取（cache miss）的**次数**，窗口内差分。每次磁盘读可能 < fio 的 256KB（因 EC 分片，BlueStore 以 chunk 为单位读） |
| **read_lat(ms)** | read_lat.avgtime（Δsum/Δavgcount） | BlueStore 每次**磁盘读的平均延迟**（窗口均值，非全局均值）。包含从提交 IO 到 NVMe 返回的全路径时间 |
| **aio_cnt** | read_wait_aio_lat.avgcount | BlueStore 等待 AIO 完成的次数（与 read_lat_cnt 一致，因为每次磁盘读都走 AIO） |
| **aio_lat(ms)** | read_wait_aio_lat.avgtime（Δsum/Δavgcount） | BlueStore 每次**等待 AIO 返回的平均延迟**（窗口均值）。是 read_lat 的子集——read_lat = 预处理 + aio_lat + 后处理 |

### 1.2.3 工作集与 Δmiss 的关系

- **fio 工作集 = 128GB**（128 jobs × 1GB × 256K 随机读），180s 内反复遍历
- **Δmiss = 205GB > 128GB**：可能因为 EC 分片放大（fio 256KB 读在 BlueStore 层被拆成多个更小的 EC chunk 读 + 元数据读取）、工作集多次遍历且 cache_data≈0 导致重复落盘、或 BlueStore 内部读放大（blob 级读取）
- **Δmiss 恒定**（7 轮波动 <0.1%）说明每轮的访问模式和落盘行为完全一致，具体放大机制不影响因果分析（只需知道它恒定即可）

---

## 二、Task 1：miss/落盘绝对量全轮复算


| 轮 | 峰 | fio | Δhit(GB) | **Δmiss(GB)** | hit% | read_lat_cnt | read_lat(ms) | aio_cnt | aio_lat(ms) |
|---|---|---|---|---|---|---|---|---|---|
| A17 | 坏 | 1299 | 524.3 | **205.32** | 71.86 | 16.58M | 0.0473 | 16.58M | 0.0426 |
| A18 | 坏 | 1293 | 522.4 | **205.28** | 71.79 | 16.53M | 0.0474 | 16.53M | 0.0427 |
| A19 | 坏 | 1297 | 524.6 | **205.28** | 71.88 | 16.58M | 0.0473 | 16.58M | 0.0426 |
| A20 | 坏 | 1306 | 532.7 | **205.19** | 72.19 | 16.77M | 0.0470 | 16.77M | 0.0422 |
| A16 | gap | 1325 | 545.6 | **205.20** | 72.67 | 17.06M | 0.0462 | 17.06M | 0.0415 |
| A21 | gap | 1355 | 565.1 | **205.19** | 73.36 | 17.50M | 0.0453 | 17.50M | 0.0406 |
| A22 | 好 | 1473 | 638.5 | **205.20** | 75.68 | 19.10M | 0.0417 | 19.10M | 0.0371 |

### 关键发现

1. **Δmiss 全 7 轮恒定 = 205.2GB（波动 <0.1%）** — 工作集（冷数据量）完全没有漂移。fio 随机读的冷数据集在每轮完全一样。"访问模式/工作集漂移"假设**被自己的数据证伪**。

2. **变的只有 Δhit**（522→639GB）：好轮多出的吞吐 100% 来自 cache hit 增加。hit% 升高是因为分子（hit）增大，不是分母中的 miss 减少。

3. **好轮落盘更多但更快**：A22 read_lat_cnt=19.1M > A17 16.6M（落盘读次数更多），但 read_lat=0.042ms < 0.047ms（每次更快）。恒定 205GB miss 被拆成**更多更小更快的落盘读** → 落盘子系统整体更高效。

4. **read_lat 和 aio_lat 均单调对齐吞吐**（好轮更快）：
   - read_lat: 坏 0.047 → gap 0.045 → 好 0.042 ms
   - aio_lat: 坏 0.043 → gap 0.041 → 好 0.037 ms
   - 这是"整体连续单调"的证据——好轮的整个 I/O 路径全面更高效，read_lat/aio_lat 随 fio 吞吐连续单调变化（非二元跳变，见 §五 5.2-1）

5. **因果链方向：hit% 是果不是因**：
   - 工作集（冷数据 205GB）每轮被完整遍历，不随吞吐变化
   - fio 固定 180s 时间窗口、固定并发（128 jobs × 128 iodepth）
   - 好轮：每个 I/O 延迟更低（read_lat 0.042ms）→ 180s 内完成更多 I/O → 更多重复访问已缓存的块 → Δhit↑ → hit%↑ → 带宽↑
   - 坏轮：每个 I/O 延迟更高（read_lat 0.047ms）→ 180s 内完成更少 I/O → 更少重复访问已缓存块 → Δhit↓ → hit%↓ → 带宽↓
   - **hit% 升高是吞吐高的结果，不是原因**。如果 hit% 是因，增大 cache 应提高 hit% 从而提高吞吐——但已证明 cache_data 好坏轮都 ~0GB、坏轮总 cache 反而更大（§三 Task 2），增大 cache 不会帮助
   - **真正的因变量是 read_lat**（BlueStore 层延迟），hit% 只是它的下游 proxy

---

## 三、Task 2：onode cache 悖论深挖

### 3.1 指标说明

以下指标取自 `ceph tell osd.N dump_mempools` 的 mempool.by_pool 段，6 OSD 首采样（randread r1 开始时刻）平均值：

| 指标 | mempool 字段 | 含义 |
|---|---|---|
| **data(GB)** | bluestore_cache_data | BlueStore **数据块缓存**占用的内存。缓存实际对象数据（用户读的数据内容）。randread 期间几乎为空（~0.2GB），说明数据块缓存基本不工作 |
| **onode(GB)** | bluestore_cache_onode | BlueStore **onode 缓存**占用的内存。onode 是对象的元数据节点（记录对象在 blob 中的布局、extents 映射等）。每读一个对象前需先查 onode |
| **meta(GB)** | bluestore_cache_meta | BlueStore **其他元数据缓存**。包括 blob 元数据、shared blob 信息等 |
| **other(GB)** | bluestore_cache_other | BlueStore **杂项缓存**。包括 buffer 引用、deferred 等辅助数据 |
| **total(GB)** | 四项之和 | BlueStore **总缓存占用**。注意：这只是 BlueStore 自己的 mempool，不含 OS page cache、RocksDB block cache 等其他内存使用者 |
| **hit%** | 同 §一-B 定义 | Δhit / (Δhit + Δmiss) × 100，窗口内差分 |

### 3.2 数据

| 轮 | 峰 | fio | hit% | data(GB) | onode(GB) | meta(GB) | other(GB) | total(GB) |
|---|---|---|---|---|---|---|---|---|
| A17 | 坏 | 1299 | 71.86 | 0.19 | **5.36** | **2.21** | 0.08 | **7.82** |
| A18 | 坏 | 1293 | 71.79 | 0.19 | 5.73 | 2.34 | 0.08 | 8.34 |
| A19 | 坏 | 1297 | 71.88 | 0.20 | 5.49 | 2.25 | 0.08 | 8.02 |
| A20 | 坏 | 1306 | 72.19 | 0.21 | 6.51 | 2.62 | 0.08 | 9.41 |
| A16 | gap | 1325 | 72.67 | 0.21 | 4.91 | 2.04 | 0.08 | 7.24 |
| A21 | gap | 1355 | 73.36 | 0.21 | 5.12 | 2.12 | 0.08 | 7.53 |
| A22 | 好 | 1473 | 75.68 | 0.21 | **4.74** | **1.98** | 0.08 | **7.01** |

### 关键发现

1. **cache_data 恒定 ~0.2GB** — 所有轮次相同，不是区分因子
2. **好轮 onode cache 反而最小**（4.74GB vs 坏轮 5.4-6.5GB）— 逆相关！
3. **好轮 total cache 最小**（7.0GB vs 坏轮 7.8-9.4GB）— cache 越小，hit_rate 越高，吞吐越高
4. **悖论解释**：坏轮 onode cache 更大 = 更多 onode 被加载（churn）但 data buffer 命中率反而更低。坏轮可能经历了更多 onode 驱逐/重载循环，cache 效率低。好轮 onode cache 稳定且小，说明 onode 命中稳定，data buffer 命中率更高。

---

## 四、Task 3：compact + op latency 溯源

### 4.1 指标说明

compact 指标取自 `ceph tell osd.N perf dump` 的 rocksdb 段，op latency 指标取自 osd 段。均为 6 OSD 首末差分（Δ）后取均值：

| 指标 | perf dump 字段 | 含义 |
|---|---|---|
| **compact_run_Δ** | rocksdb.compact_running | RocksDB compaction 是否正在运行。窗口内首末差分，Δ=0 表示整个 randread 期间没有 compaction 启动/停止（全程无 compaction） |
| **compact_q_Δ** | rocksdb.compact_queue_len | RocksDB compaction **队列长度**。窗口内首末差分，Δ=0 表示队列长度未变化（无新的 compaction 排队）。注意：队列长度本身可能 >0（有待 compact 的 SST），但只要 Δ=0 就说明测试期间没有新增排队 |
| **op_r(ms)** | osd.op_r_latency（Δsum/Δavgcount） | OSD **读 op 总延迟**的窗口均值。从 op 被 OSD 接收到 op 完成返回的全路径时间，含排队 + 处理 + 等待 BlueStore 返回 |
| **op_rproc(ms)** | osd.op_r_process_latency（Δsum/Δavgcount） | OSD 读 op **纯处理时间**的窗口均值。不含队列等待时间，是 OSD 实际处理 op 的耗时（调 BlueStore 读、打包返回数据等） |
| **op_dequeue(ms)** | osd.op_before_dequeue_op_lat（Δsum/Δavgcount） | OSD op **出队前等待时间**的窗口均值。op 从进入 shard 队列到被取出执行之间的等待。如果高 = op 在队列中排队 |

> **op_r_latency vs op_r_process_latency vs op_dequeue 的关系**：
> op_r_latency ≈ op_dequeue（排队等待）+ op_r_process_latency（处理）+ 其他开销（如 op_r_prepare_latency 准备阶段）
> 即：总延迟 = 排队 + 准备 + 处理。op_dequeue 衡量排队段，op_r_process 衡量处理段。

### 4.2 数据

| 轮 | 峰 | fio | compact_run_Δ | compact_q_Δ | op_r(ms) | op_rproc(ms) | op_dequeue(ms) |
|---|---|---|---|---|---|---|---|
| A17 | 坏 | 1299 | **0** | **0** | 0.764 | 0.594 | 0.069 |
| A18 | 坏 | 1293 | **0** | **0** | 0.658 | 0.475 | 0.071 |
| A19 | 坏 | 1297 | **0** | **0** | 0.734 | 0.534 | 0.072 |
| A20 | 坏 | 1306 | **0** | **0** | 0.827 | 0.662 | 0.067 |
| A16 | gap | 1325 | **0** | **0** | 1.057 | 0.905 | 0.069 |
| A21 | gap | 1355 | **0** | **0** | 1.043 | 0.886 | 0.071 |
| A22 | 好 | 1473 | **0** | **0** | 0.736 | 0.559 | 0.069 |

### 关键发现

1. **compact_running/queue_len 全 7 轮 delta=0** — 没有任何 compaction 活动。compaction 排除。

2. **op_r_latency 非单调**：gap 轮 A16/A21 的 op_r=1.04-1.06ms 是所有轮中最高的，但它们吞吐在 gap 而非最低。好轮 A22 的 op_r=0.736ms 与坏轮 A17=0.764ms 接近。op_r 不是吞吐的决定因子。

3. **op_dequeue 恒定 ~0.069ms** — 队列等待不是瓶颈。

4. **波动不在 compaction / op queue**：compact 全 0，op_dequeue 恒定。波动在更底层——BlueStore read 路径内部（read_lat/aio_lat 的连续效率变化）。

---

## 五-B、分盘 diskstats 对比（A23 好轮 vs A24 坏轮，首次有分盘数据）

### 5-B.1 node-150 分盘对比

| 指标 | A23（好 1468） | A24（坏 1295） | 差异 |
|---|---|---|---|
| **nvme1(TiKV) read_ios** | 34 | 17 | 极低，无差异 |
| **nvme1(TiKV) util** | 0.8% | 1.3% | TiKV 几乎空闲 |
| **nvme2(OSD) read_ios** | 699,390 | 702,802 | +0.5%（几乎相同） |
| **nvme2(OSD) rd_ms** | **0.1375** | **0.1381** | +0.4%（几乎相同！） |
| **nvme2(OSD) util** | **64.7%** | **72.4%** | **+7.7%** |
| nvme2(OSD) io_ticks | 90,624 | 101,328 | +11.8% |
| nvme3(OSD) rd_ms | 0.1366 | 0.1360 | -0.4%（几乎相同） |
| nvme3(OSD) util | 64.7% | 72.4% | +7.7% |
| CPU irq/softirq | 0% / 0% | 0% / 0% | 无差异 |
| TCP cwnd | 1117 | 1133 | 相近 |
| TCP rtt | 1.737ms | 1.776ms | +2.2%（相近） |
| TCP retrans | 0 | 0 | 一致 |

### 5-B.2 三节点一致性

| 轮-节点 | nvme1(TiKV) util | nvme2(OSD) rd_ms | nvme2 util | nvme3(OSD) rd_ms | nvme3 util |
|---|---|---|---|---|---|
| A23-150 好 | 0.8% | 0.1375 | 64.7% | 0.1366 | 64.7% |
| A23-151 好 | 0.8% | 0.1378 | 64.7% | 0.1372 | 64.6% |
| A23-152 好 | 0.8% | 0.1306 | 64.4% | 0.1373 | 64.7% |
| A24-150 坏 | 1.3% | 0.1381 | 72.4% | 0.1360 | 72.4% |
| A24-151 坏 | 1.2% | 0.1370 | 72.1% | 0.1370 | 72.0% |
| A24-152 坏 | 1.2% | 0.1367 | 72.1% | 0.1360 | 72.0% |

### 5-B.3 关键发现

1. **TiKV(nvme1) 干扰假设推翻**：TiKV 在好坏轮中几乎空闲（util<1.5%），不可能是干扰源。

2. **OSD 数据盘单次读服务时间几乎相同**（rd_ms=0.137 vs 0.138ms，差 0.4%）— 磁盘本身不慢。

3. **但 OSD 数据盘 util 高 7.7%**（64.7% → 72.4%）：io_ticks 高 11.8%，但 read_ios 和 read_ticks 几乎不变。**额外 busy 来自非读 I/O**（不是读、不是 compaction、不是 TiKV）。

4. **CPU irq/softirq 无差异** — 无中断争抢。

5. **node-150 RTT 假设推翻**（A23/A24 三节点对比）：

   A13/A15 对中 node-150 RTT 从 1.94ms 升到 3.45ms（+78%），曾被认为是好坏轮区分因子。但 A23/A24 新好/坏对中，三节点 RTT 对比：

   | 节点 | A23（好 1470） | A24（坏 1295） | 差异 |
   |---|---|---|---|
   | node-150 | 1.768ms | 1.783ms | **+0.015ms（几乎不变）** |
   | node-151 | 0.277ms | 0.225ms | -0.052ms（下降） |
   | node-152 | 0.286ms | 0.282ms | -0.004ms（不变） |

   A24 坏轮的 node-150 RTT=1.783ms，**比 A13 好轮的 1.940ms 还低**。A23/A24 好坏轮间三节点 RTT 均无显著变化，但吞吐仍降 12%。

   补充 A22 好轮：node-150 RTT=1.835ms，也在同一范围。

   **结论**：node-150 RTT 变化不是好坏轮的通用区分因子。A13/A15 的 RTT 差异是该对特有的巧合，不具普遍性。好坏轮的差异不在网络 RTT 层。

   补充：EC 4+2 每次读需从多节点获取数据分片，理论上最慢节点会成为瓶颈（木桶效应）。但 A23/A24 数据显示好坏轮间所有节点 RTT 都几乎不变，木桶效应的前提（某节点变慢）不成立。

### 5-B.4 悖论与下一步

**核心悖论**：
- 磁盘单次读服务时间不变（rd_ms 几乎相同）
- 但磁盘 busy% 高 8%
- BlueStore 层 read_lat 好轮更快（0.043 vs 0.047ms，差 9%）
- 这 9% 差异在 BlueStore 内部（onode 查找/buffer 分配），不在磁盘层，也不是 read coalescing 配置差异（coalescing 是 read_lat 变快的下游结果）
- 网络 RTT 三节点均不变（A23/A24），不是区分因子

**额外 busy 的来源候选**：
- NVMe 内部操作（SLC 缓存管理、GC、wear leveling）
- Ceph 后台任务（recovery/backfill/snap trim，不在 compact 指标内）
- 残留写 I/O（上一轮 layout 写入的 flush/commit 尾巴）

**建议下一步**：
1. 采 `iostat -x 1 1` 获取 `svctm`（纯服务时间）vs `await`（含排队），区分"盘内慢"vs"排队深"
2. 采 `nvme smart-log` 对齐好坏轮（温度/thermal throttle）—— A23/A24 已采，待分析
3. 采 `ceph tell osd.* perf dump` 中的 `osd_op_w_latency`（写 op 延迟）和 `bluestore_state_deferred_aio_wait_lat`（deferred 写等待）—— 是否有残留写活动

---

## 五、综合判定

### 5.1 已排除的假设

| 假设 | 证据 | 状态 |
|---|---|---|
| OSD 内存压力 | cache_data 好坏轮都~0.2GB，坏轮总 cache 反而更大 | ❌ 推翻 |
| 工作集/访问模式漂移 | Δmiss 全 7 轮恒定 205.2GB | ❌ 推翻 |
| compaction 触发 | compact_running/queue_len delta 全 0 | ❌ 排除 |
| op 队列排队 | op_dequeue 恒定 ~0.069ms | ❌ 排除 |
| TCP/NIC 网络拥塞 | retrans=0, tx_dropped=0, pause 不变（A11/A12） | ❌ 排除 |
| throttle 限流 | wait=0, getfail=0（A13/A15） | ❌ 排除 |
| node-150 RTT 变化 | A23/A24 好坏轮间三节点 RTT 均无显著变化（1.768→1.783ms），A13/A15 的差异是巧合 | ❌ 推翻 |
| TiKV(nvme1) 同节点干扰 | nvme1 util<1.5%，好坏轮均空闲 | ❌ 推翻 |
| 磁盘单次读变慢 | rd_ms=0.137 vs 0.138ms（差 0.4%） | ❌ 推翻 |
| osd_memory_target | cache 不受内存限制 | ❌ 不需要调 |

### 5.2 当前认知

**已确认的事实**：
1. miss 恒定（205GB）→ 工作集不漂移
2. hit 变化（522→639GB）→ 好轮 cache 命中量增加
3. read_lat/aio_lat 单调对齐吞吐（好轮更快）→ 整体连续效率梯度（read_lat 0.042→0.047ms 随 fio 1293→1473 连续变化，非二元跳变）
4. 好轮落盘更多（19.1M > 16.6M）但每次更快（0.042 < 0.047ms）→ 落盘子系统更高效
5. 好轮 onode cache 更小但 hit_rate 更高 → cache 效率更高（非 cache 容量问题）
6. compact/op queue 无差异 → 开关在 BlueStore read 路径内部

**根因方向**：BlueStore read 路径的连续效率变化（read_lat 0.042→0.047ms 连续单调，非二元跳变）。同配置下 read_lat 连续波动，好态全面更高效（更多 hit + 更多更快落盘 + 更小更高效 cache），坏态全面略低效。

### 5.3 下一步建议

1. **onode hits/misses 分级采集**：当前只采了 buffer_hit/miss（data 级），建议下一轮顺带采 `bluestore_onode_hits/misses`（perf dump 只读），区分 onode cache 命中和 data buffer 命中，定位双峰出在哪一级
2. **read 落盘粒度**：好轮落盘更多更小更快（read_lat_cnt 19M > 16M, 每次更小更快）。这是 read_lat 变快的**结果**——read_lat 快 → 相同窗口能发起更多次落盘 → 每次落盘粒度更小。coalescing 是果不是因，不作为主攻方向
3. **暂不采纳"不可控"基线**：根因在 OSD 内部 BlueStore read 路径，大概率可控或至少可解释，非外部 WekaIO

### 5.4 node-150 RTT 排查（已完成，结论：与吞吐波动无关）

A13/A15 的 ss -ti 数据显示 node-150 RTT 比 151/152 高一个数量级，且在 A13→A15（好→坏）中从 1.94ms 升到 3.45ms。但 A23/A24 新好/坏对中，三节点 RTT 均无显著变化（node-150: 1.768→1.783ms），但吞吐仍降 12%。

补充数据（A22 好轮）：node-150 RTT=1.835ms，与 A23/A24 同范围。

**结论**：node-150 RTT 绝对值偏高（~1.8ms vs 151/152 的 ~0.2ms）是该节点自身特性（可能为网卡/中断/链路），但不随好坏轮变化，不是吞吐波动的区分因子。EC 木桶效应前提不成立（好坏轮间所有节点 RTT 均不变）。

node-150 RTT 偏高的根因排查（网卡型号/中断亲和/链路）仍可作为独立运维项，但与 02-2-H 基线波动无关。

---

## 六、数据路径

### 6.1 osd-perf.csv（41 列，A16-A24）

路径：`results/prod-02-2-h-fullbaseline-20260724/opencode-02-2-h-fullbaseline/A{16..24}/randread-A*-r1/osd/osd-perf.csv`

| 列范围 | 字段 | 说明 |
|---|---|---|
| 1-2 | ts, osd_id | 时间戳、OSD ID |
| 3-5 | get_latency_avg, buffer_hit_bytes, buffer_miss_bytes | §一-B 指标说明 |
| 6-7 | compact_running, compact_queue_len | §四 指标说明 |
| 8-19 | thr_*（4组×3列） | throttle wait_cnt/wait_sum/getfail |
| 20-27 | op_r_lat/op_r_proc/op_dequeue/op_queue（各 cnt+sum） | §四 指标说明 |
| 28-33 | read_lat/read_wait_aio/kv_sync（各 cnt+sum） | §一-B 指标说明 |
| 34-37 | bs_cache_data/onode/meta/other_b | §三 指标说明 |
| 38-41 | onode_hits/onode_misses/onode_shard_hits/onode_shard_misses | R.3 onode 分级（A23+ 采集） |

分析方法：按 osd_id 分组（0-5），首末采样差分（Δ），跨 6 OSD 汇总。op/read latency 用 Δsum/Δavgcount 算窗口均值。

### 6.2 node-150/151/152.csv（41 列，A16-A24）

路径：`results/.../A{16..24}/randread-A*-r1/osd/node-15*.csv`

| 列范围 | 字段 | 说明 |
|---|---|---|
| 1-4 | ts, load1/5/15 | 节点 loadavg |
| 5-10 | cpu_us/sy/wa/id/irq/softirq | CPU 各项占比（irq/softirq A23+ 新增） |
| 11-14 | rx_bytes/tx_bytes/rx_drop/tx_drop | NIC 计数器 |
| 15-19 | nvme1_read_ios/read_ticks/in_flight/io_ticks/time_in_queue | TiKV 盘（/mnt/jfs-tikv）分盘 diskstats |
| 20-24 | nvme2_*（同上 5 列） | OSD 数据盘 1 分盘 diskstats |
| 25-29 | nvme3_*（同上 5 列） | OSD 数据盘 2 分盘 diskstats |
| 30-33 | tcp_cwnd/rtt/retrans/sndq | TCP 连接聚合（dst=157/10.3.1.13） |
| 34-37 | nic_tx_dropped/tx_pause/rx_pause/rx_discards | NIC 硬件计数器 |
| 38-41 | node_memavail/memfree/cached/buffers | 节点 /proc/meminfo |

分盘 diskstats 差分方法：nvme1/2/3 各自首末差分得 Δread_ios/Δread_ticks 等。rd_ms = Δread_ticks / Δread_ios（每次读服务时间）。util% = Δio_ticks / (采样数×5×1000) × 100。

### 6.3 其他采集文件

| 文件 | 路径 | 说明 |
|---|---|---|
| load-monitor.csv（27 列） | `.../A{5..24}/randread-A*-r1/load-monitor.csv` | 157 侧 5s CSV：loadavg + CPU + NIC + mem + JuiceFS .stats（fuse_ops/obj_get/txn） |
| historic-ops-osd{0-5}.json | `.../A{7..24}/randread-A*-r1/osd/historic-ops-osd*.json` | 每轮末尾 dump_historic_ops（最近 N 个 op 阶段分解） |
| nvme-smartlog-node{150,151,152}.txt | `.../A{23..24}/randread-A*-r1/osd/nvme-smartlog-node*.txt` | NVMe smart-log（温度/throttle，A23+ 采集） |
| fio.txt + _bw.*.log | `.../A*/randread-A*-r{1,2,3}/` | fio 原始输出 + 逐秒 per-job 带宽日志（128 个文件/项） |
| weka-load.txt | `.../A*/randread-A*-r{1,2,3}/weka-load.txt` | load_pre + load_post 两点快照 |
| nic.txt | `.../A*/randread-A*-r{1,2,3}/nic.txt` | 157 侧逐秒 NIC 计数器 |
| variable-guard-baseline.txt | `.../variable-guard-baseline.txt` | A 写入的控制变量基线（OSDSET/POOLID/CRUSHMD5） |
| reproduction-contract-{A,A2-A24}.txt | `.../reproduction-contract-*.txt` | 每轮复现契约（OSD/pool/CRUSH/版本/负载） |
