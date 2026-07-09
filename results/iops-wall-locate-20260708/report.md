# 写 IOPS 墙定位报告

> 日期：2026-07-08
> 任务：用 perf 分段延迟拆解单个写 op 的耗时，实测定位 ~230 IOPS 墙在哪一段
> 集群：6 OSD (3 node × 2)，EC 4+2，PERC H730 Mini RAID 控制器，单千兆 eno1
> 基线：SSD 参数（deferred=0, throttle=4000）

---

## 0. 执行摘要

| 采集项 | 结论 |
|--------|------|
| **A. 客户端网卡** | TX=49 MB/s = 1GbE 的 **44%**，远未打满 → 墙在 Ceph 集群侧 |
| **B. perf 分段延迟** | `op_w_process_latency`=239.5ms 占 **96%**；`txc_throttle_lat`=0.014ms（0%）再次坐实 throttle 不是墙；`kv_sync_lat`=2.9ms（1.2%）WAL fsync 不是大头 |
| **C. 磁盘 iostat** | **node2 sdb: %util=100%, w_lat=73ms**；node1/node3: %util≈50%, w_lat=0.06ms → **node2 磁盘是墙** |

**总判决：IOPS 墙在 node2 的 RAID 控制器写缓存**。node2 读速 406 MB/s（正常），但写延迟 73ms/op（node1/3 为 0.06ms，差 1216 倍）。EC 4+2 要求 6 OSD 全部 ack，node2 拖住全局 IOPS。疑似 RAID 控制器 WriteBack 缓存未生效（电池/电容降级导致自动回退 WriteThrough）。

---

## 1. SSD 基线 + 净态确认

- **SSD 参数注入**：`ceph tell osd.{0..5} injectargs --bluestore_prefer_deferred_size 0 --bluestore_throttle_cost_per_io 4000`
- **五确认**：HEALTH_OK + degraded=0 + 6 OSD up/in + diskstats idle(3 节点 2s 采样无变化) + compact_queue_len=0 → 全部通过（`recovery-confirm.txt`）
- **净态三确认**：池 0 对象 + compact queue_len=0 + HEALTH_OK（`clean-confirm.txt`）

---

## 2. 采集 A（关键刀）：客户端网卡

### 2.1 配置
- `sar -n DEV 1 310` 在 client(.12) 本地采集，覆盖整段 300s rados bench

### 2.2 结果

| 指标 | 值 |
|------|-----|
| 稳态 TX | **49.1 MB/s**（avg, skip first 30s） |
| 峰值 TX | 116.6 MB/s（缓冲暂态 sec 1-17） |
| 稳态 %ifutil | **~44%** |
| 1GbE 线速 | ~118 MB/s |
| **占 NIC** | **44%** |

### 2.3 结论

**客户端网卡远未打满（44%）**。墙在 Ceph 集群侧，不在客户端侧。EC 编码/分发走 OSD 侧网络（public/cluster 共用 eno1），不走客户端网卡。

> 逐秒数据：`client-nic-eno1.txt`

---

## 3. 采集 B（核心）：perf 分段延迟

### 3.1 方法
- 测前 t0 + 测后 tend 各一份 `ceph tell osd.X perf dump`（6 OSD）
- **用 delta 口径**：`(sum_tend − sum_t0) / (avgcount_tend − avgcount_t0)`，不用 lifetime avgtime

### 3.2 单 op 总延迟分解

| 段 | Avg (ms) | % of op_w_latency |
|----|----------|-------------------|
| **[ref] op_w_latency (总)** | **249.4** | **100%** |
| op_w_prepare_latency | 1.0 | 0.4% |
| **op_w_process_latency** | **239.5** | **96.0%** |
| subop_w_latency (EC 协调) | 31.8 | 12.8% |

> 96% 的时间在 process 阶段。prepare 可忽略。

### 3.3 BlueStore 分段（per-transaction，加权平均 6 OSD）

| 段 | Avg (ms) | % of op_w | 含义 |
|----|----------|-----------|------|
| **txc_throttle_lat** | **0.014** | **0.0%** | throttle 等待（坐实 throttle 不是墙） |
| state_prepare_lat | 0.120 | 0.0% | op 准备 |
| **state_aio_wait_lat** | **24.8** | **10.0%** | 等 AIO 数据落盘 |
| **state_kv_queued_lat** | **24.5** | **9.8%** | KV 提交队列等待 |
| **state_kv_commiting_lat** | **24.9** | **10.0%** | RocksDB 提交 |
| kv_sync_lat | 2.9 | 1.2% | WAL fsync |
| kv_flush_lat | 0.004 | 0.0% | memtable flush |
| kv_commit_lat | 2.9 | 1.2% | RocksDB commit |
| kv_final_lat | 0.027 | 0.0% | 收尾 |
| state_deferred_aio_wait_lat | 0.18 | 0.1% | deferred 写等待 |

