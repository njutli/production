# randread 双峰波动源定位简报  [2026-07-26]

> 内部记录，不给外部。简明扼要记录每阶段的现象→假设→实验→结论。

---

## 阶段 0：波动源①②③（已解决）

| 波动源 | 现象 | 假设 | 实验 | 结论 |
|---|---|---|---|---|
| ① OSD 重建→CRUSH 重映射 | randread 跨轮漂移 12-37% | OSD ID 变导致 PG→OSD 映射变 | 取证脚本对比 32/32 PG 100% 变 | stable-ID 重建（destroy 保 ID），CRUSH md5 跨重建一致 |
| ② pool delete→pool_id 变 | 同次重建内漂移 -24.1% | pool_id 是 CRUSH hash 输入 | pool_id 90→92 | soft-clean（juicefs destroy 保 pool），pool_id 全程不变 |
| ③ tmpfs/RocksDB 累积 | mseqread -28.7% | 内存态逐轮累积 | soft-clean 不重启 OSD 无法重置 | soft-clean + OSD restart + compact 双指标门控 |

①②③消除后 randread CV=2.88%（02-2-G v3 验证），但全量复现发现双峰。

---

## 阶段 1：双峰确认 + 好坏轮区分（A-A10, 10 轮）

**现象**：randread 呈双峰——好峰 1444-1486（CV~1%），坏峰 1292-1307（CV~0.5%），间距 12%，中间无过渡。组内 CV<1%（轮内极稳），跨轮跳变。仅 randread 双峰，其他项连续波动或不波动。

**假设**：起点 load<20 可预测好轮（83% 准确但有反例 A8/A11）。

**实验**：A5-A6 加 load-monitor（157 侧 5s CSV）。

**结论**：157 侧 CPU idle=82%、wa=0、D=0 好坏轮完全一致 → **157 客户端不是瓶颈**。起点 load 是弱预测信号但非因果。

---

## 阶段 2：OSD 侧初步排查（A7-A10, 4 轮）

**假设**：OSD 侧 rocksdb get_latency 或 buffer hit_rate 有差异。

**实验**：A7-A10 加 osd-monitor（ceph tell perf dump 5s CSV）。

**结论**：
- get_latency 好坏轮均 ~4μs → 排除
- OSD 节点 CPU idle ~99% → 排除
- buffer hit_rate 好轮 75.0-75.7% vs 坏轮 71.6-72.2%（Spearman ρ=1.000, 9 轮零反例）→ **hit_rate 与吞吐完全单调相关**

**但 hit_rate 是因还是果？** 此时尚未确定。

---

## 阶段 3：发送侧网络假设（A11-A12, 1 好 1 坏）

**假设**：WekaIO 挤占 157↔OSD 间 100GbE，TCP 拥塞/丢包导致坏轮。

**实验**：A11/A12 加 ss -ti（TCP cwnd/retrans/rtt）+ ethtool -S（NIC tx_dropped/pause）。

**结论**：
- retrans=0、tx_dropped=0、tx_pause 增量=0 → **发送侧网络无拥塞/丢包/流控**
- cwnd 坏轮反而更高（1605 vs 576-758）→ TCP 窗口大开但 OSD 喂不满
- **发送侧假设推翻**，瓶颈在 OSD 内部产出

---

## 阶段 4：全根因层采集（A13-A15, 1 好 1 坏 + gap）

**假设**：OSD 内部某环节（throttle / op 排队 / read 尾延迟 / 客户端发不满）。

**实验**：A13-A15 加 throttle wait/getfail + op_r/op_dequeue cnt/sum + read_lat/read_wait_aio cnt/sum + JuiceFS .stats（fuse_ops / obj_get / txn）。

**结论**：
- throttle wait=0, getfail=0 → 排除
- op_dequeue 恒定 ~0.069ms → 排除
- op_r_latency 非单调（gap 轮反而最高）→ 非直接因果
- **read_lat 好轮 0.042ms vs 坏轮 0.047ms，连续单调**（非二元跳变，gap 轮取中间值）
- **Δmiss 全 7 轮恒定 205GB（工作集不漂移）**，变的只有 Δhit（522→639GB）
- **hit% 是 read_lat 的下游 proxy**（read_lat 快→180s 内更多 IO→更多重复命中→hit%↑），不是因果起点