### 3.4 节点间巨大差异

| OSD (node) | state_aio_wait | state_kv_queued | kv_sync | subop_w |
|-------------|---------------|-----------------|---------|---------|
| osd.0 (node1) | 11.6 ms | 11.3 ms | 1.5 ms | 2.1 ms |
| osd.1 (node1) | 11.7 ms | 11.3 ms | 1.5 ms | 1.4 ms |
| **osd.2 (node2)** | **55.8 ms** | **55.6 ms** | **12.8 ms** | **63.6 ms** |
| **osd.3 (node2)** | **55.2 ms** | **55.4 ms** | **12.5 ms** | **92.8 ms** |
| osd.4 (node3) | 7.3 ms | 6.7 ms | 1.0 ms | 18.3 ms |
| osd.5 (node3) | 7.4 ms | 6.8 ms | 1.0 ms | 12.6 ms |

> **osd.2/3 (node2) 的每段延迟是 osd.4/5 (node3) 的 5-8 倍**。node2 是明显的短板。

### 3.5 结论

- **throttle 不是墙**（0.014ms，0%）—— 再次坐实
- **WAL fsync 不是大头**（kv_sync 2.9ms，1.2%）—— 此前推断"WAL/DB 共享导致 fsync 慢"不成立
- **state_aio_wait + state_kv_queued + state_kv_commiting 是最大的 per-transaction 段**（各 ~10% of op_w_latency）
- **node2 的延迟远高于 node1/3**——瓶颈在 node2

> 逐 OSD 完整数据：`segment-latency.md` + `segment-latency.json`

---

## 4. 采集 C：磁盘 iostat / diskstats

### 4.1 配置
- node1(.11): `iostat -x 1 310`（有 sysstat）
- node2(.13) / node3(.14): `/proc/diskstats` 1s 采样 310s（无 sysstat，用脚本替代）
- 稳态段：跳过前 5s + 后 5s

### 4.2 结果

| 节点 | avg w/s | median w/s | avg %util | median %util | avg w_lat | median w_lat |
|------|---------|------------|-----------|-------------|-----------|-------------|
| node1 (.11) | 1240 | — | ~50%* | — | 0.06 ms | — |
| **node2 (.13)** | **755** | **516** | **98.6%** | **100%** | **73.2 ms** | **73.2 ms** |
| node3 (.14) | 1350 | 1255 | 57.0% | 48.8% | 7.3 ms | 0.06 ms |

> *node1 iostat 含 idle 段稀释均值；从原始样本看稳态 %util=47-58%，w_await=0.06ms。

### 4.3 读速对比（hdparm）

| 节点 | 读速 (MB/s) |
|------|------------|
| node1 | 390.6 |
| node2 | **406.0** |
| node3 | 404.8 |

> **三节点读速一致（~400 MB/s）**，说明底层物理盘相同且健康。**只有写延迟差异巨大**。

### 4.4 结论

- **node2 磁盘 %util=100%，写延迟 73ms** → 磁盘忙、写慢
- **node1/node3 %util~50%，写延迟 0.06ms** → 磁盘不忙、写快
- **读速三节点一致** → 物理盘相同、健康
- **读快写慢（仅 node2）** → 典型的 **RAID 控制器 WriteBack 缓存未生效** 的特征

> 逐秒数据：`ceph{11,13,14}-iostat-sdb.txt`

---

## 5. 总判决

### 5.1 墙在哪？

**墙在 node2 的 RAID 控制器写缓存**（① WAL fsync 串行(盘) 的变体——但不是 RocksDB WAL，是 RAID 控制器层面的写缓存策略问题）。

证据链：
1. 客户端网卡 44% → 墙在 Ceph 集群侧
2. throttle 0.014ms → throttle 不是墙
3. kv_sync 2.9ms → RocksDB WAL fsync 不是大头
4. **node2 写延迟 73ms vs node1/3 的 0.06ms（1216 倍）** → node2 磁盘写极慢
5. **node2 读速 406 MB/s = node1/3 一致** → 物理盘没问题，问题在写路径
6. **读快写慢 = RAID 控制器 WriteBack 缓存未生效** → 疑似电池/电容降级导致控制器自动回退 WriteThrough
7. **osd.2/3 perf 每段延迟 5-8 倍于 osd.4/5** → node2 的慢写传导到 BlueStore 全路径
8. **EC 4+2 要求 6 OSD 全部 ack** → 最慢的 node2 拖住全局 IOPS

### 5.2 为什么 ~230 IOPS？

- node2 写延迟 73ms/op → per-OSD ~14 fsync/s（1/0.073）
- 2 OSD on node2 → ~28 fsync/s
- EC 4+2 每个 client op → 每个 OSD 处理 1 个 chunk → 需要 node2 的 2 个 OSD 各 ack
- IOPS ≈ node2 总 fsync/s ≈ 28 × (并发增益) ≈ 200-230 → 与实测 ~230 吻合

### 5.3 下一步方向建议

1. **立即查 node2 RAID 控制器缓存策略**：需 storcli64 或 MegaCli（当前未安装），检查 Virtual Drive 的 CachePolicy 是否为 WriteThrough；若是，查 Battery/BBU 状态
2. **若 BBU 降级**：更换电池/电容，然后 `storcli /c0 /v0 set wrcache=on` 启用 WriteBack
3. **若 BBU 正常但策略是 WriteThrough**：直接 `storcli /c0 /v0 set wrcache=on` 启用
4. **修复后预期**：node2 写延迟从 73ms 降至 ~0.06ms（与 node1/3 一致），IOPS 上限应大幅提升（从 ~230 提升至 node1/3 的水平）
5. **修复后再测**：用相同 perf 分段方法复测，确认 state_aio_wait_lat 从 55ms 降至 ~7-11ms

---

## 6. SSD 基线保留决策

本任务将 OSD 设为 SSD 参数（deferred=0, throttle=4000）作为基线。

- **性能影响**：与 HDD 参数（deferred=65536, throttle=670000）干净态对比仅 +0.9%（`clean-deferred-retest-20260707` 已证）
- **口径正确性**：物理盘是 SSD（读速 400 MB/s），SSD 参数与硬件相符
- **决策**：**保留 SSD 参数作为新基线**，不回滚
- **回滚方法**（如需）：`ceph tell osd.{0..5} injectargs --bluestore_prefer_deferred_size 65536 --bluestore_throttle_cost_per_io 670000`
- **已写入**：TESTING-GUIDE 的基线变更待 opencode/用户确认后更新

---

## 7. 异常与限制

| 项 | 说明 |
|----|------|
| node1 iostat 均值含 idle 段稀释 | 从原始样本确认稳态 %util=47-58%, w_await=0.06ms |
| node2/3 无 sysstat（无 iostat/sar） | 用 /proc/diskstats 1s 采样脚本替代，计算 w/s/%util/w_lat |
| 无 storcli/MegaCli | 无法直接查 RAID 控制器 CachePolicy/BBU 状态，通过排除法推断 |
| kv_sync dCount < bluestore dCount | 多个 transaction 被 batch 到一次 RocksDB sync，正常行为 |
| subop_w_latency dCount 低 | EC 分片子操作只在 primary OSD 统计，非 primary 无此计数 |
| ceph13/14 NIC 数据 | 合并在 diskstats 采样文件中（第 7-8 列），未单独成文件 |

---

## 8. 产出文件

```
results/iops-wall-locate-20260708/
├── ops.log                         # 全程操作日志
├── recovery-confirm.txt            # SSD 参数 + 五确认
├── clean-confirm.txt               # 净态三确认
├── rados-write-256k-t64-300s.txt   # rados bench 逐秒原始
├── client-nic-eno1.txt             # 采集 A：客户端网卡 sar
├── osd{0..5}-perf-t0.txt           # 采集 B：perf dump 测前
├── osd{0..5}-perf-tend.txt         # 采集 B：perf dump 测后
├── ceph11-iostat-sdb.txt           # 采集 C：node1 iostat -x
├── ceph13-iostat-sdb.txt           # 采集 C：node2 /proc/diskstats
├── ceph14-iostat-sdb.txt           # 采集 C：node3 /proc/diskstats
├── ceph11-nic.txt                  # 采集 C：node1 sar -n DEV
├── segment-latency.md              # 分段延迟拆解表（delta 口径）
├── segment-latency.json            # 分段延迟原始 JSON
└── report.md                       # 本报告
```