**此处我曾误判"二元开关"和"read coalescing"**，经 Opus 复核修正：
- "二元开关"→ 实际是连续单调梯度（read_lat 0.042→0.047ms 连续）
- "read coalescing 是因"→ 实际是果（read_lat 快→更多更小落盘）

---

## 阶段 5：内存压力假设（A16-A22, 7 轮含 1 好轮）

**假设**：坏轮 hit%↓ 是 OSD 内存压力导致 cache 被压缩。

**实验**：A16-A22 加 dump_mempools（bluestore_cache_data/onode/meta/other）+ /proc/meminfo。

**结论**：
- cache_data 好坏轮均 ~0.2GB → 数据块缓存几乎不工作，不是内存压力
- 坏轮总 cache 反而更大（7.8-9.4GB vs 好轮 7.0GB）→ cache 越小 hit% 越高（逆相关）
- **内存压力假设推翻**，osd_memory_target 调参不需要

---

## 阶段 6：分盘 diskstats + smart-log（A23-A24, 1 好 1 坏）

**假设**：TiKV(nvme1) 同节点干扰 OSD(nvme2/3)；或 NVMe 盘自身服务变慢。

**实验**：A23/A24 加分盘 diskstats（nvme1/2/3 各自 read_ios/read_ticks/in_flight/io_ticks/time_in_queue）+ CPU irq/softirq + nvme smart-log。

**结论**：
- TiKV(nvme1) util<1.5% 好坏轮均空闲 → **TiKV 干扰推翻**
- rd_ms（磁盘单次读服务时间）0.137 vs 0.138ms（差 0.4%）→ **磁盘本身不慢**
- 但 OSD 盘 util 好轮 ~51% vs 坏轮 ~57%（io_ticks 多 ~6%，三节点一致）→ **额外 busy 来自非读 I/O**
- CPU irq/softirq 均为 0 → 无中断争抢
- node-150 RTT A23→A24: 1.768→1.783ms（几乎不变），A24 坏轮 RTT 比 A13 好轮还低 → **node-150 RTT 非通用区分因子**，A13/A15 差异是巧合
- smart-log：温度 29-30°C、thermal throttle=0、percentage_used=0% → 盘健康

**Opus 进一步拆解**：
- read_lat Δ=0.0053ms 中 96% 来自 aio_lat（等 AIO 返回），BlueStore 软件层（onode/buffer）排除
- onode_misses=0（100% 命中）→ onode 不参与因果
- **根因链暂定为**：OSD 数据盘上间歇性非读 I/O → 读 AIO 排队等待变长 → aio_lat↑ → read_lat↑ → 落盘次数↓ → Δhit↓ → hit%↓ → randread↓

---

## 阶段 7：非读 I/O 来源溯源 + 终局判定（A25-A26, 1 好 1 gap）

**假设**：非读 I/O 来自 Ceph 后台任务（recovery/scrub）或 NVMe 固件 GC/写回。

**实验**：A25/A26 加 write 侧 diskstats（write_ios/write_merges/write_ticks）+ smart-log 首末两点差分 + perf dump 加 op_w/recovery/subop 计数。

**结论**：
- **OSD 盘 write_ios_delta = 0**（好轮和 gap 轮都是零写 I/O）→ 额外 busy **不是写**
- **op_w_total_delta = 0**（Ceph 层零写 op）
- **recovery_ops_delta = 0, subop_w_delta = 0**（无 Ceph 后台）
- **smart-log data_units_written 前后不变**（盘内部零写活动）
- **controller_busy_time Δ=0-1**（控制器忙时几乎不变）
- **但 disk util 好轮 64.6% vs gap 轮 68.0%**（io_ticks 多 3.4%，三节点一致）

**"非读 I/O" 假设被推翻**——没有非读 I/O。write_ios=0、recovery=0、smart-log 无变化。额外的 disk busy 来自**读 I/O 自身的到达/排队模式在好坏轮间的细微差异**，导致 NVMe 控制器内部调度效率不同，io_ticks 更高但 read_ios 和 rd_ms 不变。

**终局判定**：
- 根因 = **NVMe 固件级内部调度波动**，同样的读请求、同样的单次服务时间，但控制器内部排队/调度效率间歇性波动
- host 层面无法观测（diskstats/smart-log/perf dump 均无差异）也无法控制
- **采纳好轮统计基线**（randread 中位 ~1472 ± CI，CV ~1%），接受波动不可控

---

## 当前状态（终局）

### 已排除（共 24 项）

| # | 假设 | 排除证据 | 排除轮次 |
|---|---|---|---|
| 1 | OSD 重建/CRUSH 重映射 | stable-ID + CRUSH md5 守卫 | A-A10 |
| 2 | pool delete/recreate | pool_id 全程不变 | A-A10 |
| 3 | tmpfs/RocksDB 累积 | soft-clean + OSD restart | A-A10 |
| 4 | 157 客户端 CPU/IO | idle=82%, wa=0, D=0 好坏一致 | A5-A6 |
| 5 | 起点 load 因果 | 83% 准确但有反例 | A1-A14 |
| 6 | OSD rocksdb get_latency | 好坏轮均 ~4μs | A7-A10 |
| 7 | OSD 节点 CPU/load | idle ~99% 一致 | A7-A10 |
| 8 | 发送侧 TCP/NIC 拥塞 | retrans=0, cwnd 坏轮更高, tx_dropped=0 | A11-A12 |
| 9 | throttle 限流 | wait=0, getfail=0 | A13-A15 |
| 10 | op 队列排队 | op_dequeue 恒定 ~0.069ms | A13-A15 |
| 11 | 二元开关 | read_lat 连续单调（非二元跳变） | A16-A22 |
| 12 | 工作集/访问模式漂移 | Δmiss 恒定 205GB | A16-A22 |
| 13 | OSD 内存压力 | cache_data 好坏都~0.2GB，坏轮总 cache 反而更大 | A16-A22 |
| 14 | osd_memory_target | cache 不受内存限制 | A16-A22 |
| 15 | read coalescing 配置 | coalescing 是 read_lat 变快的下游结果 | A16-A22 |
| 16 | TiKV(nvme1) 同节点干扰 | nvme1 util<1.5% 好坏均空闲 | A23-A24 |
| 17 | 磁盘单次读变慢 | rd_ms=0.137 vs 0.138ms（差 0.4%） | A23-A24 |
| 18 | CPU 中断争抢 | irq/softirq 均为 0 | A23-A24 |
| 19 | node-150 RTT 变化 | A23/A24 好坏轮间三节点 RTT 均不变 | A23-A24 |
| 20 | BlueStore 软件层（onode/buffer） | read_lat Δ 96% 来自 aio_lat，软件层排除 | A23-A24 |
| 21 | NVMe 热节流 | smart-log thermal throttle=0, temp=29°C | A23-A24 |
| 22 | OSD 盘写 I/O | write_ios_delta=0（好轮和 gap 轮均零写） | A25-A26 |
| 23 | Ceph 后台任务（recovery/scrub/subop） | recovery_ops=0, subop_w=0, op_w_delta=0 | A25-A26 |
| 24 | NVMe 盘内部写/GC | smart-log data_units_written 前后不变 | A25-A26 |

### 终局根因

**NVMe 固件级内部调度波动**。同样的读请求（read_ios 好坏轮几乎相同）、同样的单次读服务时间（rd_ms 几乎相同）、零写 I/O、零 Ceph 后台、零盘内部写活动，但 disk util 在好坏轮间差 3-7%（io_ticks 更高）。差异发生在 NVMe 控制器内部调度层——host 层面（diskstats/perf dump/smart-log）均无法观测也无法控制。

### 采纳统计基线

好轮 randread 中位 **1472 ± CI**（9 轮：A3/A5/A6/A9/A10/A12/A13/A14/A22/A23，CV ~1%），接受波动不可控，推进后续调优计划。
